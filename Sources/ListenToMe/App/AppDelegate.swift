import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let model = AppModel()

  private let hotkey = HotkeyService()
  private var overlayController: RecordingPanelController?
  private var historyPanelController: StatusHistoryPanelController?
  private var mainWindowController: NSWindowController?
  private var statusItem: NSStatusItem?
  private var statusMenu: NSMenu?
  private var subscriptions: Set<AnyCancellable> = []
  private var pressStartedRecording = false
  private var pressAt: Date?
  private var lastPressAt: Date?
  private var liveKind: DictationLiveKind = .unclassified
  private var holdEndedAt: Date?
  private var holdClassifyTask: Task<Void, Never>?
  /// Last shortcut Carbon actually accepted, so a failed re-register cannot
  /// leave the user with no dictation key at all.
  private var registeredHotkey: HotkeySpec?

  /// Absorbs key-repeat / bounce on press (Handy-style debounce).
  private let pressDebounce: TimeInterval = 0.03

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)

    overlayController = RecordingPanelController(
      coordinator: model.recording,
      settings: model.settings
    )
    // Warm the floating plate so the first hotkey doesn't pay SwiftUI mount cost.
    overlayController?.preload()
    historyPanelController = StatusHistoryPanelController(
      model: model,
      onOpenHistory: { [weak self] in
        self?.model.showMainWindow(section: .history)
      },
      onOpenSetup: { [weak self] in
        self?.model.showMainWindow(section: .settings)
      }
    )
    model.onShowMainWindow = { [weak self] in
      self?.historyPanelController?.close()
      self?.showMainWindow()
    }
    configureMainMenu()
    configureStatusItem()
    observeAppState()
    if ProcessInfo.processInfo.arguments.contains("--show-history") {
      DispatchQueue.main.async { [weak self] in
        self?.model.showMainWindow(section: .history)
      }
    } else if ProcessInfo.processInfo.arguments.contains("--show-setup") {
      DispatchQueue.main.async { [weak self] in
        self?.model.showMainWindow(section: .settings)
      }
    } else if ProcessInfo.processInfo.arguments.contains("--show-words") {
      DispatchQueue.main.async { [weak self] in
        self?.model.showMainWindow(section: .vocabulary)
      }
    } else if ProcessInfo.processInfo.arguments.contains("--show-panel") {
      overlayController?.update(for: .connecting, enabled: true)
    }

    configureHotkey()

    // Preload start/stop cues so the first hotkey has zero audio hitch.
    DictationSoundService.shared.prepare()

    // Warm mic + OpenAI realtime while idle so hotkey isn't cold.
    // Await mic warm so the first take promotes instead of engine.start().
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 400_000_000)
      guard let self else { return }
      self.model.permissions.refresh()
      if !self.model.permissions.accessibilityGranted {
        _ = await self.model.permissions.ensureAccessibilityForPaste(promptIfNeeded: true)
      }
      await self.model.recording.prepareMicrophoneAndWait()
      self.model.recording.prepareRealtimeSession()
    }
  }

  private func configureHotkey() {
    hotkey.onPress = { [weak self] in
      self?.hotkeyPressed()
    }
    hotkey.onRelease = { [weak self] in
      self?.hotkeyReleased()
    }
    hotkey.onCancel = { [weak self] in
      guard let self else { return }
      self.holdClassifyTask?.cancel()
      self.pressStartedRecording = false
      self.liveKind = .unclassified
      self.holdEndedAt = Date()
      self.overlayController?.update(for: .idle, enabled: true)
      // After Space-lock, Esc means "I'm done" (paste), not discard.
      if self.model.recording.isHandsFreeLocked,
        self.model.recording.phase == .recording
      {
        self.playStopCueIfEnabled()
        Task { await self.model.recording.stop() }
      } else {
        self.playStopCueIfEnabled()
        self.model.recording.cancelDictation()
      }
    }
    hotkey.onLock = { [weak self] in
      self?.lockDictationFromHold()
    }
    hotkey.tapStartsHandsFree = { [weak self] in
      self?.model.settings.tapStartsHandsFree ?? true
    }
    hotkey.holdIsPushToTalk = { [weak self] in
      self?.model.settings.holdIsPushToTalk ?? true
    }
    applyHotkey(model.settings.hotkey)

    model.settings.$hotkey
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] spec in
        self?.applyHotkey(spec)
      }
      .store(in: &subscriptions)

    model.settings.$microphonePriorityUIDs
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] _ in
        self?.model.recording.prepareMicrophone()
      }
      .store(in: &subscriptions)

    // Re-warm the realtime session when dictation settings that affect
    // session.update change.
    Publishers.MergeMany(
      model.settings.$delay.map { _ in () }.eraseToAnyPublisher(),
      model.settings.$micProfile.map { _ in () }.eraseToAnyPublisher(),
      model.settings.$basePrompt.map { _ in () }.eraseToAnyPublisher(),
      model.settings.$languageText.map { _ in () }.eraseToAnyPublisher()
    )
    .dropFirst()
    .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
    .sink { [weak self] in
      self?.model.recording.prepareRealtimeSession()
    }
    .store(in: &subscriptions)

    model.settings.$isCapturingHotkey
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] capturing in
        guard let self else { return }
        if capturing {
          hotkey.suspend()
        } else {
          applyHotkey(model.settings.hotkey)
        }
      }
      .store(in: &subscriptions)
  }

  private func applyHotkey(_ spec: HotkeySpec) {
    if hotkey.register(spec) {
      registeredHotkey = spec
      return
    }
    if let registeredHotkey, registeredHotkey != spec {
      _ = hotkey.register(registeredHotkey)
    }
    model.recording.errorMessage =
      "\(spec.display) could not be registered. Another app may already use it. Pick a different shortcut in Setup."
  }

  private func hotkeyPressed() {
    let liveElapsed = pressAt.map { Date().timeIntervalSince($0) } ?? 0
    let sinceHoldEnded = holdEndedAt.map { Date().timeIntervalSince($0) }
    let action = DictationGesturePolicy.pressAction(
      phase: model.recording.phase,
      liveKind: liveKind,
      liveElapsed: liveElapsed,
      keyPhysicallyDown: hotkey.isPrimaryKeyHeld(),
      secondsSinceHoldEnded: sinceHoldEnded
    )
    if action == .ignore {
      return
    }

    if let lastPressAt, Date().timeIntervalSince(lastPressAt) < pressDebounce {
      return
    }
    lastPressAt = Date()

    switch action {
    case .ignore:
      return
    case .start:
      beginTakeFromGesture()
    case .stop:
      endTakeFromGesture()
    }
  }

  private func beginTakeFromGesture() {
    model.recording.noteHotkeyPress()
    pressStartedRecording = true
    pressAt = Date()
    holdEndedAt = nil
    let holdEnabled = model.settings.holdIsPushToTalk
    let tapEnabled = model.settings.tapStartsHandsFree
    if hotkey.pressWasHoldConfirm || (holdEnabled && !tapEnabled) {
      liveKind = .hold
    } else if tapEnabled && !holdEnabled {
      liveKind = .tap
    } else {
      liveKind = .unclassified
      scheduleHoldClassification()
    }

    playStartCueIfEnabled()
    if model.settings.showRecordingOverlay {
      overlayController?.update(for: .recording, enabled: true)
      model.recording.markLatency("overlay")
    }
    hotkey.setSessionControlsActive(true)
    let canSpaceLock =
      model.settings.spaceLocksHandsFree
      && !model.settings.hotkey.usesSpaceKey
      && liveKind != .tap
    hotkey.setSpaceLockArmed(canSpaceLock)
    Task { [weak self] in
      guard let self else { return }
      await self.model.recording.start()
      if !self.model.recording.phase.isBusy {
        self.liveKind = .unclassified
        self.overlayController?.update(
          for: self.model.recording.phase,
          enabled: self.model.settings.showRecordingOverlay
        )
      }
    }
  }

  private func scheduleHoldClassification() {
    holdClassifyTask?.cancel()
    let threshold = DictationGesturePolicy.holdThreshold
    holdClassifyTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(threshold * 1_000_000_000))
      guard let self, !Task.isCancelled else { return }
      guard self.pressStartedRecording, self.liveKind == .unclassified else { return }
      self.liveKind = .hold
    }
  }

  private func endTakeFromGesture() {
    holdClassifyTask?.cancel()
    holdClassifyTask = nil
    pressStartedRecording = false
    liveKind = .unclassified
    holdEndedAt = Date()
    hotkey.setSpaceLockArmed(false)
    playStopCueIfEnabled()
    overlayController?.update(for: .idle, enabled: true)
    Task { [weak self] in
      await self?.model.recording.dismissTake()
    }
  }

  private func hotkeyReleased() {
    let startedThisPress = pressStartedRecording
    let elapsed = pressAt.map { Date().timeIntervalSince($0) } ?? 0

    let wasLocked =
      model.recording.isHandsFreeLocked || hotkey.isSpaceLockLatched
    hotkey.setSpaceLockArmed(false)
    if wasLocked {
      hotkey.clearSpaceLockLatch()
      if !model.recording.isHandsFreeLocked {
        model.recording.setHandsFreeLocked(true)
      }
      liveKind = .tap
      pressStartedRecording = false
      holdClassifyTask?.cancel()
      return
    }

    let action = DictationGesturePolicy.releaseAction(
      startedThisPress: startedThisPress,
      liveKind: liveKind,
      holdEnabled: model.settings.holdIsPushToTalk,
      tapEnabled: model.settings.tapStartsHandsFree,
      elapsed: elapsed,
      isLocked: false
    )
    pressStartedRecording = false
    holdClassifyTask?.cancel()
    holdClassifyTask = nil

    switch action {
    case .ignore:
      break
    case .becomeTap:
      liveKind = .tap
    case .endHold:
      endTakeFromGesture()
    }
  }

  private func playStartCueIfEnabled() {
    guard model.settings.playDictationSounds else { return }
    DictationSoundService.shared.playStart()
  }

  private func playStopCueIfEnabled() {
    guard model.settings.playDictationSounds else { return }
    DictationSoundService.shared.playStop()
  }

  private func lockDictationFromHold() {
    guard model.settings.spaceLocksHandsFree else { return }
    guard !model.settings.hotkey.usesSpaceKey else { return }
    // Allow lock as soon as this press started a take  -  phase may not have
    // flipped to .recording yet if start() is still hopping onto MainActor.
    if pressStartedRecording
      || model.recording.phase == .connecting
      || model.recording.phase == .recording
    {
      hotkey.setSpaceLockArmed(false)
      hotkey.noteHandsFreeLocked()
      model.recording.setHandsFreeLocked(true)
      liveKind = .tap
      pressStartedRecording = false
      holdClassifyTask?.cancel()
      // This press is done  -  release must not PTT-stop, and the next press
      // must be free to finish.
      pressAt = pressAt ?? Date()
      overlayController?.update(for: .recording, enabled: true)
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    model.permissions.refresh()
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }

  func menuWillOpen(_ menu: NSMenu) {
    rebuildStatusMenu()
  }

  @objc private func openHistory() {
    model.showMainWindow(section: .history)
  }

  @objc private func openVocabulary() {
    model.showMainWindow(section: .vocabulary)
  }

  @objc private func openSetup() {
    model.showMainWindow(section: .settings)
  }

  @objc private func toggleRecordingOverlay() {
    model.settings.showRecordingOverlay.toggle()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }

  @objc private func statusItemClicked(_ sender: Any?) {
    guard let event = NSApp.currentEvent else { return }
    let isRightClick =
      event.type == .rightMouseUp
      || event.type == .rightMouseDown
      || event.modifierFlags.contains(.control)

    if isRightClick {
      historyPanelController?.close()
      showStatusMenu()
    } else {
      guard let button = statusItem?.button else { return }
      historyPanelController?.toggle(relativeTo: button)
    }
  }

  private func showStatusMenu() {
    guard let button = statusItem?.button, let menu = statusMenu else { return }
    rebuildStatusMenu()
    let location = NSPoint(x: 0, y: button.bounds.height + 2)
    menu.popUp(positioning: nil, at: location, in: button)
  }

  private func configureStatusItem() {
    let statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.squareLength
    )
    statusItem.button?.image = NSImage(
      systemSymbolName: "waveform",
      accessibilityDescription: "ListenToMe"
    )
    statusItem.button?.toolTip = "ListenToMe. Click for recent, right-click for menu"

    // Keep menu off the item itself so left-click can open the history panel.
    let menu = NSMenu()
    menu.delegate = self
    self.statusMenu = menu
    self.statusItem = statusItem

    statusItem.button?.target = self
    statusItem.button?.action = #selector(statusItemClicked(_:))
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    rebuildStatusMenu()
  }

  private func configureMainMenu() {
    let mainMenu = NSMenu()

    let applicationItem = NSMenuItem()
    let applicationMenu = NSMenu(title: "ListenToMe")
    applicationItem.submenu = applicationMenu
    mainMenu.addItem(applicationItem)

    let about = applicationMenu.addItem(
      withTitle: "About ListenToMe",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    about.target = NSApplication.shared

    let checkForUpdates = applicationMenu.addItem(
      withTitle: "Check for Updates…",
      action: #selector(UpdateService.checkForUpdates(_:)),
      keyEquivalent: ""
    )
    checkForUpdates.target = model.updates
    applicationMenu.addItem(.separator())

    let setup = applicationMenu.addItem(
      withTitle: "Setup…",
      action: #selector(openSetup),
      keyEquivalent: ","
    )
    setup.target = self
    applicationMenu.addItem(.separator())

    let quit = applicationMenu.addItem(
      withTitle: "Quit ListenToMe",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    quit.target = NSApplication.shared

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    fileItem.submenu = fileMenu
    mainMenu.addItem(fileItem)

    let history = fileMenu.addItem(
      withTitle: "Open History",
      action: #selector(openHistory),
      keyEquivalent: "o"
    )
    history.target = self
    let words = fileMenu.addItem(
      withTitle: "Custom Words",
      action: #selector(openVocabulary),
      keyEquivalent: "w"
    )
    words.keyEquivalentModifierMask = [.command, .shift]
    words.target = self
    fileMenu.addItem(.separator())
    fileMenu.addItem(
      withTitle: "Close Window",
      action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w"
    )

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)
    for item in [
      ("Undo", "undo:", "z"),
      ("Redo", "redo:", "Z"),
      ("Cut", "cut:", "x"),
      ("Copy", "copy:", "c"),
      ("Paste", "paste:", "v"),
      ("Select All", "selectAll:", "a"),
    ] {
      editMenu.addItem(
        withTitle: item.0,
        action: Selector((item.1)),
        keyEquivalent: item.2
      )
      if item.0 == "Redo" {
        editMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
      }
      if item.0 == "Redo" || item.0 == "Cut" {
        editMenu.insertItem(.separator(), at: editMenu.items.count - 1)
      }
    }

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowItem.submenu = windowMenu
    mainMenu.addItem(windowItem)
    windowMenu.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )

    NSApplication.shared.mainMenu = mainMenu
    NSApplication.shared.windowsMenu = windowMenu
  }

  private func rebuildStatusMenu() {
    guard let menu = statusMenu else { return }
    menu.removeAllItems()

    let overlayItem = addMenuItem(
      "Show Recording Panel",
      symbolName: "rectangle.bottomhalf.inset.filled",
      action: #selector(toggleRecordingOverlay),
      to: menu
    )
    overlayItem.state = model.settings.showRecordingOverlay ? .on : .off

    menu.addItem(.separator())
    addMenuItem(
      "History",
      symbolName: "clock.arrow.circlepath",
      action: #selector(openHistory),
      to: menu
    )
    addMenuItem(
      "Words",
      symbolName: "text.book.closed",
      action: #selector(openVocabulary),
      to: menu
    )
    addMenuItem(
      "Setup…",
      symbolName: "slider.horizontal.3",
      action: #selector(openSetup),
      to: menu
    )
    menu.addItem(.separator())
    let checkForUpdates = addMenuItem(
      "Check for Updates…",
      symbolName: "arrow.triangle.2.circlepath",
      action: #selector(UpdateService.checkForUpdates(_:)),
      to: menu
    )
    checkForUpdates.target = model.updates
    addMenuItem(
      "Quit ListenToMe",
      symbolName: "power",
      action: #selector(quit),
      to: menu
    )
  }

  @discardableResult
  private func addMenuItem(
    _ title: String,
    symbolName: String? = nil,
    action: Selector,
    to menu: NSMenu
  ) -> NSMenuItem {
    let item = menu.addItem(
      withTitle: title,
      action: action,
      keyEquivalent: ""
    )
    item.target = self
    if let symbolName,
      let image = StatusMenuIcon.image(
        systemName: symbolName,
        accessibilityDescription: title
      )
    {
      // Baked non-symbol template so newer macOS versions don't hide SF Symbols.
      item.image = image
    }
    return item
  }

  private func observeAppState() {
    model.recording.$phase
      .sink { [weak self] phase in
        guard let self else { return }
        overlayController?.update(
          for: pressStartedRecording ? .recording : phase,
          enabled: model.settings.showRecordingOverlay
        )
        updateStatusItem(for: phase)
        hotkey.setSessionControlsActive(
          pressStartedRecording
            || phase == .recording
            || phase == .connecting
            || phase == .finishing
        )
        if !phase.isBusy, !pressStartedRecording {
          liveKind = .unclassified
        }
      }
      .store(in: &subscriptions)

    model.settings.$showRecordingOverlay
      .sink { [weak self] enabled in
        guard let self else { return }
        overlayController?.update(
          for: model.recording.phase,
          enabled: enabled
        )
      }
      .store(in: &subscriptions)

    model.settings.$overlayLayout
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] _ in
        self?.overlayController?.applyLayout()
      }
      .store(in: &subscriptions)

    model.settings.$hasAPIKey
      .sink { [weak self] _ in
        guard let self else { return }
        updateStatusItem(for: model.recording.phase)
      }
      .store(in: &subscriptions)
  }

  private func showMainWindow() {
    let controller: NSWindowController
    if let mainWindowController {
      controller = mainWindowController
    } else {
      let rootView = RootView(model: model)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
        styleMask: [
          .titled,
          .closable,
          .miniaturizable,
          .resizable,
        ],
        backing: .buffered,
        defer: false
      )
      window.title = "ListenToMe"
      window.minSize = NSSize(width: 560, height: 420)
      // Hard caps  -  never let SwiftUI content or a huge autosave frame
      // stretch the window across a 4K display.
      window.maxSize = NSSize(width: 1_100, height: 860)
      window.titlebarAppearsTransparent = false
      // Empty sizingOptions: content never drives the window frame.
      let hostingView = NSHostingView(rootView: rootView)
      hostingView.sizingOptions = []
      window.contentView = hostingView
      window.center()
      window.setFrameAutosaveName("ListenToMe.MainWindow.v2")

      controller = NSWindowController(window: window)
      mainWindowController = controller
    }

    if let window = controller.window {
      window.maxSize = NSSize(width: 1_100, height: 860)
      clampMainWindowFrame(window)
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  private func clampMainWindowFrame(_ window: NSWindow) {
    let screen = window.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
    let maxWidth = min(visible.width * 0.92, window.maxSize.width)
    let maxHeight = min(visible.height * 0.90, window.maxSize.height)
    var frame = window.frame
    var changed = false
    if frame.width > maxWidth {
      frame.size.width = maxWidth
      changed = true
    }
    if frame.height > maxHeight {
      frame.size.height = maxHeight
      changed = true
    }
    if frame.width < window.minSize.width {
      frame.size.width = window.minSize.width
      changed = true
    }
    if frame.height < window.minSize.height {
      frame.size.height = window.minSize.height
      changed = true
    }
    // Keep on-screen after shrinking a bad autosave.
    if frame.maxX > visible.maxX {
      frame.origin.x = visible.maxX - frame.width
      changed = true
    }
    if frame.minX < visible.minX {
      frame.origin.x = visible.minX
      changed = true
    }
    if frame.maxY > visible.maxY {
      frame.origin.y = visible.maxY - frame.height
      changed = true
    }
    if frame.minY < visible.minY {
      frame.origin.y = visible.minY
      changed = true
    }
    if changed {
      window.setFrame(frame, display: true)
    }
  }

  private func updateStatusItem(for phase: RecordingPhase) {
    // Orange only while actually listening  -  failed/error used the same tint
    // and looked like a stuck "locked" session with no overlay.
    let isListening = phase == .recording || phase == .connecting
    statusItem?.button?.image = StatusMenuIcon.statusImage(isActive: isListening)
    statusItem?.button?.contentTintColor = nil
    statusItem?.button?.toolTip = "ListenToMe · \(statusTitle)"
  }

  private var statusTitle: String {
    if model.recording.phase == .idle
      && !model.settings.selectedEngineIsReady
    {
      return "Setup Needed"
    }
    return phaseTitle
  }

  private var phaseTitle: String {
    switch model.recording.phase {
    case .idle: "Ready"
    case .connecting, .recording, .finishing: "Listening"
    case .delivered: "Ready"
    case .failed: "Needs Attention"
    }
  }
}
