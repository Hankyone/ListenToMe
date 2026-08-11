import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let model = AppModel()

  private let hotkey = HotkeyService()
  private let updates = UpdateService()
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
    applyHotkey(model.settings.hotkey)

    model.settings.$hotkey
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] spec in
        self?.applyHotkey(spec)
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

    let isHoldStyle: Bool
    if model.settings.hotkey.kind == .modifierHold {
      isHoldStyle = true
    } else if let pressStartedAt {
      isHoldStyle = Date().timeIntervalSince(pressStartedAt) >= pushToTalkThreshold
    } else {
      isHoldStyle = false
    }
    guard isHoldStyle else { return }

    pendingReleaseTask?.cancel()
    let grace = releaseGraceNanoseconds
    pendingReleaseTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: grace)
      guard let self, !Task.isCancelled else { return }
      self.pendingReleaseTask = nil
      guard !self.model.recording.isHandsFreeLocked else { return }
      await self.model.recording.requestStop()
    }
  }

  private func lockDictationFromHold() {
    switch model.recording.phase {
    case .connecting, .recording:
      model.recording.setHandsFreeLocked(true)
    default:
      break
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
    checkForUpdates.target = updates.updaterController
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
      "Setup…",
      symbolName: "slider.horizontal.3",
      action: #selector(openSetup),
      to: menu
    )
    let checkForUpdates = addMenuItem(
      "Check for Updates…",
      symbolName: "arrow.triangle.2.circlepath",
      action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
      to: menu
    )
    checkForUpdates.target = updates.updaterController
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
      let image = NSImage(
        systemSymbolName: symbolName,
        accessibilityDescription: title
      )
    {
      image.isTemplate = true
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
          .unifiedTitleAndToolbar,
        ],
        backing: .buffered,
        defer: false
      )
      window.title = "ListenToMe"
      window.minSize = NSSize(width: 840, height: 560)
      window.titlebarAppearsTransparent = false
      window.toolbarStyle = .unifiedCompact
      window.contentView = NSHostingView(rootView: rootView)
      window.center()
      window.setFrameAutosaveName("ListenToMe.MainWindow")

      controller = NSWindowController(window: window)
      mainWindowController = controller
    }

    NSApplication.shared.activate(ignoringOtherApps: true)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
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
