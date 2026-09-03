import AppKit
import Carbon
import Foundation

private let hotkeyEventCallback: EventHandlerUPP = { _, event, userData in
  guard let event, let userData else { return OSStatus(eventNotHandledErr) }

  var hotkeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotkeyID
  )
  guard status == noErr else { return OSStatus(eventNotHandledErr) }

  let kind = UInt32(GetEventKind(event))
  let service = Unmanaged<HotkeyService>
    .fromOpaque(userData)
    .takeUnretainedValue()
  DispatchQueue.main.async {
    service.handleCarbonEvent(id: hotkeyID.id, kind: kind)
  }
  return noErr
}

/// Shared with the CGEvent tap callback (runs off the main thread).
private final class SessionTapState: @unchecked Sendable {
  private let lock = NSLock()
  var eventTap: CFMachPort?
  private var spaceLockArmed = false
  private var spaceLockLatched = false

  func setArmed(_ armed: Bool) {
    lock.lock()
    spaceLockArmed = armed
    if armed { spaceLockLatched = false }
    lock.unlock()
  }

  func clearLatch() {
    lock.lock()
    spaceLockLatched = false
    lock.unlock()
  }

  var isLatched: Bool {
    lock.lock()
    defer { lock.unlock() }
    return spaceLockLatched
  }

  func consumeSpaceLockIfArmed() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard spaceLockArmed else { return false }
    spaceLockArmed = false
    spaceLockLatched = true
    return true
  }

  func reenable() {
    lock.lock()
    let tap = eventTap
    lock.unlock()
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: true)
    }
  }

  func setTap(_ tap: CFMachPort?) {
    lock.lock()
    eventTap = tap
    lock.unlock()
  }

  var hasTap: Bool {
    lock.lock()
    defer { lock.unlock() }
    return eventTap != nil
  }
}

/// CGEvent taps see Space while a Carbon hotkey is still held  -  NSEvent
/// global monitors often do not.
private let sessionTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
  guard let userInfo else {
    return Unmanaged.passUnretained(event)
  }
  let service = Unmanaged<HotkeyService>
    .fromOpaque(userInfo)
    .takeUnretainedValue()

  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    service.sessionTapState.reenable()
    return Unmanaged.passUnretained(event)
  }

  guard type == .keyDown else {
    return Unmanaged.passUnretained(event)
  }

  if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
    return Unmanaged.passUnretained(event)
  }

  let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
  if keyCode == Int64(kVK_Escape) {
    DispatchQueue.main.async {
      service.onCancel?()
    }
    return nil
  }

  if keyCode == Int64(kVK_Space), service.sessionTapState.consumeSpaceLockIfArmed() {
    DispatchQueue.main.async {
      service.onLock?()
    }
    return nil
  }

  return Unmanaged.passUnretained(event)
}

/// One global dictation shortcut. Two shapes:
/// - A key combo (Carbon hotkey): tap toggles, hold speaks until release.
/// - A lone modifier (Fn, Right Command…): hold speaks until release.
/// While a take is live, a CGEvent tap handles Escape (cancel) and Space
/// (lock hands-free)  -  including while the primary shortcut is still held.
@MainActor
final class HotkeyService {
  private enum HotkeyIdentifier: UInt32 {
    case primary = 1
  }

  var onPress: (() -> Void)?
  var onRelease: (() -> Void)?
  var onCancel: (() -> Void)?
  var onLock: (() -> Void)?
  /// When true, a quick modifier tap (release before hold confirm) starts
  /// hands-free listening instead of doing nothing.
  var tapStartsHandsFree: () -> Bool = { true }
  /// When false, modifier holds never auto-start after the confirm delay.
  var holdIsPushToTalk: () -> Bool = { true }
  /// True when `onPress` came from a confirmed modifier hold, not a tap.
  private(set) var pressWasHoldConfirm = false

  private var handlerRef: EventHandlerRef?
  private var comboRef: EventHotKeyRef?
  private var comboIsDown = false
  private var lastPressedAt = Date.distantPast

  private var spec: HotkeySpec?
  private var globalMonitors: [Any] = []
  private var localMonitor: Any?
  private var modifierKeyIsDown = false
  private var holdCandidateGeneration = 0
  private var holdCandidateIsPending = false
  private var holdIsActive = false
  /// True when a modifier-down started a take via the delayed hold confirm.
  private var holdStartedThisPress = false
  private let holdConfirmDelay: TimeInterval = 0.2

