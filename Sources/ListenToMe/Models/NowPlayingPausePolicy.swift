import Foundation

/// Decide whether the system Now Playing session should be paused and later
/// resumed. `MRMediaRemoteSendCommand` reports command delivery, not whether
/// anything was actually playing, so a paused YouTube tab still "succeeds"
/// pause and would start on key-up if we trusted that return value.
enum NowPlayingPausePolicy {
  enum Playback: Equatable {
    case playing
    case idle
    case unknown
  }

  /// Duck when we know it is playing. Also duck when the query failed so a
  /// live browser tab still pauses, but do not resume in that case.
  static func shouldSendPause(_ playback: Playback) -> Bool {
    playback != .idle
  }

  static func shouldResume(_ playback: Playback) -> Bool {
    playback == .playing
  }
}
