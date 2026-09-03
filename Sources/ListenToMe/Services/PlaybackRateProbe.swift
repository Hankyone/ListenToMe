import Darwin
import Foundation

/// Reads the Now Playing session's playback rate - the one signal that
/// reliably says whether media is actually playing on recent macOS, where
/// reading Now Playing state through MediaRemote's old entry points has
/// been redacted. A playing session reports a positive rate (1.0 for normal
/// speed); a paused one reports 0. Returns nil when no session exists or
/// the private class cannot be reached, so callers can fall back.
///
/// Must never run on the main thread; call from the media queue.
enum PlaybackRateProbe {
  private static let frameworkPath =
    "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

  private static let handle: UnsafeMutableRawPointer? = dlopen(
    frameworkPath,
    RTLD_NOW
  )

  private static let localNowPlayingItemSelector = NSSelectorFromString(
    "localNowPlayingItem"
  )
  private static let nowPlayingInfoSelector = NSSelectorFromString(
    "nowPlayingInfo"
  )
  private static let rateKey = "kMRMediaRemoteNowPlayingInfoPlaybackRate"

  static func currentRate() -> Double? {
    guard handle != nil else { return nil }
    guard let requestClass = NSClassFromString("MRNowPlayingRequest")
      as? NSObject.Type,
      requestClass.responds(to: localNowPlayingItemSelector)
    else { return nil }

    let item = requestClass.perform(localNowPlayingItemSelector)?
      .takeUnretainedValue()
    guard let item, item.responds(to: nowPlayingInfoSelector) else {
      return nil
    }

    let info = item.perform(nowPlayingInfoSelector)?
      .takeUnretainedValue()
    guard let info = info as? NSDictionary else { return nil }
    guard let number = info[rateKey] as? NSNumber else { return nil }
    return number.doubleValue
  }
}
