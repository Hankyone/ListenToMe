import AppKit
import SwiftUI

@MainActor
final class StatusHistoryPanelController {
  private let popover = NSPopover()
  private let model: AppModel
  private let onOpenHistory: () -> Void
  private let onOpenSetup: () -> Void
  private let panelWidth: CGFloat = 340
  private var globalMouseMonitor: Any?
  private var localEventMonitor: Any?
  private var workspaceObserver: NSObjectProtocol?
  private weak var anchorButton: NSStatusBarButton?

  init(
    model: AppModel,
    onOpenHistory: @escaping () -> Void,
    onOpenSetup: @escaping () -> Void
  ) {
    self.model = model
    self.onOpenHistory = onOpenHistory
    self.onOpenSetup = onOpenSetup

    // Own dismissal ourselves. `.transient` only closes after the popover has
    // become key — which means “click it, then click away.”
    popover.behavior = .applicationDefined
    popover.animates = true
    popover.contentSize = NSSize(width: panelWidth, height: 220)
    remountContent()
  }

  var isShown: Bool { popover.isShown }

  func toggle(relativeTo button: NSStatusBarButton) {
    if popover.isShown {
      close()
      return
    }
    show(relativeTo: button)
  }

  /// Opens under the menu-bar icon. Dismisses on click-away or Escape.
  func show(relativeTo button: NSStatusBarButton) {
    remountContent()
    anchorButton = button
    button.window?.layoutIfNeeded()
    popover.show(
      relativeTo: button.bounds,
      of: button,
      preferredEdge: .minY
    )
    startDismissalMonitoring()
  }

  func close() {
    stopDismissalMonitoring()
    guard popover.isShown else { return }
    popover.performClose(nil)
  }

  private func remountContent() {
    let host = NSHostingController(
      rootView: StatusHistoryPanel(
        history: model.history,
        recording: model.recording,
        onOpenHistory: onOpenHistory,
        onOpenSetup: onOpenSetup,
        onDismiss: { [weak self] in
          self?.close()
        },
        onClearNotice: { [weak self] in
          self?.model.recording.errorMessage = nil
        }
      )
    )
    // Match contentSize to the SwiftUI tree before showing. A taller stale
    // contentSize makes AppKit park the popover, then shrink it — leaving a
    // gap under the menu bar.
    let fitting = host.sizeThatFits(
      in: NSSize(width: panelWidth, height: 10_000)
    )
    popover.contentSize = NSSize(
      width: panelWidth,
      height: min(max(fitting.height.rounded(.up), 140), 520)
    )
    popover.contentViewController = host
  }

  private func startDismissalMonitoring() {
    stopDismissalMonitoring()

    // Global monitors run off the main thread and never see in-app events.
    // Bounce to the main actor so close() is safe and actually runs.
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

      if self.isMouseInsidePopoverOrAnchor() {
        return event
      }
      self.close()
      return event
    }

    workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        app.bundleIdentifier != Bundle.main.bundleIdentifier
      else {
        return
      }
      Task { @MainActor in
        self?.close()
      }
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
    if let workspaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
      self.workspaceObserver = nil
    }
  }

  private func dismissFromOutsideInteraction() {
    guard popover.isShown else { return }
    if isMouseInsidePopoverOrAnchor() { return }
    close()
  }

  private func isMouseInsidePopoverOrAnchor() -> Bool {
    let screenPoint = NSEvent.mouseLocation

    if let popoverWindow = popover.contentViewController?.view.window,
      popoverWindow.frame.contains(screenPoint)
    {
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
