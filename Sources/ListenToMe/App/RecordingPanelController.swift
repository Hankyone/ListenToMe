import AppKit
import SwiftUI

private final class RecordingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class RecordingPanelController {
  private let panel: RecordingPanel

  init(coordinator: RecordingCoordinator, settings: SettingsStore) {
    panel = RecordingPanel(
      contentRect: NSRect(x: 0, y: 0, width: 566, height: 113),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.contentView = NSHostingView(
      rootView: RecordingOverlayView(
        coordinator: coordinator,
        settings: settings
      )
    )
  }

  func update(for phase: RecordingPhase, enabled: Bool) {
    guard enabled else {
      panel.orderOut(nil)
      return
    }
    switch phase {
    case .connecting, .recording, .finishing, .delivered:
      show()
    case .idle, .failed:
      panel.orderOut(nil)
    }
  }

  private func show() {
    guard let screen = NSScreen.main else {
      panel.orderFrontRegardless()
      return
    }
    let visible = screen.visibleFrame
    let origin = NSPoint(
      x: visible.midX - panel.frame.width / 2,
      y: visible.minY + 42
    )
    panel.setFrameOrigin(origin)
    panel.orderFrontRegardless()
  }
}
