import AppKit
import Carbon
import SwiftUI

/// Holds the NSEvent monitor off the SwiftUI view value so cancel/commit
/// cannot leave a stale callback swallowing keys after capture ends.
@MainActor
private final class HotkeyCaptureBox {
  var monitor: Any?
  var generation = 0
}

/// A keycap-styled control that captures any shortcut: a key with modifiers,
/// a bare function key, or a single held modifier such as Right ⌘ or Globe.
struct HotkeyRecorderView: View {
  @ObservedObject var settings: SettingsStore
  @State private var capture = HotkeyCaptureBox()
  @State private var hint = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Button {
          settings.isCapturingHotkey ? endCapture() : beginCapture()
        } label: {
          Text(
            settings.isCapturingHotkey
              ? "Press keys now…"
              : settings.hotkey.display
          )
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .foregroundStyle(
            settings.isCapturingHotkey
              ? AppTheme.secondaryText
              : AppTheme.primaryText
          )
          .padding(.horizontal, 14)
          .padding(.vertical, 7)
          .frame(minWidth: 150)
          .background(
            ChamferedPlate(cut: 7)
              .fill(
                settings.isCapturingHotkey
                  ? AppTheme.background
                  : AppTheme.raisedSurface
              )
          )
          .overlay(
            ChamferedPlate(cut: 7)
              .stroke(
                settings.isCapturingHotkey
                  ? AppTheme.accent
                  : AppTheme.raisedSurface,
                lineWidth: 1
              )
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          settings.isCapturingHotkey
            ? "Recording a new shortcut. Press the keys you want."
            : "Dictation shortcut: \(settings.hotkey.display). Click to change."
        )

        if settings.isCapturingHotkey {
          Button("Cancel") {
            endCapture()
          }
          .buttonStyle(.plain)
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.secondaryText)
        } else if settings.hotkey != .standard {
          Button("Reset") {
            settings.hotkey = .standard
          }
          .buttonStyle(.plain)
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.secondaryText)
        }
      }

      Text(hintLine)
        .font(.system(size: 11))
        .foregroundStyle(AppTheme.faintText)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onDisappear {
      endCapture()
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: NSApplication.willResignActiveNotification
      )
    ) { _ in
      endCapture()
    }
  }

  private var hintLine: String {
    if !hint.isEmpty {
      return hint
    }
    if settings.isCapturingHotkey {
      return "Press a key combination, or press and release one modifier alone, like Right ⌘ or Globe. Esc or Space keeps the current shortcut."
    }
    return "Behaviors for this shortcut are below — tap, hold, and Space lock."
  }

  private func beginCapture() {
    guard capture.monitor == nil else { return }
    hint = ""
    settings.isCapturingHotkey = true
    capture.generation += 1
    let generation = capture.generation

    var candidateModifier: UInt32?
    capture.monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .flagsChanged]
    ) { event in
      var swallow = true
      MainActor.assumeIsolated {
        guard generation == capture.generation else {
          swallow = false
          return
        }

        switch event.type {
        case .keyDown:
          let extraModifiers = event.modifierFlags
            .intersection([.command, .option, .control, .shift])
          if extraModifiers.isEmpty,
            event.keyCode == UInt16(kVK_Escape)
            || event.keyCode == UInt16(kVK_Space)
            || event.keyCode == UInt16(kVK_Return)
          {
            endCapture()
            return
          }

          let modifiers = extraModifiers
          let isFunctionKey = KeyGlyphs.isFunctionKey(UInt32(event.keyCode))
          let hasHardModifier = !modifiers
            .intersection([.command, .option, .control])
            .isEmpty

          guard hasHardModifier || isFunctionKey else {
            hint = "Add ⌘, ⌥, or ⌃, use an F-key, or hold a single modifier."
            return
          }

          commit(
            .keyCombo(
              keyCode: UInt32(event.keyCode),
              nsModifiers: modifiers
            )
          )

        case .flagsChanged:
          let active = event.modifierFlags.intersection([
            .command, .option, .control, .shift, .function,
          ])
          let count =
            [
              NSEvent.ModifierFlags.command, .option, .control, .shift,
              .function,
            ]
            .filter { active.contains($0) }
            .count

          if count == 1 {
            candidateModifier = UInt32(event.keyCode)
          } else if count == 0 {
            if let candidate = candidateModifier {
              commit(.modifierHold(keyCode: candidate))
            }
          } else {
            candidateModifier = nil
          }

        default:
          break
        }
      }
      return swallow ? nil : event
    }
  }

  private func commit(_ spec: HotkeySpec) {
    settings.hotkey = spec
    hint = ""
    endCapture()
  }

  private func endCapture() {
    capture.generation += 1
    if let monitor = capture.monitor {
      NSEvent.removeMonitor(monitor)
      capture.monitor = nil
    }
    settings.isCapturingHotkey = false
  }
}
