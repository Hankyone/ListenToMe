import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// Pauses Now Playing, then the hardware play/pause key if a browser ignored
/// the command, and mutes output so dictation is never talking over a video.
///
/// All AppleScript and MediaRemote waits run on a utility queue  -  never the
/// main thread. `NSAppleScript.execute` on MainActor froze the overlay.
final class MediaPauseService: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "ca.hankyone.ListenToMe.mediaPause",
    qos: .userInitiated
  )
  private var mutedOutputBeforeSession: Bool?
  private var volumeBeforeSession: Float?
  private var didMuteOutput = false
  private var didDuckVolume = false
  private var mutedViaCoreAudio = false
  private var shouldResumeNowPlaying = false
  private var didPauseWithMediaKey = false
  private var appsToResume: [String] = []
  /// Bumped on each begin/end so a late begin can't clobber a finished take.
  private var generation: UInt64 = 0

  init() {
    queue.async {
      MediaRemoteControl.prepare()
    }
  }

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

    // Mute first so a slow pause still ducks YouTube immediately.
    muteOutput()

    let wasPlaying = MediaRemoteControl.isPlaying()
    if wasPlaying {
      MediaRemoteControl.pause()
      Thread.sleep(forTimeInterval: 0.08)
    } else {
      // No-op when idle. Catches a false-negative Now Playing read.
      MediaRemoteControl.pause()
    }
    let pausedApps = pausePlayingMediaApps()
    var usedKey = false
    if NowPlayingPausePolicy.shouldSendMediaKey(
      wasPlaying: wasPlaying,
      stillPlayingAfterRemotePause: MediaRemoteControl.isPlaying()
    ) {
      MediaKey.playPause()
      usedKey = true
    }

    guard session == generation else {
      if NowPlayingPausePolicy.shouldResumeNowPlaying(wasPlaying: wasPlaying) {
        MediaKey.playPause()
      }
      for app in pausedApps {
        resumeMediaApp(app)
      }
      restoreOutput()
      return
    }

    shouldResumeNowPlaying = NowPlayingPausePolicy.shouldResumeNowPlaying(
      wasPlaying: wasPlaying
    )
    didPauseWithMediaKey = usedKey
    appsToResume = pausedApps
  }

  private func endSync() {
    generation &+= 1
    if shouldResumeNowPlaying || didPauseWithMediaKey {
      MediaKey.playPause()
    }
    for app in appsToResume {
      resumeMediaApp(app)
    }
    restoreOutput()
    shouldResumeNowPlaying = false
    didPauseWithMediaKey = false
    appsToResume = []
  }

  private func muteOutput() {
    let osMuted = readOutputMuted()
    let caMuted = readCoreAudioOutputMuted()
    mutedOutputBeforeSession = osMuted ?? caMuted ?? false
    volumeBeforeSession = readVirtualMainVolume()

    setOutputMuted(true)
    mutedViaCoreAudio = setCoreAudioOutputMuted(true)

    let nowMuted = readOutputMuted() == true || readCoreAudioOutputMuted() == true
    if !nowMuted, let volume = volumeBeforeSession, volume > 0 {
      didDuckVolume = setVirtualMainVolume(0)
    } else {
      didDuckVolume = false
    }
    didMuteOutput = true
  }

  private func restoreOutput() {
    guard didMuteOutput else { return }
    let wasMuted = mutedOutputBeforeSession ?? false
    if didDuckVolume, let volume = volumeBeforeSession {
      _ = setVirtualMainVolume(volume)
    }
    if mutedViaCoreAudio {
      _ = setCoreAudioOutputMuted(wasMuted)
    }
    setOutputMuted(wasMuted)
    mutedOutputBeforeSession = nil
    volumeBeforeSession = nil
    didMuteOutput = false
    didDuckVolume = false
    mutedViaCoreAudio = false
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

  private func virtualMainVolumeAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private func readCoreAudioOutputMuted() -> Bool? {
    guard let deviceID = MicrophoneInputCatalog.defaultOutputDeviceID() else {
      return nil
    }
    var address = defaultOutputMuteAddress()
    guard AudioObjectHasProperty(deviceID, &address) else { return nil }
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
    guard AudioObjectHasProperty(deviceID, &address) else { return false }
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
      settable.boolValue
    else {
      return false
    }
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

  private func readVirtualMainVolume() -> Float? {
    guard let deviceID = MicrophoneInputCatalog.defaultOutputDeviceID() else {
      return nil
    }
    var address = virtualMainVolumeAddress()
    guard AudioObjectHasProperty(deviceID, &address) else { return nil }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &value
    )
    return status == noErr ? value : nil
  }

  private func setVirtualMainVolume(_ volume: Float) -> Bool {
    guard let deviceID = MicrophoneInputCatalog.defaultOutputDeviceID() else {
      return false
    }
    var address = virtualMainVolumeAddress()
    guard AudioObjectHasProperty(deviceID, &address) else { return false }
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
      settable.boolValue
    else {
      return false
    }
    var value = Float32(min(max(volume, 0), 1))
    let size = UInt32(MemoryLayout<Float32>.size)
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

/// Hardware play/pause key. Chromium listens to this and ignores MediaRemote
/// play. It toggles, so callers must only send it when playback was active.
private enum MediaKey {
  private static let playPauseKey: UInt32 = 16

  static func playPause() {
    let post = {
      send(down: true)
      send(down: false)
    }
    if Thread.isMainThread {
      post()
    } else {
      DispatchQueue.main.sync(execute: post)
    }
  }

  private static func send(down: Bool) {
    let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
    let data1 = Int((playPauseKey << 16) | ((down ? 0xA : 0xB) << 8))
    let event = NSEvent.otherEvent(
      with: .systemDefined,
      location: .zero,
      modifierFlags: flags,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      subtype: 8,
      data1: data1,
      data2: -1
    )
    event?.cgEvent?.post(tap: .cghidEventTap)
  }
}

/// Pause/play the system Now Playing session without linking MediaRemote.
private enum MediaRemoteControl {
  private static let frameworkPath =
    "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

  private typealias IsPlaying = @convention(c) (
    DispatchQueue, @escaping (Bool) -> Void
  ) -> Void
  private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Void
  private typealias Register = @convention(c) (DispatchQueue) -> Void

  private static let handle: UnsafeMutableRawPointer? = dlopen(
    frameworkPath,
    RTLD_NOW
  )
  private static let isPlayingFn: IsPlaying? = {
    guard let handle, let symbol = dlsym(
      handle,
      "MRMediaRemoteGetNowPlayingApplicationIsPlaying"
    ) else {
      return nil
    }
    return unsafeBitCast(symbol, to: IsPlaying.self)
  }()
  private static let sendFn: SendCommand? = {
    guard let handle, let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
    else {
      return nil
    }
    return unsafeBitCast(symbol, to: SendCommand.self)
  }()
  private static let didRegister: Bool = {
    guard let handle, let symbol = dlsym(
      handle,
      "MRMediaRemoteRegisterForNowPlayingNotifications"
    ) else {
      return false
    }
    unsafeBitCast(symbol, to: Register.self)(DispatchQueue.main)
    return true
  }()

  static func prepare() {
    _ = handle
    _ = didRegister
  }

  static func isPlaying() -> Bool {
    _ = didRegister
    guard let isPlayingFn else { return false }
    let box = Box()
    let lock = DispatchSemaphore(value: 0)
    isPlayingFn(DispatchQueue.main) { playing in
      box.value = playing
      lock.signal()
    }
    _ = lock.wait(timeout: .now() + 0.8)
    return box.value
  }

  static func pause() {
    sendFn?(1, nil)
  }

  private final class Box: @unchecked Sendable {
    var value = false
  }
}
