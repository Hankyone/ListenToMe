import AppKit
import ApplicationServices
import Foundation

@MainActor
final class TextDeliveryService {
  private struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
  }

  private let markerType = NSPasteboard.PasteboardType(
    "ca.hankyone.ListenToMe.PasteSession"
  )

  func deliver(
    _ text: String,
    to target: TargetApplication?
  ) async -> DeliveryOutcome {
    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let policy = DeliveryPolicy.outcome(
      target: target,
      frontmostProcessIdentifier: frontmostPID,
      hasAccessibilityPermission: AXIsProcessTrusted()
    )

    guard policy == .pasted, let target else {
      copy(text)
      return policy
    }

    let snapshot = captureClipboard()
    let marker = UUID().uuidString
    guard preparePasteboard(text: text, marker: marker) else {
      copy(text)
      return .copiedPasteFailed
    }

    try? await Task.sleep(nanoseconds: 100_000_000)
    guard
      NSWorkspace.shared.frontmostApplication?.processIdentifier
        == target.processIdentifier
    else {
      copy(text)
      return .copiedFocusChanged
    }

    guard postPasteShortcut() else {
      copy(text)
      return .copiedPasteFailed
    }

    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 600_000_000)
      self?.restoreClipboard(snapshot, ifMarkerMatches: marker)
    }
    return .pasted
  }

  func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private func captureClipboard() -> ClipboardSnapshot {
    let items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
      [NSPasteboard.PasteboardType: Data](
        uniqueKeysWithValues: item.types.compactMap { type in
          guard let data = item.data(forType: type) else { return nil }
          return (type, data)
        }
      )
    }
    return ClipboardSnapshot(items: items)
  }

  private func preparePasteboard(text: String, marker: String) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else { return false }
    return pasteboard.setString(marker, forType: markerType)
  }

  private func restoreClipboard(
    _ snapshot: ClipboardSnapshot,
    ifMarkerMatches marker: String
  ) {
    let pasteboard = NSPasteboard.general
    guard pasteboard.string(forType: markerType) == marker else { return }

    pasteboard.clearContents()
    guard !snapshot.items.isEmpty else { return }

    let restoredItems = snapshot.items.map { captured in
      let item = NSPasteboardItem()
      for (type, data) in captured {
        item.setData(data, forType: type)
      }
      return item
    }
    pasteboard.writeObjects(restoredItems)
  }

  private func postPasteShortcut() -> Bool {
    let commandKeyCode: CGKeyCode = 0x37
    let vKeyCode: CGKeyCode = 0x09
    let source = CGEventSource(stateID: .hidSystemState)

    let events: [(CGKeyCode, Bool, CGEventFlags)] = [
      (commandKeyCode, true, .maskCommand),
      (vKeyCode, true, .maskCommand),
      (vKeyCode, false, .maskCommand),
      (commandKeyCode, false, []),
    ]

    for (keyCode, isDown, flags) in events {
      guard
        let event = CGEvent(
          keyboardEventSource: source,
          virtualKey: keyCode,
          keyDown: isDown
        )
      else {
        return false
      }
      event.flags = flags
      event.post(tap: .cghidEventTap)
    }
    return true
  }
}
