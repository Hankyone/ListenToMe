import Foundation

/// Decide how to pause and restore Now Playing. Chromium (YouTube in Chrome)
/// ignores MediaRemote pause, so a still-playing session needs the hardware
/// play/pause key. That key toggles, so it must not fire when nothing was
/// playing or a paused tab starts on key-up.
enum NowPlayingPausePolicy {
  /// After we pause playing media, keep the mic closed so the last video
  /// word is not the first word of the take. Same length as the key-up tail.
  static let captureLeadAfterPause: TimeInterval = 0.40
  static var captureLeadNanoseconds: UInt64 {
    UInt64(captureLeadAfterPause * 1_000_000_000)
  }

  static func shouldResumeNowPlaying(wasPlaying: Bool) -> Bool {
    wasPlaying
  }

  static func shouldDelayCapture(didPausePlayback: Bool) -> Bool {
    didPausePlayback
  }

  static func shouldSendMediaKey(
    wasPlaying: Bool,
    stillPlayingAfterRemotePause: Bool
  ) -> Bool {
    wasPlaying && stillPlayingAfterRemotePause
  }
}
