import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
  @Published var selectedSection: AppSection
  @Published var selectedHistoryID: UUID?

  let settings: SettingsStore
  let history: HistoryStore
  let permissions: PermissionService
  let recording: RecordingCoordinator
  let updates: UpdateService
  var onShowMainWindow: (() -> Void)?

  init(
    settings: SettingsStore? = nil,
    history: HistoryStore? = nil,
    permissions: PermissionService? = nil,
    updates: UpdateService? = nil
  ) {
    let resolvedSettings = settings ?? SettingsStore()
    let resolvedHistory = history ?? HistoryStore()
    let resolvedPermissions = permissions ?? PermissionService()

    self.settings = resolvedSettings
    self.history = resolvedHistory
    self.permissions = resolvedPermissions
    self.updates = updates ?? UpdateService()
    recording = RecordingCoordinator(
      settings: resolvedSettings,
      history: resolvedHistory,
      permissions: resolvedPermissions
    )

    selectedSection =
      resolvedSettings.selectedEngineIsReady ? .history : .settings
    selectedHistoryID = resolvedHistory.entries.first?.id

    recording.onHistoryEntryCreated = { [weak self] id in
      self?.selectedHistoryID = id
    }
  }

  func toggleRecording() async {
    await recording.toggle()
  }

  func showMainWindow(section: AppSection? = nil) {
    if let section {
      selectedSection = section
    }
    onShowMainWindow?()
  }
}
