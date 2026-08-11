import SwiftUI

struct RootView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var recording: RecordingCoordinator
  /// Manual split — not NavigationSplitView — so the sidebar control stays put
  /// and section changes never reshuffle system toolbar items.
  @AppStorage("ListenToMe.showSidebar") private var showSidebar = true

  init(model: AppModel) {
    self.model = model
    recording = model.recording
  }

  var body: some View {
    HStack(spacing: 0) {
      if showSidebar {
        AppSidebarView(
          selection: $model.selectedSection,
          recording: recording,
          settings: model.settings
        )
        .frame(width: 220)
        .transition(.move(edge: .leading).combined(with: .opacity))
      }

      VStack(spacing: 0) {
        windowChrome
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(AppTheme.background)
      }
    }
    .animation(.easeOut(duration: 0.18), value: showSidebar)
    .preferredColorScheme(.dark)
    .tint(AppTheme.accent)
  }

  /// Fixed leading control. Never uses the system sidebar-toggle toolbar item,
  /// which jumps when detail toolbars appear/disappear.
  private var windowChrome: some View {
    HStack(spacing: 0) {
      Button {
        showSidebar.toggle()
      } label: {
        Image(systemName: "sidebar.left")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(AppTheme.secondaryText)
          .frame(width: 28, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(showSidebar ? "Hide Sidebar" : "Show Sidebar")
      .accessibilityLabel(showSidebar ? "Hide Sidebar" : "Show Sidebar")

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(AppTheme.background)
  }

  @ViewBuilder
  private var detail: some View {
    VStack(spacing: 0) {
      if let message = recording.errorMessage {
        inlineNotice(message)
      }

      Group {
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
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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
          .lineLimit(4)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
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
    .frame(maxHeight: 110)
    .background(AppTheme.raisedSurface)
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
