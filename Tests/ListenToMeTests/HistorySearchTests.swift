import XCTest

@testable import ListenToMe

final class HistorySearchTests: XCTestCase {
  func testEmptyQueryReturnsAll() {
    let entries = [
      entry("Hello from Notes"),
      entry("Meeting notes about Toronto"),
    ]
    XCTAssertEqual(HistorySearch.matching(entries, query: "").map(\.transcript), [
      "Hello from Notes",
      "Meeting notes about Toronto",
    ])
    XCTAssertEqual(
      HistorySearch.matching(entries, query: "   ").map(\.id),
      entries.map(\.id)
    )
  }

  func testMatchesTranscriptCaseInsensitively() {
    let entries = [
      entry("Went to Toronto"),
      entry("Called Montreal"),
      entry("toronto again later"),
    ]
    let matches = HistorySearch.matching(entries, query: "Toronto")
    XCTAssertEqual(matches.map(\.transcript), [
      "Went to Toronto",
      "toronto again later",
    ])
  }

  func testIgnoresTargetNameAndEmptyTranscripts() {
    let notes = HistoryEntry(
      id: UUID(),
      createdAt: Date(),
      transcript: "",
      duration: 1,
      audioFileName: "a.caf",
      targetApplication: TargetApplication(
        name: "Toronto App",
        bundleIdentifier: nil,
        processIdentifier: 1
      ),
      deliveryOutcome: .audioSaved
    )
    let spoken = entry("Just some words")
    let matches = HistorySearch.matching([notes, spoken], query: "Toronto")
    XCTAssertTrue(matches.isEmpty)
  }
}

private func entry(_ transcript: String) -> HistoryEntry {
  HistoryEntry(
    id: UUID(),
    createdAt: Date(),
    transcript: transcript,
    duration: 1,
    audioFileName: "a.caf",
    targetApplication: nil,
    deliveryOutcome: .copiedNoTarget
  )
}
