import AppKit
import Carbon
import SwiftUI

/// A keycap-styled control that captures any shortcut: a key with modifiers,
/// a bare function key, or a single held modifier such as Right ⌘ or Globe.
struct HotkeyRecorderView: View {
  @ObservedObject var settings: SettingsStore
  @State private var monitor: Any?
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
  }

  private var hintLine: String {
    if !hint.isEmpty {
      return hint
    }
    if settings.isCapturingHotkey {
      return "Press a key combination, or press and release one modifier alone, like Right ⌘ or Globe. Esc keeps the current shortcut."
    }
    switch settings.hotkey.kind {
    case .keyCombo:
      return "Tap to start and stop, or hold it down and speak: release to finish."
    case .modifierHold:
      return "Hold the key down and speak. Release to finish. Needs Accessibility access."
    }
  }

  private func beginCapture() {
    guard monitor == nil else { return }
    hint = ""
    settings.isCapturingHotkey = true

    var candidateModifier: UInt32?
    monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .flagsChanged]
    ) { event in
      MainActor.assumeIsolated {
        switch event.type {
        case .keyDown:
          if event.keyCode == UInt16(kVK_Escape),
            event.modifierFlags
              .intersection([.command, .option, .control, .shift])
              .isEmpty
          {
            endCapture()
            return
          }

          let modifiers = event.modifierFlags
            .intersection([.command, .option, .control, .shift])
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
      return nil
    }
  }

  private func commit(_ spec: HotkeySpec) {
    settings.hotkey = spec
    hint = ""
    endCapture()
  }

  private func endCapture() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    settings.isCapturingHotkey = false
  }
}
