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
  private let accessibilityProvider = AccessibilityPermissionStatusProvider()
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
    accessibilityGranted = readAccessibilityTrusted()
  }

  /// Call while Setup is on screen. Menu-bar apps often never become key
  /// again after System Settings, so activation-only refresh is not enough.
  func startVisibilityMonitoring() {
    stopVisibilityMonitoring()
    refresh()
    visibilityPollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 750_000_000)
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

  /// Prefer the non-prompting options API; fall back to the simple check and
  /// PermissionFlow's provider (they can disagree briefly after a toggle).
  private func readAccessibilityTrusted() -> Bool {
    let options =
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
    if AXIsProcessTrustedWithOptions(options) {
      return true
    }
    if AXIsProcessTrusted() {
      return true
    }
    return accessibilityProvider.authorizationState() == .granted
  }

  private func observeAccessibilityAPIChanges() {
    // Fires when any app's Accessibility toggle changes. The trust bit is
    // briefly stale if read in the notification handler — recheck after delays.
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
      for delay in [0.2, 0.6, 1.2, 2.5, 5.0] as [TimeInterval] {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !Task.isCancelled else { return }
        self?.refresh()
        if self?.accessibilityGranted == true { return }
      }
    }
  }
}
