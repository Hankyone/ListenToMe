import AppKit
import SwiftUI

@MainActor
final class StatusHistoryPanelController {
  private let popover = NSPopover()
  private let model: AppModel
  private let onOpenHistory: () -> Void

  init(model: AppModel, onOpenHistory: @escaping () -> Void) {
    self.model = model
    self.onOpenHistory = onOpenHistory

    popover.behavior = .transient
    popover.animates = true
    popover.contentSize = NSSize(width: 340, height: 420)

    let root = StatusHistoryPanel(
      history: model.history,
      recording: model.recording,
      onOpenHistory: onOpenHistory,
      onDismiss: { [weak self] in
        self?.close()
      }
    )
    popover.contentViewController = NSHostingController(rootView: root)
  }

  var isShown: Bool { popover.isShown }

  func toggle(relativeTo button: NSStatusBarButton) {
    if popover.isShown {
      close()
      return
    }
    // Remount so the recent list is fresh each open.
    popover.contentViewController = NSHostingController(
      rootView: StatusHistoryPanel(
        history: model.history,
        recording: model.recording,
        onOpenHistory: onOpenHistory,
        onDismiss: { [weak self] in
          self?.close()
        }
      )
    )
    popover.show(
      relativeTo: button.bounds,
      of: button,
      preferredEdge: .minY
    )
  }

  func close() {
    popover.performClose(nil)
  }
}
