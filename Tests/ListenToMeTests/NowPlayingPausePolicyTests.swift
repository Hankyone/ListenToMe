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

  func testHoldsMicOnlyWhenSomethingWasPlaying() {
    XCTAssertTrue(
      NowPlayingPausePolicy.shouldHoldMicUntilPaused(wasPlaying: true)
    )
    XCTAssertFalse(
      NowPlayingPausePolicy.shouldHoldMicUntilPaused(wasPlaying: false)
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
