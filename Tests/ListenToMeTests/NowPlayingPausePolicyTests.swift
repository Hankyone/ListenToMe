import XCTest

@testable import ListenToMe

final class NowPlayingPausePolicyTests: XCTestCase {
  func testPlayingIsResumed() {
    XCTAssertTrue(NowPlayingPausePolicy.shouldResumeNowPlaying(.playing))
  }

  func testIdleIsNotResumed() {
    XCTAssertFalse(NowPlayingPausePolicy.shouldResumeNowPlaying(.idle))
    XCTAssertFalse(NowPlayingPausePolicy.shouldResumeNowPlaying(.unknown))
  }

  func testHoldsMicOnlyWhenPlayingIsConfirmed() {
    XCTAssertTrue(NowPlayingPausePolicy.shouldHoldMicUntilPaused(.playing))
    XCTAssertFalse(NowPlayingPausePolicy.shouldHoldMicUntilPaused(.idle))
    XCTAssertFalse(NowPlayingPausePolicy.shouldHoldMicUntilPaused(.unknown))
  }

  func testMediaKeyOnlyIfRemotePauseDidNotStick() {
    XCTAssertTrue(
      NowPlayingPausePolicy.shouldSendMediaKey(
        playback: .playing,
        stillPlayingAfterRemotePause: true
      )
    )
    XCTAssertFalse(
      NowPlayingPausePolicy.shouldSendMediaKey(
        playback: .playing,
        stillPlayingAfterRemotePause: false
      )
    )
    XCTAssertFalse(
      NowPlayingPausePolicy.shouldSendMediaKey(
        playback: .idle,
        stillPlayingAfterRemotePause: true
      )
    )
  }
}
