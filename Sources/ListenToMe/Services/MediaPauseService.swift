import AppKit
import CoreAudio
import Darwin
import Foundation

/// Pauses the media that was active when a take began, then resumes it when
/// that exact take releases the microphone.
///
/// Detection uses Core Audio process activity to spot audible apps cheaply,
/// then the Now Playing playback rate as ground truth before the hardware
/// play/pause key goes out: the key is a toggle, and the stream signal lags
/// a real pause by a second or two, so only the rate can tell a playing
/// video from a just-paused one. Control uses one mechanism per take: a
/// paired hardware play/pause key for known media apps, or paired
/// MediaRemote pause/play commands for other players. There is no global
/// output mute, no AppleScript, and no wait-for-silence loop.
final class MediaPauseService: @unchecked Sendable {
  private struct ActiveSession {
    let id: Int
    let plan: MediaPausePlan
  }

  private let queue = DispatchQueue(
    label: "ca.hankyone.ListenToMe.mediaPause",
    qos: .userInitiated
  )
  private var activeSession: ActiveSession?

  init() {
    queue.async {
      MediaRemoteControl.prepare()
    }
  }

  /// Returns after the pause command plus the fixed 200 ms capture lead.
  /// Idle takes and call-only audio return immediately.
  func arm(sessionID: Int) async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async { [weak self] in
        continuation.resume(
          returning: self?.armSync(sessionID: sessionID) ?? false
        )
      }
    }
  }

  /// Ends only the matching take. Stale and duplicate cleanup is a no-op.
  func end(sessionID: Int) {
    queue.async { [weak self] in
      self?.endSync(sessionID: sessionID)
    }
  }

  private func armSync(sessionID: Int) -> Bool {
    if let activeSession, activeSession.id == sessionID { return true }

    let audibleBundles = activeBundleIDs(
      property: kAudioProcessPropertyIsRunningOutput
    )
    guard !audibleBundles.isEmpty else { return false }

    let inputBundles = activeBundleIDs(
      property: kAudioProcessPropertyIsRunningInput
    )
    guard let plan = NowPlayingPausePolicy.plan(
      audibleBundles: audibleBundles,
      inputBundles: inputBundles
    ) else {
      return false
    }

    // A stale session from an aborted take would toggle its pause back on
    // here, and the new take would toggle it again. When both takes drive
    // the same route, the new take simply adopts the existing pause; the
    // same number of key presses still pair up by take end.
    var adoptedPlan: MediaPausePlan?
    if let activeSession {
      if activeSession.plan.route == plan.route {
        adoptedPlan = activeSession.plan
      } else {
        resume(activeSession.plan)
      }
      self.activeSession = nil
    }

    if let adoptedPlan {
      activeSession = ActiveSession(id: sessionID, plan: adoptedPlan)
      Thread.sleep(
        forTimeInterval: NowPlayingPausePolicy.captureLeadAfterPause
      )
      return true
    }

    switch plan.route {
    case .mediaKey:
      // The key toggles, so it goes out only when the Now Playing session
      // confirms media is actually playing. The stream signal above lags a
      // pause by a second or two while the player drains; the rate does
      // not. Without this check, a take over a just-paused video would
      // toggle it straight back on.
      let rate = PlaybackRateProbe.currentRate()
      guard NowPlayingPausePolicy.shouldSendPauseToggle(playbackRate: rate)
      else {
        return false
      }
      _ = MediaKey.playPause()
    case .mediaRemote:
      guard MediaRemoteControl.pause() else { return false }
    }
    activeSession = ActiveSession(id: sessionID, plan: plan)

    Thread.sleep(
      forTimeInterval: NowPlayingPausePolicy.captureLeadAfterPause
    )
    return true
  }

  private func endSync(sessionID: Int) {
    guard let activeSession, activeSession.id == sessionID else { return }
    self.activeSession = nil
    resume(activeSession.plan)
  }

  private func resume(_ plan: MediaPausePlan) {
    guard targetApplicationIsStillRunning(plan.targetBundles) else { return }
    switch plan.route {
    case .mediaKey:
      // Resume only when media is still paused. Playing again means our
      // pause never landed or the user restarted playback; either way a
      // toggle would pause it.
      let rate = PlaybackRateProbe.currentRate()
      guard NowPlayingPausePolicy.shouldSendResumeToggle(playbackRate: rate)
      else { return }
      MediaKey.playPause()
    case .mediaRemote:
      _ = MediaRemoteControl.play()
    }
  }

  private func targetApplicationIsStillRunning(
    _ targetBundles: Set<String>
  ) -> Bool {
    let runningBundles = Set(
      NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    )
    return !targetBundles.isDisjoint(with: runningBundles)
  }

  /// Bundle IDs of processes currently running input or output. Browser helper
  /// processes are resolved to their regular parent app whenever possible.
  private func activeBundleIDs(
    property: AudioObjectPropertySelector
  ) -> Set<String> {
    var bundles = Set<String>()
    for pid in activeProcessPIDs(property: property) {
      if let bundle = bundleID(for: pid) {
        bundles.insert(bundle)
      }
    }
    return bundles
  }

  private func activeProcessPIDs(
    property: AudioObjectPropertySelector
  ) -> [pid_t] {
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

    var processObjects = [AudioObjectID](
      repeating: 0,
      count: Int(size) / MemoryLayout<AudioObjectID>.size
    )
    guard AudioObjectGetPropertyData(
      system,
      &listAddress,
      0,
      nil,
      &size,
      &processObjects
    ) == noErr else {
      return []
    }

    let selfPID = ProcessInfo.processInfo.processIdentifier
    var active: [pid_t] = []
    for processObject in processObjects where processObject != 0 {
      guard let pid = processID(for: processObject), pid != selfPID else {
        continue
      }
      var activityAddress = AudioObjectPropertyAddress(
        mSelector: property,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      guard AudioObjectHasProperty(processObject, &activityAddress) else {
        continue
      }
      var running: UInt32 = 0
      var runningSize = UInt32(MemoryLayout<UInt32>.size)
      if AudioObjectGetPropertyData(
        processObject,
        &activityAddress,
        0,
        nil,
        &runningSize,
        &running
      ) == noErr, running != 0 {
        active.append(pid)
      }
    }
    return active
  }

  private func processID(for processObject: AudioObjectID) -> pid_t? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyPID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var pid: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(
      processObject,
      &address,
      0,
      nil,
      &size,
      &pid
    ) == noErr else {
      return nil
    }
    return pid
  }

  private func bundleID(for pid: pid_t) -> String? {
    var current = pid
    var fallback: String?
    for _ in 0..<8 {
      if let application = NSRunningApplication(processIdentifier: current),
        let bundle = application.bundleIdentifier
      {
        fallback = fallback ?? bundle
        if application.activationPolicy != .prohibited {
          return bundle
        }
      }

      guard let parent = parentPID(of: current),
        parent > 1,
        parent != current
      else {
        return fallback
      }
      current = parent
    }
    return fallback
  }

  private func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
      return nil
    }
    return info.kp_eproc.e_ppid
  }
}

/// Hardware play/pause key. This is a blind toggle, so it is used only as the
/// paired start/end command for one recorded media session.
private enum MediaKey {
  private static let playPauseKey: UInt32 = 16

  @discardableResult
  static func playPause() -> Bool {
    guard let down = event(down: true)?.cgEvent,
      let up = event(down: false)?.cgEvent
    else {
      return false
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }

  private static func event(down: Bool) -> NSEvent? {
    let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
    let data1 = Int((playPauseKey << 16) | ((down ? 0xA : 0xB) << 8))
    return NSEvent.otherEvent(
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
  }
}

/// Sends commands to the system Now Playing session without linking the
/// private MediaRemote framework. Command 0 is play and command 1 is pause.
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

  @discardableResult
  static func play() -> Bool {
    guard let sendFn else { return false }
    sendFn(0, nil)
    return true
  }

  @discardableResult
  static func pause() -> Bool {
    guard let sendFn else { return false }
    sendFn(1, nil)
    return true
  }
}
