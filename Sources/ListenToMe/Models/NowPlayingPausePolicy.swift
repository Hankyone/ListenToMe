import Foundation

/// Decide how to pause and restore Now Playing. Chromium (YouTube in Chrome)
/// ignores MediaRemote pause, so a still-playing session needs the hardware
/// play/pause key. That key toggles, so it must not fire when nothing was
/// playing or a paused tab starts on key-up.
enum NowPlayingPausePolicy {
  static func shouldResumeNowPlaying(wasPlaying: Bool) -> Bool {
    wasPlaying
  }

  /// Hold the mic only when Now Playing was actually playing. Idle takes
  /// must not wait on pause.
  static func shouldHoldMicUntilPaused(wasPlaying: Bool) -> Bool {
    wasPlaying
  }

  static func shouldSendMediaKey(
    wasPlaying: Bool,
    stillPlayingAfterRemotePause: Bool
  ) -> Bool {
    wasPlaying && stillPlayingAfterRemotePause
  }
}
