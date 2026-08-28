import Foundation
import OSLog

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
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ca.hankyone.ListenToMe",
    category: "GeminiLive"
  )
  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var readyTimeoutTask: Task<Void, Never>?
  private var readyContinuation: CheckedContinuation<Void, Error>?
  private var eventHandler: (@MainActor (TranscriptionClientEvent) -> Void)?
  private var configuration: TranscriptionConfiguration?
  private var resumptionHandle: String?
  private var sessionReady = false
  private var connectedAt: Date?
  private var connectionGeneration = 0
  private var activityOpen = false
  private var isDisconnecting = false

  init(apiKey: String) {
    self.apiKey = apiKey
  }

  var isSessionReady: Bool {
    guard sessionReady, socket != nil, let connectedAt else { return false }
    // A claimed warm socket should leave most of the model's ten-minute
    // streaming window available to the take.
    return reconnectTask == nil && Date().timeIntervalSince(connectedAt) < 2 * 60
  }

  func connect(
    configuration: TranscriptionConfiguration,
    eventHandler: @escaping @MainActor (TranscriptionClientEvent) -> Void
  ) async throws {
    await tearDownSocket(emittingCancellation: false)
    self.eventHandler = eventHandler
    self.configuration = configuration
    resumptionHandle = nil
    activityOpen = false
    isDisconnecting = false
    try await openSocket(configuration: configuration, resumptionHandle: nil)
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
    await reconnectTask?.value
    guard sessionReady, socket != nil else { return }
    if activityOpen {
      try await send(["realtimeInput": ["activityEnd": [:]]])
      activityOpen = false
    }
  }

  func beginAudio() async throws {
    await reconnectTask?.value
    guard sessionReady, socket != nil else { throw ClientError.notConnected }
    if !activityOpen {
      try await send(["realtimeInput": ["activityStart": [:]]])
      activityOpen = true
    }
  }

  func appendAudio(_ data: Data) async throws {
    guard !data.isEmpty else { return }
    await reconnectTask?.value
    guard sessionReady, socket != nil, activityOpen else {
      throw ClientError.notConnected
    }
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
    await reconnectTask?.value
    guard sessionReady, socket != nil else { throw ClientError.notConnected }
    if activityOpen {
      try await send(["realtimeInput": ["activityEnd": [:]]])
      activityOpen = false
    }
  }

  func disconnect() async {
    isDisconnecting = true
    reconnectTask?.cancel()
    reconnectTask = nil
    await tearDownSocket(emittingCancellation: true)
    configuration = nil
    resumptionHandle = nil
  }

  static func setupEvent(
    configuration: TranscriptionConfiguration,
    resumptionHandle: String? = nil
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

    var sessionResumption: [String: Any] = [:]
    if let resumptionHandle, !resumptionHandle.isEmpty {
      sessionResumption["handle"] = resumptionHandle
    }
    let setup: [String: Any] = [
      "model": transcriptionModel,
      "generationConfig": ["responseModalities": ["TEXT"]],
      "realtimeInputConfig": [
        "automaticActivityDetection": ["disabled": true]
      ],
      "inputAudioTranscription": transcription,
      "sessionResumption": sessionResumption,
      "contextWindowCompression": [
        "slidingWindow": [String: Any]()
      ],
    ]
    return ["setup": setup]
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

  private func openSocket(
    configuration: TranscriptionConfiguration,
    resumptionHandle: String?
  ) async throws {
    guard var components = URLComponents(string: Self.endpoint) else {
      throw ClientError.invalidURL
    }
    components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
    guard let url = components.url else { throw ClientError.invalidURL }

    receiveTask?.cancel()
    receiveTask = nil
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    sessionReady = false
    connectedAt = nil
    connectionGeneration += 1
    let generation = connectionGeneration

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    let socket = URLSession.shared.webSocketTask(with: request)
    self.socket = socket
    socket.resume()

    receiveTask = Task { [weak self] in
      await self?.receiveLoop(socket: socket, generation: generation)
    }

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      readyContinuation = continuation
      readyTimeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        guard !Task.isCancelled else { return }
        await self?.resolveReady(with: .failure(ClientError.connectionTimedOut))
      }
      Task { [weak self] in
        guard let self else { return }
        do {
          try await self.send(
            Self.setupEvent(
              configuration: configuration,
              resumptionHandle: resumptionHandle
            ),
            through: socket
          )
        } catch {
          await self.resolveReady(with: .failure(error))
        }
      }
    }
    connectedAt = Date()
    logger.info(
      "Gemini live socket ready; resumed=\(resumptionHandle != nil, privacy: .public)"
    )
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
    connectionGeneration += 1
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    eventHandler = nil
    sessionReady = false
    connectedAt = nil
    activityOpen = false
  }

  private func send(_ event: [String: Any]) async throws {
    guard let socket else { throw ClientError.notConnected }
    try await send(event, through: socket)
  }

  private func send(
    _ event: [String: Any],
    through socket: URLSessionWebSocketTask
  ) async throws {
    guard JSONSerialization.isValidJSONObject(event),
      let data = try? JSONSerialization.data(withJSONObject: event),
      let text = String(data: data, encoding: .utf8)
    else {
      throw ClientError.invalidEvent
    }
    try await socket.send(.string(text))
  }

  private func receiveLoop(
    socket: URLSessionWebSocketTask,
    generation: Int
  ) async {
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
        guard generation == connectionGeneration else { return }

        if event["setupComplete"] != nil {
          resolveReady(with: .success(()))
          await emit(.sessionReady)
          continue
        }

        if let update = event["sessionResumptionUpdate"] as? [String: Any],
          update["resumable"] as? Bool == true,
          let handle = update["newHandle"] as? String,
          !handle.isEmpty
        {
          resumptionHandle = handle
        }

        let parsed = Self.transcriptionEvents(from: event)
        for transcriptionEvent in parsed {
          if case .error(let message) = transcriptionEvent, !sessionReady {
            resolveReady(
              with: .failure(ClientError.serverRejected(message))
            )
            continue
          }
          await emit(transcriptionEvent)
        }

        if event["goAway"] != nil {
          sessionReady = false
          let timeLeft = Self.goAwaySeconds(from: event)
          logger.info(
            "Gemini requested connection rollover; secondsLeft=\(timeLeft ?? -1, privacy: .public)"
          )
          await emit(.connectionInterrupted)
          scheduleReconnect(reason: "goAway")
          return
        }
      } catch {
        guard !Task.isCancelled, generation == connectionGeneration else { return }
        sessionReady = false
        let message = UserFacingError.message(from: error.localizedDescription)
        if readyContinuation != nil {
          resolveReady(with: .failure(ClientError.serverRejected(message)))
          return
        }
        guard !isDisconnecting else { return }
        logger.error("Gemini live socket closed unexpectedly")
        await emit(.connectionInterrupted)
        scheduleReconnect(reason: "socketClosed")
        return
      }
    }
  }

  static func goAwaySeconds(from event: [String: Any]) -> Double? {
    guard let goAway = event["goAway"] as? [String: Any],
      let raw = goAway["timeLeft"]
    else { return nil }
    if let seconds = raw as? Double { return seconds }
    if let seconds = raw as? Int { return Double(seconds) }
    if let text = raw as? String {
      return Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "s")))
    }
    if let duration = raw as? [String: Any] {
      if let seconds = duration["seconds"] as? Double { return seconds }
      if let seconds = duration["seconds"] as? Int { return Double(seconds) }
      if let text = duration["seconds"] as? String { return Double(text) }
    }
    return nil
  }

  private func scheduleReconnect(reason: String) {
    guard reconnectTask == nil, configuration != nil, !isDisconnecting else { return }
    logger.info("Scheduling Gemini live recovery; reason=\(reason, privacy: .public)")
    reconnectTask = Task { [weak self] in
      await self?.recoverConnection()
    }
  }

  private func recoverConnection() async {
    guard let configuration, !isDisconnecting else {
      reconnectTask = nil
      return
    }
    let handle = resumptionHandle
    var lastError: Error = ClientError.notConnected

    for attempt in 0..<3 {
      guard !Task.isCancelled, !isDisconnecting else {
        reconnectTask = nil
        return
      }
      if attempt > 0 {
        try? await Task.sleep(nanoseconds: UInt64(attempt) * 300_000_000)
      }
      do {
        var resumed = false
        if let handle {
          do {
            try await openSocket(configuration: configuration, resumptionHandle: handle)
            resumed = true
          } catch {
            lastError = error
            resumptionHandle = nil
            try await openSocket(configuration: configuration, resumptionHandle: nil)
          }
        } else {
          try await openSocket(configuration: configuration, resumptionHandle: nil)
        }

        if activityOpen {
          try await send(["realtimeInput": ["activityStart": [:]]])
        }
        reconnectTask = nil
        logger.info(
          "Gemini live recovery succeeded; resumed=\(resumed, privacy: .public)"
        )
        await emit(.connectionRecovered(resumed: resumed))
        return
      } catch {
        lastError = error
        logger.error(
          "Gemini live recovery attempt failed; attempt=\(attempt + 1, privacy: .public)"
        )
      }
    }

    reconnectTask = nil
    sessionReady = false
    await emit(
      .error(
        "Gemini could not restore the live connection. The saved recording will be transcribed when you stop. \(UserFacingError.message(from: lastError.localizedDescription))"
      )
    )
  }

  private func emit(_ event: TranscriptionClientEvent) async {
    guard let eventHandler else { return }
    await eventHandler(event)
  }
}
