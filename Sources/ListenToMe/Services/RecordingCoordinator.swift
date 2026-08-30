import AppKit
import Combine
import Foundation

@MainActor
final class RecordingCoordinator: ObservableObject {
  @Published private(set) var phase: RecordingPhase = .idle
  @Published private(set) var partialTranscript = ""
  @Published private(set) var committedTranscript = ""
  @Published private(set) var tentativeTranscript = ""
  @Published private(set) var elapsed: TimeInterval = 0
  /// Wall-clock start for the overlay timer (TimelineView reads this).
  @Published private(set) var listenStartedAt: Date?
  @Published private(set) var levels: [Float] = Array(repeating: 0.04, count: 24)
  @Published private(set) var targetApplication: TargetApplication?
  /// Set when Space locks a push-to-talk hold into hands-free continuation.
  @Published private(set) var isHandsFreeLocked = false
  @Published private(set) var reprocessingID: UUID?
  @Published private(set) var isImportingAudio = false
  @Published private(set) var importingID: UUID?
  @Published var errorTitle = "Dictation stopped"
  @Published var errorMessage: String?

  var onHistoryEntryCreated: ((UUID) -> Void)?

  private let settings: SettingsStore
  private let history: HistoryStore
  private let permissions: PermissionService
  private let audioCapture = AudioCaptureService()
  private let delivery = TextDeliveryService()
  private let mediaPause = MediaPauseService()
  private lazy var liveDraft = LiveTranscriptDraft { [weak self] snapshot in
    self?.applyLiveSnapshot(snapshot)
  }

  private var client: (any ReusableTranscriptionClient)?
  /// Pre-connected provider socket so hotkey doesn't pay TLS + session setup.
  private var standbyClient: (any ReusableTranscriptionClient)?
  private var standbyProvider: TranscriptionProvider?
  private var standbyConfiguration: TranscriptionConfiguration?
  private var standbyTask: Task<Void, Never>?
  private var audioContinuation: AsyncStream<Data>.Continuation?
  private var audioSendTask: Task<Void, Never>?
  private var elapsedTask: Task<Void, Never>?
  private var finishTimeoutTask: Task<Void, Never>?
  private var recordingURL: URL?
  private var activeProvider: TranscriptionProvider?
  private var activeConfiguration: TranscriptionConfiguration?
  private var startedAt: Date?
  private var didFinalizeCurrentRecording = false
  private var stopRequestedWhileStarting = false
  /// When true, stop() uploads the CAF instead of waiting on a live websocket.
  private var usesBatchTranscription = false
  /// Live websocket died mid-take; mic keeps writing the CAF.
  private var liveStreamDetached = false
  /// Prevents overlapping fail/cancel/finalize paths from trashing the take.
  private var isClosingTake = false
  /// Bumped on start/stop so an in-flight `start()` cannot open the mic after
  /// a later press already asked to stop.
  private var takeID = 0
  /// Identity of the live socket/mic take. Survives `stop()` incrementing
  /// `takeID`, so the final transcript is not dropped.
  private var sessionTakeID = 0
  private var latency: TakeLatencyTrace?
  /// Created on key-down so overlay marks belong to the next take, not a
  /// finishing take we are about to hand off.
  private var nextTakeTrace: TakeLatencyTrace?

  init(
    settings: SettingsStore,
    history: HistoryStore,
    permissions: PermissionService
  ) {
    self.settings = settings
    self.history = history
    self.permissions = permissions
  }

  /// Sleep, dock, and USB replug leave a warm graph pointing at a dead HAL
  /// device. Tear it down and rebuild for whatever is preferred right now.
  func recoverCaptureHardware() {
    Task { [weak self] in
      guard let self else { return }
      await self.audioCapture.invalidateWarmGraph()
      self.prepareMicrophone()
    }
  }

  func toggle() async {
    if phase.isBusy {
      await dismissTake()
    } else {
      await start()
    }
  }

  func noteHotkeyPress() {
    nextTakeTrace = TakeLatencyTrace()
    nextTakeTrace?.mark("hotkey")
  }

  func markLatency(_ name: String) {
    (nextTakeTrace ?? latency)?.mark(name)
  }

  private func finishLatency(_ reason: String) {
    guard let latency else { return }
    latency.note("end", reason)
    LatencyLog.write(latency.finish())
    self.latency = nil
  }

