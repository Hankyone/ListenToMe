import SwiftUI

/// The floating plate shown while dictating. It sits over whatever the user
/// is doing, so it must be instantly legible and never ambiguous about
/// whether the microphone is live.
struct RecordingOverlayView: View {
  @ObservedObject var coordinator: RecordingCoordinator
  @ObservedObject var settings: SettingsStore

  private var isDelivered: Bool {
    if case .delivered = coordinator.phase { return true }
    return false
  }

  var body: some View {
    HStack(spacing: 18) {
      Group {
        if coordinator.phase == .connecting {
          ConnectingWaveform()
        } else {
          WaveformView(
            levels: coordinator.levels,
            color: isDelivered ? AppTheme.success : AppTheme.accent,
            animated: true
          )
        }
      }
      .frame(width: 112, height: 46)

      VStack(alignment: .leading, spacing: 6) {
        Text(statusLine)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(AppTheme.primaryText)
          .contentTransition(.opacity)
          .animation(.easeOut(duration: 0.18), value: statusLine)

        transcriptLine
          .font(.system(size: 13))
          .lineLimit(2)
          .truncationMode(.head)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      VStack(alignment: .trailing, spacing: 7) {
        Text(timeText)
          .font(.system(size: 15, weight: .medium, design: .monospaced))
          .monospacedDigit()
          .foregroundStyle(
            isDelivered ? AppTheme.success : AppTheme.primaryText
          )
        Text(trailingHint)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(AppTheme.faintText)
      }
      .frame(width: 86, alignment: .trailing)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 17)
    .frame(width: 560, height: 96)
    .background(
      ChamferedPlate(cut: 12)
        .fill(AppTheme.surface)
        .overlay(
          ChamferedPlate(cut: 12)
            .fill(AppTheme.plateSheen)
        )
    )
    .overlay(
      ChamferedPlate(cut: 12)
        .stroke(AppTheme.edge.opacity(0.85), lineWidth: 1)
    )
    .compositingGroup()
    .shadow(
      color: Color.black.opacity(0.38),
      radius: 9,
      x: 0,
      y: 5
    )
    .padding(.horizontal, 3)
    .padding(.top, 3)
    .padding(.bottom, 14)
  }

  private var statusLine: String {
    switch coordinator.phase {
    case .connecting:
      return "Opening the line…"
    case .recording:
      if let target = coordinator.targetApplication?.name {
        return "Listening · for \(target)"
      }
      return "Listening"
    case .finishing:
      return "Finishing the last words…"
    case .delivered(let outcome):
      return outcome.title
    case .failed:
      return "Recording stopped"
    case .idle:
      return "Ready"
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
      // Committed = stable ink; tentative = still-revising live tail.
      (Text(committed).foregroundStyle(AppTheme.primaryText)
        + Text(tentative).foregroundStyle(AppTheme.secondaryText))
    }
  }

  private var placeholderTranscript: String {
    switch coordinator.phase {
    case .connecting:
      return "You can start speaking now."
    case .finishing:
      return "Checking the last words."
    default:
      return "Speak naturally. Pauses are fine."
    }
  }

  private var trailingHint: String {
    switch coordinator.phase {
    case .recording, .connecting:
      if coordinator.isHandsFreeLocked {
        return "locked · esc cancels"
      }
      return "space locks · esc cancels"
    default:
      return settings.hotkey.display.lowercased()
    }
  }

  private var timeText: String {
    let seconds = Int(coordinator.elapsed)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
