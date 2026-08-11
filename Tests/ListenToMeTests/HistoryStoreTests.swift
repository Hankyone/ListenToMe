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
}
