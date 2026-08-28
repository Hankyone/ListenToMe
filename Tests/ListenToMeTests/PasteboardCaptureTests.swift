import AppKit
import XCTest

@testable import ListenToMe

final class PasteboardCaptureTests: XCTestCase {
  func testRestoresStringContentsOnAPrivatePasteboard() {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.clearContents()
    pasteboard.setString("secret-password", forType: .string)

    let capture = PasteboardCapture.snapshot(from: pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("dictated message", forType: .string)
    XCTAssertEqual(pasteboard.string(forType: .string), "dictated message")

    capture.restore(to: pasteboard)
    XCTAssertEqual(pasteboard.string(forType: .string), "secret-password")
  }

  func testRestoringEmptySnapshotClearsThePasteboard() {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.clearContents()
    let capture = PasteboardCapture.snapshot(from: pasteboard)

    pasteboard.setString("dictated message", forType: .string)
    capture.restore(to: pasteboard)
    XCTAssertNil(pasteboard.string(forType: .string))
  }
}
