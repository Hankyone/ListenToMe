import AppKit
import Combine
import Sparkle
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
  private var pendingReleaseTask: Task<Void, Never>?

  /// Holding the key past this long means push-to-talk: release stops.
  /// A quicker tap leaves dictation running until the next tap.
  /// Space during a live take locks hands-free continuation after release.
  private let pushToTalkThreshold: TimeInterval = 0.5
  /// Absorbs key-repeat / bounce on press (Handy-style debounce).
  private let pressDebounce: TimeInterval = 0.03
  /// Defers PTT stop briefly so auto-repeat release/press pairs don't cut off.
  private let releaseGraceNanoseconds: UInt64 = 50_000_000

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
      self?.model.recording.cancelDictation()
    }
    hotkey.onLock = { [weak self] in
      self?.lockDictationFromHold()
    }
    hotkey.isSpaceLockAllowed = { [weak self] in
      guard let self else { return false }
      guard self.model.settings.spaceLocksHandsFree else { return false }
      guard !self.model.recording.isHandsFreeLocked else { return false }
      return self.pressStartedRecording || self.model.recording.phase.isBusy
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
      model.settings.$languageText.map { _ in () }.eraseToAnyPublisher(),
      model.settings.$apiProvider.map { _ in () }.eraseToAnyPublisher()
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
    guard hotkey.register(spec) else {
      model.recording.errorMessage =
        "\(spec.display) could not be registered. Another app may already use it. Pick a different shortcut in Setup."
      return
    }
  }

  private func hotkeyPressed() {
    // A press during the release-grace window cancels the pending stop.
    if pendingReleaseTask != nil {
      pendingReleaseTask?.cancel()
      pendingReleaseTask = nil
      return
    }

    if let lastPressAt, Date().timeIntervalSince(lastPressAt) < pressDebounce {
      return
    }
    lastPressAt = Date()

    switch model.recording.phase {
    case .idle, .delivered, .failed:
      pressStartedRecording = true
      pressAt = Date()
      // Paint the overlay on the hotkey thread before any async start work.
      if model.settings.showRecordingOverlay {
        overlayController?.update(for: .recording, enabled: true)
      }
      // Space/Esc must work while the primary key is still held — don't wait
      // for phase to flip inside the async start() Task.
      hotkey.setSessionControlsActive(true)
      Task {
        await model.recording.start()
      }
    case .recording:
      // Second press always finishes, whether hold, tap-toggle, or Space-locked.
      pressStartedRecording = false
      Task {
        await model.recording.stop()
      }
    case .connecting, .finishing:
      break
    }
  }

  private func hotkeyReleased() {
    let startedThisPress = pressStartedRecording
    let pressStartedAt = pressAt
    pressStartedRecording = false
    pressAt = nil

    guard startedThisPress else { return }
    // Space locked the take: keep listening after the hotkey comes up.
    guard !model.recording.isHandsFreeLocked else { return }

    let settings = model.settings
    let isHoldStyle: Bool
    if settings.hotkey.kind == .modifierHold {
      // Lone modifiers are always hold-to-talk when that mode is on.
      isHoldStyle = settings.holdIsPushToTalk
    } else if !settings.holdIsPushToTalk {
      // Tap-only: release never stops; second press does.
      isHoldStyle = false
    } else if !settings.tapStartsHandsFree {
      // Hold-only: any press stops on release.
      isHoldStyle = true
    } else if let pressStartedAt {
      isHoldStyle = Date().timeIntervalSince(pressStartedAt) >= pushToTalkThreshold
    } else {
      isHoldStyle = false
    }
    guard isHoldStyle else { return }

    // Drop the plate immediately on release — don't wait for paste/finalize.
    if model.settings.showRecordingOverlay {
      overlayController?.update(for: .finishing, enabled: true)
    }

    pendingReleaseTask?.cancel()
    let grace = releaseGraceNanoseconds
    pendingReleaseTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: grace)
      guard let self, !Task.isCancelled else { return }
      self.pendingReleaseTask = nil
      guard !self.model.recording.isHandsFreeLocked else {
        // Locked during the grace window — bring the plate back.
        if self.model.settings.showRecordingOverlay {
          self.overlayController?.update(for: .recording, enabled: true)
        }
        return
      }
      await self.model.recording.requestStop()
    }
  }

  private func lockDictationFromHold() {
    guard model.settings.spaceLocksHandsFree else { return }
    // Allow lock as soon as this press started a take — phase may not have
    // flipped to .recording yet if start() is still hopping onto MainActor.
    if pressStartedRecording
      || model.recording.phase == .connecting
      || model.recording.phase == .recording
    {
      model.recording.setHandsFreeLocked(true)
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
    statusItem.button?.toolTip = "ListenToMe — click for recent, right-click for menu"

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
      action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
      keyEquivalent: ""
    )
    checkForUpdates.target = model.updates.updaterController
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
      action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
      to: menu
    )
    checkForUpdates.target = model.updates.updaterController
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
          for: phase,
          enabled: model.settings.showRecordingOverlay
        )
        updateStatusItem(for: phase)
        hotkey.setSessionControlsActive(
          phase == .recording || phase == .connecting
        )
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

    model.settings.$hasAPIKey
      .sink { [weak self] _ in
        guard let self else { return }
        updateStatusItem(for: model.recording.phase)
      }
      .store(in: &subscriptions)

    model.recording.$errorMessage
      .compactMap { $0 }
      .removeDuplicates()
      .sink { [weak self] message in
        self?.presentErrorIfNeeded(message)
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
        contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 660),
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
      window.minSize = NSSize(width: 840, height: 560)
      // Hard caps — never let SwiftUI content or a huge autosave frame
      // stretch the window across a 4K display.
      window.maxSize = NSSize(width: 1_600, height: 1_000)
      window.titlebarAppearsTransparent = false
      // Empty sizingOptions: content never drives the window frame.
      let hostingView = NSHostingView(rootView: rootView)
      hostingView.sizingOptions = []
      window.contentView = hostingView
      window.center()
      window.setFrameAutosaveName("ListenToMe.MainWindow")

      controller = NSWindowController(window: window)
      mainWindowController = controller
    }

    if let window = controller.window {
      window.maxSize = NSSize(width: 1_600, height: 1_000)
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

  private func presentErrorIfNeeded(_ message: String) {
    // Non-activating notice under the menu bar — never activate / makeKey.
    updateStatusItem(for: model.recording.phase)
    statusItem?.button?.toolTip = "ListenToMe · \(message)"
    guard mainWindowController?.window?.isVisible != true else { return }
    guard let button = statusItem?.button else { return }
    historyPanelController?.show(
      relativeTo: button,
      style: .notice(seconds: 4)
    )
  }

  private func updateStatusItem(for phase: RecordingPhase) {
    let isRecording = phase == .recording
    let needsAttention =
      phase == .failed || model.recording.errorMessage != nil
    statusItem?.button?.image = NSImage(
      systemSymbolName: isRecording ? "record.circle.fill" : "waveform",
      accessibilityDescription: isRecording ? "Recording" : "ListenToMe"
    )
    statusItem?.button?.contentTintColor =
      isRecording || needsAttention
      ? NSColor(calibratedRed: 0.80, green: 0.35, blue: 0.24, alpha: 1)
      : nil
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
    case .connecting: "Connecting"
    case .recording: "Listening"
    case .finishing: "Finishing"
    case .delivered: "Delivered"
    case .failed: "Needs Attention"
    }
  }
}
