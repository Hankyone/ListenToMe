import XCTest

@testable import ListenToMe

final class NowPlayingPausePolicyTests: XCTestCase {
  func testCaptureLeadIsBoundedAtTwoHundredMilliseconds() {
    XCTAssertEqual(
      NowPlayingPausePolicy.captureLeadAfterPause,
      0.20,
      accuracy: 0.001
    )
    XCTAssertEqual(
      NowPlayingPausePolicy.captureLeadNanoseconds,
      200_000_000
    )
  }

  func testRecordingWatchdogIsBoundedAtTenMinutes() {
    XCTAssertEqual(
      DictationGesturePolicy.recordingWatchdogSeconds,
      600
    )
  }

  func testBrowserAudioUsesExplicitMediaRemoteRoute() {
    let plan = NowPlayingPausePolicy.plan(
      audibleBundles: ["com.google.Chrome"],
      inputBundles: []
    )

    XCTAssertEqual(plan?.route, .mediaRemote)
    XCTAssertEqual(
      plan?.targetBundles,
      Set(["com.google.Chrome"])
    )
  }

  func testSpotifyUsesExplicitMediaRemoteRoute() {
    let plan = NowPlayingPausePolicy.plan(
      audibleBundles: ["com.spotify.client"],
      inputBundles: []
    )

    XCTAssertEqual(plan?.route, .mediaRemote)
    XCTAssertEqual(
      plan?.targetBundles,
      Set(["com.spotify.client"])
    )
  }

  func testUnknownPlayerUsesPreciseMediaRemoteCommands() {
    let plan = NowPlayingPausePolicy.plan(
      audibleBundles: ["com.example.player"],
      inputBundles: []
    )

    XCTAssertEqual(plan?.route, .mediaRemote)
    XCTAssertEqual(
      plan?.targetBundles,
      Set(["com.example.player"])
    )
  }

  func testKnownCallAudioProducesNoPausePlan() {
    XCTAssertNil(
      NowPlayingPausePolicy.plan(
        audibleBundles: ["us.zoom.xos"],
        inputBundles: ["us.zoom.xos"]
      )
    )
  }

  func testBrowserWithActiveInputIsTreatedAsAWebCall() {
    XCTAssertNil(
      NowPlayingPausePolicy.plan(
        audibleBundles: ["com.google.Chrome"],
        inputBundles: ["com.google.Chrome.helper.renderer"]
      )
    )
  }

  func testMixedCallAndMediaPausesOnlyTheMediaTarget() {
    let plan = NowPlayingPausePolicy.plan(
      audibleBundles: ["us.zoom.xos", "com.spotify.client"],
      inputBundles: ["us.zoom.xos"]
    )

    XCTAssertEqual(plan?.route, .mediaRemote)
    XCTAssertEqual(
      plan?.targetBundles,
      Set(["com.spotify.client"])
    )
  }

  func testNoAudioProducesNoPausePlan() {
    XCTAssertNil(
      NowPlayingPausePolicy.plan(
        audibleBundles: [],
        inputBundles: []
      )
    )
  }

  func testCallAudioIsLeftAlone() {
    XCTAssertTrue(
      NowPlayingPausePolicy.isDefinitelyCallAudio(
        audibleBundles: ["us.zoom.xos"]
      )
    )
    XCTAssertTrue(
      NowPlayingPausePolicy.isDefinitelyCallAudio(
        audibleBundles: ["us.zoom.xos", "com.apple.FaceTime"]
      )
    )
  }

  func testMediaOrUnknownAudioIsNotCallAudio() {
    XCTAssertFalse(
      NowPlayingPausePolicy.isDefinitelyCallAudio(
        audibleBundles: ["com.google.Chrome"]
      )
    )
    XCTAssertFalse(
      NowPlayingPausePolicy.isDefinitelyCallAudio(
        audibleBundles: ["us.zoom.xos", "com.spotify.client"]
      )
    )
    XCTAssertFalse(
      NowPlayingPausePolicy.isDefinitelyCallAudio(audibleBundles: [])
    )
  }

  func testResumeIsSentOnlyWhenMediaIsStillPaused() {
    // Still paused: resume what this take paused.
    XCTAssertTrue(NowPlayingPausePolicy.shouldResumeAfterPause(playbackRate: 0.0))

    // Playing again - the pause never landed or the user restarted: playing
    // would pause it.
    XCTAssertFalse(NowPlayingPausePolicy.shouldResumeAfterPause(playbackRate: 1.0))
    XCTAssertFalse(NowPlayingPausePolicy.shouldResumeAfterPause(playbackRate: 0.5))

    // No session: cannot confirm still paused, so do not play. Paused
    // session-less media stays paused for the user to resume by hand,
    // which is far better than starting something that was never playing.
    XCTAssertFalse(NowPlayingPausePolicy.shouldResumeAfterPause(playbackRate: nil))
  }
}
