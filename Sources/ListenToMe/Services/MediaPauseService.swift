import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// Mutes output instantly so dictation never talks over a video, then
/// pauses whatever is actually making sound and resumes it on release.
///
/// Now Playing reads have been redacted for third-party apps since
/// macOS 15.4  -  they report "not playing" while Spotify or YouTube is
/// audibly playing  -  so detection never reads Now Playing. The ground
/// truth is Core Audio: which processes are running an output stream.
/// MediaRemote commands still route fine and pause well-behaved players;
/// Chromium ignores them and answers only the hardware play/pause key,
/// which toggles blindly, so it is the second attempt and only for
/// media-capable apps. `end()` resumes with exactly the mechanism that
/// paused, and only when nothing has started playing since.
///
/// Everything runs on a utility queue  -  never the main thread.
/// `NSAppleScript.execute` on MainActor froze the overlay.
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

  init() {
    queue.async {
      MediaRemoteControl.prepare()
    }
  }

  /// Mutes output, then pauses whatever is making sound. Idle takes return
  /// immediately so the mic opens at once; a take started over real
  /// playback holds the mic (bounded) until output is quiet, so the last
  /// word of a video never bleeds into the transcript. Returns true when
  /// media was playing  -  it only feeds a latency trace.
  func arm() async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async { [weak self] in
        continuation.resume(returning: self?.armSync() ?? false)
      }
    }
  }

  func end() {
    queue.async { [weak self] in
      self?.endSync()
    }
  }

  private func armSync() -> Bool {
    endSync()
    shouldResumeNowPlaying = false
    didPauseWithMediaKey = false
    appsToResume = []

    muteFast()

    // Idle takes open the mic immediately; only real playback holds it.
    guard anyProcessPlayingOutput() else { return false }
    // A notification ping is audible for a moment too; only chase sound
    // that persists.
    Thread.sleep(forTimeInterval: 0.12)
    guard anyProcessPlayingOutput() else { return false }

    // Call audio is not media: never pause it, never hold the mic for it.
    if NowPlayingPausePolicy.isDefinitelyCallAudio(
      audibleBundles: audibleProcessBundleIDs()
    ) {
      return false
    }

    setOutputMuted(true)

    // Music and Spotify answer AppleScript, which targets the app exactly
    //  -  no routing ambiguity no matter who owns the Now Playing session.
    pauseAudibleScriptableApps()

    // Apps we just paused keep their stream alive while draining
    // (Spotify: over a second), so they are still "audible". Exclude them
    // before choosing the next mechanism, or the hardware key below could
    // toggle a just-paused player straight back on.
    var stillAudible = audibleProcessBundleIDs()
    for app in Self.scriptablePlayers where appsToResume.contains(app.name) {
      stillAudible.remove(app.bundleID)
    }
    if !stillAudible.isEmpty {
      if NowPlayingPausePolicy.shouldSendMediaKey(audibleBundles: stillAudible) {
        // Chromium ignores MediaRemote commands entirely; the hardware key
        // reaches it. The key toggles blindly, so it must be the ONLY
        // thing sent to these apps  -  a MediaRemote pause first would
        // pause, and the key would then toggle the same player back on
        // mid-take. Pause and resume pair by construction.
        MediaKey.playPause()
        didPauseWithMediaKey = true
      } else {
        // MediaRemote commands reach whoever owns the Now Playing session.
        MediaRemoteControl.pause()
        shouldResumeNowPlaying = true
      }
    }

    // When the output device refuses to mute (some displays and docks),
    // the only thing keeping the last video word out of the transcript is
    // holding the mic until playback has actually stopped.
    if !mutedViaCoreAudio && !didDuckVolume {
      waitUntilOutputQuiet(timeout: 2.5)
    }
    return true
  }

  private static let scriptablePlayers: [(name: String, bundleID: String)] = [
    ("Music", "com.apple.Music"),
    ("Spotify", "com.spotify.client"),
  ]

  private func pauseAudibleScriptableApps() {
    let audible = audibleProcessBundleIDs()
    for app in Self.scriptablePlayers where audible.contains(app.bundleID) {
      // The process is audibly playing, so it has a player to pause. A
      // first attempt may show a one-time Automation consent prompt; a
      // refusal just fails the script fast and we try the next mechanism.
      if runOSASCRIPT("tell application \"\(app.name)\" to pause") != nil {
        appsToResume.append(app.name)
      }
    }
  }

  private func resumeMediaApp(_ app: String) {
    guard let bundleID = Self.scriptablePlayers.first(where: {
      $0.name == app
    })?.bundleID,
      NSWorkspace.shared.runningApplications.contains(where: {
        $0.bundleIdentifier == bundleID
      })
    else { return }
    _ = runOSASCRIPT("tell application \"\(app)\" to play")
  }

  /// Waits for output to go quiet. Players keep their stream alive for
  /// over a second after pausing (Spotify lingers ~1.4s), so the window
  /// has to be generous.
  private func waitUntilOutputQuiet(timeout: TimeInterval = 1.6) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !anyProcessPlayingOutput() { return }
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  /// Ground truth from Core Audio: is any other process running an output
  /// stream right now? Now Playing reads lie or time out; this does not.
  private func anyProcessPlayingOutput() -> Bool {
    !audibleProcessPIDs().isEmpty
  }

  /// Bundle IDs of other processes currently running an output stream.
  /// Browser audio runs in helper processes with no bundle identity, so a
  /// helper resolves to its parent app (Chrome Helper -> com.google.Chrome).
  private func audibleProcessBundleIDs() -> Set<String> {
    var bundles = Set<String>()
    for pid in audibleProcessPIDs() {
      if let bundle = bundleID(for: pid) {
        bundles.insert(bundle)
      }
    }
    return bundles
  }

  private func bundleID(for pid: pid_t) -> String? {
    var current = pid
    for _ in 0..<4 {
      if let bundle = NSRunningApplication(processIdentifier: current)?
        .bundleIdentifier
      {
        return bundle
      }
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
      guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
        return nil
      }
      let parent = info.kp_eproc.e_ppid
      guard parent > 1, parent != current else { return nil }
      current = parent
    }
    return nil
  }

  private func audibleProcessPIDs() -> [pid_t] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var listAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(system, &listAddress) else { return [] }
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size)
      == noErr
    else { return [] }
    var ids = [AudioObjectID](
      repeating: 0,
      count: Int(size) / MemoryLayout<AudioObjectID>.size
    )
    guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &ids)
      == noErr
    else { return [] }

    let selfPID = ProcessInfo.processInfo.processIdentifier
    var audible: [pid_t] = []
    for id in ids where id != 0 {
      var pidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var pid: pid_t = 0
      var pidSize = UInt32(MemoryLayout<pid_t>.size)
      guard AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid)
        == noErr, pid != selfPID
      else { continue }

      var runAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      guard AudioObjectHasProperty(id, &runAddress) else { continue }
      var running: UInt32 = 0
      var runSize = UInt32(MemoryLayout<UInt32>.size)
      if AudioObjectGetPropertyData(id, &runAddress, 0, nil, &runSize, &running)
        == noErr, running != 0
      {
        audible.append(pid)
      }
    }
    return audible
  }

  private func endSync() {
    // Resume with exactly what paused. The key toggles, so it goes out only
    // when it also did the pausing and nothing is playing now  -  a user
    // who restarted their media by hand mid-take must not be paused again.
    // MediaRemote play is a precise command and a no-op when already
    // playing.
    // Resume only when output is quiet: if audio is playing again, the
    // user restarted their media by hand mid-take and must not be paused
    // again, and if our pause never landed there is nothing to resume.
    let quiet = !anyProcessPlayingOutput()
    if didPauseWithMediaKey {
      if quiet {
        MediaKey.playPause()
      }
    } else if shouldResumeNowPlaying, quiet {
      MediaRemoteControl.play()
    }
    for app in appsToResume {
      resumeMediaApp(app)
    }
    restoreOutput()
    shouldResumeNowPlaying = false
    didPauseWithMediaKey = false
    appsToResume = []
  }

  /// Core Audio only  -  no osascript, so idle takes are not held up.
  private func muteFast() {
    let caMuted = readCoreAudioOutputMuted()
    volumeBeforeSession = readVirtualMainVolume()
    mutedViaCoreAudio = setCoreAudioOutputMuted(true)
    mutedOutputBeforeSession = caMuted ?? false
    if let volume = volumeBeforeSession, volume > 0 {
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
    } catch {
      return nil
    }
    // A pending Automation consent prompt blocks osascript until the user
    // answers. Never let that stall the take: give up and let the next
    // mechanism try instead.
    let deadline = Date().addingTimeInterval(1.5)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      process.terminate()
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }
}

/// Hardware play/pause key. Chromium listens to this and ignores MediaRemote
/// play. It toggles, so callers must only send it when media was audibly
/// playing and every other pause attempt failed.
private enum MediaKey {
  private static let playPauseKey: UInt32 = 16

  static func playPause() {
    send(down: true)
    send(down: false)
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

/// Send play/pause commands to the system Now Playing session without
/// linking MediaRemote. Commands route fine on macOS 15.4+; reads of Now
/// Playing state do not (redacted for third-party apps), which is why
/// this enum deliberately exposes no way to read state  -  detection uses
/// Core Audio output streams instead. Command 0 = play, 1 = pause.
private enum MediaRemoteControl {
  private static let frameworkPath =
    "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

  private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Void

  private static let handle: UnsafeMutableRawPointer? = dlopen(
    frameworkPath,
    RTLD_NOW
  )
  private static let sendFn: SendCommand? = {
    guard let handle, let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
    else {
      return nil
    }
    return unsafeBitCast(symbol, to: SendCommand.self)
  }()

  static func prepare() {
    _ = handle
  }

  static func play() {
    sendFn?(0, nil)
  }

  static func pause() {
    sendFn?(1, nil)
  }
}
