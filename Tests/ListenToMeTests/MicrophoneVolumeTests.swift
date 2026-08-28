import XCTest

@testable import ListenToMe

final class MicrophoneVolumeTests: XCTestCase {
  func testAttachedInputsExposeWritableSystemVolume() throws {
    let devices = MicrophoneInputCatalog.listInputs().filter {
      !$0.isSystemDefault && !$0.name.contains("Aggregate")
    }
    try XCTSkipIf(
      devices.isEmpty,
      "No Core Audio input devices on this machine"
    )

    for device in devices {
      let snapshot = MicrophoneVolumeService.snapshot(forUID: device.id)
      XCTAssertNotNil(
        snapshot,
        "Expected System Settings-style input volume for \(device.name)"
      )
      XCTAssertEqual(
        snapshot?.isWritable,
        true,
        "Expected writable input volume for \(device.name)"
      )
      if let scalar = snapshot?.scalar {
        XCTAssertGreaterThanOrEqual(scalar, 0)
        XCTAssertLessThanOrEqual(scalar, 1)
      }
    }
  }
}
