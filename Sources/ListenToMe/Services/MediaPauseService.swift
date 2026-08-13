import Foundation

/// Pauses common media apps and mutes system output while dictating, then
/// restores both when the take ends (Handy-style ducking + media pause).
///
/// All `osascript` work runs on a utility queue  -  never the main thread.
/// `NSAppleScript.execute` on MainActor was freezing the overlay timer and
/// waveform for 5–8s at the start of every take.
final class MediaPauseService: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "ca.hankyone.ListenToMe.mediaPause",
    qos: .utility
  )
  private var mutedOutputBeforeSession: Bool?
  private var didMuteOutput = false
  private var appsToResume: [String] = []
  /// Bumped on each begin/end so a late begin can't clobber a finished take.
  private var generation: UInt64 = 0

  func begin() {
    queue.async { [weak self] in
      self?.beginSync()
    }
  }

  func end() {
    queue.async { [weak self] in
      self?.endSync()
    }
  }

  private func beginSync() {
    endSync()
    generation &+= 1
    let session = generation

    let paused = pausePlayingMediaApps()
    guard session == generation else {
      // Take already ended while we were scripting  -  put media back.
      for app in paused {
        resumeMediaApp(app)
      }
      return
    }

    appsToResume = paused
    mutedOutputBeforeSession = readOutputMuted()
    setOutputMuted(true)
    didMuteOutput = true
  }

  private func endSync() {
    generation &+= 1
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
      if runOSASCRIPT(script)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
    _ = runOSASCRIPT(script)
  }

  private func readOutputMuted() -> Bool? {
    let script = "output muted of (get volume settings)"
    guard let result = runOSASCRIPT(script)?
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
    _ = runOSASCRIPT(script)
  }

  /// Prefer `/usr/bin/osascript` over `NSAppleScript` so this never has to
  /// touch the main thread (NSAppleScript is historically main-bound).
  private func runOSASCRIPT(_ source: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }
}
