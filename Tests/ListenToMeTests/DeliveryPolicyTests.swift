import XCTest

@testable import ListenToMe

final class DeliveryPolicyTests: XCTestCase {
  private let target = TargetApplication(
    name: "Notes",
    bundleIdentifier: "com.apple.Notes",
    processIdentifier: 42
  )

  func testCanAttemptPasteWhenTargetAndAccessibilityExist() {
    XCTAssertEqual(
      DeliveryPolicy.canAttemptPaste(
        target: target,
        hasAccessibilityPermission: true
      ),
      .pasted
    )
  }

  func testCanAttemptPasteIgnoresCurrentFrontmost() {
    // Finishing a recording often leaves another app frontmost briefly;
    // that must not block an attempt after we reactivate the target.
    XCTAssertEqual(
      DeliveryPolicy.canAttemptPaste(
        target: target,
        hasAccessibilityPermission: true
      ),
      .pasted
    )
  }

  func testOutcomeRequiresFocusMatch() {
    XCTAssertEqual(
      DeliveryPolicy.outcome(
        target: target,
        frontmostProcessIdentifier: 42,
        hasAccessibilityPermission: true
      ),
      .pasted
    )
    XCTAssertEqual(
      DeliveryPolicy.outcome(
        target: target,
        frontmostProcessIdentifier: 77,
        hasAccessibilityPermission: true
      ),
      .copiedFocusChanged
    )
  }

  func testCopiesWhenAccessibilityPermissionIsMissing() {
    XCTAssertEqual(
      DeliveryPolicy.canAttemptPaste(
        target: target,
        hasAccessibilityPermission: false
      ),
      .copiedNoAccessibility
    )
  }

  func testCopiesWhenRecordingStartedInsideListenToMe() {
    XCTAssertEqual(
      DeliveryPolicy.canAttemptPaste(
        target: nil,
        hasAccessibilityPermission: true
      ),
      .copiedNoTarget
    )
  }
}
