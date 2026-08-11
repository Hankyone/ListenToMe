import XCTest

@testable import ListenToMe

final class VocabularyTests: XCTestCase {
  func testNormalizesValidTerm() {
    XCTAssertEqual(
      VocabularyValidation.normalizedTerm("  Claude  "),
      "Claude"
    )
  }

  func testRejectsCharactersDisallowedByRealtimeAPI() {
    XCTAssertNil(VocabularyValidation.normalizedTerm("Cloud\nClaude"))
    XCTAssertNil(VocabularyValidation.normalizedTerm("<Claude>"))
    XCTAssertNil(VocabularyValidation.normalizedTerm("   "))
  }

  func testPromptExplainsAmbiguousSpellingWithoutHardReplacement() {
    let configuration = TranscriptionConfiguration(
      basePrompt: "Keep the speaker's meaning.",
      vocabulary: [
        VocabularyItem(term: "Claude", oftenHeardAs: "cloud")
      ],
      languages: ["en"],
      delay: .low
    )

    XCTAssertTrue(configuration.prompt.contains("Claude"))
    XCTAssertTrue(configuration.prompt.contains("cloud"))
    XCTAssertTrue(configuration.prompt.contains("hints only"))
    XCTAssertEqual(configuration.keywords, ["Claude"])
  }

  func testPromptTeachesSpokenCorrectionRewrites() {
    let configuration = TranscriptionConfiguration(
      basePrompt: "Keep the speaker's meaning.",
      vocabulary: [],
      languages: ["en"],
      delay: .low
    )

    XCTAssertTrue(configuration.prompt.contains("correction"))
    XCTAssertTrue(configuration.prompt.contains("scratch that"))
    XCTAssertTrue(configuration.prompt.contains("I mean"))
    XCTAssertTrue(configuration.prompt.contains("Do not keep the cue words"))
  }
}
