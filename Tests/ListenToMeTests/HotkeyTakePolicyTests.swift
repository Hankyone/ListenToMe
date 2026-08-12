import XCTest

@testable import ListenToMe

final class HotkeyTakePolicyTests: XCTestCase {
  func testIdlePressAlwaysStarts() {
    for pending in [false, true] {
      XCTAssertEqual(
        HotkeyTakePolicy.actionForPress(phase: .idle, pendingReleaseStop: pending),
        .start
      )
      XCTAssertEqual(
        HotkeyTakePolicy.actionForPress(phase: .failed, pendingReleaseStop: pending),
        .start
      )
      XCTAssertEqual(
        HotkeyTakePolicy.actionForPress(
          phase: .delivered(.pasted),
          pendingReleaseStop: pending
        ),
        .start
      )
    }
  }

  func testLivePressAlwaysStops() {
    XCTAssertEqual(
      HotkeyTakePolicy.actionForPress(phase: .recording, pendingReleaseStop: false),
      .stop
    )
    XCTAssertEqual(
      HotkeyTakePolicy.actionForPress(phase: .connecting, pendingReleaseStop: false),
      .stop
    )
  }

  func testReleaseBounceDoesNotStopALiveTake() {
    XCTAssertEqual(
      HotkeyTakePolicy.actionForPress(phase: .recording, pendingReleaseStop: true),
      .continueTake
    )
  }

  func testFinishingPressStartsANewTake() {
    XCTAssertEqual(
      HotkeyTakePolicy.actionForPress(phase: .finishing, pendingReleaseStop: false),
      .start
    )
    XCTAssertEqual(
      HotkeyTakePolicy.actionForPress(phase: .finishing, pendingReleaseStop: true),
      .start
    )
  }
}
