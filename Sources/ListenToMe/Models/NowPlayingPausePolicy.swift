import Foundation

/// Decide how to pause and restore Now Playing. Chromium (YouTube in Chrome)
/// ignores MediaRemote pause, so a still-playing session needs the hardware
/// play/pause key. That key toggles, so it must not fire when nothing was
/// playing or a paused tab starts on key-up.
enum NowPlayingPausePolicy {
  enum Playback: Equatable {
    case playing
    case idle
    case unknown
  }

  static func shouldResumeNowPlaying(_ playback: Playback) -> Bool {
    playback == .playing
  }

  /// Hold the mic only when playback is confirmed. Idle and unknown must
  /// not delay the take.
  static func shouldHoldMicUntilPaused(_ playback: Playback) -> Bool {
    playback == .playing
  }

  static func shouldSendMediaKey(
    playback: Playback,
    stillPlayingAfterRemotePause: Bool
  ) -> Bool {
    playback == .playing && stillPlayingAfterRemotePause
  }
}
