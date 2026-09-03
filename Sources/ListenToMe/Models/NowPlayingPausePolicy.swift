import Foundation

enum MediaPauseRoute: Equatable, Sendable {
  case mediaKey
  case mediaRemote
}

struct MediaPausePlan: Equatable, Sendable {
  let route: MediaPauseRoute
  let targetBundles: Set<String>
}

/// Chooses one pause mechanism for the media that was active when a take began.
///
/// Core Audio supplies process activity. A bundle producing microphone input is
/// treated as a call, including browser-based calls such as Meet. Known call
/// apps are excluded as well. The resulting plan is immutable so pause and
/// resume always use one matching command pair.
enum NowPlayingPausePolicy {
  /// Give the player 200 ms to stop producing audible samples before opening
  /// the microphone. This is fixed, never a poll with a multi-second timeout.
  static let captureLeadAfterPause: TimeInterval = 0.20
  static var captureLeadNanoseconds: UInt64 {
    UInt64(captureLeadAfterPause * 1_000_000_000)
  }

  /// Players that reliably answer the system play/pause key. The command is a
  /// toggle, so MediaPauseService sends it exactly once at each edge of a take.
  private static let mediaKeyBundlePrefixes = [
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

    let mediaKeyTargets = Set(candidates.filter(isMediaKeyBundle))
    if !mediaKeyTargets.isEmpty {
      return MediaPausePlan(
        route: .mediaKey,
        targetBundles: mediaKeyTargets
      )
    }

    return MediaPausePlan(
      route: .mediaRemote,
      targetBundles: candidates
    )
  }

  /// The hardware play/pause key toggles, so it may only go out when the
  /// Now Playing session confirms media is actually playing. A definitive
  /// rate of 0 means the player is paused: the toggle would start it, which
  /// is exactly what must never happen. nil means no session could be read
  /// (some players, like Twitter in a browser, never register one): treat
  /// that as not playing too, so a paused video is never toggled back on.
  /// The cost is that a genuinely playing video with no session is not
  /// paused, but that is far better than starting a paused one.
  static func shouldSendPauseToggle(playbackRate: Double?) -> Bool {
    guard let rate = playbackRate else { return false }
    return rate > 0.01
  }

  /// At take end the resume key may go out only when media is still
  /// paused: that resumes what this take paused. nil means the session is
  /// gone, so we cannot confirm it is still paused; do not toggle, or we
  /// might start something the user never had playing.
  static func shouldSendResumeToggle(playbackRate: Double?) -> Bool {
    guard let rate = playbackRate else { return false }
    return rate <= 0.01
  }

  static func shouldSendMediaKey(audibleBundles: Set<String>) -> Bool {
    audibleBundles.contains(where: isMediaKeyBundle)
  }

  static func isDefinitelyCallAudio(audibleBundles: Set<String>) -> Bool {
    !audibleBundles.isEmpty
      && audibleBundles.allSatisfy(isKnownCallBundle)
  }

  static func isKnownCallBundle(_ bundle: String) -> Bool {
    callBundlePrefixes.contains { bundle.hasPrefix($0) }
  }

  private static func isMediaKeyBundle(_ bundle: String) -> Bool {
    mediaKeyBundlePrefixes.contains { bundle.hasPrefix($0) }
  }

  /// Helpers from one browser can have slightly different bundle identifiers.
  /// Prefix-family matching keeps an output helper and an input helper tied to
  /// the same browser, so a live web call is never mistaken for media.
  private static func representsSameApplication(
    _ first: String,
    _ second: String
  ) -> Bool {
    if first == second { return true }
    return (mediaKeyBundlePrefixes + callBundlePrefixes).contains { prefix in
      first.hasPrefix(prefix) && second.hasPrefix(prefix)
    }
  }
}
