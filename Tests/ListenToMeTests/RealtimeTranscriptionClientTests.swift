import XCTest

@testable import ListenToMe

final class RealtimeTranscriptionClientTests: XCTestCase {
  func testConnectionDeclaresTranscriptionIntent() throws {
    let url = try XCTUnwrap(RealtimeTranscriptionClient.connectionURL)
    let components = try XCTUnwrap(
      URLComponents(url: url, resolvingAgainstBaseURL: false)
    )
    let intent = components.queryItems?.first(where: { $0.name == "intent" })?
      .value
    let model = components.queryItems?.first(where: { $0.name == "model" })

    XCTAssertEqual(intent, "transcription")
    XCTAssertNil(model)
  }

  func testTranscriptionModelLivesUnderAudioInput() throws {
    let configuration = TranscriptionConfiguration(
      basePrompt: "Keep the speaker's meaning.",
      vocabulary: [VocabularyItem(term: "Claude")],
      languages: ["en"],
      delay: .low
    )
    let event = RealtimeTranscriptionClient.sessionUpdateEvent(
      configuration: configuration
    )
    let session = try XCTUnwrap(event["session"] as? [String: Any])
    let audio = try XCTUnwrap(session["audio"] as? [String: Any])
    let input = try XCTUnwrap(audio["input"] as? [String: Any])
    let transcription = try XCTUnwrap(
      input["transcription"] as? [String: Any]
    )

    XCTAssertEqual(session["type"] as? String, "transcription")
    XCTAssertNil(session["model"])
    XCTAssertEqual(
      transcription["model"] as? String,
      "gpt-live-transcribe"
    )
  }
}
