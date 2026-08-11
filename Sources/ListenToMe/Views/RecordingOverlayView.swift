import SwiftUI

/// Compact floating plate while dictating — tiny meter, room for live text.
struct RecordingOverlayView: View {
  @ObservedObject var coordinator: RecordingCoordinator
  @ObservedObject var settings: SettingsStore

  static let panelSize = CGSize(width: 420, height: 58)

  private var isDelivered: Bool {
    if case .delivered = coordinator.phase { return true }
    return false
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Group {
        if coordinator.phase == .connecting {
          ConnectingWaveform(barWidth: 2)
        } else {
          WaveformView(
            levels: coordinator.levels,
            color: isDelivered ? AppTheme.success : AppTheme.accent,
            barWidth: 2,
            animated: true
          )
        }
      }
      .frame(width: 40, height: 20)

      VStack(alignment: .leading, spacing: 2) {
        transcriptLine
          .font(.system(size: 12))
          .lineLimit(2)
          .truncationMode(.head)
          .frame(maxWidth: .infinity, alignment: .leading)

        Text(trailingHint)
          .font(.system(size: 9, weight: .medium, design: .monospaced))
          .foregroundStyle(AppTheme.faintText)
          .lineLimit(1)
      }

      Text(timeText)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(
          isDelivered ? AppTheme.success : AppTheme.secondaryText
        )
        .frame(minWidth: 34, alignment: .trailing)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .frame(
      width: Self.panelSize.width,
      height: Self.panelSize.height
    )
    .background(
      ChamferedPlate(cut: 9)
        .fill(AppTheme.surface)
        .overlay(
          ChamferedPlate(cut: 9)
            .fill(AppTheme.plateSheen)
        )
    )
    .overlay(
      ChamferedPlate(cut: 9)
        .stroke(AppTheme.edge.opacity(0.85), lineWidth: 1)
    )
    .compositingGroup()
    .shadow(
      color: Color.black.opacity(0.38),
      radius: 8,
      x: 0,
      y: 4
    )
    .padding(.horizontal, 2)
    .padding(.top, 2)
    .padding(.bottom, 8)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(statusLine)
  }

  private var statusLine: String {
    switch coordinator.phase {
    case .connecting: "Listening"
    case .recording:
      if let target = coordinator.targetApplication?.name {
        "Listening for \(target)"
      } else {
        "Listening"
      }
    case .finishing: "Finishing"
    case .delivered(let outcome): outcome.title
    case .failed: "Stopped"
    case .idle: "Ready"
    }
  }

  @ViewBuilder
  private var transcriptLine: some View {
    let committed = coordinator.committedTranscript
    let tentative = coordinator.tentativeTranscript
    let combined = (committed + tentative)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if combined.isEmpty {
      Text(placeholderTranscript)
        .foregroundStyle(AppTheme.secondaryText)
    } else {
      (Text(committed).foregroundStyle(AppTheme.primaryText)
        + Text(tentative).foregroundStyle(AppTheme.secondaryText))
    }
  }

  private var placeholderTranscript: String {
    switch coordinator.phase {
    case .connecting: "Listening…"
    case .finishing: "Checking last words…"
    case .delivered: "Done"
    default: "Listening…"
    }
  }

  private var trailingHint: String {
    switch coordinator.phase {
    case .recording, .connecting:
      if coordinator.isHandsFreeLocked {
        return "locked · esc"
      }
      return "space locks · esc"
    default:
      return settings.hotkey.display.lowercased()
    }
  }

  private var timeText: String {
    let seconds = Int(coordinator.elapsed)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
