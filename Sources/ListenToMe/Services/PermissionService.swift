import AppKit
import ApplicationServices
import Foundation
import PermissionFlow

/// Thin observable wrapper around PermissionFlow status providers so the
/// rest of the app can read mic/accessibility state without owning UI.
@MainActor
final class PermissionService: ObservableObject {
  @Published private(set) var microphoneGranted = false
  @Published private(set) var accessibilityGranted = false

  private let microphoneProvider = MicrophonePermissionStatusProvider()
  private var accessibilityChangeObserver: NSObjectProtocol?
  private var visibilityPollTask: Task<Void, Never>?
  private var pendingAccessibilityRechecks: Task<Void, Never>?

  init() {
    refresh()
    observeAccessibilityAPIChanges()
  }

  deinit {
    if let accessibilityChangeObserver {
      DistributedNotificationCenter.default()
        .removeObserver(accessibilityChangeObserver)
    }
  }

  func refresh() {
    microphoneGranted = microphoneProvider.authorizationState() == .granted
    // Read via options API (prompt off). Immediate reads right after the
    // System Settings toggle can be stale — callers delay/poll as needed.
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false]
    accessibilityGranted = AXIsProcessTrustedWithOptions(options)
  }

  /// Call while Setup is on screen. Menu-bar apps often never become key
  /// again after System Settings, so activation-only refresh is not enough.
  func startVisibilityMonitoring() {
    stopVisibilityMonitoring()
    refresh()
    visibilityPollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        self?.refresh()
      }
    }
  }

  func stopVisibilityMonitoring() {
    visibilityPollTask?.cancel()
    visibilityPollTask = nil
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

  private func observeAccessibilityAPIChanges() {
    // Fires when any app's Accessibility toggle changes. The trust bit is
    // briefly stale if read in the notification handler — recheck after a delay.
    accessibilityChangeObserver = DistributedNotificationCenter.default()
      .addObserver(
        forName: Notification.Name("com.apple.accessibility.api"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.scheduleAccessibilityRechecks()
        }
      }
  }

  private func scheduleAccessibilityRechecks() {
    pendingAccessibilityRechecks?.cancel()
    pendingAccessibilityRechecks = Task { [weak self] in
      // Empirically needs both a short delay and a follow-up check.
      try? await Task.sleep(nanoseconds: 150_000_000)
      self?.refresh()
      try? await Task.sleep(nanoseconds: 500_000_000)
      self?.refresh()
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      self?.refresh()
    }
  }
}
