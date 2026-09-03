import XCTest

@testable import ListenToMe

@MainActor
final class ProviderSettingsTests: XCTestCase {
  func testStoresProviderSelectionAndKeysIndependently() throws {
    let suite = "ListenToMeTests.ProviderSettings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("listentome-provider-tests-\(UUID().uuidString)")
    defer {
      defaults.removePersistentDomain(forName: suite)
      if FileManager.default.fileExists(atPath: root.path) {
        _ = try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
      }
    }

    let store = SettingsStore(
      defaults: defaults,
      apiKeys: APIKeyStore(rootURL: root)
    )
    try store.saveAPIKey("open-key", for: .openAI)
    try store.saveAPIKey("gemini-key", for: .gemini)
    store.selectedProvider = .gemini

    XCTAssertTrue(store.hasOpenAIAPIKey)
    XCTAssertTrue(store.hasGeminiAPIKey)
    XCTAssertEqual(try store.loadAPIKey(for: .openAI), "open-key")
    XCTAssertEqual(try store.loadAPIKey(for: .gemini), "gemini-key")

    let reloaded = SettingsStore(
      defaults: defaults,
      apiKeys: APIKeyStore(rootURL: root)
    )
    XCTAssertEqual(reloaded.selectedProvider, .gemini)
    XCTAssertTrue(reloaded.selectedEngineIsReady)
  }

  func testPauseMediaWhileListeningDefaultsOnAndPersists() throws {
    let suite = "ListenToMeTests.ProviderSettings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("listentome-provider-tests-\(UUID().uuidString)")
    defer {
      defaults.removePersistentDomain(forName: suite)
      if FileManager.default.fileExists(atPath: root.path) {
        _ = try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
      }
    }

    let store = SettingsStore(
      defaults: defaults,
      apiKeys: APIKeyStore(rootURL: root)
    )
    XCTAssertTrue(store.pauseMediaWhileListening)

    store.pauseMediaWhileListening = false
    let reloaded = SettingsStore(
      defaults: defaults,
      apiKeys: APIKeyStore(rootURL: root)
    )
    XCTAssertFalse(reloaded.pauseMediaWhileListening)
  }
}
