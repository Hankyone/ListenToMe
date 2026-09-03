import Foundation

enum MediaPauseRoute: Equatable, Sendable {
  case mediaRemote
}

struct MediaPausePlan: Equatable, Sendable {
  let route: MediaPauseRoute
  let targetBundles: Set<String>
}

/// Chooses how to pause the media that was active when a take began.
///
/// Core Audio supplies process activity. A bundle producing microphone input is
/// treated as a call, including browser-based calls such as Meet. Known call
/// apps are excluded as well.
///
/// There is exactly one mechanism: explicit MediaRemote pause (command 1) and
/// play (command 0). These are precise commands, not toggles, so pausing an
/// already-paused player is a no-op instead of starting it. The hardware
/// play/pause key is never used: it toggles blindly, which is what started
/// paused Twitter videos on push-to-talk press and stopped them on release.
enum NowPlayingPausePolicy {
  /// Give the player 200 ms to stop producing audible samples before opening
  /// the microphone. This is fixed, never a poll with a multi-second timeout.
  static let captureLeadAfterPause: TimeInterval = 0.20
  static var captureLeadNanoseconds: UInt64 {
    UInt64(captureLeadAfterPause * 1_000_000_000)
  }

  /// Bundle families used to tie a helper process to its parent app, so a
  /// live web call is never mistaken for media (Chrome output + Chrome input
  /// = call, not music). These prefixes are only for that matching, never
  /// for choosing a pause mechanism: everything pauses via MediaRemote.
  private static let browserBundlePrefixes = [
    "com.google.Chrome",
    "org.chromium.Chromium",
    "com.apple.Safari",
    "company.thebrowser.Browser",
    "org.mozilla.firefox",
    "com.microsoft.edgemac",
    "com.brave.Browser",
    "com.operasoftware.Opera",
    "com.vivaldi.Vivaldi",
    "com.kagi.kagimacOS",
    "com.spotify.client",
    "com.apple.Music",
    "com.apple.TV",
    "com.apple.QuickTimePlayerX",
    "com.apple.podcasts",
    "org.videolan.vlc",
    "com.colliderli.iina",
    "tv.plex.plexamp",
  ]

  private static let callBundlePrefixes = [
    "us.zoom.xos",
    "com.microsoft.teams",
    "com.apple.FaceTime",
    "com.webex.",
    "com.skype.",
    "com.hnc.Discord",
    "com.tinyspeck.slackmacgap",
  ]

  static func plan(
    audibleBundles: Set<String>,
    inputBundles: Set<String>
  ) -> MediaPausePlan? {
    let candidates = Set(audibleBundles.filter { bundle in
      !isKnownCallBundle(bundle)
        && !inputBundles.contains(where: {
          representsSameApplication($0, bundle)
        })
    })
    guard !candidates.isEmpty else { return nil }

    return MediaPausePlan(
      route: .mediaRemote,
      targetBundles: candidates
    )
  }

  /// Resume only when the Now Playing session confirms media is still paused
  /// (rate 0). A positive rate means the pause never landed or the user
  /// restarted playback mid-take: playing would pause it. nil means the
  /// session is gone or unreadable: playing would risk starting something
  /// the user never had playing, so leave it alone. Paused-without-session
  /// media simply stays paused for the user to resume by hand.
  static func shouldResumeAfterPause(playbackRate: Double?) -> Bool {
    guard let rate = playbackRate else { return false }
    return rate <= 0.01
  }

  /// Resume rule for a take: only the take that paused may resume, and it
  /// stands down when the session already reports playback (the user
  /// restarted mid-take). Unknown state resumes, because the take knows it
  /// paused: explicit play is idempotent, never a toggle-on.
  static func shouldResumePausedTake(
    didPause: Bool,
    currentPlaying: Bool?
  ) -> Bool {
    guard didPause else { return false }
    return currentPlaying != true
  }

  static func isDefinitelyCallAudio(audibleBundles: Set<String>) -> Bool {
    !audibleBundles.isEmpty
      && audibleBundles.allSatisfy(isKnownCallBundle)
  }

  static func isKnownCallBundle(_ bundle: String) -> Bool {
    callBundlePrefixes.contains { bundle.hasPrefix($0) }
  }

  /// Helpers from one browser can have slightly different bundle identifiers.
  /// Prefix-family matching keeps an output helper and an input helper tied to
  /// the same browser, so a live web call is never mistaken for media.
  private static func representsSameApplication(
    _ first: String,
    _ second: String
  ) -> Bool {
    if first == second { return true }
    return (browserBundlePrefixes + callBundlePrefixes).contains { prefix in
      first.hasPrefix(prefix) && second.hasPrefix(prefix)
    }
  }
}
