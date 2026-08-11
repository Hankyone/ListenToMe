import AppKit
import SwiftUI

/// Non-activating panel so notices never steal key focus from the user's app.
private final class StatusMenuPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusHistoryPanelController {
  private let panel: StatusMenuPanel
  private let model: AppModel
  private let onOpenHistory: () -> Void
  private let onOpenSetup: () -> Void
  private let panelWidth: CGFloat = 340
  private let menuGap: CGFloat = 6

  private var globalMouseMonitor: Any?
  private var localEventMonitor: Any?
  private var autoDismissTask: Task<Void, Never>?
  private weak var anchorButton: NSStatusBarButton?
  private var hostingController: NSHostingController<StatusHistoryPanel>?

  init(
    model: AppModel,
    onOpenHistory: @escaping () -> Void,
    onOpenSetup: @escaping () -> Void
  ) {
    self.model = model
    self.onOpenHistory = onOpenHistory
    self.onOpenSetup = onOpenSetup

    panel = StatusMenuPanel(
      contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 220),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .utilityWindow
  }

  var isShown: Bool { panel.isVisible }

  func toggle(relativeTo button: NSStatusBarButton) {
    if panel.isVisible {
      close()
      return
    }
    show(relativeTo: button, style: .recent)
  }

  /// Opens under the menu-bar icon without activating ListenToMe.
  func show(
    relativeTo button: NSStatusBarButton,
    style: StatusPanelStyle = .recent
  ) {
    cancelAutoDismiss()
    anchorButton = button
    remountContent(style: style)
    positionPanel(relativeTo: button)
    // orderFrontRegardless keeps the user's frontmost app key.
    panel.orderFrontRegardless()
    startDismissalMonitoring()

    if case .notice(let seconds) = style, seconds > 0 {
      autoDismissTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard !Task.isCancelled else { return }
        self?.close()
      }
    }
  }

  func close() {
    cancelAutoDismiss()
    stopDismissalMonitoring()
    panel.orderOut(nil)
  }

  private func cancelAutoDismiss() {
    autoDismissTask?.cancel()
    autoDismissTask = nil
  }

  private func remountContent(style: StatusPanelStyle) {
    let root = StatusHistoryPanel(
      history: model.history,
      recording: model.recording,
      presentation: style.presentation,
      onOpenHistory: onOpenHistory,
      onOpenSetup: onOpenSetup,
      onDismiss: { [weak self] in
        self?.close()
      },
      onClearNotice: { [weak self] in
        self?.model.recording.errorMessage = nil
      }
    )
    let controller = NSHostingController(rootView: root)
    // Propose the max height we allow — some SwiftUI versions echo a huge
    // proposed height back as the fitting size.
    let maxHeight: CGFloat = 420
    let fitting = controller.sizeThatFits(
      in: NSSize(width: panelWidth, height: maxHeight)
    )
    let height = min(max(fitting.height.rounded(.up), 72), maxHeight)
    controller.view.frame = NSRect(x: 0, y: 0, width: panelWidth, height: height)
    panel.contentView = controller.view
    hostingController = controller
    panel.setContentSize(NSSize(width: panelWidth, height: height))
  }

  private func positionPanel(relativeTo button: NSStatusBarButton) {
    guard let buttonWindow = button.window else { return }
    buttonWindow.layoutIfNeeded()

    let buttonRect = buttonWindow.convertToScreen(
      button.convert(button.bounds, to: nil)
    )
    let size = panel.frame.size
    var origin = NSPoint(
      x: buttonRect.midX - size.width / 2,
      y: buttonRect.minY - size.height - menuGap
    )

    if let screen = buttonWindow.screen ?? NSScreen.main {
      let visible = screen.visibleFrame
      origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
      // Keep attached under the menu bar even if the panel is tall.
      origin.y = min(origin.y, buttonRect.minY - size.height - menuGap)
      origin.y = max(origin.y, visible.minY + 8)
    }

    panel.setFrameOrigin(origin)
  }

  private func startDismissalMonitoring() {
    stopDismissalMonitoring()

    globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      Task { @MainActor in
        self?.dismissFromOutsideInteraction()
      }
    }

    localEventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .keyDown]
    ) { [weak self] event in
      guard let self else { return event }

      if event.type == .keyDown {
        if event.keyCode == 53 {  // Escape
          self.close()
          return nil
        }
        return event
      }

      if self.isMouseInsidePanelOrAnchor() {
        return event
      }
      self.close()
      return event
    }
  }

  private func stopDismissalMonitoring() {
    if let globalMouseMonitor {
      NSEvent.removeMonitor(globalMouseMonitor)
      self.globalMouseMonitor = nil
    }
    if let localEventMonitor {
      NSEvent.removeMonitor(localEventMonitor)
      self.localEventMonitor = nil
    }
  }

  private func dismissFromOutsideInteraction() {
    guard panel.isVisible else { return }
    if isMouseInsidePanelOrAnchor() { return }
    close()
  }

  private func isMouseInsidePanelOrAnchor() -> Bool {
    let screenPoint = NSEvent.mouseLocation
    if panel.frame.contains(screenPoint) {
      return true
    }
    if let button = anchorButton, let buttonWindow = button.window {
      let rectInWindow = button.convert(button.bounds, to: nil)
      let rectOnScreen = buttonWindow.convertToScreen(rectInWindow)
      if rectOnScreen.contains(screenPoint) {
        return true
      }
    }
    return false
  }
}

enum StatusPanelStyle {
  case recent
  /// Compact notice that auto-dismisses after `seconds`.
  case notice(seconds: TimeInterval)

  var presentation: StatusHistoryPanel.Presentation {
    switch self {
    case .recent: .recent
    case .notice: .noticeOnly
    }
  }
}
