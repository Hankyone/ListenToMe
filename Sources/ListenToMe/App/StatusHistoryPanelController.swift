import AppKit
import SwiftUI

@MainActor
final class StatusHistoryPanelController {
  private let popover = NSPopover()
  private let model: AppModel
  private let onOpenHistory: () -> Void
  private let onOpenSetup: () -> Void
  private let panelWidth: CGFloat = 340
  private var dismissalMonitors: [Any] = []
  private weak var anchorButton: NSStatusBarButton?

  init(
    model: AppModel,
    onOpenHistory: @escaping () -> Void,
    onOpenSetup: @escaping () -> Void
  ) {
    self.model = model
    self.onOpenHistory = onOpenHistory
    self.onOpenSetup = onOpenSetup

    // Transient alone is unreliable for NSStatusItem anchors; we also install
    // click-away monitors in show(_:).
    popover.behavior = .transient
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
    // Helps AppKit treat the popover as the active transient surface.
    popover.contentViewController?.view.window?.makeKey()
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

    let mouseHandler: (NSEvent) -> Void = { [weak self] event in
      guard let self, self.popover.isShown else { return }
      if self.isEventInsidePopoverOrAnchor(event) { return }
      self.close()
    }

    if let global = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown],
      handler: mouseHandler
    ) {
      dismissalMonitors.append(global)
    }

    if let local = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .keyDown],
      handler: { [weak self] event in
        guard let self, self.popover.isShown else { return event }

        if event.type == .keyDown {
          // Escape
          if event.keyCode == 53 {
            self.close()
            return nil
          }
          return event
        }

        if self.isEventInsidePopoverOrAnchor(event) {
          return event
        }
        self.close()
        return event
      }
    ) {
      dismissalMonitors.append(local)
    }
  }

  private func stopDismissalMonitoring() {
    for monitor in dismissalMonitors {
      NSEvent.removeMonitor(monitor)
    }
    dismissalMonitors.removeAll()
  }

  private func isEventInsidePopoverOrAnchor(_ event: NSEvent) -> Bool {
    let screenPoint = NSEvent.mouseLocation

    if let popoverWindow = popover.contentViewController?.view.window,
      popoverWindow.frame.contains(screenPoint)
    {
      return true
    }

    if let button = anchorButton,
      let buttonWindow = button.window
    {
      let rectInWindow = button.convert(button.bounds, to: nil)
      let rectOnScreen = buttonWindow.convertToScreen(rectInWindow)
      if rectOnScreen.contains(screenPoint) {
        return true
      }
    }

    // Keep the event available for local handling (e.g. status-item toggle).
    _ = event
    return false
  }
}
