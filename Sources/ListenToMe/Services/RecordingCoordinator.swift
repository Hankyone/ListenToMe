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

  private var client: (any TranscriptionClient)?
  /// Pre-connected OpenAI realtime socket so hotkey doesn't pay TLS + session.setup.
  private var standbyClient: RealtimeTranscriptionClient?
  private var standbyConfiguration: TranscriptionConfiguration?
  private var standbyTask: Task<Void, Never>?
  private var audioContinuation: AsyncStream<Data>.Continuation?
  private var audioSendTask: Task<Void, Never>?
  private var elapsedTask: Task<Void, Never>?
  private var finishTimeoutTask: Task<Void, Never>?
  private var recordingURL: URL?
  private var startedAt: Date?
  private var didFinalizeCurrentRecording = false
  private var stopRequestedWhileStarting = false
  /// When true, stop() uploads the CAF instead of waiting on a live websocket.
  private var usesBatchTranscription = false
  /// Live websocket died mid-take; mic keeps writing the CAF.
  private var liveStreamDetached = false
  /// Prevents overlapping fail/cancel/finalize paths from trashing the take.
  private var isClosingTake = false

  init(
    settings: SettingsStore,
    history: HistoryStore,
    permissions: PermissionService
  ) {
    self.settings = settings
    self.history = history
    self.permissions = permissions
  }

  func toggle() async {
    switch phase {
    case .idle, .delivered, .failed:
      await start()
    case .recording:
      await stop()
    case .connecting, .finishing:
      break
    }
  }

  func start() async {
    guard !phase.isBusy else { return }

    // Paint live UI first. Never run AppleScript / engine.start / TLS on the
    // main thread — that froze the overlay at 0:00 with a dead waveform.
    errorMessage = nil
    didFinalizeCurrentRecording = false
    stopRequestedWhileStarting = false
    isHandsFreeLocked = false
    isClosingTake = false
    liveStreamDetached = false
    usesBatchTranscription = !settings.apiProvider.supportsLiveStreaming
    liveDraft.reset()
    elapsed = 0
    levels = Array(repeating: 0.04, count: 24)
    targetApplication = captureTargetApplication()
    let now = Date()
    startedAt = now
    listenStartedAt = now
    phase = .recording
    startElapsedTimer()
    // Duck media off-main immediately (was blocking MainActor 5–8s via AppleScript).
    mediaPause.begin()
    await Task.yield()

    let languageHints = settings.normalizeLanguageTextIfNeeded()
    if languageHints.isBlocking, let message = languageHints.message {
      await failAndPreserve(message)
      return
    }

    let apiKey: String
    do {
      apiKey = try settings.loadAPIKey()
    } catch {
      await failAndPreserve(
        "The \(settings.apiProvider.title) API key could not be read. Paste it again in Setup."
      )
      return
    }
    guard !apiKey.isEmpty else {
      await failAndPreserve(
        "Paste a \(settings.apiProvider.title) API key in Setup before dictating."
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

    if !permissions.accessibilityGranted {
      permissions.openAccessibilitySettings()
      await failAndPreserve(
        "Accessibility is off, so text can’t be pasted into the focused field. Enable ListenToMe in System Settings → Privacy & Security → Accessibility, quit ListenToMe from the menu bar, reopen it, then try again."
      )
      return
    }

    do {
      let recordingURL = try history.newRecordingURL()
      self.recordingURL = recordingURL

      if usesBatchTranscription {
        try await startBatchCapture(recordingURL: recordingURL)
      } else {
        try await startLiveCapture(recordingURL: recordingURL, apiKey: apiKey)
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
    Task.detached(priority: .userInitiated) { [audioCapture] in
      try? await audioCapture.prepare(deviceUID: deviceUID)
    }
  }

  /// Awaitable warm-up used at launch so the first take can promote instantly.
  func prepareMicrophoneAndWait() async {
    permissions.refresh()
    guard permissions.microphoneGranted else { return }
    let deviceUID = settings.preferredMicrophoneUID()
    try? await audioCapture.prepare(deviceUID: deviceUID)
  }

  /// Pre-open the OpenAI realtime socket while idle (mic warm + WS warm).
  func prepareRealtimeSession() {
    guard settings.apiProvider.supportsLiveStreaming else { return }
    scheduleStandbyConnection()
  }

  /// Mic + realtime standby — call on launch and after each take.
  func prepareForNextTake() {
    prepareMicrophone()
    prepareRealtimeSession()
  }

  /// Stop that is safe to call from the hotkey release handler even while
  /// `start()` is still opening the microphone.
  func requestStop() async {
    if phase == .recording {
      // Capture may still be opening off-main; remember the release.
      if audioContinuation == nil, audioSendTask == nil {
        stopRequestedWhileStarting = true
        return
      }
      await stop()
    } else if phase == .connecting {
      stopRequestedWhileStarting = true
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
    guard phase == .recording else { return }
    phase = .finishing
    if let startedAt {
      elapsed = Date().timeIntervalSince(startedAt)
    }
    listenStartedAt = nil
    elapsedTask?.cancel()
    elapsedTask = nil

    if usesBatchTranscription {
      await stopBatchTranscription()
      return
    }

    if let remainder = await audioCapture.stop() {
      audioContinuation?.yield(remainder)
    }
    audioContinuation?.finish()
    audioContinuation = nil

    await audioSendTask?.value
    audioSendTask = nil

    do {
      try await client?.commit()
    } catch {
      await finishWithBestAvailableTranscript()
      return
    }

    // Prefer the final `completed` event, but don't leave the user hanging
    // after release when we already have live text.
    let hasLiveText =
      !partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let timeoutNs: UInt64 = hasLiveText ? 2_500_000_000 : 12_000_000_000
    finishTimeoutTask?.cancel()
    finishTimeoutTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: timeoutNs)
      guard let self, self.phase == .finishing else { return }
      await self.finishWithBestAvailableTranscript()
    }
  }

  func copyTranscript(_ text: String) {
    delivery.copy(text)
  }

  func reprocessHistoryEntry(id: UUID) async {
    guard reprocessingID == nil else { return }
    guard let entry = history.entry(id: id) else { return }

    let apiKey: String
    do {
      apiKey = try settings.loadAPIKey()
    } catch {
      errorMessage = UserFacingError.message(
        from:
          "The \(settings.apiProvider.title) API key could not be read. Paste it again in Setup."
      )
      return
    }
    guard !apiKey.isEmpty else {
      errorMessage = UserFacingError.message(
        from:
          "Paste a \(settings.apiProvider.title) API key in Setup before reprocessing."
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
        provider: settings.apiProvider,
        apiKey: apiKey,
        prompt: configuration.prompt,
        languages: configuration.languages
      )
      history.updateTranscript(id: id, transcript: text)
    } catch {
      errorMessage = UserFacingError.message(from: error.localizedDescription)
    }
  }

  private func startLiveCapture(recordingURL: URL, apiKey: String) async throws {
    var configuration = settings.transcriptionConfiguration
    configuration.targetAppName = targetApplication?.name

    let streamPair = AsyncStream<Data>.makeStream(
      bufferingPolicy: .unbounded
    )
    audioContinuation = streamPair.continuation

    // Mic first on the hardware queue — waveform is local and must not wait
    // on standby claim / websocket work.
    try await audioCapture.start(
      recordingURL: recordingURL,
      deviceUID: settings.preferredMicrophoneUID(),
      onPCMChunk: { [weak self] data in
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

    let claimed = await claimStandbyClient(matching: configuration)
    let client: RealtimeTranscriptionClient
    let needsConnect: Bool
    if let claimed {
      client = claimed
      needsConnect = false
    } else {
      client = RealtimeTranscriptionClient(apiKey: apiKey)
      needsConnect = true
    }
    self.client = client

    // Warm path: socket already session-ready → stream audio immediately.
    // Cold path: connect off MainActor while mic already feeds the waveform.
    audioSendTask = Task.detached(priority: .userInitiated) { [weak self] in
      do {
        if needsConnect {
          try await client.connect(configuration: configuration) {
            [weak self] event in
            self?.handle(event)
          }
        } else {
          await client.setEventHandler { [weak self] event in
            self?.handle(event)
          }
          Task.detached {
            try? await client.refreshSession(configuration: configuration)
          }
        }
        for await chunk in streamPair.stream {
          try Task.checkCancellation()
          try await client.appendAudio(chunk)
        }
      } catch is CancellationError {
        return
      } catch {
        await MainActor.run { [weak self] in
          self?.handleLiveStreamFailure(error.localizedDescription)
        }
      }
    }
  }

  private func claimStandbyClient(
    matching configuration: TranscriptionConfiguration
  ) async -> RealtimeTranscriptionClient? {
    guard let standby = standbyClient else { return nil }
    guard await standby.isSessionReady else {
      await standby.disconnect()
      standbyClient = nil
      standbyConfiguration = nil
      return nil
    }
    // Reuse when core settings match; target app is refreshed via session.update.
    if let standbyConfiguration,
      !Self.standbyCompatible(standbyConfiguration, configuration)
    {
      await standby.disconnect()
      standbyClient = nil
      self.standbyConfiguration = nil
      return nil
    }
    standbyClient = nil
    self.standbyConfiguration = nil
    return standby
  }

  private static func standbyCompatible(
    _ standby: TranscriptionConfiguration,
    _ live: TranscriptionConfiguration
  ) -> Bool {
    standby.basePrompt == live.basePrompt
      && standby.vocabulary == live.vocabulary
      && standby.languages == live.languages
      && standby.delay == live.delay
      && standby.micProfile == live.micProfile
  }

  private func scheduleStandbyConnection() {
    guard settings.apiProvider.supportsLiveStreaming else { return }
    standbyTask?.cancel()
    // Detached so TLS + session.updated never sit on MainActor behind a hotkey.
    standbyTask = Task.detached(priority: .utility) { [weak self] in
      await self?.refreshStandbyConnection()
    }
  }

  private func refreshStandbyConnection() async {
    guard !Task.isCancelled else { return }
    guard settings.apiProvider.supportsLiveStreaming else { return }
    // Don't fight an active take.
    switch phase {
    case .connecting, .recording, .finishing:
      return
    default:
      break
    }

    let apiKey: String
    do {
      apiKey = try settings.loadAPIKey()
    } catch {
      return
    }
    guard !apiKey.isEmpty else { return }

    let configuration = settings.transcriptionConfiguration
    if let standby = standbyClient,
      let standbyConfiguration,
      Self.standbyCompatible(standbyConfiguration, configuration),
      await standby.isSessionReady
    {
      return
    }

    if let old = standbyClient {
      await old.disconnect()
    }
    standbyClient = nil
    standbyConfiguration = nil

    let client = RealtimeTranscriptionClient(apiKey: apiKey)
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
      standbyConfiguration = configuration
    } catch {
      standbyClient = nil
      standbyConfiguration = nil
    }
  }

  private func parkClientForStandby(_ client: RealtimeTranscriptionClient) async {
    do {
      try await client.clearInputBuffer()
      await client.setEventHandler(nil)
      let configuration = settings.transcriptionConfiguration
      standbyClient = client
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
    guard let realtime = active as? RealtimeTranscriptionClient else {
      await active?.disconnect()
      scheduleStandbyConnection()
      return
    }
    await parkClientForStandby(realtime)
  }

  private func startBatchCapture(recordingURL: URL) async throws {
    try await audioCapture.start(
      recordingURL: recordingURL,
      deviceUID: settings.preferredMicrophoneUID(),
      onPCMChunk: { _ in },
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
  }

  private func stopBatchTranscription() async {
    _ = await audioCapture.stop()

    guard let recordingURL else {
      await persistFailedTake(message: "The recording file was missing.")
      return
    }

    let apiKey: String
    do {
      apiKey = try settings.loadAPIKey()
    } catch {
      await persistFailedTake(
        message:
          "The \(settings.apiProvider.title) API key could not be read. Paste it again in Setup."
      )
      return
    }

    var configuration = settings.transcriptionConfiguration
    configuration.targetAppName = targetApplication?.name

    do {
      let text = try await FileTranscriptionService.transcribe(
        audioURL: recordingURL,
        provider: settings.apiProvider,
        apiKey: apiKey,
        prompt: configuration.prompt,
        languages: configuration.languages
      )
      await finalize(transcript: text)
    } catch {
      if Self.isBenignEmptyTake(error.localizedDescription),
        !recordingFileHasAudio()
      {
        abandonQuietly()
      } else {
        await persistFailedTake(message: error.localizedDescription)
      }
    }
  }

  private func handle(_ event: TranscriptionClientEvent) {
    switch event {
    case .sessionReady:
      break

    case .delta(_, let text):
      guard phase == .recording || phase == .finishing else { return }
      liveDraft.applyDelta(text)

    case .completed(_, let transcript):
      guard phase == .recording || phase == .finishing else { return }
      // Source of truth for delivery — includes spoken "correction" rewrites.
      liveDraft.applyCompleted(transcript)
      Task {
        await finalize(transcript: transcript)
      }

    case .error(let message):
      guard phase.isBusy, !liveStreamDetached else { return }
      if phase == .recording {
        handleLiveStreamFailure(message)
        return
      }
      if Self.isBenignEmptyTake(message), !recordingFileHasAudio() {
        abandonQuietly()
      } else {
        Task { await failAndPreserve(message) }
      }
    }
  }

  private static func isBenignEmptyTake(_ message: String) -> Bool {
    let lower = message.lowercased()
    return lower.contains("no speech")
      || lower.contains("empty transcript")
      || lower.contains("no audio")
      || lower.contains("audio too short")
      || lower.contains("did not return a final transcript")
  }

  private func applyLiveSnapshot(_ snapshot: LiveTranscriptSnapshot) {
    committedTranscript = snapshot.committed
    tentativeTranscript = snapshot.tentative
    partialTranscript = snapshot.display
  }

  private func finalize(transcript: String) async {
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

    let finalText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !finalText.isEmpty, let recordingURL else {
      await recycleOrDropClient()
      if recordingFileHasAudio() {
        await persistFailedTake(message: "No transcript came back.")
      } else {
        discardCurrentRecording()
        abandonQuietly()
      }
      return
    }

    await recycleOrDropClient()

    var outcome = await delivery.deliver(finalText, to: targetApplication)
    if outcome == .copiedNoAccessibility {
      // Last-chance recovery if TCC flipped mid-session or trust was stale.
      if await permissions.ensureAccessibilityForPaste() {
        outcome = await delivery.deliver(finalText, to: targetApplication)
      } else {
        permissions.openAccessibilitySettings()
      }
    }

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

    if let recovered = await transcribePreservedRecording() {
      isClosingTake = false
      await finalize(transcript: recovered)
      return
    }

    await persistFailedTake(message: message)
  }

  private func finishWithBestAvailableTranscript() async {
    guard !didFinalizeCurrentRecording, !isClosingTake else { return }
    let live = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    if !liveStreamDetached, !live.isEmpty {
      await finalize(transcript: live)
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
    await failAndPreserve("Transcription did not finish.")
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
    if recordingFileHasAudio() {
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
    prepareForNextTake()
  }

  private func persistFailedTake(message: String) async {
    guard !didFinalizeCurrentRecording else { return }
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
    prepareForNextTake()
  }

  private func transcribePreservedRecording() async -> String? {
    guard let recordingURL, recordingFileHasAudio() else { return nil }
    let apiKey: String
    do {
      apiKey = try settings.loadAPIKey()
    } catch {
      return nil
    }
    guard !apiKey.isEmpty else { return nil }

    var configuration = settings.transcriptionConfiguration
    configuration.targetAppName = targetApplication?.name
    do {
      return try await FileTranscriptionService.transcribe(
        audioURL: recordingURL,
        provider: settings.apiProvider,
        apiKey: apiKey,
        prompt: configuration.prompt,
        languages: configuration.languages
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

  /// End a take with nothing to deliver — no banner, no "Dictation stopped".
  private func abandonQuietly() {
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil
    errorMessage = nil
    isHandsFreeLocked = false
    phase = .idle
    discardCurrentRecording()
    teardownSession()
    resetRecordingReferences()
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
    // is busy — TimelineView in the overlay is the primary display path.
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

  private func resetRecordingReferences() {
    listenStartedAt = nil
    recordingURL = nil
    startedAt = nil
    targetApplication = nil
    usesBatchTranscription = false
    liveStreamDetached = false
    isClosingTake = false
  }
}
