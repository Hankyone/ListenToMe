import XCTest

@testable import ListenToMe

final class EmptyTakePolicyTests: XCTestCase {
  func testSilentNoSpeechIsNotShown() {
    XCTAssertFalse(
      EmptyTakePolicy.shouldShowFailure(
        message: "No speech was found in that recording.",
        hasTranscript: false,
        hadSpeech: false
      )
    )
  }

  func testTranscriptionTimeoutWithoutSpeechIsNotShown() {
    XCTAssertFalse(
      EmptyTakePolicy.shouldShowFailure(
        message: "Transcription did not finish.",
        hasTranscript: false,
        hadSpeech: false
      )
    )
  }

  func testSpeechWithoutTranscriptStillSurfaces() {
    XCTAssertTrue(
      EmptyTakePolicy.shouldShowFailure(
        message: "The network connection dropped.",
        hasTranscript: false,
        hadSpeech: true
      )
    )
  }

  func testNoSpeechStaysQuietEvenWithRoomNoise() {
    XCTAssertFalse(
      EmptyTakePolicy.shouldShowFailure(
        message: "No speech was found in that recording.",
        hasTranscript: false,
        hadSpeech: true
      )
    )
  }

  func testAPIKeyFailureSurfacesEvenWhenSilent() {
    XCTAssertTrue(
      EmptyTakePolicy.shouldShowFailure(
        message: "Paste an OpenAI API key in Setup before dictating.",
        hasTranscript: false,
        hadSpeech: false
      )
    )
  }

  func testMicrophonePermissionSurfacesEvenWhenSilent() {
    XCTAssertTrue(
      EmptyTakePolicy.shouldShowFailure(
        message: "Microphone access is off. Allow it in System Settings, then try again.",
        hasTranscript: false,
        hadSpeech: false
      )
    )
  }

  func testQuotaFailureSurfacesEvenWhenSilent() {
    XCTAssertTrue(
      EmptyTakePolicy.shouldShowFailure(
        message: "The API account is out of quota. Check billing for that provider.",
        hasTranscript: false,
        hadSpeech: false
      )
    )
  }

  func testTranscriptAlwaysSurfaces() {
    XCTAssertTrue(
      EmptyTakePolicy.shouldShowFailure(
        message: "No speech was found in that recording.",
        hasTranscript: true,
        hadSpeech: false
      )
    )
  }

  func testBenignEmptyTakeMessages() {
    XCTAssertTrue(
      EmptyTakePolicy.isBenignEmptyTake("No speech was found in that recording.")
    )
    XCTAssertTrue(
      EmptyTakePolicy.isBenignEmptyTake("Transcription did not finish.")
    )
    XCTAssertFalse(
      EmptyTakePolicy.isBenignEmptyTake("The API key was rejected. Paste a valid key in Setup.")
    )
  }
}
