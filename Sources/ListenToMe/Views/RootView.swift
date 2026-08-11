import SwiftUI

struct RootView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var recording: RecordingCoordinator

  init(model: AppModel) {
    self.model = model
    recording = model.recording
  }

  var body: some View {
    VStack(spacing: 0) {
      topNavigation

      if let message = recording.errorMessage {
        inlineNotice(message)
      }

      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(AppTheme.background)
    .preferredColorScheme(.dark)
    .tint(AppTheme.accent)
  }

  private var topNavigation: some View {
    ZStack {
      HStack(spacing: 4) {
        SpeechToCursorMark()
          .frame(width: 36, height: 20)
          .padding(.trailing, 2)

        ForEach(AppSection.allCases) { section in
          TopNavTab(
            section: section,
            isSelected: model.selectedSection == section
          ) {
            model.selectedSection = section
          }
        }
      }

      HStack {
        Spacer(minLength: 0)
        Text(statusCaption)
          .font(.system(size: 11, design: .rounded))
          .foregroundStyle(
            recording.phase.isRecording ? AppTheme.accent : AppTheme.faintText
          )
          .contentTransition(.opacity)
          .animation(.easeOut(duration: 0.18), value: statusCaption)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(AppTheme.sidebar)
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
        permissions: model.permissions,
        updates: model.updates
      )
    }
  }

  private var statusCaption: String {
    switch recording.phase {
    case .recording:
      recording.isHandsFreeLocked ? "Locked" : "Listening"
    case .connecting: "Connecting"
    case .finishing: "Finishing"
    case .delivered: "Delivered"
    default: model.settings.hotkey.display
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

private struct TopNavTab: View {
  let section: AppSection
  let isSelected: Bool
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: section.symbolName)
          .font(.system(size: 11, weight: .semibold))
        Text(section.title)
          .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
      }
      .foregroundStyle(
        isSelected ? AppTheme.primaryText : AppTheme.secondaryText
      )
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        ChamferedPlate(cut: 5)
          .fill(
            isSelected
              ? AppTheme.raisedSurface
              : (isHovering ? AppTheme.surface : Color.clear)
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
