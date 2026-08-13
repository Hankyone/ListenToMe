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
    XCTAssertTrue(configuration.prompt.contains("Claude (cloud)"))
    XCTAssertFalse(configuration.prompt.contains("also heard as"))
    XCTAssertTrue(configuration.prompt.contains("If spoken, spell:"))
    XCTAssertEqual(configuration.keywords, ["Claude"])
  }

  func testPromptListsMultipleHeardAsSpellings() {
    let configuration = TranscriptionConfiguration(
      basePrompt: "Keep the speaker's meaning.",
      vocabulary: [
        VocabularyItem(term: "Anouar", oftenHeardAs: "Anwar, Anuar; Anouar ")
      ],
      languages: ["en"],
      delay: .low
    )

    XCTAssertTrue(configuration.prompt.contains("Anouar (Anwar, Anuar)"))
    XCTAssertFalse(configuration.prompt.contains("also heard as"))
    XCTAssertFalse(configuration.prompt.contains("as Anwar, Anuar, Anouar"))
    XCTAssertEqual(configuration.keywords, ["Anouar"])
  }

  func testParsesCommaAndSemicolonAliases() {
    XCTAssertEqual(
      VocabularyAliases.parse("Anwar, Anuar;  Anouar "),
      ["Anwar", "Anuar", "Anouar"]
    )
    XCTAssertEqual(
      VocabularyAliases.normalized(" Anwar,,  Anuar ; "),
      "Anwar, Anuar"
    )
  }

  func testPromptTeachesSpokenCorrectionRewrites() {
    let configuration = TranscriptionConfiguration(
      basePrompt: "Keep the speaker's meaning.",
      vocabulary: [],
      languages: ["en", "fr"],
      delay: .low
    )

    XCTAssertTrue(configuration.prompt.contains("correction"))
    XCTAssertTrue(configuration.prompt.contains("scratch that"))
    XCTAssertTrue(configuration.prompt.contains("I mean"))
    XCTAssertTrue(configuration.prompt.contains("annule"))
    XCTAssertTrue(configuration.prompt.contains("je veux dire"))
    XCTAssertTrue(configuration.prompt.contains("restatement"))
    XCTAssertTrue(configuration.prompt.contains("drop the cue"))
  }

  func testDefaultBasePromptDoesNotLectureTheModel() {
    XCTAssertTrue(WritingGuidance.defaultBasePrompt.isEmpty)
    XCTAssertTrue(
      WritingGuidance.isFactoryDefault(
        "One speaker, live, inserting at the caret. Written English at the insertion point: sentence case; standard punctuation; Arabic numerals (42, 3.14, 1,000) unless the words themselves are the content; emails, URLs, and paths as user@host and https://..., not spoken at/dot/slash. Drop um, uh, er; keep like, you know, so, well when they belong in the sentence. Keep wording, order, and register. Homophones follow the destination app and listed spellings. End with one trailing space, never a newline."
      )
    )
  }

  func testPromptStaysWithinRealtimeCharacterLimitForLongAppNames() {
    let vocabulary = (1...40).map { index in
      VocabularyItem(term: "Term\(index)", oftenHeardAs: "sound\(index)")
    }
    let configuration = TranscriptionConfiguration(
      basePrompt: WritingGuidance.defaultBasePrompt,
      vocabulary: vocabulary,
      languages: ["en"],
      delay: .low,
      targetAppName: "Ghostty  -  Hankyone Sidebar Fork"
    )

    XCTAssertLessThanOrEqual(
      configuration.prompt.utf8.count,
      TranscriptionConfiguration.realtimePromptLimit
    )
    XCTAssertTrue(configuration.prompt.contains("Ghostty"))
    XCTAssertTrue(configuration.prompt.contains("correction"))
  }

  func testCompactPromptFitsGhosttyForkWithRealWordList() {
    let configuration = TranscriptionConfiguration(
      basePrompt: WritingGuidance.defaultBasePrompt,
      vocabulary: [
        VocabularyItem(term: "Anouar", oftenHeardAs: "Anwar"),
        VocabularyItem(term: "Claude", oftenHeardAs: "cloud"),
      ],
      languages: ["en"],
      delay: .low,
      targetAppName: "Ghostty Pro Plus Ultra"
    )

    XCTAssertLessThan(
      configuration.prompt.utf8.count,
      TranscriptionConfiguration.realtimePromptLimit
    )
    XCTAssertTrue(configuration.prompt.contains("Ghostty Pro Plus Ultra"))
    XCTAssertTrue(configuration.prompt.contains("Anouar (Anwar)"))
    XCTAssertTrue(configuration.prompt.contains("Claude (cloud)"))
    XCTAssertFalse(configuration.prompt.contains("also heard as"))
    XCTAssertFalse(configuration.prompt.contains("\n\n"))
  }

  func testClampedPromptNeverExceedsLimit() {
    let clamped = TranscriptionConfiguration.clampedPrompt(
      base: String(repeating: "Guidance ", count: 80),
      appLine: "The speaker is dictating into Ghostty.",
      wordsLine: String(repeating: "Anouar (also heard as Anwar, Anuar), ", count: 20),
      correction: "Keep the final text paste-ready.",
      limit: 1024
    )
    XCTAssertLessThanOrEqual(clamped.utf8.count, 1024)
    XCTAssertTrue(clamped.contains("Ghostty"))
    XCTAssertFalse(clamped.isEmpty)
  }
}