  fileprivate let sessionTapState = SessionTapState()
  private var runLoopSource: CFRunLoopSource?
  /// True while Escape/Space session controls are installed (a take is live).
  private var sessionControlsActive = false

  /// True after Space was hit on this hold, even if MainActor hasn't applied it yet.
  var isSpaceLockLatched: Bool { sessionTapState.isLatched }

  /// Drops the primary shortcut, e.g. while the recorder captures a new one.
  func suspend() {
    unregisterPrimary()
  }

  func register(_ spec: HotkeySpec) -> Bool {
    unregisterPrimary()
    self.spec = spec

    guard installCarbonHandlerIfNeeded() else { return false }

    switch spec.kind {
    case .keyCombo:
      var hotkeyRef: EventHotKeyRef?
      let hotkeyID = EventHotKeyID(
        signature: 0x4C54_4D45,
        id: HotkeyIdentifier.primary.rawValue
      )
      let status = RegisterEventHotKey(
        spec.keyCode,
        spec.carbonModifiers,
        hotkeyID,
        GetApplicationEventTarget(),
        0,
        &hotkeyRef
      )
      guard status == noErr else { return false }
      comboRef = hotkeyRef
      return true

    case .modifierHold:
      guard spec.heldModifierFlag != nil else { return false }
      installModifierMonitors()
      return true
    }
  }

  /// Call when Space locks hands-free so the next primary press can finish
  /// the take even if Carbon missed a key-up while Space was swallowed.
  func noteHandsFreeLocked() {
    comboIsDown = false
    holdCandidateIsPending = false
    // Keep modifierKeyIsDown as-is until the real key-up; clearing holdIsActive
    // lets the release path avoid a duplicate onRelease stop attempt.
    holdIsActive = false
  }

  /// Arm Space-to-lock for the duration of a push-to-talk hold.
  func setSpaceLockArmed(_ armed: Bool) {
    sessionTapState.setArmed(armed)
  }

  func clearSpaceLockLatch() {
    sessionTapState.clearLatch()
  }

  func setSessionControlsActive(_ active: Bool) {
    sessionControlsActive = active
    if active {
      installSessionTap()
    } else {
      setSpaceLockArmed(false)
      tearDownSessionTap()
      // A missed key-up while the take ended must not latch comboIsDown and
      // drop every later press.
      comboIsDown = false
    }
  }

  fileprivate func handleCarbonEvent(id: UInt32, kind: UInt32) {
    switch HotkeyIdentifier(rawValue: id) {
    case .primary:
      if kind == UInt32(kEventHotKeyPressed) {
        if comboIsDown {
          // Key-repeat fires another "pressed" after ~0.5s while the key is
          // still down  -  that must not stop a live take. Only treat it as a
          // new press when the physical key is already up (missed key-up).
          // Repeats are periodic, so a pressed event this long after the
          // last one is a fresh press whose key-up was lost, no matter what
          // the HID state claims  -  eating it would leave the hotkey dead.
          let isPeriodicRepeat =
            Date().timeIntervalSince(lastPressedAt) < 2.0
          if isPeriodicRepeat, isPrimaryKeyHeld() {
            return
          }
          pressWasHoldConfirm = false
          lastPressedAt = Date()
          onPress?()
          return
        }
        comboIsDown = true
        lastPressedAt = Date()
        pressWasHoldConfirm = false
        onPress?()
      } else if kind == UInt32(kEventHotKeyReleased) {
        guard comboIsDown else { return }
        comboIsDown = false
        onRelease?()
      }
    case nil:
      break
    }
  }

  func isPrimaryKeyHeld() -> Bool {
    guard let spec else { return false }
    return CGEventSource.keyState(
      .hidSystemState,
      key: CGKeyCode(spec.keyCode)
    )
  }

