import AppKit
import SwiftUI

private final class RecordingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class RecordingPanelController {
  private let panel: RecordingPanel
  private var hideTask: Task<Void, Never>?

  init(coordinator: RecordingCoordinator, settings: SettingsStore) {
    let size = RecordingOverlayView.panelSize
    panel = RecordingPanel(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: size.width + 4,
        height: size.height + 12
      ),
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

  /// Mount/layout once at launch so the first dictation doesn't hitch.
  func preload() {
    positionOffscreen()
    panel.orderBack(nil)
    panel.orderOut(nil)
  }

  func update(for phase: RecordingPhase, enabled: Bool) {
    hideTask?.cancel()
    hideTask = nil
    guard enabled else {
      panel.orderOut(nil)
      return
    }
    switch phase {
    case .connecting, .recording:
      show()
    case .failed:
      show()
      hideTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard !Task.isCancelled else { return }
        self?.panel.orderOut(nil)
      }
    case .finishing, .delivered, .idle:
      panel.orderOut(nil)
    }
  }

  private func show() {
    positionOnScreen()
    panel.orderFrontRegardless()
  }

  private func positionOnScreen() {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    let origin = NSPoint(
      x: visible.midX - panel.frame.width / 2,
      y: visible.minY + 42
    )
    panel.setFrameOrigin(origin)
  }

  private func positionOffscreen() {
    panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
  }
}
