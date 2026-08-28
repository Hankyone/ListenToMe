import XCTest

@testable import ListenToMe

final class HotkeyTakePolicyTests: XCTestCase {
  func testIdlePressStarts() {
    XCTAssertEqual(
      DictationGesturePolicy.pressAction(
        phase: .idle,
        liveKind: .unclassified,
        liveElapsed: 0,
        keyPhysicallyDown: true,
        secondsSinceHoldEnded: nil
      ),
      .start
    )
  }

  func testHoldRepeatIsIgnored() {
    XCTAssertEqual(
      DictationGesturePolicy.pressAction(
        phase: .recording,
        liveKind: .hold,
        liveElapsed: 1.2,
        keyPhysicallyDown: true,
        secondsSinceHoldEnded: nil
      ),
      .ignore
    )
  }

  func testUnclassifiedRepeatIsIgnored() {
    XCTAssertEqual(
      DictationGesturePolicy.pressAction(
        phase: .recording,
        liveKind: .unclassified,
        liveElapsed: 0.1,
        keyPhysicallyDown: true,
        secondsSinceHoldEnded: nil
      ),
      .ignore
    )
  }

  func testQuickRetriggerAfterTapKeepsListening() {
    XCTAssertEqual(
      DictationGesturePolicy.pressAction(
        phase: .recording,
        liveKind: .tap,
        liveElapsed: 0.15,
        keyPhysicallyDown: true,
        secondsSinceHoldEnded: nil
      ),
      .ignore
    )
  }

  func testSecondClickAfterTapStops() {
    XCTAssertEqual(
      DictationGesturePolicy.pressAction(
        phase: .recording,
        liveKind: .tap,
        liveElapsed: 0.8,
        keyPhysicallyDown: true,
        secondsSinceHoldEnded: nil
      ),
      .stop
    )
  }

  func testBounceAfterHoldEndIsIgnored() {
    XCTAssertEqual(
      DictationGesturePolicy.pressAction(
        phase: .idle,
        liveKind: .unclassified,
        liveElapsed: 0,
        keyPhysicallyDown: false,
        secondsSinceHoldEnded: 0.05
      ),
      .ignore
    )
  }

  func testImmediateRepressAfterHoldStarts() {
    XCTAssertEqual(
      DictationGesturePolicy.pressAction(
        phase: .finishing,
        liveKind: .unclassified,
        liveElapsed: 0,
        keyPhysicallyDown: true,
        secondsSinceHoldEnded: 0.05
      ),
      .start
    )
  }

  func testFinishingPressStartsNextTake() {
    XCTAssertEqual(
      DictationGesturePolicy.pressAction(
        phase: .finishing,
        liveKind: .unclassified,
        liveElapsed: 1,
        keyPhysicallyDown: true,
        secondsSinceHoldEnded: 0.3
      ),
      .start
    )
  }

  func testReleaseBeforeThresholdBecomesTap() {
    XCTAssertEqual(
      DictationGesturePolicy.releaseAction(
        startedThisPress: true,
        liveKind: .unclassified,
        holdEnabled: true,
        tapEnabled: true,
        elapsed: 0.1,
        isLocked: false
      ),
      .becomeTap
    )
  }

  func testReleaseAfterThresholdEndsHold() {
    XCTAssertEqual(
      DictationGesturePolicy.releaseAction(
        startedThisPress: true,
        liveKind: .unclassified,
        holdEnabled: true,
        tapEnabled: true,
        elapsed: 0.3,
        isLocked: false
      ),
      .endHold
    )
  }

  func testConfirmedHoldReleaseAlwaysEnds() {
    XCTAssertEqual(
      DictationGesturePolicy.releaseAction(
        startedThisPress: true,
        liveKind: .hold,
        holdEnabled: true,
        tapEnabled: true,
        elapsed: 0.05,
        isLocked: false
      ),
      .endHold
    )
  }

  func testTapReleaseDoesNotEnd() {
    XCTAssertEqual(
      DictationGesturePolicy.releaseAction(
        startedThisPress: true,
        liveKind: .tap,
        holdEnabled: true,
        tapEnabled: true,
        elapsed: 0.4,
        isLocked: false
      ),
      .ignore
    )
  }

  func testLockedReleaseDoesNotEndHold() {
    XCTAssertEqual(
      DictationGesturePolicy.releaseAction(
        startedThisPress: true,
        liveKind: .hold,
        holdEnabled: true,
        tapEnabled: true,
        elapsed: 1,
        isLocked: true
      ),
      .ignore
    )
  }

  func testHoldOnlyReleaseEndsEvenIfShort() {
    XCTAssertEqual(
      DictationGesturePolicy.releaseAction(
        startedThisPress: true,
        liveKind: .unclassified,
        holdEnabled: true,
        tapEnabled: false,
        elapsed: 0.05,
        isLocked: false
      ),
      .endHold
    )
  }

  func testTinyTakesSkipTranscription() {
    XCTAssertTrue(DictationGesturePolicy.shouldSkipTranscription(elapsed: 0.1))
    XCTAssertFalse(DictationGesturePolicy.shouldSkipTranscription(elapsed: 0.8))
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

  func testFirstStopWhileMicIsUpWaitsToFinishPipeline() {
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

  func testStopAfterLiveDetachFinishesTheSavedAudioPath() {
    XCTAssertEqual(
      RecordingStopPolicy.decision(
        phase: .recording,
        hasAudioSendTask: false,
        isMicRecording: true,
        alreadyRequestedStop: false,
        usesBatchTranscription: true
      ),
      .finishLive
    )
  }
}
