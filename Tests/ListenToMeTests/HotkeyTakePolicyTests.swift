import XCTest

@testable import ListenToMe

final class HotkeyTakePolicyTests: XCTestCase {
  func testIdlePressAlwaysStarts() {
    for pending in [false, true] {
      XCTAssertEqual(
        HotkeyTakePolicy.actionForPress(phase: .idle, pendingReleaseStop: pending),
        .start
      )
      XCTAssertEqual(
        HotkeyTakePolicy.actionForPress(phase: .failed, pendingReleaseStop: pending),
        .start
      )
      XCTAssertEqual(
        HotkeyTakePolicy.actionForPress(
          phase: .delivered(.pasted),
          pendingReleaseStop: pending
        ),
        .start
      )
    }
  }

  func testLivePressAlwaysStops() {
    XCTAssertEqual(
      HotkeyTakePolicy.actionForPress(phase: .recording, pendingReleaseStop: false),
      .stop
    )
    XCTAssertEqual(
      HotkeyTakePolicy.actionForPress(phase: .connecting, pendingReleaseStop: false),
      .stop
    )
  }

  func testReleaseBounceDoesNotStopALiveTake() {
    XCTAssertEqual(
      HotkeyTakePolicy.actionForPress(phase: .recording, pendingReleaseStop: true),
      .continueTake
    )
  }

  func testFinishingPressStopsTheTake() {
    XCTAssertEqual(
      HotkeyTakePolicy.actionForPress(phase: .finishing, pendingReleaseStop: false),
      .stop
    )
    XCTAssertEqual(
      HotkeyTakePolicy.actionForPress(phase: .finishing, pendingReleaseStop: true),
      .stop
    )
  }

  func testStopBeforeStartMarksTheFlag() {
    XCTAssertEqual(
      RecordingStopPolicy.decision(
        phase: .idle,
        hasAudioSendTask: false,
        isMicRecording: false,
        alreadyRequestedStop: false
      ),
      .markStopBeforeStart
    )
  }

  func testFirstStopWhileMicIsUpWaitsToFinish() {
    XCTAssertEqual(
      RecordingStopPolicy.decision(
        phase: .recording,
        hasAudioSendTask: false,
        isMicRecording: true,
        alreadyRequestedStop: false
      ),
      .finishAfterConnect
    )
  }

  func testSecondStopAbortsAStuckStartup() {
    XCTAssertEqual(
      RecordingStopPolicy.decision(
        phase: .recording,
        hasAudioSendTask: false,
        isMicRecording: true,
        alreadyRequestedStop: true
      ),
      .abort
    )
    XCTAssertEqual(
      RecordingStopPolicy.decision(
        phase: .recording,
        hasAudioSendTask: false,
        isMicRecording: false,
        alreadyRequestedStop: false
      ),
      .abort
    )
  }

  func testLiveStopFinishesAndFinishingRecovers() {
    XCTAssertEqual(
      RecordingStopPolicy.decision(
        phase: .recording,
        hasAudioSendTask: true,
        isMicRecording: true,
        alreadyRequestedStop: false
      ),
      .finishLive
    )
    XCTAssertEqual(
      RecordingStopPolicy.decision(
        phase: .finishing,
        hasAudioSendTask: true,
        isMicRecording: false,
        alreadyRequestedStop: false
      ),
      .recoverFinishing
    )
  }
}
