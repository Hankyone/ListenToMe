import SwiftUI

struct StatusHistoryPanel: View {
  enum Presentation {
    case recent
    case noticeOnly
  }

  @ObservedObject var history: HistoryStore
  @ObservedObject var recording: RecordingCoordinator
  var presentation: Presentation = .recent
  var onOpenHistory: () -> Void
  var onOpenSetup: () -> Void
  var onDismiss: () -> Void
  var onClearNotice: () -> Void

  @StateObject private var playback = AudioPlaybackController()
  @State private var activePlaybackID: UUID?
  @State private var copiedID: UUID?

  private var recentEntries: [HistoryEntry] {
    Array(history.entries.prefix(3))
  }

  private var notice: String? {
    recording.errorMessage
  }

  private var noticeSuggestsSetup: Bool {
    guard let notice else { return false }
    return notice.localizedCaseInsensitiveContains("key")
      || notice.localizedCaseInsensitiveContains("shortcut")
      || notice.localizedCaseInsensitiveContains("setup")
      || notice.localizedCaseInsensitiveContains("permission")
      || notice.localizedCaseInsensitiveContains("language")
  }

  var body: some View {
    Group {
      switch presentation {
      case .noticeOnly:
        noticeOnlyBody
      case .recent:
        recentBody
      }
    }
    .frame(width: 340)
    .background(AppTheme.surface)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(AppTheme.edge.opacity(0.7), lineWidth: 1)
    )
    .preferredColorScheme(.dark)
    .onDisappear {
      playback.stop()
      activePlaybackID = nil
    }
  }

  private var noticeOnlyBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let notice {
        noticeBanner(notice)
          .padding(12)
      } else {
        Text("Ready")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(AppTheme.faintText)
          .padding(14)
      }
    }
  }

  private var recentBody: some View {
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

      if let notice {
        noticeBanner(notice)
          .padding(.horizontal, 12)
          .padding(.bottom, 10)
      }

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
  }

  private var modelStatus: String {
    if recording.phase == .recording { return "Listening" }
    if recording.phase == .connecting { return "Connecting" }
    if recording.phase == .finishing { return "Finishing" }
    if notice != nil || recording.phase == .failed { return "Needs attention" }
    return "Ready"
  }

  @ViewBuilder
  private func noticeBanner(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(AppTheme.accent)
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: 4) {
          Text("Dictation stopped")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
          Text(message)
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.secondaryText)
            .lineLimit(5)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        Button {
          onClearNotice()
          if presentation == .noticeOnly {
            onDismiss()
          }
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppTheme.faintText)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
      }

      if noticeSuggestsSetup {
        Button {
          onOpenSetup()
          onDismiss()
        } label: {
          Text("Open Setup…")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(12)
    .background(
      ChamferedPlate(cut: 8)
        .fill(AppTheme.raisedSurface)
        .overlay(
          ChamferedPlate(cut: 8)
            .stroke(AppTheme.accent.opacity(0.35), lineWidth: 1)
        )
    )
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

      Text(entry.previewText)
        .font(.system(size: 13))
        .foregroundStyle(
          entry.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            ? AppTheme.secondaryText
            : AppTheme.primaryText
        )
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
        .disabled(
          entry.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        )

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
