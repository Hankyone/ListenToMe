import AppKit
import CoreAudio
import Darwin
import Foundation

/// Pauses the media that was active when a take began, then resumes it when
/// that exact take releases the microphone.
///
/// Detection uses Core Audio process activity to spot audible apps and the
/// vendored mediaremote-adapter (via /usr/bin/perl) for true Now Playing
/// state on macOS 15.4+, where direct reads are redacted. Control uses only
/// explicit pause/play commands, never the hardware toggle key. Pause goes
/// out only when the session confirms media is playing; resume goes out
/// only for the take that paused. There is no global output mute, no
/// AppleScript, and no wait-for-silence loop.
final class MediaPauseService: @unchecked Sendable {
  private struct ActiveSession {
    let id: Int
    let plan: MediaPausePlan
    /// True only when this take actually paused playing media. Resume fires
    /// solely on this flag, so already-paused media is never started.
    let didPause: Bool
  }

  private let queue = DispatchQueue(
    label: "ca.hankyone.ListenToMe.mediaPause",
    qos: .userInitiated
  )
  private var activeSession: ActiveSession?

  init() {
    queue.async {
      MediaRemoteControl.prepare()
      MediaRemoteAdapterClient.prewarm()
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

    // A stale session from an aborted take already paused this route. The
    // new take adopts the existing pause, keeping its resume flag, so one
    // pause still pairs with one resume at take end.
    var adoptedSession: ActiveSession?
    if let activeSession {
      if activeSession.plan.route == plan.route {
        adoptedSession = activeSession
      } else {
        resume(activeSession)
      }
      self.activeSession = nil
    }

    if let adoptedSession {
      activeSession = ActiveSession(
        id: sessionID,
        plan: adoptedSession.plan,
        didPause: adoptedSession.didPause
      )
      Thread.sleep(
        forTimeInterval: NowPlayingPausePolicy.captureLeadAfterPause
      )
      return true
    }

    // The adapter reports true state even on macOS 15.4+, where direct
    // reads are redacted. Pause only when the session confirms playback;
    // an already-paused or session-less player is left untouched, so a
    // paused Twitter video can never be started by push-to-talk.
    if let session = MediaRemoteAdapterClient.currentSession() {
      guard session.isPlaying else { return false }
      guard pausePlayback() else { return false }
      activeSession = ActiveSession(id: sessionID, plan: plan, didPause: true)
      Thread.sleep(
        forTimeInterval: NowPlayingPausePolicy.captureLeadAfterPause
      )
      return true
    }

    // No readable session (session-less players report nothing). Fall back
    // to one explicit pause, which is a no-op on already-paused players,
    // but never resume: without a session we cannot confirm we paused.
    guard MediaRemoteControl.pause() else { return false }
    activeSession = ActiveSession(id: sessionID, plan: plan, didPause: false)

    Thread.sleep(
      forTimeInterval: NowPlayingPausePolicy.captureLeadAfterPause
    )
    return true
  }

  private func endSync(sessionID: Int) {
    guard let activeSession, activeSession.id == sessionID else { return }
    self.activeSession = nil
    resume(activeSession)
  }

  private func resume(_ session: ActiveSession) {
    // Only the take that paused may resume. Anything else leaves playback
    // exactly as found, so paused media is never started.
    guard targetApplicationIsStillRunning(session.plan.targetBundles) else {
      return
    }
    let currentPlaying = MediaRemoteAdapterClient.currentSession()?.isPlaying
    guard
      NowPlayingPausePolicy.shouldResumePausedTake(
        didPause: session.didPause,
        currentPlaying: currentPlaying
      )
    else { return }
    playPlayback()
  }

  /// Explicit pause via the adapter, falling back to the direct command.
  /// Returns true when a pause command was accepted.
  private func pausePlayback() -> Bool {
    if MediaRemoteAdapterClient.send(1) { return true }
    return MediaRemoteControl.pause()
  }

  /// Explicit resume via the adapter, falling back to the direct command.
  private func playPlayback() {
    if MediaRemoteAdapterClient.send(0) { return }
    _ = MediaRemoteControl.play()
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
