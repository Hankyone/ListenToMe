import Foundation

actor RealtimeTranscriptionClient: ReusableTranscriptionClient {
  static let transcriptionModel = "gpt-live-transcribe"
  static let connectionURL = URL(
    string: "wss://api.openai.com/v1/realtime?intent=transcription"
  )

  enum ClientError: LocalizedError {
    case invalidURL
    case notConnected
    case invalidEvent
    case connectionTimedOut
    case serverRejected(String)

    var errorDescription: String? {
      switch self {
      case .invalidURL: "The OpenAI realtime address is invalid."
      case .notConnected: "The OpenAI realtime connection is not ready."
      case .invalidEvent: "A realtime message could not be encoded."
      case .connectionTimedOut:
        "OpenAI did not finish opening the live transcription session."
      case .serverRejected(let message):
        message
      }
    }
  }

  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var readyTimeoutTask: Task<Void, Never>?
  private var eventHandler: (@MainActor (TranscriptionClientEvent) -> Void)?
  private var readyContinuation: CheckedContinuation<Void, Error>?
  private var sessionReady = false
  private let apiKey: String

  init(apiKey: String) {
    self.apiKey = apiKey
  }

  var isSessionReady: Bool { sessionReady && socket != nil }

  func connect(
    configuration: TranscriptionConfiguration,
    eventHandler: @escaping @MainActor (TranscriptionClientEvent) -> Void
  ) async throws {
    guard let url = Self.connectionURL else {
      throw ClientError.invalidURL
    }

    // Replace any previous socket.
    await tearDownSocket(emittingCancellation: false)

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let socket = URLSession.shared.webSocketTask(with: request)
    self.socket = socket
    self.eventHandler = eventHandler
    self.sessionReady = false
    socket.resume()

    receiveTask = Task { [weak self] in
      await self?.receiveLoop()
    }

    let event = Self.sessionUpdateEvent(configuration: configuration)
    try await send(event)

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      readyContinuation = continuation
      readyTimeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        guard !Task.isCancelled else { return }
        await self?.resolveReady(with: .failure(ClientError.connectionTimedOut))
      }
    }
  }

  /// Swap the live event sink without tearing down the warm socket.
  func setEventHandler(
    _ eventHandler: (@MainActor (TranscriptionClientEvent) -> Void)?
  ) {
    self.eventHandler = eventHandler
  }

  /// Update prompt/languages/etc. on an already-ready session (no TLS redo).
  func refreshSession(configuration: TranscriptionConfiguration) async throws {
    guard sessionReady, socket != nil else {
      throw ClientError.notConnected
    }
    try await send(Self.sessionUpdateEvent(configuration: configuration))
  }

  /// Drop any residual audio between takes so the next hotkey starts clean.
  func clearInputBuffer() async throws {
    guard sessionReady, socket != nil else { return }
    try await send(["type": "input_audio_buffer.clear"])
  }

  static func sessionUpdateEvent(
    configuration: TranscriptionConfiguration
  ) -> [String: Any] {
    var transcription: [String: Any] = [
      "model": transcriptionModel,
      "delay": configuration.delay.rawValue,
    ]
    if !configuration.prompt.isEmpty {
      transcription["prompt"] = configuration.prompt
    }
    if !configuration.keywords.isEmpty {
      transcription["keywords"] = configuration.keywords
    }
    if !configuration.languages.isEmpty {
      transcription["languages"] = configuration.languages
    }

    var input: [String: Any] = [
      "format": [
        "type": "audio/pcm",
        "rate": 24_000,
      ],
      "transcription": transcription,
      "turn_detection": NSNull(),
    ]
    if let noiseReduction = configuration.micProfile.noiseReductionType {
      input["noise_reduction"] = ["type": noiseReduction]
    }

    return [
      "type": "session.update",
      "session": [
        "type": "transcription",
        "audio": ["input": input],
      ],
    ]
  }

  private func resolveReady(with result: Result<Void, Error>) {
    readyTimeoutTask?.cancel()
    readyTimeoutTask = nil
    if case .success = result {
      sessionReady = true
    }
    guard let continuation = readyContinuation else { return }
    readyContinuation = nil
    continuation.resume(with: result)
  }

  func appendAudio(_ data: Data) async throws {
    guard !data.isEmpty else { return }
    try await send([
      "type": "input_audio_buffer.append",
      "audio": data.base64EncodedString(),
    ])
  }

  func commit() async throws {
    try await send([
      "type": "input_audio_buffer.commit"
    ])
  }

  func disconnect() async {
    await tearDownSocket(emittingCancellation: true)
  }

  private func tearDownSocket(emittingCancellation: Bool) async {
    if emittingCancellation {
      resolveReady(with: .failure(CancellationError()))
    } else {
      readyTimeoutTask?.cancel()
      readyTimeoutTask = nil
      if let continuation = readyContinuation {
        readyContinuation = nil
        continuation.resume(throwing: CancellationError())
      }
    }
    receiveTask?.cancel()
    receiveTask = nil
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    eventHandler = nil
    sessionReady = false
  }

  private func send(_ event: [String: Any]) async throws {
    guard let socket else { throw ClientError.notConnected }
    guard JSONSerialization.isValidJSONObject(event),
      let data = try? JSONSerialization.data(withJSONObject: event),
      let text = String(data: data, encoding: .utf8)
    else {
      throw ClientError.invalidEvent
    }
    try await socket.send(.string(text))
  }

  private func receiveLoop() async {
    guard let socket else { return }

    while !Task.isCancelled {
      do {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let text):
          data = Data(text.utf8)
        case .data(let received):
          data = received
        @unknown default:
          continue
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
          let event = object as? [String: Any],
          let type = event["type"] as? String
        else {
          continue
        }

        await handle(type: type, event: event)
      } catch {
        guard !Task.isCancelled else { return }
        sessionReady = false
        let message = Self.userFacingMessage(for: error)
        resolveReady(
          with: .failure(ClientError.serverRejected(message))
        )
        await emit(.error(message))
        return
      }
    }
  }

  private func handle(type: String, event: [String: Any]) async {
    switch type {
    case "session.updated":
      resolveReady(with: .success(()))
      await emit(.sessionReady)

    case "conversation.item.input_audio_transcription.delta":
      if let delta = event["delta"] as? String {
        await emit(
          .delta(
            itemID: event["item_id"] as? String,
            text: delta
          )
        )
      }

    case "conversation.item.input_audio_transcription.completed":
      if let transcript = event["transcript"] as? String {
        await emit(
          .completed(
            itemID: event["item_id"] as? String,
            transcript: transcript
          )
        )
      }

    case "conversation.item.input_audio_transcription.failed", "error":
      let error = event["error"] as? [String: Any]
      let raw =
        (error?["message"] as? String)
        ?? (event["message"] as? String)
        ?? "OpenAI could not complete this transcription."
      let message = UserFacingError.message(from: raw)
      resolveReady(
        with: .failure(ClientError.serverRejected(message))
      )
      await emit(.error(message))

    default:
      break
    }
  }

  private func emit(_ event: TranscriptionClientEvent) async {
    guard let eventHandler else { return }
    await eventHandler(event)
  }

  private static func userFacingMessage(for error: Error) -> String {
    if error is CancellationError {
      return "The live transcription connection ended before the text was ready."
    }
    let mapped = UserFacingError.message(from: error.localizedDescription)
    if mapped.localizedCaseInsensitiveContains("NSURLError")
      || mapped.localizedCaseInsensitiveContains("Code=-")
      || mapped.localizedCaseInsensitiveContains("The operation couldn’t be completed")
    {
      return "The live transcription connection ended before the text was ready."
    }
    return mapped
  }
}
