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

/// One global dictation shortcut. Two shapes:
/// - A key combo (Carbon hotkey): tap toggles, hold speaks until release.
/// - A lone modifier (Fn, Right Command…): hold speaks until release,
///   watched through `flagsChanged` monitors.
/// While dictation is live, a transient Escape hotkey cancels it.
@MainActor
final class HotkeyService {
  private enum HotkeyIdentifier: UInt32 {
    case primary = 1
    case cancel = 2
  }

  var onPress: (() -> Void)?
  var onRelease: (() -> Void)?
  var onCancel: (() -> Void)?

  private var handlerRef: EventHandlerRef?
  private var comboRef: EventHotKeyRef?
  private var cancelRef: EventHotKeyRef?
  private var comboIsDown = false

  private var spec: HotkeySpec?
  private var globalMonitors: [Any] = []
  private var localMonitor: Any?
  private var modifierKeyIsDown = false
  private var holdCandidateGeneration = 0
  private var holdCandidateIsPending = false
  private var holdIsActive = false
  private let holdConfirmDelay: TimeInterval = 0.2

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

  func setCancelKeyActive(_ active: Bool) {
    if active {
      guard cancelRef == nil, installCarbonHandlerIfNeeded() else { return }
      var hotkeyRef: EventHotKeyRef?
      let hotkeyID = EventHotKeyID(
        signature: 0x4C54_4D45,
        id: HotkeyIdentifier.cancel.rawValue
      )
      let status = RegisterEventHotKey(
        UInt32(kVK_Escape),
        0,
        hotkeyID,
        GetApplicationEventTarget(),
        0,
        &hotkeyRef
      )
      if status == noErr {
        cancelRef = hotkeyRef
      }
    } else if let cancelRef {
      UnregisterEventHotKey(cancelRef)
      self.cancelRef = nil
    }
  }

  fileprivate func handleCarbonEvent(id: UInt32, kind: UInt32) {
    switch HotkeyIdentifier(rawValue: id) {
    case .primary:
      if kind == UInt32(kEventHotKeyPressed) {
        guard !comboIsDown else { return }
        comboIsDown = true
        onPress?()
      } else if kind == UInt32(kEventHotKeyReleased) {
        guard comboIsDown else { return }
        comboIsDown = false
        onRelease?()
      }
    case .cancel:
      if kind == UInt32(kEventHotKeyPressed) {
        onCancel?()
      }
    case nil:
      break
    }
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

  // MARK: - Lone-modifier hold

  private func installModifierMonitors() {
    let flagsHandler: (NSEvent) -> Void = { [weak self] event in
      MainActor.assumeIsolated {
        self?.handleFlagsChanged(event)
      }
    }
    let keyHandler: (NSEvent) -> Void = { [weak self] _ in
      MainActor.assumeIsolated {
        // Any real keystroke means the modifier is part of a chord,
        // not a dictation hold.
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
    // Events for this key code alternate down and up. The flag itself can
    // stay raised when the twin key (the other Command, say) is also held,
    // so the tracked state decides.
    let isPress = flagPresent && !modifierKeyIsDown

    if isPress {
      modifierKeyIsDown = true
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
        self.onPress?()
      }
    } else {
      modifierKeyIsDown = false
      holdCandidateIsPending = false
      let wasActive = holdIsActive
      holdIsActive = false
      if wasActive {
        onRelease?()
      }
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
    if let cancelRef {
      UnregisterEventHotKey(cancelRef)
    }
    if let handlerRef {
      RemoveEventHandler(handlerRef)
    }
  }
}
