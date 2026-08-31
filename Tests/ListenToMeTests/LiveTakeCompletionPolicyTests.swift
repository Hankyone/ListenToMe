import XCTest

@testable import ListenToMe

final class LiveTakeCompletionPolicyTests: XCTestCase {
  func testDoesNotPasteWhileRecording() {
    XCTAssertFalse(
      LiveTakeCompletionPolicy.shouldPasteNow(phase: .recording)
    )
  }

  func testPastesAfterTheUserStops() {
    XCTAssertTrue(
      LiveTakeCompletionPolicy.shouldPasteNow(phase: .finishing)
    )
  }

  func testIgnoresIdleAndDelivered() {
    XCTAssertFalse(LiveTakeCompletionPolicy.shouldPasteNow(phase: .idle))
    XCTAssertFalse(
      LiveTakeCompletionPolicy.shouldPasteNow(phase: .delivered(.pasted))
    )
  }
}
