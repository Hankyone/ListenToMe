import XCTest

@testable import ListenToMe

final class DeliveryPolicyTests: XCTestCase {
  private let target = TargetApplication(
    name: "Notes",
    bundleIdentifier: "com.apple.Notes",
    processIdentifier: 42
  )

  func testPastesOnlyWhenTargetStillHasFocusAndPermissionExists() {
    XCTAssertEqual(
      DeliveryPolicy.outcome(
        target: target,
        frontmostProcessIdentifier: 42,
        hasAccessibilityPermission: true
      ),
      .pasted
    )
  }

  func testCopiesWhenFocusChanged() {
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
      DeliveryPolicy.outcome(
        target: target,
        frontmostProcessIdentifier: 42,
        hasAccessibilityPermission: false
      ),
      .copiedNoAccessibility
    )
  }

  func testCopiesWhenRecordingStartedInsideListenToMe() {
    XCTAssertEqual(
      DeliveryPolicy.outcome(
        target: nil,
        frontmostProcessIdentifier: 42,
        hasAccessibilityPermission: true
      ),
      .copiedNoTarget
    )
  }
}
