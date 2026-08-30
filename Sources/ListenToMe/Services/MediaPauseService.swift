import AppKit
import CoreAudio
import Darwin
import Foundation

/// Pauses Now Playing (YouTube in Chrome, Music, Spotify, …) and mutes
/// system output while dictating, then restores both when the take ends.
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
  private var mutedViaCoreAudio = false
  private var shouldResumeNowPlaying = false
  private var appsToResume: [String] = []
  /// Bumped on each begin/end so a late begin can't clobber a finished take.
  private var generation: UInt64 = 0

  func begin(onFinished: (() -> Void)? = nil) {
    queue.async { [weak self] in
      self?.beginSync()
      onFinished?()
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

    let playback = MediaRemoteControl.playback()
    if NowPlayingPausePolicy.shouldSendPause(playback) {
      _ = MediaRemoteControl.pause()
    }
    let resumeNowPlaying = NowPlayingPausePolicy.shouldResume(playback)
    let paused = pausePlayingMediaApps()
    guard session == generation else {
      if resumeNowPlaying { _ = MediaRemoteControl.play() }
      for app in paused {
        resumeMediaApp(app)
      }
      return
    }

    shouldResumeNowPlaying = resumeNowPlaying
    appsToResume = paused
    if let muted = readCoreAudioOutputMuted() {
      mutedOutputBeforeSession = muted
      mutedViaCoreAudio = setCoreAudioOutputMuted(true)
    } else {
      mutedOutputBeforeSession = readOutputMuted()
      mutedViaCoreAudio = false
    }
    if !mutedViaCoreAudio {
      setOutputMuted(true)
    }
    didMuteOutput = true
  }

  private func endSync() {
    generation &+= 1
    if shouldResumeNowPlaying {
      _ = MediaRemoteControl.play()
    }
    if didMuteOutput {
      let wasMuted = mutedOutputBeforeSession ?? false
      if mutedViaCoreAudio {
        _ = setCoreAudioOutputMuted(wasMuted)
      } else {
        setOutputMuted(wasMuted)
      }
    }
    for app in appsToResume {
      resumeMediaApp(app)
    }
    mutedOutputBeforeSession = nil
    didMuteOutput = false
    mutedViaCoreAudio = false
    shouldResumeNowPlaying = false
    appsToResume = []
  }

  private func pausePlayingMediaApps() -> [String] {
    var paused: [String] = []
    for app in Self.mediaApps where isRunning(bundleID: app.bundleID) {
      let script = """
        tell application "\(app.name)"
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
        paused.append(app.name)
      }
    }
    return paused
  }

  private func isRunning(bundleID: String) -> Bool {
    NSWorkspace.shared.runningApplications.contains {
      $0.bundleIdentifier == bundleID
    }
  }

  private static let mediaApps: [(name: String, bundleID: String)] = [
    ("Music", "com.apple.Music"),
    ("Spotify", "com.spotify.client"),
    ("TV", "com.apple.TV"),
    ("QuickTime Player", "com.apple.QuickTimePlayerX"),
  ]

  private func resumeMediaApp(_ app: String) {
    let bundleID = Self.mediaApps.first { $0.name == app }?.bundleID
    if let bundleID, !isRunning(bundleID: bundleID) { return }
    let script = """
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

  private func defaultOutputMuteAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private func readCoreAudioOutputMuted() -> Bool? {
    guard let deviceID = MicrophoneInputCatalog.defaultOutputDeviceID() else {
      return nil
    }
    var address = defaultOutputMuteAddress()
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &value
    )
    guard status == noErr else { return nil }
    return value != 0
  }

  private func setCoreAudioOutputMuted(_ muted: Bool) -> Bool {
    guard let deviceID = MicrophoneInputCatalog.defaultOutputDeviceID() else {
      return false
    }
    var address = defaultOutputMuteAddress()
    var value: UInt32 = muted ? 1 : 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectSetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      size,
      &value
    ) == noErr
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

/// Pause/play the system Now Playing session (Chrome YouTube, Music, …)
/// without linking the private MediaRemote framework.
private enum MediaRemoteControl {
  private static let frameworkPath =
    "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
  private static let handle: UnsafeMutableRawPointer? = dlopen(
    frameworkPath,
    RTLD_LAZY
  )
  private static let callbackQueue = DispatchQueue(
    label: "ca.hankyone.ListenToMe.mediaRemote.callback"
  )
  /// Touching this registers once; GetNowPlaying can return nothing beforehand.
  private static let didRegister: Bool = {
    registerForNotifications()
    return true
  }()

  static func playback() -> NowPlayingPausePolicy.Playback {
    _ = didRegister
    guard
      let handle,
      let symbol = dlsym(
        handle,
        "MRMediaRemoteGetNowPlayingApplicationIsPlaying"
      )
    else {
      return .unknown
    }
    typealias Handler = @convention(block) (DarwinBoolean) -> Void
    typealias Get = @convention(c) (DispatchQueue, Handler) -> Void
    let get = unsafeBitCast(symbol, to: Get.self)

    let box = Box()
    let lock = DispatchSemaphore(value: 0)
    let handler: Handler = { isPlaying in
      box.value = isPlaying.boolValue ? .playing : .idle
      lock.signal()
    }
    get(callbackQueue, handler)
    if lock.wait(timeout: .now() + 0.3) == .timedOut {
      return .unknown
    }
    return box.value
  }

  static func pause() -> Bool { send(1) }
  static func play() -> Bool { send(0) }

  private static func registerForNotifications() {
    guard
      let handle,
      let symbol = dlsym(
        handle,
        "MRMediaRemoteRegisterForNowPlayingNotifications"
      )
    else {
      return
    }
    typealias Register = @convention(c) (DispatchQueue) -> Void
    unsafeBitCast(symbol, to: Register.self)(callbackQueue)
  }

  private static func send(_ command: Int32) -> Bool {
    guard
      let handle,
      let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
    else {
      return false
    }
    typealias Send = @convention(c) (Int32, CFDictionary?) -> UInt8
    let send = unsafeBitCast(symbol, to: Send.self)
    return send(command, nil) != 0
  }

  private final class Box: @unchecked Sendable {
    var value = NowPlayingPausePolicy.Playback.unknown
  }
}
