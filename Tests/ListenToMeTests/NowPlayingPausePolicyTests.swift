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

  func testBrowserAudioUsesOnePairedMediaKeyRoute() {
    let plan = NowPlayingPausePolicy.plan(
      audibleBundles: ["com.google.Chrome"],
      inputBundles: []
    )

    XCTAssertEqual(plan?.route, .mediaKey)
    XCTAssertEqual(
      plan?.targetBundles,
      Set(["com.google.Chrome"])
    )
  }

  func testBrowserHelperAudioMayUseMediaKey() {
    XCTAssertTrue(
      NowPlayingPausePolicy.shouldSendMediaKey(
        audibleBundles: ["com.google.Chrome.helper"]
      )
    )
  }

  func testSpotifyUsesThePairedMediaKeyRoute() {
    let plan = NowPlayingPausePolicy.plan(
      audibleBundles: ["com.spotify.client"],
      inputBundles: []
    )

    XCTAssertEqual(plan?.route, .mediaKey)
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

    XCTAssertEqual(plan?.route, .mediaKey)
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
    XCTAssertFalse(
      NowPlayingPausePolicy.shouldSendMediaKey(audibleBundles: [])
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

  func testPauseToggleIsSentOnlyWhenMediaIsActuallyPlaying() {
    // Playing: the toggle may go out.
    XCTAssertTrue(NowPlayingPausePolicy.shouldSendPauseToggle(playbackRate: 1.0))
    XCTAssertTrue(NowPlayingPausePolicy.shouldSendPauseToggle(playbackRate: 0.5))
    XCTAssertTrue(NowPlayingPausePolicy.shouldSendPauseToggle(playbackRate: 2.0))

    // Definitively paused: the toggle would start the video. Never send it.
    XCTAssertFalse(NowPlayingPausePolicy.shouldSendPauseToggle(playbackRate: 0.0))
    XCTAssertFalse(NowPlayingPausePolicy.shouldSendPauseToggle(playbackRate: -0.5))

    // No session (some players never register one): treat as not playing,
    // so a paused video is never toggled back on.
    XCTAssertFalse(NowPlayingPausePolicy.shouldSendPauseToggle(playbackRate: nil))
  }

  func testResumeToggleIsSentOnlyWhenMediaIsStillPaused() {
    // Still paused: the toggle resumes what this take paused.
    XCTAssertTrue(NowPlayingPausePolicy.shouldSendResumeToggle(playbackRate: 0.0))

    // Playing again - the pause never landed or the user restarted: a
    // toggle would pause it.
    XCTAssertFalse(NowPlayingPausePolicy.shouldSendResumeToggle(playbackRate: 1.0))
    XCTAssertFalse(NowPlayingPausePolicy.shouldSendResumeToggle(playbackRate: 0.5))

    // No session: cannot confirm still paused, so do not toggle.
    XCTAssertFalse(NowPlayingPausePolicy.shouldSendResumeToggle(playbackRate: nil))
  }
}
