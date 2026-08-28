import SwiftUI

struct HistoryWorkspaceView: View {
  @ObservedObject var history: HistoryStore
  @Binding var selectedID: UUID?
  @ObservedObject var recording: RecordingCoordinator
  let hotkeyDisplay: String
  let onImportAudio: () -> Void
  @State private var isDropTarget = false

  var body: some View {
    HSplitView {
      HistoryListView(
        history: history,
        selectedID: $selectedID,
        hotkeyDisplay: hotkeyDisplay,
        isImportingAudio: recording.isImportingAudio,
        canImportAudio: !recording.phase.isBusy
          && recording.reprocessingID == nil
          && !recording.isImportingAudio,
        importingID: recording.importingID,
        onImportAudio: onImportAudio
      )
      .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

      HistoryDetailView(
        history: history,
        selectedID: $selectedID,
        recording: recording
      )
      .frame(minWidth: 320)
    }
    .background(AppTheme.background)
    .overlay(
      Rectangle()
        .stroke(
          isDropTarget ? AppTheme.accent : Color.clear,
          lineWidth: 2
        )
        .allowsHitTesting(false)
    )
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first,
        !recording.phase.isBusy,
        !recording.isImportingAudio
      else { return false }
      Task { await recording.importAudio(at: url) }
      return true
    } isTargeted: {
      isDropTarget = $0
    }
  }
}

private struct HistoryListView: View {
  @ObservedObject var history: HistoryStore
  @Binding var selectedID: UUID?
  let hotkeyDisplay: String
  let isImportingAudio: Bool
  let canImportAudio: Bool
  let importingID: UUID?
  let onImportAudio: () -> Void
  @State private var query = ""

  private var visibleEntries: [HistoryEntry] {
    HistorySearch.matching(history.entries, query: query)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text("History")
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(AppTheme.primaryText)
        Text("\(visibleEntries.count)")
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundStyle(AppTheme.faintText)
        Spacer()
        Button(action: onImportAudio) {
          Label(
            isImportingAudio ? "Transcribing…" : "Transcribe Audio…",
            systemImage: isImportingAudio ? "ellipsis" : "waveform.badge.plus"
          )
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(!canImportAudio)
        .help(isImportingAudio ? "Transcribing audio" : "Transcribe audio file")
        .accessibilityLabel(
          isImportingAudio ? "Transcribing audio" : "Transcribe audio file"
        )
      }
      .padding(.horizontal, 18)
      .padding(.top, 20)
      .padding(.bottom, 10)

      if !history.entries.isEmpty {
        ThemedTextField(
          placeholder: "Search transcripts",
          text: $query
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .accessibilityLabel("Search transcripts")
      }

      if history.entries.isEmpty {
        EmptyHistoryView(
          hotkeyDisplay: hotkeyDisplay,
          isImportingAudio: isImportingAudio,
          canImportAudio: canImportAudio,
          onImportAudio: onImportAudio
        )
      } else if visibleEntries.isEmpty {
        Text("No matching transcripts")
          .font(.system(size: 13))
          .foregroundStyle(AppTheme.secondaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(28)
      } else {
        // ScrollView instead of List. System List selection draws a blue
        // rect that bleeds past our chamfered plates.
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(visibleEntries) { entry in
              let isSelected = selectedID == entry.id
              HistoryRow(
                entry: entry,
                isImporting: importingID == entry.id
              )
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  ChamferedPlate(cut: 7)
                    .fill(
                      isSelected
                        ? AppTheme.raisedSurface
                        : AppTheme.background.opacity(0.35)
                    )
                )
                .overlay(
                  ChamferedPlate(cut: 7)
                    .stroke(
                      isSelected
                        ? AppTheme.accent.opacity(0.55)
                        : AppTheme.edge.opacity(0.35),
                      lineWidth: isSelected ? 1.5 : 1
                    )
                )
                .contentShape(ChamferedPlate(cut: 7))
                .onTapGesture {
                  selectedID = entry.id
                }
                .contextMenu {
                  Button("Copy Transcript") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(entry.transcript, forType: .string)
                  }
                  .disabled(
                    entry.transcript.trimmingCharacters(
                      in: .whitespacesAndNewlines
                    ).isEmpty
                  )
                  Button("Move Recording to Trash", role: .destructive) {
                    history.remove(id: entry.id)
                    if selectedID == entry.id {
                      selectedID =
                        HistorySearch.matching(
                          history.entries,
                          query: query
                        ).first?.id
                    }
                  }
                  .disabled(importingID == entry.id)
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
          }
          .padding(.horizontal, 12)
          .padding(.bottom, 16)
        }
      }
    }
    .background(AppTheme.surface)
    .onChange(of: query) { _, _ in
      let visibleIDs = Set(visibleEntries.map(\.id))
      if let selectedID, visibleIDs.contains(selectedID) {
        return
      }
      selectedID = visibleEntries.first?.id
    }
  }
}