  private func installCarbonHandlerIfNeeded() -> Bool {
    guard handlerRef == nil else { return true }

    var eventTypes = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
      ),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyReleased)
      ),
    ]
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      hotkeyEventCallback,
      eventTypes.count,
      &eventTypes,
      pointer,
      &handlerRef
    )
    return status == noErr
  }

  // MARK: - Session Escape / Space (CGEvent tap)

  private func installSessionTap() {
    if sessionTapState.hasTap {
      sessionTapState.reenable()
      return
    }

    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: sessionTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      return
    }

    sessionTapState.setTap(tap)
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    runLoopSource = source
    if let source {
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  private func tearDownSessionTap() {
    if let tap = sessionTapState.eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    runLoopSource = nil
    sessionTapState.setTap(nil)
  }

  // MARK: - Lone-modifier hold

  private func installModifierMonitors() {
    let flagsHandler: (NSEvent) -> Void = { [weak self] event in
      MainActor.assumeIsolated {
        self?.handleFlagsChanged(event)
      }
    }
    let keyHandler: (NSEvent) -> Void = { [weak self] event in
      MainActor.assumeIsolated {
        // Chord keystrokes cancel a pending hold confirm  -  but not Space/Esc,
        // which the session tap handles for lock/cancel.
        if event.keyCode == UInt16(kVK_Space)
          || event.keyCode == UInt16(kVK_Escape)
        {
          return
        }
        self?.holdCandidateIsPending = false
      }
    }

    if let monitor = NSEvent.addGlobalMonitorForEvents(
      matching: .flagsChanged,
      handler: flagsHandler
    ) {
      globalMonitors.append(monitor)
    }
    if let monitor = NSEvent.addGlobalMonitorForEvents(
      matching: .keyDown,
      handler: keyHandler
    ) {
      globalMonitors.append(monitor)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.flagsChanged, .keyDown]
    ) { event in
      MainActor.assumeIsolated {
        if event.type == .flagsChanged {
          flagsHandler(event)
        } else {
          keyHandler(event)
        }
      }
      return event
    }
  }

  private func handleFlagsChanged(_ event: NSEvent) {
    guard let spec, spec.kind == .modifierHold,
      event.keyCode == UInt16(spec.keyCode),
      let flag = spec.heldModifierFlag
    else {
      return
    }

    let flagPresent = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .contains(flag)
    let isPress = flagPresent && !modifierKeyIsDown

    if isPress {
      beginModifierPress()
    } else if !flagPresent {
      modifierKeyIsDown = false
      let wasPending = holdCandidateIsPending
      holdCandidateIsPending = false
      let wasActive = holdIsActive
      holdIsActive = false
      holdStartedThisPress = false

      if wasActive {
        onRelease?()
      } else if wasPending, tapStartsHandsFree(), !sessionControlsActive {
        // Released before the hold confirm  -  treat as a tap: start hands-free.
        pressWasHoldConfirm = false
        onPress?()
      }
    }
  }

  private func beginModifierPress() {
    modifierKeyIsDown = true
    holdStartedThisPress = false
    // While a take is already live, finish immediately on tap.
    if sessionControlsActive {
      holdCandidateIsPending = false
      holdIsActive = true
      pressWasHoldConfirm = false
      onPress?()
      return
    }

    let wantsTap = tapStartsHandsFree()
    let wantsHold = holdIsPushToTalk()

    if wantsHold {
      // Wait briefly to see if this is a hold (PTT) or a quick tap.
      holdCandidateIsPending = true
      holdCandidateGeneration += 1
      let generation = holdCandidateGeneration
      let delay = holdConfirmDelay
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard let self,
          self.holdCandidateIsPending,
          self.holdCandidateGeneration == generation
        else {
          return
        }
        self.holdCandidateIsPending = false
        self.holdIsActive = true
        self.holdStartedThisPress = true
        self.pressWasHoldConfirm = true
        self.onPress?()
      }
    } else if wantsTap {
      // Tap-only modifier: start immediately on down.
      holdIsActive = true
      holdStartedThisPress = true
      pressWasHoldConfirm = false
      onPress?()
    }
  }

  private func unregisterPrimary() {
    if let comboRef {
      UnregisterEventHotKey(comboRef)
      self.comboRef = nil
    }
    comboIsDown = false
    for monitor in globalMonitors {
      NSEvent.removeMonitor(monitor)
    }
    globalMonitors = []
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
      self.localMonitor = nil
    }
    modifierKeyIsDown = false
    holdCandidateIsPending = false
    holdIsActive = false
    spec = nil
  }

  deinit {
    if let comboRef {
      UnregisterEventHotKey(comboRef)
    }
    if let handlerRef {
      RemoveEventHandler(handlerRef)
    }
    if let tap = sessionTapState.eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
  }
}