  func start() async {
    if phase == .finishing {
      await detachFinishingTake()
    }
    guard !phase.isBusy else { return }
    if stopRequestedWhileStarting {
      stopRequestedWhileStarting = false
      finishLatency("aborted_before_start")
      nextTakeTrace = nil
      return
    }

    takeID += 1
    let id = takeID
    latency = nextTakeTrace ?? TakeLatencyTrace()
    nextTakeTrace = nil
    latency?.mark("start")

    // Paint live UI first. Never run AppleScript / engine.start / TLS on the
    // main thread  -  that froze the overlay at 0:00 with a dead waveform.
    errorTitle = "Dictation stopped"
    errorMessage = nil
    didFinalizeCurrentRecording = false
    stopRequestedWhileStarting = false
    isHandsFreeLocked = false
    isClosingTake = false
    liveStreamDetached = false
    usesBatchTranscription = false
    liveDraft.reset()
    elapsed = 0
    levels = Array(repeating: 0.04, count: 24)
    targetApplication = captureTargetApplication()
    let now = Date()
    startedAt = now
    listenStartedAt = now
    phase = .recording
    latency?.mark("ui")
    startElapsedTimer()
    let trace = latency
    mediaPause.begin {
      trace?.mark("media_pause")
    }
    await Task.yield()
    guard id == takeID else {
      await abortIncompleteStart()
      return
    }

    let provider = settings.selectedProvider
    activeProvider = provider
    let languageHints = settings.normalizeLanguageTextIfNeeded()
    if languageHints.isBlocking, let message = languageHints.message {
      await failAndPreserve(message)
      return
    }

    let apiKey: String
    do {
      apiKey = try settings.loadAPIKey(for: provider)
    } catch {
      await failAndPreserve(
        "The \(provider.title) API key could not be read. Paste it again in Setup."
      )
      return
    }
    guard !apiKey.isEmpty else {
      await failAndPreserve(
        "Paste a \(provider.title) API key in Setup before dictating."
      )
      return
    }

    permissions.refresh()
    if !permissions.microphoneGranted {
      let granted = await permissions.requestMicrophone()
      guard granted else {
        await failAndPreserve(
          "Microphone access is off. Allow it in System Settings, then try again."
        )
        return
      }
    }

    guard id == takeID else {
      await abortIncompleteStart()
      return
    }

    do {
      let recordingURL = try history.newRecordingURL()
      self.recordingURL = recordingURL
      guard id == takeID else {
        await abortIncompleteStart()
        return
      }
      if stopRequestedWhileStarting {
        await abortIncompleteStart()
        return
      }

      try await startLiveCapture(
        recordingURL: recordingURL,
        provider: provider,
        apiKey: apiKey
      )
      guard id == takeID else {
        _ = await audioCapture.stop()
        await cleanUpConnection()
        await abortIncompleteStart()
        return
      }

      if stopRequestedWhileStarting {
        stopRequestedWhileStarting = false
        await stop()
      }
    } catch {
      await cleanUpConnection()
      await failAndPreserve(error.localizedDescription)
    }
  }

  /// Warm the HAL graph so the next hotkey doesn't pay cold-start latency.
  func prepareMicrophone() {
    permissions.refresh()
    guard permissions.microphoneGranted else { return }
    let deviceUID = settings.preferredMicrophoneUID()
    let provider = settings.selectedProvider
    Task.detached(priority: .userInitiated) { [audioCapture] in
      try? await audioCapture.prepare(
        deviceUID: deviceUID,
        sampleRate: provider.liveSampleRate,
        chunkByteCount: provider.liveChunkByteCount
      )
    }
  }

  /// Awaitable warm-up used at launch so the first take can promote instantly.
  func prepareMicrophoneAndWait() async {
    permissions.refresh()
    guard permissions.microphoneGranted else { return }
    let deviceUID = settings.preferredMicrophoneUID()
    let provider = settings.selectedProvider
    try? await audioCapture.prepare(
      deviceUID: deviceUID,
      sampleRate: provider.liveSampleRate,
      chunkByteCount: provider.liveChunkByteCount
    )
  }

  /// Pre-open the selected provider's realtime socket while idle.
  func prepareRealtimeSession() {
    scheduleStandbyConnection()
  }

  /// Mic + realtime standby  -  call on launch and after each take.
  func prepareForNextTake() {
    prepareMicrophone()
    prepareRealtimeSession()
  }

  /// Gesture-driven end: hide is the caller's job. Tiny takes skip
  /// transcription; otherwise finish even if the websocket is still coming up.
  func dismissTake() async {
    let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
    if DictationGesturePolicy.shouldSkipTranscription(elapsed: elapsed) {
      stopRequestedWhileStarting = true
      takeID += 1
      switch phase {
      case .recording, .connecting:
        await abortIncompleteStart()
      case .finishing:
        await recoverToIdle()
      default:
        break
      }
      return
    }
    await requestStop()
  }

  /// Stop that is safe to call from the hotkey even while `start()` is still
  /// opening the microphone. A second press always aborts so the overlay
  /// cannot stick while the websocket is still coming up.
  func requestStop() async {
    switch RecordingStopPolicy.decision(
      phase: phase,
      hasAudioSendTask: audioSendTask != nil,
      isMicRecording: audioCapture.isRecording,
      alreadyRequestedStop: stopRequestedWhileStarting,
      usesBatchTranscription: usesBatchTranscription
    ) {
    case .markStopBeforeStart:
      stopRequestedWhileStarting = true
    case .finishAfterConnect:
      stopRequestedWhileStarting = true
    case .finishLive:
      takeID += 1
      await stop()
    case .abort:
      stopRequestedWhileStarting = true
      takeID += 1
      await abortIncompleteStart()
    case .recoverFinishing:
      await recoverToIdle()
    }
  }

  func setHandsFreeLocked(_ locked: Bool) {
    isHandsFreeLocked = locked
  }

  func cancelDictation() {
    guard phase.isBusy else { return }
    Task { await cancelPreservingAudio() }
  }

  func stop() async {
    let generation = takeID
    takeID += 1
    guard phase == .recording else { return }
    latency?.mark("stop")
    phase = .finishing
    if let startedAt {
      elapsed = Date().timeIntervalSince(startedAt)
    }
    listenStartedAt = nil
    elapsedTask?.cancel()
    elapsedTask = nil

    try? await Task.sleep(
      nanoseconds: DictationGesturePolicy.releaseTailNanoseconds
    )
    guard phase == .finishing, takeID == generation + 1 else { return }
    latency?.mark("release_tail")

    if usesBatchTranscription {
      await stopBatchTranscription()
      playStopCueIfEnabled()
      return
    }

    if let remainder = await audioCapture.stop() {
      audioContinuation?.yield(remainder)
    }
    playStopCueIfEnabled()
    guard sessionTakeID != 0, takeID == generation + 1 else { return }
    latency?.mark("mic_stopped")
    audioContinuation?.finish()
    audioContinuation = nil

    let sendTask = audioSendTask
    audioSendTask = nil
    if let sendTask {
      let timeout = Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        sendTask.cancel()
      }
      await sendTask.value
      timeout.cancel()
    }
    guard sessionTakeID != 0, takeID == generation + 1 else { return }

