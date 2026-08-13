import XCTest

@testable import ListenToMe

final class OverlayLayoutTests: XCTestCase {
  func testWideAndTallAreDoubleTheStandardPlate() {
    let standard = OverlayLayout.compact.panelSize
    XCTAssertEqual(OverlayLayout.wide.panelSize.width, standard.width * 2)
    XCTAssertEqual(OverlayLayout.wide.panelSize.height, standard.height)
    XCTAssertEqual(OverlayLayout.tall.panelSize.width, standard.width)
    XCTAssertEqual(OverlayLayout.tall.panelSize.height, standard.height * 2)
  }
}
