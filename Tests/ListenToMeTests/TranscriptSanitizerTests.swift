import XCTest

@testable import ListenToMe

final class TranscriptSanitizerTests: XCTestCase {
  private let prompt = """
    Destination: T3 Code (Alpha). If spoken, spell: Anouar (Anwar); Claude (cloud). \
    correction / scratch that / I mean / annule / je veux dire → keep the restatement, \
    drop the cue. End with one trailing space, never a newline.
    """

  func testDropsExactPromptEcho() {
    XCTAssertEqual(TranscriptSanitizer.spokenText(from: prompt, prompt: prompt), "")
  }

  func testKeepsSpeechBeforeRepeatedPromptEcho() {
    let transcript = """
      Hmm.Context: ###
      \(prompt)
      ###\(prompt)\(prompt)
      """
    XCTAssertEqual(
      TranscriptSanitizer.spokenText(from: transcript, prompt: prompt),
      "Hmm."
    )
  }

  func testLeavesOrdinarySpeechAlone() {
    XCTAssertEqual(
      TranscriptSanitizer.spokenText(
        from: "Ship the overlay fix tonight.",
        prompt: prompt
      ),
      "Ship the overlay fix tonight."
    )
  }
}
