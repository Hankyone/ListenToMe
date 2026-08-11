import AppKit
import Foundation

/// Pauses common media apps and mutes system output while dictating, then
/// restores both when the take ends (Handy-style ducking + media pause).
@MainActor
final class MediaPauseService {
  private var mutedOutputBeforeSession: Bool?
  private var didMuteOutput = false
  private var appsToResume: [String] = []

  func begin() {
    end()

    appsToResume = pausePlayingMediaApps()
    mutedOutputBeforeSession = readOutputMuted()
    setOutputMuted(true)
    didMuteOutput = true
  }

  func end() {
    if didMuteOutput {
      setOutputMuted(mutedOutputBeforeSession ?? false)
    }
    for app in appsToResume {
      resumeMediaApp(app)
    }
    mutedOutputBeforeSession = nil
    didMuteOutput = false
    appsToResume = []
  }

  private func pausePlayingMediaApps() -> [String] {
    let candidates = ["Music", "Spotify", "TV", "QuickTime Player"]
    var paused: [String] = []
    for app in candidates {
      let script = """
        tell application "System Events"
          if not (exists process "\(app)") then return "idle"
        end tell
        tell application "\(app)"
          try
            if player state is playing then
              pause
              return "paused"
            end if
          end try
        end tell
        return "idle"
        """
      if runAppleScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines)
        == "paused"
      {
        paused.append(app)
      }
    }
    return paused
  }

  private func resumeMediaApp(_ app: String) {
    let script = """
      tell application "System Events"
        if not (exists process "\(app)") then return
      end tell
      tell application "\(app)"
        try
          play
        end try
      end tell
      """
    _ = runAppleScript(script)
  }

  private func readOutputMuted() -> Bool? {
    let script = "output muted of (get volume settings)"
    guard let result = runAppleScript(script)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    else {
      return nil
    }
    switch result {
    case "true": return true
    case "false": return false
    default: return nil
    }
  }

  private func setOutputMuted(_ muted: Bool) {
    let script = "set volume output muted \(muted ? "true" : "false")"
    _ = runAppleScript(script)
  }

  private func runAppleScript(_ source: String) -> String? {
    var error: NSDictionary?
    guard
      let script = NSAppleScript(source: source)
    else {
      return nil
    }
    let result = script.executeAndReturnError(&error)
    if error != nil { return nil }
    return result.stringValue
  }
}
