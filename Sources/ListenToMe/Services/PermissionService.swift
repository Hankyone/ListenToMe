import Foundation
import PermissionFlow

/// Thin observable wrapper around PermissionFlow status providers so the
/// rest of the app can read mic/accessibility state without owning UI.
@MainActor
final class PermissionService: ObservableObject {
  @Published private(set) var microphoneGranted = false
  @Published private(set) var accessibilityGranted = false

  private let microphoneProvider = MicrophonePermissionStatusProvider()
  private let accessibilityProvider = AccessibilityPermissionStatusProvider()

  init() {
    refresh()
  }

  func refresh() {
    microphoneGranted = microphoneProvider.authorizationState() == .granted
    accessibilityGranted = accessibilityProvider.authorizationState() == .granted
  }

  func requestMicrophone() async -> Bool {
    await withCheckedContinuation { continuation in
      microphoneProvider.requestAuthorization { [weak self] state in
        Task { @MainActor in
          self?.refresh()
          continuation.resume(returning: state == .granted)
        }
      }
    }
  }
}
