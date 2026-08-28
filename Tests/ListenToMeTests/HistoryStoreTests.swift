import Foundation
import XCTest

@testable import ListenToMe

@MainActor
final class HistoryStoreTests: XCTestCase {
  func testHistorySurvivesReload() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ListenToMeTests-\(UUID().uuidString)")
    defer {
      _ = try? FileManager.default.trashItem(
        at: root,
        resultingItemURL: nil
      )
    }

    let store = HistoryStore(rootURL: root)
    let entry = HistoryEntry(
      id: UUID(),
      createdAt: Date(),
      transcript: "A saved transcript.",
      duration: 2.4,
      audioFileName: "recording.caf",
      targetApplication: nil,
      deliveryOutcome: .copiedNoTarget
    )
    store.add(entry)

    let reloaded = HistoryStore(rootURL: root)
    XCTAssertEqual(reloaded.entries.count, 1)
    XCTAssertEqual(reloaded.entries.first?.transcript, "A saved transcript.")
  }

  func testTranscriptEditsPersist() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ListenToMeTests-\(UUID().uuidString)")
    defer {
      _ = try? FileManager.default.trashItem(
        at: root,
        resultingItemURL: nil
      )
    }

    let store = HistoryStore(rootURL: root)
    let entry = HistoryEntry(
      id: UUID(),
      createdAt: Date(),
      transcript: "Cloud made this.",
      duration: 1,
      audioFileName: "recording.caf",
      targetApplication: nil,
      deliveryOutcome: .copiedNoTarget
    )
    store.add(entry)
    store.updateTranscript(id: entry.id, transcript: "Claude made this.")

    let reloaded = HistoryStore(rootURL: root)
    XCTAssertEqual(reloaded.entries.first?.transcript, "Claude made this.")
  }

  func testCompletingImportPersistsTranscriptAndOutcome() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ListenToMeTests-\(UUID().uuidString)")
    defer {
      _ = try? FileManager.default.trashItem(
        at: root,
        resultingItemURL: nil
      )
    }

    let store = HistoryStore(rootURL: root)
    let entry = HistoryEntry(
      id: UUID(),
      createdAt: Date(),
      transcript: "",
      duration: 8,
      audioFileName: "imported.m4a",
      targetApplication: nil,
      sourceName: "meeting.wav",
      deliveryOutcome: .audioSaved
    )
    store.add(entry)
    store.completeImport(id: entry.id, transcript: "Imported words.")

    let reloaded = HistoryStore(rootURL: root)
    XCTAssertEqual(reloaded.entries.first?.transcript, "Imported words.")
    XCTAssertEqual(reloaded.entries.first?.deliveryOutcome, .imported)
    XCTAssertEqual(reloaded.entries.first?.shortTargetName, "meeting.wav")
  }

  func testPurgesEntriesOlderThanRetention() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ListenToMeTests-\(UUID().uuidString)")
    defer {
      _ = try? FileManager.default.trashItem(
        at: root,
        resultingItemURL: nil
      )
    }

    let store = HistoryStore(rootURL: root)
    let now = Date()
    let old = HistoryEntry(
      id: UUID(),
      createdAt: now.addingTimeInterval(-40 * 24 * 60 * 60),
      transcript: "Old take.",
      duration: 1,
      audioFileName: "old.caf",
      targetApplication: nil,
      deliveryOutcome: .copiedNoTarget
    )
    let fresh = HistoryEntry(
      id: UUID(),
      createdAt: now,
      transcript: "Fresh take.",
      duration: 1,
      audioFileName: "fresh.caf",
      targetApplication: nil,
      deliveryOutcome: .copiedNoTarget
    )
    store.add(old)
    store.add(fresh)
    XCTAssertEqual(store.purgeExpired(olderThanDays: 30, now: now), 1)
    XCTAssertEqual(store.entries.count, 1)
    XCTAssertEqual(store.entries.first?.transcript, "Fresh take.")
  }

  func testHasPreservableAudioIgnoresTinyFiles() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ListenToMeTests-\(UUID().uuidString)")
    defer {
      _ = try? FileManager.default.trashItem(
        at: root,
        resultingItemURL: nil
      )
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let tiny = root.appendingPathComponent("tiny.caf")
    try Data(repeating: 0, count: 128).write(to: tiny)
    XCTAssertFalse(HistoryStore.hasPreservableAudio(at: tiny))

    let real = root.appendingPathComponent("real.caf")
    try Data(repeating: 1, count: 8_192).write(to: real)
    XCTAssertTrue(HistoryStore.hasPreservableAudio(at: real))
    XCTAssertFalse(
      HistoryStore.hasPreservableAudio(
        at: root.appendingPathComponent("missing.caf")
      )
    )
  }

  func testAudioSavedOutcomeSurvivesReload() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ListenToMeTests-\(UUID().uuidString)")
    defer {
      _ = try? FileManager.default.trashItem(
        at: root,
        resultingItemURL: nil
      )
    }

    let store = HistoryStore(rootURL: root)
    let entry = HistoryEntry(
      id: UUID(),
      createdAt: Date(),
      transcript: "",
      duration: 12,
      audioFileName: "kept.caf",
      targetApplication: TargetApplication(
        name: "Terminal",
        bundleIdentifier: "com.apple.Terminal",
        processIdentifier: 99
      ),
      deliveryOutcome: .audioSaved
    )
    store.add(entry)

    let reloaded = HistoryStore(rootURL: root)
    XCTAssertEqual(reloaded.entries.first?.deliveryOutcome, .audioSaved)
    XCTAssertEqual(reloaded.entries.first?.transcript, "")
    XCTAssertTrue(
      reloaded.entries.first?.previewText.localizedCaseInsensitiveContains("audio saved")
        == true
    )
  }
}
