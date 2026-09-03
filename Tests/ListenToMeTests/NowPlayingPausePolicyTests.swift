import XCTest

@testable import ListenToMe

final class NowPlayingPausePolicyTests: XCTestCase {
  func testBrowserAudioMayUseMediaKey() {
    XCTAssertTrue(
      NowPlayingPausePolicy.shouldSendMediaKey(
        audibleBundles: ["com.google.Chrome"]
      )
    )
    XCTAssertTrue(
      NowPlayingPausePolicy.shouldSendMediaKey(
        audibleBundles: ["com.apple.Safari"]
      )
    )
  }

  func testBrowserHelperAudioMayUseMediaKey() {
    // Chrome audio runs in a helper process; resolved to the parent app
    // before this check, but a stray helper-style bundle must still match.
    XCTAssertTrue(
      NowPlayingPausePolicy.shouldSendMediaKey(
        audibleBundles: ["com.google.Chrome.helper"]
      )
    )
  }

  func testCallAudioNeverUsesMediaKey() {
    XCTAssertFalse(
      NowPlayingPausePolicy.shouldSendMediaKey(
        audibleBundles: ["us.zoom.xos"]
      )
    )
    XCTAssertFalse(
      NowPlayingPausePolicy.shouldSendMediaKey(
        audibleBundles: ["com.apple.FaceTime"]
      )
    )
    XCTAssertFalse(
      NowPlayingPausePolicy.shouldSendMediaKey(
        audibleBundles: ["com.microsoft.teams"]
      )
    )
  }

  func testNoAudioNeverUsesMediaKey() {
    XCTAssertFalse(
      NowPlayingPausePolicy.shouldSendMediaKey(audibleBundles: [])
    )
  }
}
