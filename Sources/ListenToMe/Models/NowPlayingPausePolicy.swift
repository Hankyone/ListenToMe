import Foundation

/// Decide whether the hardware play/pause key may be sent.
///
/// Now Playing reads have been redacted for third-party apps since
/// macOS 15.4: they report "not playing" even while Spotify or YouTube
/// is audibly playing, so they cannot drive any decision. The one signal
/// that always reflects real playback is Core Audio — which processes
/// are running an output stream. MediaRemote commands still reach
/// well-behaved players, but Chromium ignores them and answers only the
/// hardware key. That key toggles blindly, so it is a last resort, sent
/// only when the sound comes from a known media-capable app — never for
/// call or meeting audio, where a stray toggle could start a paused
/// playlist mid-call.
enum NowPlayingPausePolicy {
  /// Browsers and players that answer the hardware play/pause key.
  /// Browser audio runs in helper processes with no bundle identity of
  /// their own; callers resolve helpers to the parent app first
  /// (Chrome Helper -> com.google.Chrome).
  private static let mediaKeyAudibleBundlePrefixes = [
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
    "org.videolan.vlc",
    "com.colliderli.iina",
    "tv.plex.plexamp",
  ]

  static func shouldSendMediaKey(audibleBundles: Set<String>) -> Bool {
    audibleBundles.contains { bundle in
      mediaKeyAudibleBundlePrefixes.contains { bundle.hasPrefix($0) }
    }
  }

  /// Call and meeting apps. Their audio must never be paused, muted
  /// mid-call is already handled by the output mute, and the mic must
  /// not be held for them.
  private static let callBundlePrefixes = [
    "us.zoom.xos",
    "com.microsoft.teams",
    "com.apple.FaceTime",
    "com.webex.",
    "com.skype.",
    "com.hnc.Discord",
    "com.tinyspeck.slackmacgap",
  ]

  /// True only when every audible process is a known call or meeting app.
  /// An empty or unattributed set answers false: unknown sound gets the
  /// full pause treatment.
  static func isDefinitelyCallAudio(audibleBundles: Set<String>) -> Bool {
    !audibleBundles.isEmpty
      && audibleBundles.allSatisfy { bundle in
        callBundlePrefixes.contains { bundle.hasPrefix($0) }
      }
  }
}
