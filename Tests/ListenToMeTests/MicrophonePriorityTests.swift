import XCTest

@testable import ListenToMe

@MainActor
final class MicrophonePriorityTests: XCTestCase {
  func testPicksFirstAvailableDeviceInPriorityOrder() {
    let suite = "ListenToMe.MicPriority.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = SettingsStore(defaults: defaults)
    store.microphonePriorityUIDs = ["usb-mic", "built-in", ""]

    let available = [
      MicrophoneInput(id: "built-in", name: "MacBook Mic", deviceID: 2),
      MicrophoneInput.systemDefault(),
    ]

    XCTAssertEqual(store.preferredMicrophoneUID(from: available), "built-in")
  }

  func testFallsBackToSystemDefaultWhenNoneMatch() {
    let suite = "ListenToMe.MicPriority.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = SettingsStore(defaults: defaults)
    store.microphonePriorityUIDs = ["missing-a", "missing-b"]

    let available = [
      MicrophoneInput(id: "built-in", name: "MacBook Mic", deviceID: 2),
      MicrophoneInput.systemDefault(),
    ]

    XCTAssertEqual(
      store.preferredMicrophoneUID(from: available),
      MicrophoneInput.systemDefaultID
    )
  }
}
