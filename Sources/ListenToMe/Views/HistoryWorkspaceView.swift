import SwiftUI

struct HistoryWorkspaceView: View {
  @ObservedObject var history: HistoryStore
  @Binding var selectedID: UUID?
  @ObservedObject var recording: RecordingCoordinator
  let hotkeyDisplay: String

  var body: some View {
    GeometryReader { proxy in
      let narrow = proxy.size.width < 700
      if narrow {
        // In a tight window, stack list above detail instead of clipping.
        VSplitView {
          HistoryListView(
            history: history,
            selectedID: $selectedID,
            hotkeyDisplay: hotkeyDisplay
          )
          .frame(minHeight: 160, idealHeight: proxy.size.height * 0.38)

          HistoryDetailView(
            history: history,
            selectedID: $selectedID,
            recording: recording
          )
          .frame(minHeight: 220)
        }
      } else {
        HSplitView {
          HistoryListView(
            history: history,
            selectedID: $selectedID,
            hotkeyDisplay: hotkeyDisplay
          )
          .frame(minWidth: 200, idealWidth: 280, maxWidth: 360)

          HistoryDetailView(
            history: history,
            selectedID: $selectedID,
            recording: recording
          )
          .frame(minWidth: 300)
        }
      }
    }
    .background(AppTheme.background)
  }
}

private struct HistoryListView: View {
  @ObservedObject var history: HistoryStore
  @Binding var selectedID: UUID?
  let hotkeyDisplay: String

  var body: some View {
    VStack(spacing: 0) {
      if history.entries.isEmpty {
        EmptyHistoryView(hotkeyDisplay: hotkeyDisplay)
      } else {
        List(history.entries, selection: $selectedID) { entry in
          HistoryRow(entry: entry)
            .tag(entry.id)
            .listRowSeparator(.hidden)
            .listRowBackground(
              ChamferedPlate(cut: 6)
                .fill(
                  selectedID == entry.id
                    ? AppTheme.raisedSurface
                    : Color.clear
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            )
            .contextMenu {
              Button("Copy Transcript") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(entry.transcript, forType: .string)
              }
              Button("Move Recording to Trash", role: .destructive) {
                history.remove(id: entry.id)
                if selectedID == entry.id {
                  selectedID = history.entries.first?.id
                }
              }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
    }
    .background(AppTheme.surface)
  }
}

private struct HistoryRow: View {
  let entry: HistoryEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(AppTheme.secondaryText)
        Text(entry.shortTargetName)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(AppTheme.faintText)
          .lineLimit(1)
        Spacer(minLength: 4)
        Image(systemName: entry.deliveryOutcome.symbolName)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(AppTheme.faintText)
      }

      Text(entry.transcript)
        .font(.system(size: 13))
        .foregroundStyle(AppTheme.primaryText)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 6)
    .contentShape(Rectangle())
  }
}

private struct EmptyHistoryView: View {
  let hotkeyDisplay: String

  var body: some View {
    ContentUnavailableView {
      Label {
        Text("Your words land here.")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(AppTheme.primaryText)
      } icon: {
        SpeechToCursorMark()
          .frame(width: 78, height: 42)
      }
    } description: {
      Text(
        "Press \(hotkeyDisplay), speak, then release. Space locks hands-free; press the shortcut again to finish."
      )
      .font(.system(size: 13))
      .foregroundStyle(AppTheme.secondaryText)
      .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(28)
  }
}

private struct HistoryDetailView: View {
  @ObservedObject var history: HistoryStore
  @Binding var selectedID: UUID?
  @ObservedObject var recording: RecordingCoordinator
  @StateObject private var playback = AudioPlaybackController()
  @State private var didJustCopy = false