    do {
      try await client?.commit()
      guard sessionTakeID != 0 else { return }
      latency?.mark("commit")
    } catch {
      await finishWithBestAvailableTranscript()
      return
    }

    // Prefer the final `completed` event, but don't leave a silent tap hanging.
    let hasLiveText =
      !partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let timeoutNs: UInt64 = hasLiveText ? 1_200_000_000 : 400_000_000
    finishTimeoutTask?.cancel()
    let session = sessionTakeID
    finishTimeoutTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: timeoutNs)
      guard let self,
        self.sessionTakeID == session,
        self.phase == .finishing
      else { return }
      await self.finishWithBestAvailableTranscript()
    }
  }

  func copyTranscript(_ text: String) {
    delivery.copy(text)
  }

  func importAudio(at sourceURL: URL) async {
    guard !phase.isBusy, reprocessingID == nil, !isImportingAudio else { return }
    errorTitle = "Audio transcription failed"
    let provider = settings.selectedProvider
    let languageHints = settings.normalizeLanguageTextIfNeeded()
    if languageHints.isBlocking, let message = languageHints.message {
      errorMessage = message
      return
    }

    let apiKey: String
    do {
      apiKey = try settings.loadAPIKey(for: provider)
    } catch {
      errorMessage = "The \(provider.title) API key could not be read. Paste it again in Setup."
      return
    }
    guard !apiKey.isEmpty else {
      errorMessage = "Paste a \(provider.title) API key in Setup before importing audio."
      return
    }

    isImportingAudio = true
    errorMessage = nil
    defer {
      importingID = nil
      isImportingAudio = false
    }

    let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
    let importedURL: URL
    do {
      importedURL = try history.importRecording(from: sourceURL)
    } catch {
      if hasScopedAccess { sourceURL.stopAccessingSecurityScopedResource() }
      errorMessage = UserFacingError.message(from: error.localizedDescription)
      return
    }
    if hasScopedAccess { sourceURL.stopAccessingSecurityScopedResource() }

    let duration = HistoryStore.audioDuration(at: importedURL)
    let entryID = UUID()
    let entry = HistoryEntry(
      id: entryID,
      createdAt: Date(),
      transcript: "",
      duration: duration,
      audioFileName: importedURL.lastPathComponent,
      targetApplication: nil,
      sourceName: sourceURL.lastPathComponent,
      deliveryOutcome: .audioSaved
    )
    history.add(entry)
    importingID = entryID
    onHistoryEntryCreated?(entryID)

    let configuration = settings.transcriptionConfiguration
    do {
      let text = try await FileTranscriptionService.transcribe(
        audioURL: importedURL,
        provider: provider,
        apiKey: apiKey,
        configuration: configuration
      )
      history.completeImport(
        id: entryID,
        transcript: spokenTranscript(text, target: nil, provider: provider)
      )
    } catch {
      errorTitle = "Audio transcription failed"
      errorMessage =
        UserFacingError.message(from: error.localizedDescription)
        + " Your audio is saved in History."
    }
  }

  func reprocessHistoryEntry(id: UUID) async {
    guard reprocessingID == nil, !isImportingAudio, !phase.isBusy else { return }
    guard let entry = history.entry(id: id) else { return }

    errorTitle = "Audio transcription failed"
    let provider = settings.selectedProvider
    let apiKey: String
    do {
      apiKey = try settings.loadAPIKey(for: provider)
    } catch {
      errorMessage = UserFacingError.message(
        from:
          "The \(provider.title) API key could not be read. Paste it again in Setup."
      )
      return
    }
    guard !apiKey.isEmpty else {
      errorMessage = UserFacingError.message(
        from:
          "Paste a \(provider.title) API key in Setup before reprocessing."
      )
      return
    }

    reprocessingID = id
    defer { reprocessingID = nil }

    var configuration = settings.transcriptionConfiguration
    configuration.targetAppName = entry.targetApplication?.name

    do {
      let text = try await FileTranscriptionService.transcribe(
        audioURL: history.audioURL(for: entry),
        provider: provider,
        apiKey: apiKey,
        configuration: configuration
      )
      if entry.targetApplication == nil {
        history.completeImport(id: id, transcript: text)
      } else {
        history.updateTranscript(id: id, transcript: text)
      }
    } catch {
      errorTitle = "Audio transcription failed"
      errorMessage = UserFacingError.message(from: error.localizedDescription)
    }
  }

  private func startLiveCapture(
    recordingURL: URL,
    provider: TranscriptionProvider,
    apiKey: String
  ) async throws {
    var configuration = settings.transcriptionConfiguration
    configuration.targetAppName = targetApplication?.name
    activeConfiguration = configuration

    let streamPair = AsyncStream<Data>.makeStream(
      bufferingPolicy: .unbounded
    )
    audioContinuation = streamPair.continuation
    let trace = latency
    let captureTakeID = takeID
    sessionTakeID = captureTakeID

    try await audioCapture.start(
      recordingURL: recordingURL,
      deviceUID: settings.preferredMicrophoneUID(),
      sampleRate: provider.liveSampleRate,
      chunkByteCount: provider.liveChunkByteCount,
      onPCMChunk: { [weak self] data in
        trace?.mark("first_pcm")
        self?.audioContinuation?.yield(data)
      },
      onLevel: { [weak self] level in
        DispatchQueue.main.async {
          self?.appendLevel(level)
        }
      },
      onError: { [weak self] error in
        DispatchQueue.main.async {
          Task { await self?.failAndPreserve(error.localizedDescription) }
        }
      }
    )
    trace?.mark("mic")

    let claimed = await claimStandbyClient(
      provider: provider,
      matching: configuration
    )
    let client: any ReusableTranscriptionClient
    let needsConnect: Bool
    if let claimed {
      client = claimed
      needsConnect = false
      trace?.note("path", "warm")
      trace?.mark("socket_warm")
    } else {
      client = makeLiveClient(provider: provider, apiKey: apiKey)
      needsConnect = true
      trace?.note("path", "cold")
    }
    self.client = client

    audioSendTask = Task.detached(priority: .userInitiated) { [weak self] in
      do {
        if needsConnect {
          try await client.connect(configuration: configuration) {
            [weak self] event in
            self?.handle(event, take: captureTakeID)
          }
          trace?.mark("socket_ready")
        } else {
          await client.setEventHandler { [weak self] event in
            self?.handle(event, take: captureTakeID)
          }
          try await client.refreshSession(configuration: configuration)
          trace?.mark("session_refresh")
        }
        try await client.beginAudio()
        var sentFirst = false
        for await chunk in streamPair.stream {
          try Task.checkCancellation()
          if !sentFirst {
            sentFirst = true
            trace?.mark("first_append")
          }
          try await client.appendAudio(chunk)
        }
      } catch is CancellationError {
        return
      } catch {
        await MainActor.run { [weak self] in
          guard let self, self.sessionTakeID == captureTakeID else { return }
          self.handleLiveStreamFailure(error.localizedDescription)
        }
      }
    }
  }

  private func claimStandbyClient(
    provider: TranscriptionProvider,
    matching configuration: TranscriptionConfiguration
  ) async -> (any ReusableTranscriptionClient)? {
    guard let standby = standbyClient else { return nil }
    guard standbyProvider == provider else {
      await standby.disconnect()
      standbyClient = nil
      standbyProvider = nil
      standbyConfiguration = nil
      return nil
    }
    guard await standby.isSessionReady else {
      await standby.disconnect()
      standbyClient = nil
      standbyProvider = nil
      standbyConfiguration = nil
      return nil
    }
    // Reuse when core settings match; target app is refreshed via session.update.
    if let standbyConfiguration,
      !Self.standbyCompatible(
        standbyConfiguration,
        configuration,
        provider: provider
      )
    {
      await standby.disconnect()
      standbyClient = nil
      standbyProvider = nil
      self.standbyConfiguration = nil
      return nil
    }
    standbyClient = nil
    standbyProvider = nil
    self.standbyConfiguration = nil
    return standby
  }

  private static func standbyCompatible(
    _ standby: TranscriptionConfiguration,
    _ live: TranscriptionConfiguration,
    provider: TranscriptionProvider
  ) -> Bool {
    switch provider {
    case .openAI:
      return standby.basePrompt == live.basePrompt
        && standby.vocabulary == live.vocabulary
        && standby.languages == live.languages
        && standby.delay == live.delay
        && standby.micProfile == live.micProfile
    case .gemini:
      return standby.keywords == live.keywords
        && standby.languages == live.languages
    }
  }

  private func makeLiveClient(
    provider: TranscriptionProvider,
    apiKey: String
  ) -> any ReusableTranscriptionClient {
    switch provider {
    case .openAI: RealtimeTranscriptionClient(apiKey: apiKey)
    case .gemini: GeminiLiveTranscriptionClient(apiKey: apiKey)
    }
  }

  private func scheduleStandbyConnection() {
    standbyTask?.cancel()
    // Detached so TLS + session.updated never sit on MainActor behind a hotkey.
    standbyTask = Task.detached(priority: .utility) { [weak self] in
      await self?.refreshStandbyConnection()
    }
  }

  private func refreshStandbyConnection() async {
    guard !Task.isCancelled else { return }
    // Don't fight an active take.
    switch phase {
    case .connecting, .recording, .finishing:
      return
    default:
      break
    }

    let apiKey: String
    do {
      apiKey = try settings.loadAPIKey(for: settings.selectedProvider)
    } catch {
      return
    }
    guard !apiKey.isEmpty else { return }

    let configuration = settings.transcriptionConfiguration
    let provider = settings.selectedProvider
    if let standby = standbyClient,
      standbyProvider == provider,
      let standbyConfiguration,
      Self.standbyCompatible(
        standbyConfiguration,
        configuration,
        provider: provider
      ),
      await standby.isSessionReady
    {
      return
    }

    if let old = standbyClient {
      await old.disconnect()
    }
    standbyClient = nil
    standbyProvider = nil
    standbyConfiguration = nil

    let client = makeLiveClient(provider: provider, apiKey: apiKey)
    do {
      // Noop handler until a take claims this socket.
      try await client.connect(configuration: configuration) { _ in }
      guard !Task.isCancelled else {
        await client.disconnect()
        return
      }
      // Another take may have started while we connected.
      switch phase {
      case .connecting, .recording, .finishing:
        await client.disconnect()
        return
      default:
        break
      }
      standbyClient = client
      standbyProvider = provider
      standbyConfiguration = configuration
    } catch {
      standbyClient = nil
      standbyProvider = nil
      standbyConfiguration = nil
    }
  }

  private func parkClientForStandby(
    _ client: any ReusableTranscriptionClient,
    provider: TranscriptionProvider,
    configuration: TranscriptionConfiguration
  ) async {
    do {
      try await client.clearInputBuffer()
      await client.setEventHandler(nil)
      standbyClient = client
      standbyProvider = provider
      standbyConfiguration = configuration
    } catch {
      await client.disconnect()
      scheduleStandbyConnection()
    }
  }

  private func recycleOrDropClient() async {
    audioSendTask?.cancel()
    audioSendTask = nil
    audioContinuation?.finish()
    audioContinuation = nil

    let active = client
    client = nil
    guard let active,
      let provider = activeProvider,
      let configuration = activeConfiguration
    else {
      await active?.disconnect()
      scheduleStandbyConnection()
      return
    }
    await parkClientForStandby(
      active,
      provider: provider,
      configuration: configuration
    )
  }

  private func stopBatchTranscription() async {
    _ = await audioCapture.stop()
    latency?.mark("mic_stopped")
    latency?.note("fallback", "file")

    guard let recordingURL else {
      await persistFailedTake(message: "The recording file was missing.")
      return
    }

    let provider = activeProvider ?? settings.selectedProvider
    let apiKey: String
    do {
      apiKey = try settings.loadAPIKey(for: provider)
    } catch {
      await persistFailedTake(
        message:
          "The \(provider.title) API key could not be read. Paste it again in Setup."
      )
      return
    }

    var configuration = settings.transcriptionConfiguration
    configuration.targetAppName = targetApplication?.name

    do {
      latency?.mark("file_transcribe")
      let text = try await FileTranscriptionService.transcribe(
        audioURL: recordingURL,
        provider: provider,
        apiKey: apiKey,
        configuration: configuration
      )
      latency?.mark("completed")
      await finalize(
        transcript: spokenTranscript(
          text,
          target: targetApplication,
          provider: provider
        )
      )
    } catch {
      if !EmptyTakePolicy.shouldShowFailure(
        message: error.localizedDescription,
        hasTranscript: hasLiveTranscript,
        hadSpeech: takeHadSpeechEnergy()
      ) {
        abandonQuietly()
      } else {
        await persistFailedTake(message: error.localizedDescription)
      }
    }
  }

  private func handle(_ event: TranscriptionClientEvent, take: Int) {
    guard take == sessionTakeID else { return }
    switch event {
    case .sessionReady:
      latency?.mark("session_ready")

    case .connectionInterrupted:
      guard phase == .recording || phase == .finishing else { return }
      latency?.note("live_recovery", "started")
      usesBatchTranscription = true

    case .connectionRecovered(let resumed):
      guard phase == .recording || phase == .finishing else { return }
      latency?.note("live_recovery", resumed ? "resumed" : "fresh")
      // The live text remains useful feedback, but the whole CAF is the
      // authoritative final source after any socket rollover.
      usesBatchTranscription = true
      if !resumed {
        liveDraft.beginNewInterimSegment()
      }

    case .delta(_, let text):
      guard phase == .recording || phase == .finishing else { return }
      latency?.mark("first_text")
      liveDraft.applyDelta(text)

    case .interim(let text):
      guard phase == .recording || phase == .finishing else { return }
      latency?.mark("first_text")
      liveDraft.applyInterim(text)

    case .completed(_, let transcript):
      guard phase == .recording || phase == .finishing else { return }
      latency?.mark("completed")
      liveDraft.applyCompleted(transcript)
      if usesBatchTranscription {
        if phase == .finishing {
          Task { await self.finishWithBestAvailableTranscript() }
        }
        return
      }
      Task {
        await self.finalize(transcript: transcript, take: take)
      }

    case .error(let message):
      guard phase.isBusy, !liveStreamDetached else { return }
      if phase == .recording {
        handleLiveStreamFailure(message)
        return
      }
      if !EmptyTakePolicy.shouldShowFailure(
        message: message,
        hasTranscript: hasLiveTranscript,
        hadSpeech: takeHadSpeechEnergy()
      ) {
        abandonQuietly()
      } else {
        Task { await failAndPreserve(message) }
      }
    }
  }

  private func applyLiveSnapshot(_ snapshot: LiveTranscriptSnapshot) {
    committedTranscript = snapshot.committed
    tentativeTranscript = snapshot.tentative
    partialTranscript = snapshot.display
  }

  private func finalize(transcript: String, take: Int? = nil) async {
    if let take, take != sessionTakeID { return }
    guard !didFinalizeCurrentRecording else { return }
    didFinalizeCurrentRecording = true
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil
    elapsedTask?.cancel()
    elapsedTask = nil

    if phase == .recording {
      if let remainder = await audioCapture.stop() {
        audioContinuation?.yield(remainder)
      }
      audioContinuation?.finish()
      audioContinuation = nil
      await audioSendTask?.value
      audioSendTask = nil
    }

    let finalText = spokenTranscript(
      transcript,
      target: targetApplication,
      provider: activeProvider ?? settings.selectedProvider
    )
    guard !finalText.isEmpty, let recordingURL else {
      await recycleOrDropClient()
      discardCurrentRecording()
      abandonQuietly()
      return
    }

    await recycleOrDropClient()

    latency?.mark("paste")
    let outcome = await delivery.deliver(finalText, to: targetApplication)

    let duration = max(0, Date().timeIntervalSince(startedAt ?? Date()))
    let entry = HistoryEntry(
      id: UUID(),
      createdAt: Date(),
      transcript: finalText,
      duration: duration,
      audioFileName: recordingURL.lastPathComponent,
      targetApplication: targetApplication,
      deliveryOutcome: outcome
    )
    history.add(entry)
    onHistoryEntryCreated?(entry.id)
    latency?.mark("pasted")
    finishLatency("delivered")

    liveDraft.applyCompleted(finalText)
    isHandsFreeLocked = false
    mediaPause.end()

    if outcome == .copiedNoAccessibility {
      errorMessage =
        "Transcript is on the clipboard, but paste access is off. Enable ListenToMe under Accessibility, quit and reopen this app, then paste with ⌘V or dictate again."
      phase = .failed
      resetRecordingReferences()
      prepareForNextTake()
      return
    }

    phase = .delivered(outcome)
    resetRecordingReferences()
    prepareForNextTake()

    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      guard let self else { return }
      if case .delivered = self.phase {
        self.phase = .idle
      }
    }
  }

  /// Live STT died while the user is still talking. Keep the mic and CAF;
  /// transcribe the file when they stop.
  private func handleLiveStreamFailure(_ message: String) {
    if liveStreamDetached { return }
    if phase == .recording {
      detachLiveTranscription()
      return
    }
    Task { await failAndPreserve(message) }
  }

  private func detachLiveTranscription() {
    liveStreamDetached = true
    usesBatchTranscription = true
    latency?.note("live", "detached")
    audioContinuation?.finish()
    audioContinuation = nil
    audioSendTask?.cancel()
    audioSendTask = nil
    let active = client
    client = nil
    Task {
      await active?.disconnect()
    }
  }

  private func failAndPreserve(_ message: String) async {
    guard !didFinalizeCurrentRecording, !isClosingTake else { return }
    isClosingTake = true
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil
    if phase == .recording {
      phase = .finishing
    }

    await stopCapturePreservingFile()
    await recycleOrDropClient()

    let hadSpeech = takeHadSpeechEnergy()
    if !EmptyTakePolicy.shouldShowFailure(
      message: message,
      hasTranscript: hasLiveTranscript,
      hadSpeech: hadSpeech
    ) {
      isClosingTake = false
      abandonQuietly()
      return
    }

    if hasLiveTranscript || hadSpeech,
      let recovered = await transcribePreservedRecording()
    {
      isClosingTake = false
      await finalize(transcript: recovered)
      return
    }

    await persistFailedTake(message: message)
  }

  private func finishWithBestAvailableTranscript() async {
    guard !didFinalizeCurrentRecording, !isClosingTake else { return }
    let live = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    if !usesBatchTranscription, !liveStreamDetached, !live.isEmpty {
      await finalize(transcript: live)
      return
    }
    if live.isEmpty, !usesBatchTranscription {
      abandonQuietly()
      return
    }
    if let recovered = await transcribePreservedRecording() {
      await finalize(transcript: recovered)
      return
    }
    if !live.isEmpty {
      await finalize(transcript: live)
      return
    }
    abandonQuietly()
  }

  private func cancelPreservingAudio() async {
    guard phase.isBusy, !didFinalizeCurrentRecording, !isClosingTake else { return }
    isClosingTake = true
    stopRequestedWhileStarting = false
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil
    await stopCapturePreservingFile()
    await recycleOrDropClient()

    let partial = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    if !partial.isEmpty {
      delivery.copy(partial)
    }
    if recordingFileHasAudio(), hasLiveTranscript || takeHadSpeechEnergy() {
      saveHistoryPreservingAudio(
        transcript: partial,
        outcome: .audioSaved
      )
    } else {
      discardCurrentRecording()
    }

    didFinalizeCurrentRecording = true
    liveDraft.reset()
    errorMessage = nil
    isHandsFreeLocked = false
    phase = .idle
    teardownSession()
    resetRecordingReferences()
    finishLatency("cancel")
    prepareForNextTake()
  }

  private func persistFailedTake(message: String) async {
    guard !didFinalizeCurrentRecording else { return }
    if !EmptyTakePolicy.shouldShowFailure(
      message: message,
      hasTranscript: hasLiveTranscript,
      hadSpeech: takeHadSpeechEnergy()
    ) {
      abandonQuietly()
      return
    }
    didFinalizeCurrentRecording = true
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil

    await stopCapturePreservingFile()
    await recycleOrDropClient()

    let partial = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    if !partial.isEmpty {
      delivery.copy(partial)
    }

    let saved = recordingFileHasAudio()
    if saved {
      saveHistoryPreservingAudio(transcript: partial, outcome: .audioSaved)
      let mapped = UserFacingError.message(from: message)
      errorMessage =
        mapped.localizedCaseInsensitiveContains("history")
        ? mapped
        : mapped + " Your audio is saved in History."
    } else {
      discardCurrentRecording()
      errorMessage = UserFacingError.message(from: message)
    }

    isHandsFreeLocked = false
    phase = .failed
    teardownSession()
    resetRecordingReferences()
    finishLatency("failed")
    prepareForNextTake()
  }

  private func spokenTranscript(
    _ transcript: String,
    target: TargetApplication?,
    provider: TranscriptionProvider
  ) -> String {
    var configuration = settings.transcriptionConfiguration
    configuration.targetAppName = target?.name
    return TranscriptSanitizer.spokenText(
      from: transcript,
      prompt: provider == .openAI ? configuration.prompt : ""
    )
  }

  private func transcribePreservedRecording() async -> String? {
    guard let recordingURL, recordingFileHasAudio() else { return nil }
    return await transcribeRecording(
      at: recordingURL,
      target: targetApplication,
      provider: activeProvider ?? settings.selectedProvider,
      trace: latency
    )
  }

  private func transcribeRecording(
    at url: URL,
    target: TargetApplication?,
    provider: TranscriptionProvider,
    trace: TakeLatencyTrace?
  ) async -> String? {
    guard HistoryStore.hasPreservableAudio(at: url) else { return nil }
    let apiKey: String
    do {
      apiKey = try settings.loadAPIKey(for: provider)
    } catch {
      return nil
    }
    guard !apiKey.isEmpty else { return nil }

    var configuration = settings.transcriptionConfiguration
    configuration.targetAppName = target?.name
    do {
      trace?.mark("file_transcribe")
      return try await FileTranscriptionService.transcribe(
        audioURL: url,
        provider: provider,
        apiKey: apiKey,
        configuration: configuration
      )
    } catch {
      return nil
    }
  }

  @discardableResult
  private func saveHistoryPreservingAudio(
    transcript: String,
    outcome: DeliveryOutcome
  ) -> UUID? {
    guard let recordingURL, recordingFileHasAudio() else { return nil }
    let duration = max(0, Date().timeIntervalSince(startedAt ?? Date()))
    let entry = HistoryEntry(
      id: UUID(),
      createdAt: Date(),
      transcript: transcript,
      duration: duration,
      audioFileName: recordingURL.lastPathComponent,
      targetApplication: targetApplication,
      deliveryOutcome: outcome
    )
    history.add(entry)
    onHistoryEntryCreated?(entry.id)
    return entry.id
  }

  private func stopCapturePreservingFile() async {
    if audioCapture.isRecording {
      _ = await audioCapture.stop()
    }
    audioContinuation?.finish()
    audioContinuation = nil
    audioSendTask?.cancel()
    audioSendTask = nil
  }

  private func recordingFileHasAudio() -> Bool {
    guard let recordingURL else { return false }
    return HistoryStore.hasPreservableAudio(at: recordingURL)
  }

  private var hasLiveTranscript: Bool {
    !partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Waveform floor is 0.04; anything clearly above that is real input.
  private func takeHadSpeechEnergy() -> Bool {
    levels.contains { $0 >= 0.18 }
  }

  /// The previous take is still committing/pasting. Peel it off so a new
  /// press can open the mic immediately instead of playing another stop.
  private func detachFinishingTake() async {
    takeID += 1
    sessionTakeID = 0
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil
    elapsedTask?.cancel()
    elapsedTask = nil
    listenStartedAt = nil
    stopRequestedWhileStarting = false
    isClosingTake = false
    isHandsFreeLocked = false
    if audioCapture.isRecording {
      _ = await audioCapture.stop()
    }

    let take = DetachedTake(
      recordingURL: recordingURL,
      transcript: partialTranscript,
      startedAt: startedAt,
      targetApplication: targetApplication,
      provider: activeProvider ?? settings.selectedProvider,
      latency: latency,
      client: client
    )
    latency?.note("handoff", "1")
    latency = nil
    client = nil
    audioContinuation?.finish()
    audioContinuation = nil
    audioSendTask?.cancel()
    audioSendTask = nil
    didFinalizeCurrentRecording = true
    recordingURL = nil
    startedAt = nil
    targetApplication = nil
    usesBatchTranscription = false
    liveStreamDetached = false
    liveDraft.reset()
    phase = .idle

    Task { [weak self] in
      await self?.deliverDetachedTake(take)
    }
  }

  private func deliverDetachedTake(_ take: DetachedTake) async {
    let client = take.client
    Task {
      await client?.disconnect()
    }

    var text = spokenTranscript(
      take.transcript,
      target: take.targetApplication,
      provider: take.provider
    )
    let elapsed = take.startedAt.map { Date().timeIntervalSince($0) } ?? 0
    if text.isEmpty,
      elapsed >= DictationGesturePolicy.minTranscribeDuration,
      let url = take.recordingURL,
      HistoryStore.hasPreservableAudio(at: url),
      let recovered = await transcribeRecording(
        at: url,
        target: take.targetApplication,
        provider: take.provider,
        trace: take.latency
      )
    {
      text = spokenTranscript(
        recovered,
        target: take.targetApplication,
        provider: take.provider
      )
    }

    guard let recordingURL = take.recordingURL else {
      take.latency?.note("end", "abandon")
      if let latency = take.latency {
        LatencyLog.write(latency.finish())
      }
      return
    }

    if text.isEmpty {
      if HistoryStore.hasPreservableAudio(at: recordingURL) {
        let duration = max(0, Date().timeIntervalSince(take.startedAt ?? Date()))
        let entry = HistoryEntry(
          id: UUID(),
          createdAt: Date(),
          transcript: "",
          duration: duration,
          audioFileName: recordingURL.lastPathComponent,
          targetApplication: take.targetApplication,
          deliveryOutcome: .audioSaved
        )
        history.add(entry)
        onHistoryEntryCreated?(entry.id)
        take.latency?.note("end", "failed")
      } else {
        take.latency?.note("end", "abandon")
      }
      if let latency = take.latency {
        LatencyLog.write(latency.finish())
      }
      return
    }

    take.latency?.mark("completed")
    take.latency?.mark("paste")
    let outcome = await delivery.deliver(text, to: take.targetApplication)
    let duration = max(0, Date().timeIntervalSince(take.startedAt ?? Date()))
    let entry = HistoryEntry(
      id: UUID(),
      createdAt: Date(),
      transcript: text,
      duration: duration,
      audioFileName: recordingURL.lastPathComponent,
      targetApplication: take.targetApplication,
      deliveryOutcome: outcome
    )
    history.add(entry)
    onHistoryEntryCreated?(entry.id)
    take.latency?.mark("pasted")
    take.latency?.note("end", "delivered")
    if let latency = take.latency {
      LatencyLog.write(latency.finish())
    }
  }

  /// Drop a hung `.finishing` take so the next `start()` can run.
  private func recoverToIdle() async {
    takeID += 1
    sessionTakeID = 0
    stopRequestedWhileStarting = false
    isClosingTake = false
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil
    elapsedTask?.cancel()
    elapsedTask = nil

    await stopCapturePreservingFile()
    await recycleOrDropClient()

    if !didFinalizeCurrentRecording {
      let live = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
      if !live.isEmpty {
        await finalize(transcript: live)
        return
      }
      if recordingFileHasAudio(), hasLiveTranscript {
        await persistFailedTake(
          message: "The take stopped while transcription was recovering."
        )
        return
      }
    }

    if phase.isBusy {
      abandonQuietly()
    }
    finishLatency("recover")
  }

  /// `start()` lost the race to a later stop/press. Drop the half-open take
  /// so the hotkey is not stuck in `.recording`.
  private func abortIncompleteStart() async {
    guard phase == .recording || phase == .connecting,
      !didFinalizeCurrentRecording
    else { return }
    let recordedDuration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
    if recordedDuration >= DictationGesturePolicy.minTranscribeDuration,
      recordingFileHasAudio(),
      hasLiveTranscript
    {
      stopRequestedWhileStarting = false
      await persistFailedTake(
        message: "The take stopped before live transcription finished starting."
      )
      return
    }
    mediaPause.end()
    elapsedTask?.cancel()
    elapsedTask = nil
    listenStartedAt = nil
    isHandsFreeLocked = false
    stopRequestedWhileStarting = false
    sessionTakeID = 0
    phase = .idle
    discardCurrentRecording()
    teardownSession()
    resetRecordingReferences()
    playStopCueIfEnabled()
    finishLatency("aborted")
    prepareForNextTake()
  }

  /// End a take with nothing to deliver  -  no banner, no "Dictation stopped".
  private func abandonQuietly() {
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil
    didFinalizeCurrentRecording = true
    isClosingTake = false
    errorMessage = nil
    isHandsFreeLocked = false
    phase = .idle
    discardCurrentRecording()
    teardownSession()
    resetRecordingReferences()
    finishLatency("abandon")
    prepareForNextTake()
  }

  private func teardownSession() {
    elapsedTask?.cancel()
    elapsedTask = nil
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil
    mediaPause.end()

    audioContinuation?.finish()
    audioContinuation = nil
    audioSendTask?.cancel()
    audioSendTask = nil

    let client = self.client
    self.client = nil
    Task {
      await audioCapture.cancel()
      await client?.disconnect()
    }
  }

  private func cleanUpConnection() async {
    audioContinuation?.finish()
    audioContinuation = nil
    audioSendTask?.cancel()
    audioSendTask = nil
    await client?.disconnect()
    client = nil
  }

  private func captureTargetApplication() -> TargetApplication? {
    guard let application = NSWorkspace.shared.frontmostApplication else {
      return nil
    }
    if let ownBundleIdentifier = Bundle.main.bundleIdentifier,
      application.bundleIdentifier == ownBundleIdentifier
    {
      return nil
    }
    return TargetApplication(application: application)
  }

  private func appendLevel(_ level: Float) {
    levels.append(max(0.04, level))
    if levels.count > 24 {
      levels.removeFirst(levels.count - 24)
    }
  }

  private func startElapsedTimer() {
    elapsedTask?.cancel()
    // Prefer a RunLoop timer so ticks keep landing even when Swift concurrency
    // is busy  -  TimelineView in the overlay is the primary display path.
    elapsedTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard let self, let startedAt = self.startedAt else { return }
        self.elapsed = Date().timeIntervalSince(startedAt)
      }
    }
  }

  private func discardCurrentRecording() {
    guard let recordingURL,
      FileManager.default.fileExists(atPath: recordingURL.path)
    else {
      self.recordingURL = nil
      return
    }
    _ = try? FileManager.default.trashItem(
      at: recordingURL,
      resultingItemURL: nil
    )
    self.recordingURL = nil
  }

  private func playStopCueIfEnabled() {
    guard settings.playDictationSounds else { return }
    DictationSoundService.shared.playStop()
  }

  private func resetRecordingReferences() {
    listenStartedAt = nil
    recordingURL = nil
    startedAt = nil
    targetApplication = nil
    activeProvider = nil
    activeConfiguration = nil
    usesBatchTranscription = false
    liveStreamDetached = false
    isClosingTake = false
  }
}

private struct DetachedTake {
  var recordingURL: URL?
  var transcript: String
  var startedAt: Date?
  var targetApplication: TargetApplication?
  var provider: TranscriptionProvider
  var latency: TakeLatencyTrace?
  var client: (any ReusableTranscriptionClient)?
}
