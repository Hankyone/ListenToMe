import SwiftUI

struct RootView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var recording: RecordingCoordinator
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  init(model: AppModel) {
    self.model = model
    recording = model.recording
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      AppSidebarView(
        selection: sectionSelection,
        recording: recording,
        settings: model.settings
      )
      .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    } detail: {
      NavigationStack {
        detailBody
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(AppTheme.background)
          .navigationTitle(model.selectedSection.title)
          .navigationSubtitle(detailSubtitle)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .preferredColorScheme(.dark)
    .tint(AppTheme.accent)
  }

  private var sectionSelection: Binding<AppSection?> {
    Binding(
      get: { model.selectedSection },
      set: { model.selectedSection = $0 ?? .history }
    )
  }

  private var detailSubtitle: String {
    switch model.selectedSection {
    case .history:
      let count = model.history.entries.count
      return count == 1 ? "1 recording" : "\(count) recordings"
    case .vocabulary:
      let count = model.settings.vocabulary.count
      return count == 1 ? "1 custom word" : "\(count) custom words"
    case .settings:
      return model.settings.selectedEngineIsReady ? "Ready" : "Needs a key"
    }
  }

  @ViewBuilder
  private var detailBody: some View {
    VStack(spacing: 0) {
      if let message = recording.errorMessage {
        inlineNotice(message)
      }

      switch model.selectedSection {
      case .history:
        HistoryWorkspaceView(
          history: model.history,
          selectedID: $model.selectedHistoryID,
          recording: model.recording,
          hotkeyDisplay: model.settings.hotkey.display
        )
      case .vocabulary:
        VocabularyView(settings: model.settings)
      case .settings:
        SettingsContentView(
          settings: model.settings,
          permissions: model.permissions
        )
      }
    }
  }

  private func inlineNotice(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(AppTheme.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text("Dictation stopped")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(AppTheme.primaryText)
        Text(message)
          .font(.system(size: 12))
          .foregroundStyle(AppTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button("Open Setup") {
        model.selectedSection = .settings
        recording.errorMessage = nil
      }
      .buttonStyle(QuietButtonStyle())
      Button {
        recording.errorMessage = nil
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(AppTheme.faintText)
      }
      .buttonStyle(.plain)
      .help("Dismiss")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(AppTheme.raisedSurface)
  }
}

private struct AppSidebarView: View {
  @Binding var selection: AppSection?
  @ObservedObject var recording: RecordingCoordinator
  @ObservedObject var settings: SettingsStore

  var body: some View {
    List(selection: $selection) {
      Section {
        ForEach(AppSection.allCases) { section in
          Label(section.title, systemImage: section.symbolName)
            .tag(section)
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(AppTheme.sidebar)
    .safeAreaInset(edge: .top, spacing: 0) {
      HStack(spacing: 12) {
        SpeechToCursorMark()
          .frame(width: 44, height: 26)
        VStack(alignment: .leading, spacing: 2) {
          Text("ListenToMe")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
            .lineLimit(1)
          Text(sidebarStatus)
            .font(.system(size: 11))
            .foregroundStyle(
              recording.phase.isRecording
                ? AppTheme.accent
                : AppTheme.secondaryText
            )
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.18), value: sidebarStatus)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .padding(.top, 14)
      .padding(.bottom, 10)
      .background(AppTheme.sidebar)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(settings.hotkey.display)
          .font(.system(size: 12, weight: .semibold, design: .monospaced))
          .foregroundStyle(AppTheme.secondaryText)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Text("Start or stop from any app")
          .font(.system(size: 11))
          .foregroundStyle(AppTheme.faintText)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(AppTheme.sidebar)
    }
  }

  private var sidebarStatus: String {
    switch recording.phase {
    case .recording: "Listening"
    case .connecting: "Connecting"
    case .finishing: "Finishing"
    case .delivered: "Delivered"
    default: "Ready for dictation"
    }
  }
}
