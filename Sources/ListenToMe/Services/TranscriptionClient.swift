import Foundation

enum TranscriptionClientEvent: Equatable, Sendable {
  case sessionReady
  case delta(String)
  case completed(String)
  case error(String)
}

protocol TranscriptionClient: Sendable {
  func connect(
    configuration: TranscriptionConfiguration,
    eventHandler: @escaping @MainActor (TranscriptionClientEvent) -> Void
  ) async throws

  func appendAudio(_ data: Data) async throws
  func commit() async throws
  func disconnect() async
}
