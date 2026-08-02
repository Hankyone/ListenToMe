import SwiftUI

struct RootView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var recording: RecordingCoordinator

  init(model: AppModel) {
    self.model = model
    recording = model.recording
  }

  var body: some View {
    NavigationSplitView {
      AppSidebarView(
        selection: $model.selectedSection,
        recording: recording,
        settings: model.settings
      )
      .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
    } detail: {
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
    }
    .frame(minWidth: 840, minHeight: 560)
    .preferredColorScheme(.dark)
    .tint(AppTheme.accent)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          Task {
            await model.toggleRecording()
          }
        } label: {
          HStack(spacing: 7) {
            Image(
              systemName: recording.phase.isRecording
                ? "stop.fill"
                : "record.circle"
            )
            Text(recording.phase.isRecording ? "Stop" : "Dictate")
          }
        }
        .buttonStyle(
          RecordActionButtonStyle(
            isRecording: recording.phase.isRecording
          )
        )
        .disabled(
          recording.phase == .connecting
            || recording.phase == .finishing
        )
        .accessibilityLabel(
          recording.phase.isRecording
            ? "Stop dictation"
            : "Start dictation"
        )
      }
    }
    .alert(
      "Dictation stopped",
      isPresented: Binding(
        get: { recording.errorMessage != nil },
        set: { isPresented in
          if !isPresented {
            recording.errorMessage = nil
          }
        }
      )
    ) {
      Button("Open Setup") {
        model.selectedSection = .settings
        recording.errorMessage = nil
      }
      Button("OK", role: .cancel) {
        recording.errorMessage = nil
      }
    } message: {
      Text(recording.errorMessage ?? "")
    }
  }

  @ViewBuilder
  private var detail: some View {
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

private struct AppSidebarView: View {
  @Binding var selection: AppSection
  @ObservedObject var recording: RecordingCoordinator
  @ObservedObject var settings: SettingsStore

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 13) {
        SpeechToCursorMark()
          .frame(width: 56, height: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text("ListenToMe")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
          Text(sidebarStatus)
            .font(.system(size: 11))
            .foregroundStyle(
              recording.phase.isRecording
                ? AppTheme.accent
                : AppTheme.secondaryText
            )
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.18), value: sidebarStatus)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 18)
      .padding(.top, 20)
      .padding(.bottom, 22)

      VStack(spacing: 3) {
        ForEach(AppSection.allCases) { section in
          SidebarRow(
            section: section,
            isSelected: selection == section
          ) {
            selection = section
          }
        }
      }
      .padding(.horizontal, 10)

      Spacer(minLength: 0)

      VStack(alignment: .leading, spacing: 5) {
        Text(settings.hotkey.display)
          .font(.system(size: 12, weight: .semibold, design: .monospaced))
          .foregroundStyle(AppTheme.secondaryText)
        Text("Start or stop from any app")
          .font(.system(size: 11))
          .foregroundStyle(AppTheme.faintText)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(18)
    }
    .background(AppTheme.sidebar)
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

private struct SidebarRow: View {
  let section: AppSection
  let isSelected: Bool
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: section.symbolName)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(
            isSelected ? AppTheme.accent : AppTheme.secondaryText
          )
          .frame(width: 18)
        Text(section.title)
          .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
          .foregroundStyle(
            isSelected ? AppTheme.primaryText : AppTheme.secondaryText
          )
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        ChamferedPlate(cut: 6)
          .fill(
            isSelected
              ? AppTheme.raisedSurface
              : (isHovering ? AppTheme.surface : Color.clear)
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovering = hovering
    }
    .animation(.easeOut(duration: 0.12), value: isHovering)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
