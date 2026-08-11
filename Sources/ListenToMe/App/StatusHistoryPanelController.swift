import AppKit
import SwiftUI

@MainActor
final class StatusHistoryPanelController {
  private let popover = NSPopover()
  private let model: AppModel
  private let onOpenHistory: () -> Void
  private let onOpenSetup: () -> Void
  private let panelWidth: CGFloat = 340

  init(
    model: AppModel,
    onOpenHistory: @escaping () -> Void,
    onOpenSetup: @escaping () -> Void
  ) {
    self.model = model
    self.onOpenHistory = onOpenHistory
    self.onOpenSetup = onOpenSetup

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

  /// Opens under the menu-bar icon without activating the app or stealing focus.
  func show(relativeTo button: NSStatusBarButton) {
    remountContent()
    button.window?.layoutIfNeeded()
    popover.show(
      relativeTo: button.bounds,
      of: button,
      preferredEdge: .minY
    )
  }

  func close() {
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
}
