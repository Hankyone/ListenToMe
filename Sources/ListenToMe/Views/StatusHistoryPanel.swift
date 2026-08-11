import SwiftUI

struct StatusHistoryPanel: View {
  @ObservedObject var history: HistoryStore
  @ObservedObject var recording: RecordingCoordinator
  var onOpenHistory: () -> Void
  var onDismiss: () -> Void

  @StateObject private var playback = AudioPlaybackController()
  @State private var activePlaybackID: UUID?
  @State private var copiedID: UUID?

  private var recentEntries: [HistoryEntry] {
    Array(history.entries.prefix(3))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text("Recent")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(AppTheme.primaryText)
        Spacer()
        Text(modelStatus)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(AppTheme.faintText)
      }
      .padding(.horizontal, 16)
      .padding(.top, 14)
      .padding(.bottom, 10)

      if recentEntries.isEmpty {
        emptyState
      } else {
        VStack(spacing: 8) {
          ForEach(recentEntries) { entry in
            recentRow(entry)
          }
        }
        .padding(.horizontal, 12)
      }

      Divider()
        .overlay(AppTheme.edge.opacity(0.55))
        .padding(.top, 12)

      Button {
        onOpenHistory()
        onDismiss()
      } label: {
        Text("Open History…")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(AppTheme.secondaryText)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .frame(width: 340)
    .background(AppTheme.surface)
    .preferredColorScheme(.dark)
    .onDisappear {
      playback.stop()
      activePlaybackID = nil
    }
  }

  private var modelStatus: String {
    if recording.phase == .recording { return "Listening" }
    if recording.phase == .connecting { return "Connecting" }
    if recording.phase == .finishing { return "Finishing" }
    return "Ready"
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("No dictations yet")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(AppTheme.primaryText)
      Text("Use your shortcut to capture something. It will show up here.")
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 18)
  }

  private func recentRow(_ entry: HistoryEntry) -> some View {
    let isActive = activePlaybackID == entry.id && playback.isPlaying

    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(AppTheme.secondaryText)
        Text(entry.shortTargetName)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(AppTheme.faintText)
          .lineLimit(1)
        Spacer(minLength: 4)
        Text(formattedDuration(entry.duration))
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(AppTheme.faintText)
      }

      Text(entry.transcript)
        .font(.system(size: 13))
        .foregroundStyle(AppTheme.primaryText)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 14) {
        Button {
          togglePlayback(for: entry)
        } label: {
          Label(
            isActive ? "Pause" : "Play",
            systemImage: isActive ? "pause.fill" : "play.fill"
          )
        }
        .buttonStyle(QuietButtonStyle())

        Button {
          recording.copyTranscript(entry.transcript)
          copiedID = entry.id
          Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedID == entry.id {
              copiedID = nil
            }
          }
        } label: {
          Label(
            copiedID == entry.id ? "Copied" : "Copy",
            systemImage: copiedID == entry.id ? "checkmark" : "doc.on.doc"
          )
        }
        .buttonStyle(QuietButtonStyle())

        Spacer(minLength: 0)
      }
    }
    .padding(12)
    .background(
      ChamferedPlate(cut: 8)
        .fill(AppTheme.raisedSurface)
        .overlay(
          ChamferedPlate(cut: 8)
            .fill(AppTheme.plateSheen)
        )
    )
  }

  private func togglePlayback(for entry: HistoryEntry) {
    if activePlaybackID == entry.id {
      playback.toggle()
      return
    }

    playback.stop()
    playback.load(history.audioURL(for: entry))
    activePlaybackID = entry.id
    playback.toggle()
  }

  private func formattedDuration(_ duration: TimeInterval) -> String {
    let seconds = Int(max(0, duration))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
