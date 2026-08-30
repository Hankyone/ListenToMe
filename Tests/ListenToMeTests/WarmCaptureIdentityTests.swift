import XCTest

@testable import ListenToMe

final class WarmCaptureIdentityTests: XCTestCase {
  func testReusesWhenUIDAndHALIdentityMatch() {
    XCTAssertTrue(
      WarmCaptureIdentity.canReuse(
        warmedUID: "usb-solocast",
        warmedDeviceID: 42,
        requestedUID: "usb-solocast",
        liveDeviceID: 42
      )
    )
  }

  func testRebuildsWhenUSBReplugChangesDeviceID() {
    XCTAssertFalse(
      WarmCaptureIdentity.canReuse(
        warmedUID: "usb-solocast",
        warmedDeviceID: 42,
        requestedUID: "usb-solocast",
        liveDeviceID: 99
      )
    )
  }

  func testRebuildsWhenPreferredDeviceChanges() {
    XCTAssertFalse(
      WarmCaptureIdentity.canReuse(
        warmedUID: "built-in",
        warmedDeviceID: 2,
        requestedUID: "usb-solocast",
        liveDeviceID: 42
      )
    )
  }

  func testRebuildsWhenLiveDeviceIsGone() {
    XCTAssertFalse(
      WarmCaptureIdentity.canReuse(
        warmedUID: "usb-solocast",
        warmedDeviceID: 42,
        requestedUID: "usb-solocast",
        liveDeviceID: nil
      )
    )
  }
}
