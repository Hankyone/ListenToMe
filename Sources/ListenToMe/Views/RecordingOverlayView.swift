import SwiftUI

/// Compact floating plate while dictating — tiny meter, room for live text.
struct RecordingOverlayView: View {
  @ObservedObject var coordinator: RecordingCoordinator
  @ObservedObject var settings: SettingsStore

  private var layout: OverlayLayout { settings.overlayLayout }
  private var panelSize: CGSize { layout.panelSize }

  private var isDelivered: Bool {
    if case .delivered = coordinator.phase { return true }
    return false
  }

  var body: some View {
    HStack(alignment: layout == .tall ? .top : .center, spacing: 10) {
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
      .padding(.top, layout == .tall ? 2 : 0)

      VStack(alignment: .leading, spacing: 2) {
        transcriptLine
          .font(.system(size: 12))
          .lineLimit(layout.lineLimit)
          .truncationMode(.head)
          .frame(maxWidth: .infinity, alignment: .leading)

        Text(trailingHint)
          .font(.system(size: 9, weight: .medium, design: .monospaced))
          .foregroundStyle(AppTheme.faintText)
          .lineLimit(1)
      }

      TimelineView(.periodic(from: .now, by: 0.1)) { context in
        Text(timeText(at: context.date))
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .monospacedDigit()
          .foregroundStyle(
            isDelivered ? AppTheme.success : AppTheme.secondaryText
          )
          .frame(minWidth: 34, alignment: .trailing)
      }
      .padding(.top, layout == .tall ? 2 : 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .frame(
      width: panelSize.width,
      height: panelSize.height
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
    case .connecting, .recording, .finishing:
      if let target = coordinator.targetApplication?.name {
        "Listening for \(target)"
      } else {
        "Listening"
      }
    case .delivered(let outcome): outcome.title
    case .failed: coordinator.errorMessage ?? "Audio saved"
    case .idle: "Ready"
    }
  }

  @ViewBuilder
  private var transcriptLine: some View {
    let committed = coordinator.committedTranscript
    let tentative = coordinator.tentativeTranscript
    let combined = (committed + tentative)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if let message = coordinator.errorMessage, coordinator.phase == .failed {
      Text(message)
        .foregroundStyle(AppTheme.secondaryText)
    } else if combined.isEmpty {
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
    case .finishing: "Listening…"
    case .delivered: "Done"
    default: "Listening…"
    }
  }

  private var trailingHint: String {
    switch coordinator.phase {
    case .recording, .connecting, .finishing:
      if coordinator.isHandsFreeLocked {
        return "press again · esc finishes"
      }
      if settings.spaceLocksHandsFree, settings.holdIsPushToTalk {
        return "space locks · esc"
      }
      return "esc cancels"
    default:
      return settings.hotkey.display.lowercased()
    }
  }

  private func timeText(at now: Date) -> String {
    let seconds: Int
    if let started = coordinator.listenStartedAt {
      seconds = max(0, Int(now.timeIntervalSince(started)))
    } else {
      seconds = Int(coordinator.elapsed)
    }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
