import XCTest

@testable import ListenToMe

final class NowPlayingPausePolicyTests: XCTestCase {
  func testPlayingIsResumed() {
    XCTAssertTrue(NowPlayingPausePolicy.shouldResumeNowPlaying(wasPlaying: true))
  }

  func testIdleIsNotResumed() {
    XCTAssertFalse(
      NowPlayingPausePolicy.shouldResumeNowPlaying(wasPlaying: false)
    )
  }

  func testDelaysCaptureOnlyAfterAPause() {
    XCTAssertTrue(
      NowPlayingPausePolicy.shouldDelayCapture(didPausePlayback: true)
    )
    XCTAssertFalse(
      NowPlayingPausePolicy.shouldDelayCapture(didPausePlayback: false)
    )
  }

  func testCaptureLeadMatchesReleaseTail() {
    XCTAssertEqual(
      NowPlayingPausePolicy.captureLeadAfterPause,
      DictationGesturePolicy.releaseTail
    )
  }

  func testMediaKeyOnlyIfRemotePauseDidNotStick() {
    XCTAssertTrue(
      NowPlayingPausePolicy.shouldSendMediaKey(
        wasPlaying: true,
        stillPlayingAfterRemotePause: true
      )
    )
    XCTAssertFalse(
      NowPlayingPausePolicy.shouldSendMediaKey(
        wasPlaying: true,
        stillPlayingAfterRemotePause: false
      )
    )
    XCTAssertFalse(
      NowPlayingPausePolicy.shouldSendMediaKey(
        wasPlaying: false,
        stillPlayingAfterRemotePause: true
      )
    )
  }
}
