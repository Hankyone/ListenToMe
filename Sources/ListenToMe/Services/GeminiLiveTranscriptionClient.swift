import Foundation

actor GeminiLiveTranscriptionClient: ReusableTranscriptionClient {
  static let transcriptionModel = "models/gemini-3.5-transcribe-live"
  static let endpoint =
    "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

  enum ClientError: LocalizedError {
    case invalidURL
    case notConnected
    case invalidEvent
    case connectionTimedOut
    case serverRejected(String)

    var errorDescription: String? {
      switch self {
      case .invalidURL: "The Gemini live transcription address is invalid."
      case .notConnected: "The Gemini live transcription connection is not ready."
      case .invalidEvent: "A Gemini live message could not be encoded."
      case .connectionTimedOut:
        "Gemini did not finish opening the live transcription session."
      case .serverRejected(let message): message
      }
    }
  }

  private let apiKey: String
  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var readyTimeoutTask: Task<Void, Never>?
  private var readyContinuation: CheckedContinuation<Void, Error>?
  private var eventHandler: (@MainActor (TranscriptionClientEvent) -> Void)?
  private var sessionReady = false
  private var connectedAt: Date?
  private var activityOpen = false

  init(apiKey: String) {
    self.apiKey = apiKey
  }

  var isSessionReady: Bool {
    guard sessionReady, socket != nil, let connectedAt else { return false }
    // Gemini live sessions are finite. Replace warm sockets before the limit.
    return Date().timeIntervalSince(connectedAt) < 8 * 60
  }

  func connect(
    configuration: TranscriptionConfiguration,
    eventHandler: @escaping @MainActor (TranscriptionClientEvent) -> Void
  ) async throws {
    guard var components = URLComponents(string: Self.endpoint) else {
      throw ClientError.invalidURL
    }
    components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
    guard let url = components.url else { throw ClientError.invalidURL }

    await tearDownSocket(emittingCancellation: false)

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    let socket = URLSession.shared.webSocketTask(with: request)
    self.socket = socket
    self.eventHandler = eventHandler
    sessionReady = false
    connectedAt = nil
    activityOpen = false
    socket.resume()

    receiveTask = Task { [weak self] in
      await self?.receiveLoop()
    }

    try await send(Self.setupEvent(configuration: configuration))
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

  func setEventHandler(
    _ eventHandler: (@MainActor (TranscriptionClientEvent) -> Void)?
  ) {
    self.eventHandler = eventHandler
  }

  /// Gemini setup is immutable. Warm sockets are claimed only when the core
  /// configuration still matches, so no update message is needed.
  func refreshSession(configuration: TranscriptionConfiguration) async throws {
    guard isSessionReady else { throw ClientError.notConnected }
  }

  func clearInputBuffer() async throws {
    guard sessionReady, socket != nil else { return }
    if activityOpen {
      try await send(["realtimeInput": ["activityEnd": [:]]])
      activityOpen = false
    }
  }

  func beginAudio() async throws {
    guard sessionReady, socket != nil else { throw ClientError.notConnected }
    if !activityOpen {
      try await send(["realtimeInput": ["activityStart": [:]]])
      activityOpen = true
    }
  }

  func appendAudio(_ data: Data) async throws {
    guard !data.isEmpty else { return }
    guard activityOpen else { throw ClientError.notConnected }
    try await send([
      "realtimeInput": [
        "audio": [
          "data": data.base64EncodedString(),
          "mimeType": "audio/pcm;rate=16000",
        ]
      ]
    ])
  }

  func commit() async throws {
    guard sessionReady, socket != nil else { throw ClientError.notConnected }
    if activityOpen {
      try await send(["realtimeInput": ["activityEnd": [:]]])
      activityOpen = false
    }
  }

  func disconnect() async {
    await tearDownSocket(emittingCancellation: true)
  }

  static func setupEvent(
    configuration: TranscriptionConfiguration
  ) -> [String: Any] {
    var transcription: [String: Any] = [
      "mode": "SMART"
    ]
    if !configuration.languages.isEmpty {
      transcription["languageCodes"] = configuration.languages
    }
    let terms = Array(
      configuration.keywords
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .prefix(1_000)
    )
    if !terms.isEmpty {
      transcription["customVocabulary"] = terms
    }

    return [
      "setup": [
        "model": transcriptionModel,
        "generationConfig": ["responseModalities": ["TEXT"]],
        "realtimeInputConfig": [
          "automaticActivityDetection": ["disabled": true]
        ],
        "inputAudioTranscription": transcription,
      ]
    ]
  }

  static func transcriptionEvents(from event: [String: Any]) -> [TranscriptionClientEvent] {
    guard let content = event["serverContent"] as? [String: Any] else {
      if let error = event["error"] as? [String: Any],
        let message = error["message"] as? String
      {
        return [.error(UserFacingError.message(from: message))]
      }
      return []
    }

    var events: [TranscriptionClientEvent] = []
    if let interim = content["interimInputTranscription"] as? [String: Any],
      let text = interim["text"] as? String,
      !text.isEmpty
    {
      events.append(.interim(text: text))
    }
    if let final = content["inputTranscription"] as? [String: Any],
      let text = final["text"] as? String,
      !text.isEmpty
    {
      events.append(.completed(itemID: nil, transcript: text))
    }
    return events
  }

  private func resolveReady(with result: Result<Void, Error>) {
    readyTimeoutTask?.cancel()
    readyTimeoutTask = nil
    if case .success = result {
      sessionReady = true
      connectedAt = Date()
    }
    guard let continuation = readyContinuation else { return }
    readyContinuation = nil
    continuation.resume(with: result)
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
    connectedAt = nil
    activityOpen = false
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
        case .string(let text): data = Data(text.utf8)
        case .data(let received): data = received
        @unknown default: continue
        }
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }

        if event["setupComplete"] != nil {
          resolveReady(with: .success(()))
          await emit(.sessionReady)
          continue
        }

        let parsed = Self.transcriptionEvents(from: event)
        for transcriptionEvent in parsed {
          if case .error(let message) = transcriptionEvent, !sessionReady {
            resolveReady(
              with: .failure(ClientError.serverRejected(message))
            )
          }
          await emit(transcriptionEvent)
        }

        if event["goAway"] != nil {
          sessionReady = false
          await emit(
            .error("The Gemini live session ended. Your audio will be transcribed from History."))
          return
        }
      } catch {
        guard !Task.isCancelled else { return }
        sessionReady = false
        let message = UserFacingError.message(from: error.localizedDescription)
        resolveReady(with: .failure(ClientError.serverRejected(message)))
        await emit(.error(message))
        return
      }
    }
  }

  private func emit(_ event: TranscriptionClientEvent) async {
    guard let eventHandler else { return }
    await eventHandler(event)
  }
}
