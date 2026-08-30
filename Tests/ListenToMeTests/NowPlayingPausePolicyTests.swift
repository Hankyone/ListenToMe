import XCTest

@testable import ListenToMe

final class NowPlayingPausePolicyTests: XCTestCase {
  func testPlayingIsPausedAndResumed() {
    XCTAssertTrue(NowPlayingPausePolicy.shouldSendPause(.playing))
    XCTAssertTrue(NowPlayingPausePolicy.shouldResume(.playing))
  }

  func testIdleIsLeftAlone() {
    XCTAssertFalse(NowPlayingPausePolicy.shouldSendPause(.idle))
    XCTAssertFalse(NowPlayingPausePolicy.shouldResume(.idle))
  }

  func testUnknownPausesButDoesNotResume() {
    XCTAssertTrue(NowPlayingPausePolicy.shouldSendPause(.unknown))
    XCTAssertFalse(NowPlayingPausePolicy.shouldResume(.unknown))
  }
}
