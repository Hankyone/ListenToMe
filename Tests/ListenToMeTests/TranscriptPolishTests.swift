import XCTest

@testable import ListenToMe

final class TranscriptPolishTests: XCTestCase {
  func testPromptTreatsCorrectionsAsSpeechNotSyntax() {
    let prompt = TranscriptPolishService.systemPrompt(
      guidance: "Polish dictation lightly.",
      vocabulary: [VocabularyItem(term: "Anouar", oftenHeardAs: "Anwar")]
    )
    XCTAssertTrue(prompt.contains("Pauses, commas, and wording vary"))
    XCTAssertTrue(prompt.contains("Toronto, correction, Montreal"))
    XCTAssertTrue(prompt.contains("Anouar"))
    XCTAssertTrue(prompt.contains("Polish dictation lightly."))
  }

  func testAcceptsNormalRewrite() {
    XCTAssertTrue(
      TranscriptPolishService.shouldAccept(
        original:
          "I so was planning a trip to Toronto, correction, Montreal, and then see where I was gonna go next.",
        candidate:
          "I so was planning a trip to Montreal, and then see where I was gonna go next."
      )
    )
  }

  func testRejectsEmptyOrRambling() {
    XCTAssertFalse(
      TranscriptPolishService.shouldAccept(original: "hello", candidate: "   ")
    )
    let ramble = String(repeating: "word ", count: 80)
    XCTAssertFalse(
      TranscriptPolishService.shouldAccept(original: "hello there", candidate: ramble)
    )
  }

  func testDecodesChatCompletionContent() throws {
    let json = """
      {"choices":[{"message":{"content":"a trip to Montreal"}}]}
      """.data(using: .utf8)!
    XCTAssertEqual(
      TranscriptPolishService.decodeContent(json),
      "a trip to Montreal"
    )
  }
}