private struct HistoryRow: View {
  let entry: HistoryEntry
  let isImporting: Bool

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
        if isImporting {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: entry.deliveryOutcome.symbolName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppTheme.faintText)
        }
      }

      Text(isImporting ? "Transcribing audio…" : entry.previewText)
        .font(.system(size: 13))
        .foregroundStyle(
          entry.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            ? AppTheme.secondaryText
            : AppTheme.primaryText
        )
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct EmptyHistoryView: View {
  let hotkeyDisplay: String
  let isImportingAudio: Bool
  let canImportAudio: Bool
  let onImportAudio: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      SpeechToCursorMark()
        .frame(width: 78, height: 42)
      Text("Your words land here.")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(AppTheme.primaryText)
      Text("Press \(hotkeyDisplay) to dictate.")
        .font(.system(size: 13))
        .foregroundStyle(AppTheme.secondaryText)
        .multilineTextAlignment(.center)
      Button(isImportingAudio ? "Transcribing…" : "Transcribe Audio…") {
        onImportAudio()
      }
      .buttonStyle(RecordActionButtonStyle())
      .disabled(!canImportAudio)
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
        VStack(spacing: 12) {
          Text("Choose a recording")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
          Text("The transcript and original audio appear here.")
            .font(.system(size: 13))
            .foregroundStyle(AppTheme.secondaryText)
        }
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
    let isImporting = recording.importingID == entry.id
    let isProcessing = isReprocessing || isImporting

    return VStack(alignment: .leading, spacing: 0) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 18) {
          detailHeading(for: entry, isImporting: isImporting)
          Spacer(minLength: 12)
          detailActions(
            for: entry,
            isReprocessing: isReprocessing,
            isImporting: isImporting
          )
        }
        VStack(alignment: .leading, spacing: 14) {
          detailHeading(for: entry, isImporting: isImporting)
          detailActions(
            for: entry,
            isReprocessing: isReprocessing,
            isImporting: isImporting
          )
        }
      }
      .padding(.horizontal, 28)
      .padding(.top, 26)
      .padding(.bottom, 18)

      VStack(alignment: .leading, spacing: 8) {
        Text("Original recording")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(AppTheme.secondaryText)
        PlaybackBar(
          playback: playback,
          duration: entry.duration
        )
      }
      .padding(.horizontal, 28)
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
      .disabled(isProcessing)
      .padding(22)
      .background(
        ChamferedPlate(cut: 10)
          .fill(AppTheme.surface)
          .overlay(
            ChamferedPlate(cut: 10)
              .fill(AppTheme.plateSheen)
          )
      )
      .padding(.horizontal, 28)
      .padding(.top, 14)
      .padding(.bottom, 28)
      .opacity(isProcessing ? 0.65 : 1)
    }
  }

  private func detailHeading(
    for entry: HistoryEntry,
    isImporting: Bool
  ) -> some View {
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
      Text(detailLine(for: entry, isImporting: isImporting))
        .font(.system(size: 12))
        .foregroundStyle(AppTheme.secondaryText)
        .lineLimit(2)
    }
  }

  private func detailActions(
    for entry: HistoryEntry,
    isReprocessing: Bool,
    isImporting: Bool
  ) -> some View {
    let isProcessing = isReprocessing || isImporting

    return HStack(spacing: 10) {
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
      .buttonStyle(QuietButtonStyle())
      .disabled(
        isProcessing
          || entry.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
      )

      Button {
        Task {
          await recording.reprocessHistoryEntry(id: entry.id)
        }
      } label: {
        Label(
          isProcessing ? "Transcribing…" : "Reprocess",
          systemImage: "arrow.triangle.2.circlepath"
        )
      }
      .buttonStyle(QuietButtonStyle())
      .disabled(
        isProcessing
          || recording.isImportingAudio
          || recording.phase.isBusy
      )

      Button {
        history.remove(id: entry.id)
        selectedID = history.entries.first?.id
      } label: {
        Label("Trash", systemImage: "trash")
      }
      .buttonStyle(QuietButtonStyle(isDestructive: true))
      .disabled(isProcessing)
    }
  }

  private func detailLine(for entry: HistoryEntry, isImporting: Bool) -> String {
    [
      entry.shortTargetName,
      isImporting ? "Transcribing" : entry.deliveryOutcome.title,
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
