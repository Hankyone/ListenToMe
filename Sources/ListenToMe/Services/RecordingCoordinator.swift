import AppKit
import Combine
import Foundation

@MainActor
final class RecordingCoordinator: ObservableObject {
  @Published private(set) var phase: RecordingPhase = .idle
  @Published private(set) var partialTranscript = ""
  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var levels: [Float] = Array(repeating: 0.04, count: 24)
  @Published private(set) var targetApplication: TargetApplication?
  @Published var errorMessage: String?

  var onHistoryEntryCreated: ((UUID) -> Void)?

  private let settings: SettingsStore
  private let history: HistoryStore
  private let permissions: PermissionService
  private let audioCapture = AudioCaptureService()
  private let delivery = TextDeliveryService()

  private var client: (any TranscriptionClient)?
  private var audioContinuation: AsyncStream<Data>.Continuation?
  private var audioSendTask: Task<Void, Never>?
  private var elapsedTask: Task<Void, Never>?
  private var finishTimeoutTask: Task<Void, Never>?
  private var recordingURL: URL?
  private var startedAt: Date?
  private var didFinalizeCurrentRecording = false
  private var stopRequestedWhileStarting = false

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

    errorMessage = nil
    didFinalizeCurrentRecording = false
    stopRequestedWhileStarting = false
    partialTranscript = ""
    elapsed = 0
    levels = Array(repeating: 0.04, count: 24)

    let apiKey: String
    do {
      apiKey = try settings.loadAPIKey()
    } catch {
      fail("The OpenAI API key could not be read from Keychain.")
      return
    }
    guard !apiKey.isEmpty else {
      fail("Add an OpenAI API key in Setup before dictating.")
      return
    }
    let client = RealtimeTranscriptionClient(apiKey: apiKey)

    permissions.refresh()
    if !permissions.microphoneGranted {
      phase = .connecting
      let granted = await permissions.requestMicrophone()
      guard granted else {
        fail("Microphone access is off. Allow it in System Settings, then try again.")
        return
      }
    }

    targetApplication = captureTargetApplication()

    // The microphone opens first so speech is never missed. Captured audio
    // buffers in the stream while the OpenAI session opens alongside it.
    do {
      let recordingURL = try history.newRecordingURL()
      self.recordingURL = recordingURL
      startedAt = Date()
      self.client = client

      let streamPair = AsyncStream<Data>.makeStream()
      audioContinuation = streamPair.continuation

      var configuration = settings.transcriptionConfiguration
      configuration.targetAppName = targetApplication?.name

      audioSendTask = Task { [weak self] in
        do {
          try await client.connect(configuration: configuration) {
            [weak self] event in
            self?.handle(event)
          }
          for await chunk in streamPair.stream {
            try Task.checkCancellation()
            try await client.appendAudio(chunk)
          }
        } catch is CancellationError {
          return
        } catch {
          await MainActor.run { [weak self] in
            self?.fail(error.localizedDescription)
          }
        }
      }

      try audioCapture.start(
        recordingURL: recordingURL,
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
            self?.fail(error.localizedDescription)
          }
        }
      )

      phase = .recording
      startElapsedTimer()

      if stopRequestedWhileStarting {
        stopRequestedWhileStarting = false
        await stop()
      }
    } catch {
      await cleanUpConnection()
      discardCurrentRecording()
      fail(error.localizedDescription)
    }
  }

  /// Stop that is safe to call from the hotkey release handler even while
  /// `start()` is still opening the microphone.
  func requestStop() async {
    if phase == .recording {
      await stop()
    } else if phase == .connecting {
      stopRequestedWhileStarting = true
    }
  }

  func cancelDictation() {
    guard phase.isBusy else { return }
    stopRequestedWhileStarting = false
    didFinalizeCurrentRecording = true
    teardownSession()
    partialTranscript = ""
    phase = .idle
    resetRecordingReferences()
  }

  func stop() async {
    guard phase == .recording else { return }
    phase = .finishing
    elapsedTask?.cancel()
    elapsedTask = nil

    if let remainder = audioCapture.stop() {
      audioContinuation?.yield(remainder)
    }
    audioContinuation?.finish()
    audioContinuation = nil

    await audioSendTask?.value
    audioSendTask = nil

    do {
      try await client?.commit()
    } catch {
      if partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        fail("OpenAI did not receive the end of this recording.")
      } else {
        await finalize(transcript: partialTranscript)
      }
      return
    }

    finishTimeoutTask?.cancel()
    finishTimeoutTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 20_000_000_000)
      guard let self, self.phase == .finishing else { return }
      let fallback = self.partialTranscript
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if fallback.isEmpty {
        self.fail("OpenAI did not return a final transcript.")
      } else {
        await self.finalize(transcript: fallback)
      }
    }
  }

  func copyTranscript(_ text: String) {
    delivery.copy(text)
  }

  private func handle(_ event: TranscriptionClientEvent) {
    switch event {
    case .sessionReady:
      break

    case .delta(let text):
      guard phase == .recording || phase == .finishing else { return }
      partialTranscript += text

    case .completed(let transcript):
      guard phase == .recording || phase == .finishing else { return }
      Task {
        await finalize(transcript: transcript)
      }

    case .error(let message):
      guard phase.isBusy else { return }
      fail(message)
    }
  }

  private func finalize(transcript: String) async {
    guard !didFinalizeCurrentRecording else { return }
    didFinalizeCurrentRecording = true
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil
    elapsedTask?.cancel()
    elapsedTask = nil

    if phase == .recording {
      if let remainder = audioCapture.stop() {
        audioContinuation?.yield(remainder)
      }
      audioContinuation?.finish()
      audioContinuation = nil
      await audioSendTask?.value
      audioSendTask = nil
    }

    let finalText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !finalText.isEmpty, let recordingURL else {
      await cleanUpConnection()
      discardCurrentRecording()
      fail("No speech was found in that recording.")
      return
    }

    await client?.disconnect()
    client = nil

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

    partialTranscript = finalText
    phase = .delivered(outcome)
    resetRecordingReferences()

    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      guard let self else { return }
      if case .delivered = self.phase {
        self.phase = .idle
      }
    }
  }

  private func fail(_ message: String) {
    guard phase != .failed else { return }
    errorMessage = message
    phase = .failed
    teardownSession()
    resetRecordingReferences()
  }

  private func teardownSession() {
    elapsedTask?.cancel()
    elapsedTask = nil
    finishTimeoutTask?.cancel()
    finishTimeoutTask = nil

    audioCapture.cancel()
    audioContinuation?.finish()
    audioContinuation = nil
    audioSendTask?.cancel()
    audioSendTask = nil
    discardCurrentRecording()

    let client = self.client
    self.client = nil
    Task {
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
    recordingURL = nil
    startedAt = nil
    targetApplication = nil
  }
}
