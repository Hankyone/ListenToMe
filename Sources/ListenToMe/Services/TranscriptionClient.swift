import Foundation

enum TranscriptionClientEvent: Equatable, Sendable {
  case sessionReady
  /// The provider connection dropped or announced an imminent rollover.
  case connectionInterrupted
  /// A live provider connection rolled over while the microphone stayed active.
  case connectionRecovered(resumed: Bool)
  case delta(itemID: String?, text: String)
  /// A full replacement hypothesis, used by Gemini live transcription.
  case interim(text: String)
  case completed(itemID: String?, transcript: String)
  case error(String)
}

protocol TranscriptionClient: Sendable {
  func connect(
    configuration: TranscriptionConfiguration,
    eventHandler: @escaping @MainActor (TranscriptionClientEvent) -> Void
  ) async throws

  func beginAudio() async throws
  func appendAudio(_ data: Data) async throws
  func commit() async throws
  func disconnect() async
}

extension TranscriptionClient {
  func beginAudio() async throws {}
}

protocol ReusableTranscriptionClient: TranscriptionClient {
  var isSessionReady: Bool { get async }
  func setEventHandler(
    _ eventHandler: (@MainActor (TranscriptionClientEvent) -> Void)?
  ) async
  func refreshSession(configuration: TranscriptionConfiguration) async throws
  func clearInputBuffer() async throws
}
