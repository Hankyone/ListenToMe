import Foundation

/// Now Playing snapshot read through the vendored mediaremote-adapter.
///
/// On macOS 15.4+ the system closed the Now Playing daemon to ordinary app
/// processes, so direct reads report "not playing" while music is blasting.
/// The adapter is loaded by /usr/bin/perl (an Apple-signed binary the system
/// still trusts), which is how shipping dictation apps solved this same
/// problem. BSD-3 licensed, see Resources/MediaRemoteAdapter/LICENSE-*.
struct MediaRemoteNowPlaying: Equatable, Sendable {
  /// True while the active session reports playback.
  let isPlaying: Bool
  let bundleIdentifier: String?
  let playbackRate: Double?
}

/// Runs the vendored adapter. All calls block the calling thread with a
/// bounded timeout, so call only from the media pause queue, never main.
enum MediaRemoteAdapterClient {
  private static let perlPath = "/usr/bin/perl"
  private static let scriptName = "mediaremote-adapter.pl"
  private static let frameworkName = "MediaRemoteAdapter.framework"
  private static let testClientName = "MediaRemoteAdapterTestClient"
  private static let directoryName = "MediaRemoteAdapter"

  /// Warms the adapter so the first real take does not pay process spawn.
  static func prewarm() {
    _ = isAvailable()
  }

  static func isAvailable(timeout: TimeInterval = 5) -> Bool {
    guard let paths = locate() else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: perlPath)
    process.arguments = [
      paths.script, paths.framework, paths.testClient, "test",
    ]
    return run(process, timeout: timeout) != nil
  }

  /// Reads the active Now Playing session once. nil means no session (or the
  /// adapter is missing/timed out), never "paused": callers must not resume
  /// on nil, only skip.
  static func currentSession(timeout: TimeInterval = 1.5) -> MediaRemoteNowPlaying? {
    guard let paths = locate() else { return nil }
    let outPipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: perlPath)
    process.arguments = [
      paths.script, paths.framework, "get", "--no-artwork",
    ]
    process.standardOutput = outPipe
    process.standardError = FileHandle.nullDevice
    guard run(process, timeout: timeout) != nil else { return nil }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    return parseGetOutput(data)
  }

  /// Sends an explicit command: 0 is play, 1 is pause. Both are idempotent,
  /// unlike the hardware toggle key.
  @discardableResult
  static func send(_ command: Int, timeout: TimeInterval = 1.0) -> Bool {
    guard let paths = locate() else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: perlPath)
    process.arguments = [
      paths.script, paths.framework, "send", String(command),
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return run(process, timeout: timeout) != nil
  }

  static func parseGetOutput(_ data: Data) -> MediaRemoteNowPlaying? {
    guard !data.isEmpty else { return nil }
    let trimmed = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty, trimmed != "null" else { return nil }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let playing = json["playing"] as? Bool ?? false
    let bundle = json["bundleIdentifier"] as? String
    let rate = (json["playbackRate"] as? NSNumber)?.doubleValue
    return MediaRemoteNowPlaying(
      isPlaying: playing,
      bundleIdentifier: bundle,
      playbackRate: rate
    )
  }

  private struct Paths {
    let script: String
    let framework: String
    let testClient: String
  }

  private static func locate() -> Paths? {
    let manager = FileManager.default
    var candidates: [URL] = []
    if let resources = Bundle.main.resourceURL {
      candidates.append(resources.appendingPathComponent(directoryName))
    }
    if let executable = Bundle.main.executableURL {
      candidates.append(
        executable.deletingLastPathComponent()
          .appendingPathComponent("../Resources/\(directoryName)")
          .standardized
      )
    }
    candidates.append(
      URL(fileURLWithPath: manager.currentDirectoryPath)
        .appendingPathComponent("Resources/\(directoryName)")
    )
    for dir in candidates {
      let script = dir.appendingPathComponent(scriptName).path
      let framework = dir.appendingPathComponent(frameworkName).path
      let testClient = dir.appendingPathComponent(testClientName).path
      var isDir: ObjCBool = false
      guard manager.fileExists(atPath: script),
        manager.fileExists(atPath: framework, isDirectory: &isDir),
        isDir.boolValue
      else { continue }
      return Paths(
        script: script,
        framework: framework,
        testClient: testClient
      )
    }
    return nil
  }

  /// Runs the process with a hard timeout. Returns termination status on
  /// success, nil on launch failure or timeout (the process is killed).
  @discardableResult
  private static func run(_ process: Process, timeout: TimeInterval) -> Int32? {
    do {
      try process.run()
    } catch {
      return nil
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      process.terminate()
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    return process.terminationStatus
  }
}
