import AppKit
import Sparkle

/// Owns the Sparkle updater used for automatic and menu-driven update checks.
///
/// Menu items should target `updaterController` with
/// `checkForUpdates(_:)` so Sparkle can validate/enable the item via
/// `SPUUpdater.canCheckForUpdates` (see Sparkle programmatic setup docs).
@MainActor
final class UpdateService: NSObject {
  /// Created before the app finishes launching, matching Sparkle's
  /// programmatic `SPUStandardUpdaterController` examples.
  let updaterController: SPUStandardUpdaterController

  override init() {
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    super.init()
  }
}