  var body: some View {
    Group {
      if let entry = history.entry(id: selectedID) {
        detail(entry)
          .id(entry.id)
      } else {
        ContentUnavailableView(
          "Choose a recording",
          systemImage: "waveform",
          description: Text(
            "The transcript and original audio will appear here."
          )
        )
        .foregroundStyle(AppTheme.primaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(AppTheme.background)
    .onChange(of: selectedID) { _, newID in
      playback.stop()
      didJustCopy = false
      if let entry = history.entry(id: newID) {
        playback.load(history.audioURL(for: entry))
      }
    }
  }

  private func detail(_ entry: HistoryEntry) -> some View {
    let isReprocessing = recording.reprocessingID == entry.id

    return VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        Text(
          entry.createdAt.formatted(
            date: .abbreviated,
            time: .shortened
          )
        )
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(AppTheme.primaryText)
        .lineLimit(2)
        .minimumScaleFactor(0.85)
        Text(detailLine(for: entry))
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.secondaryText)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 24)
      .padding(.top, 20)
      .padding(.bottom, 14)

      VStack(alignment: .leading, spacing: 8) {
        Text("Original recording")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(AppTheme.secondaryText)
        PlaybackBar(
          playback: playback,
          duration: entry.duration
        )
      }
      .padding(.horizontal, 24)
      .onAppear {
        playback.load(history.audioURL(for: entry))
      }

      TextEditor(
        text: Binding(
          get: { history.entry(id: entry.id)?.transcript ?? "" },
          set: { history.updateTranscript(id: entry.id, transcript: $0) }
        )
      )
      .font(.system(size: 16, design: .serif))
      .lineSpacing(5)
      .foregroundStyle(AppTheme.primaryText)
      .scrollContentBackground(.hidden)
      .disabled(isReprocessing)
      .padding(18)
      .background(
        ChamferedPlate(cut: 10)
          .fill(AppTheme.surface)
          .overlay(
            ChamferedPlate(cut: 10)
              .fill(AppTheme.plateSheen)
          )
      )
      .padding(.horizontal, 24)
      .padding(.top, 12)
      .padding(.bottom, 24)
      .opacity(isReprocessing ? 0.65 : 1)
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          recording.copyTranscript(entry.transcript)
          didJustCopy = true
          Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            didJustCopy = false
          }
        } label: {
          Label(
            didJustCopy ? "Copied" : "Copy",
            systemImage: didJustCopy ? "checkmark" : "doc.on.doc"
          )
        }
        .disabled(isReprocessing)
        .help("Copy transcript")

        Button {
          Task {
            await recording.reprocessHistoryEntry(id: entry.id)
          }
        } label: {
          Label(
            isReprocessing ? "Reprocessing…" : "Reprocess",
            systemImage: "arrow.triangle.2.circlepath"
          )
        }
        .disabled(isReprocessing || recording.phase.isBusy)
        .help("Reprocess with current provider and writing guidance")

        Button(role: .destructive) {
          history.remove(id: entry.id)
          selectedID = history.entries.first?.id
        } label: {
          Label("Trash", systemImage: "trash")
        }
        .disabled(isReprocessing)
        .help("Move recording to Trash")
      }
    }
  }

  private func detailLine(for entry: HistoryEntry) -> String {
    [
      entry.shortTargetName,
      entry.deliveryOutcome.title,
    ]
    .joined(separator: " · ")
  }
}

private struct PlaybackBar: View {
  @ObservedObject var playback: AudioPlaybackController
  let duration: TimeInterval

  var body: some View {
    HStack(spacing: 13) {
      Button {
        playback.toggle()
      } label: {
        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(AppTheme.accent)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        playback.isPlaying ? "Pause recording" : "Play recording"
      )

      GeometryReader { proxy in
        let total = max(playback.duration, duration, 0.1)
        let fraction = min(1, max(0, playback.currentTime / total))
        ZStack(alignment: .leading) {
          Capsule()
            .fill(AppTheme.raisedSurface)
            .frame(height: 4)
          Capsule()
            .fill(AppTheme.accent)
            .frame(width: max(4, proxy.size.width * fraction), height: 4)
        }
        .frame(maxHeight: .infinity, alignment: .center)
      }
      .frame(height: 22)

      Text(formattedDuration)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(AppTheme.secondaryText)
        .frame(width: 44, alignment: .trailing)
    }
    .padding(.vertical, 6)
  }

  private var formattedDuration: String {
    let seconds = Int(playback.duration > 0 ? playback.duration : duration)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
