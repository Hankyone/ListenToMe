import XCTest

@testable import ListenToMe

final class LanguageHintValidationTests: XCTestCase {
  func testAcceptsISO6391() {
    let result = LanguageHintValidation.parse("en, fr")
    XCTAssertEqual(result.codes, ["en", "fr"])
    XCTAssertEqual(result.normalizedText, "en, fr")
    XCTAssertNil(result.message)
    XCTAssertFalse(result.isBlocking)
  }

  func testNormalizesRegionalToBaseLanguage() {
    let result = LanguageHintValidation.parse("fr-CA")
    XCTAssertEqual(result.codes, ["fr"])
    XCTAssertEqual(result.normalizedText, "fr")
    XCTAssertFalse(result.isBlocking)
    XCTAssertNotNil(result.message)
    XCTAssertTrue(result.message?.contains("fr-ca") == true
      || result.message?.contains("regional") == true)
  }

  func testAllowsChineseLocales() {
    let result = LanguageHintValidation.parse("zh-CN, zh-tw")
    XCTAssertEqual(result.codes, ["zh-cn", "zh-tw"])
    XCTAssertFalse(result.isBlocking)
  }

  func testRejectsGarbage() {
    let result = LanguageHintValidation.parse("not-a-lang")
    XCTAssertTrue(result.isBlocking)
    XCTAssertTrue(result.codes.isEmpty)
    XCTAssertNotNil(result.message)
  }

  func testEmptyIsFine() {
    let result = LanguageHintValidation.parse("  ")
    XCTAssertEqual(result.codes, [])
    XCTAssertFalse(result.isBlocking)
    XCTAssertNil(result.message)
  }
}

final class UserFacingErrorTests: XCTestCase {
  func testMapsLanguageAPIErrors() {
    let message = UserFacingError.message(
      from:
        #"Invalid value: 'fr-CA'. Supported values for 'session.audio.input.transcription.languages' are: en, fr, …"#
    )
    XCTAssertTrue(message.localizedCaseInsensitiveContains("language"))
    XCTAssertLessThanOrEqual(message.count, UserFacingError.maxLength)
  }

  func testTruncatesLongJunk() {
    let long = String(repeating: "x", count: 500)
    let message = UserFacingError.message(from: long)
    XCTAssertLessThanOrEqual(message.count, UserFacingError.maxLength)
    XCTAssertTrue(message.hasSuffix("…"))
  }

  func testMapsLiveLengthLimitWithoutDumpingRawAPIText() {
    let message = UserFacingError.message(
      from: "input_audio_buffer is too large: audio too long for this session"
    )
    XCTAssertTrue(message.localizedCaseInsensitiveContains("history"))
    XCTAssertTrue(message.localizedCaseInsensitiveContains("reprocess"))
    XCTAssertFalse(message.localizedCaseInsensitiveContains("input_audio_buffer"))
  }

  func testMapsPromptTooLongSeparatelyFromAudioLimits() {
    let message = UserFacingError.message(
      from:
        "Invalid 'session.audio.input.transcription.prompt': string too long. Expected a string with maximum length 1024, but got a string with length 1028 instead."
    )
    XCTAssertTrue(message.localizedCaseInsensitiveContains("writing guidance"))
    XCTAssertFalse(message.localizedCaseInsensitiveContains("1028"))
    XCTAssertFalse(message.localizedCaseInsensitiveContains("session.audio"))
  }
}
