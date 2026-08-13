import AppKit
import Sparkle

/// Owns the Sparkle updater used for automatic and menu-driven update checks.
///
/// Menu items should target `checkForUpdates(_:)` on this object (not the
/// controller) so we can promote out of accessory mode before Sparkle shows
/// a window. On macOS 27 beta 4, a second `showWindow` while already checking
/// aborts in ViewBridge (`NSRemoteView containingWindowWillOrderOnScreen:`).
@MainActor
final class UpdateService: NSObject, NSMenuItemValidation {
  /// Created before the app finishes launching, matching Sparkle's
  /// programmatic `SPUStandardUpdaterController` examples.
  let updaterController: SPUStandardUpdaterController
  private let sparkleUI = SparkleUserDriverDelegate()
  private var didPromoteActivationPolicy = false

  override init() {
    updaterController = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: nil,
      userDriverDelegate: sparkleUI
    )
    super.init()
    sparkleUI.owner = self
    updaterController.startUpdater()
  }

  static var shortVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? ""
  }

  /// User-initiated check. No-ops if a session is already on screen so we
  /// never ask Sparkle to order its window forward a second time.
  @objc func checkForUpdates(_ sender: Any?) {
    guard updaterController.updater.canCheckForUpdates else { return }
    promoteForSparkleUI()
    updaterController.checkForUpdates(sender)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    menuItem.action == #selector(checkForUpdates(_:))
      ? updaterController.updater.canCheckForUpdates
      : true
  }

  fileprivate func promoteForSparkleUI() {
    if NSApp.activationPolicy() != .regular {
      NSApp.setActivationPolicy(.regular)
      didPromoteActivationPolicy = true
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  fileprivate func restoreAccessoryPolicy() {
    guard didPromoteActivationPolicy else { return }
    didPromoteActivationPolicy = false
    NSApp.setActivationPolicy(.accessory)
  }
}

/// Sparkle’s user-driver delegate is not MainActor-isolated in the SDK, but
/// callbacks always arrive on the main thread.
private final class SparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
  weak var owner: UpdateService?

  func standardUserDriverWillShowModalAlert() {
    MainActor.assumeIsolated {
      owner?.promoteForSparkleUI()
    }
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    MainActor.assumeIsolated {
      owner?.promoteForSparkleUI()
    }
  }

  func standardUserDriverWillFinishUpdateSession() {
    MainActor.assumeIsolated {
      owner?.restoreAccessoryPolicy()
    }
  }

  func standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool {
    false
  }
}
