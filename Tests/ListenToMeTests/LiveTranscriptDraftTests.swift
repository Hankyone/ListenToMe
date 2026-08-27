import XCTest

@testable import ListenToMe

@MainActor
final class LiveTranscriptDraftTests: XCTestCase {
  func testDeltasStayTentativeUntilStabilized() async {
    let draft = LiveTranscriptDraft(stabilizeDelayNanoseconds: 50_000_000)
    draft.applyDelta("Hello ")
    XCTAssertEqual(draft.snapshot.committed, "")
    XCTAssertEqual(draft.snapshot.tentative, "Hello ")

    let stabilized = await waitUntil(timeoutNanoseconds: 1_000_000_000) {
      draft.snapshot.committed == "Hello " && draft.snapshot.tentative.isEmpty
    }
    XCTAssertTrue(stabilized, "Delta should commit after the quiet period")
  }

  func testNewDeltasAfterStabilizeBecomeTentativeTail() async {
    let draft = LiveTranscriptDraft(stabilizeDelayNanoseconds: 40_000_000)
    draft.applyDelta("went to the store")

    let stabilized = await waitUntil(timeoutNanoseconds: 1_000_000_000) {
      draft.snapshot.committed == "went to the store"
        && draft.snapshot.tentative.isEmpty
    }
    XCTAssertTrue(stabilized, "Prefix should commit before the next delta")

    draft.applyDelta(" correction the park")

    XCTAssertEqual(draft.snapshot.committed, "went to the store")
    XCTAssertEqual(draft.snapshot.tentative, " correction the park")
    XCTAssertEqual(
      draft.snapshot.display,
      "went to the store correction the park"
    )
  }

  func testCompletedReplacesDraftAsCommitted() {
    let draft = LiveTranscriptDraft(stabilizeDelayNanoseconds: 1_000_000_000)
    draft.applyDelta("went to the store correction the park")
    draft.applyCompleted("went to the park")

    XCTAssertEqual(draft.snapshot.committed, "went to the park")
    XCTAssertEqual(draft.snapshot.tentative, "")
  }

  func testInterimReplacesGeminiHypothesis() {
    let draft = LiveTranscriptDraft(stabilizeDelayNanoseconds: 1_000_000_000)
    draft.applyInterim("Use Chronicle")
    draft.applyInterim("Use Chronicle for this")

    XCTAssertEqual(draft.snapshot.display, "Use Chronicle for this")
    XCTAssertEqual(draft.snapshot.committed, "")
  }

  private func waitUntil(
    timeoutNanoseconds: UInt64,
    pollNanoseconds: UInt64 = 5_000_000,
    _ condition: () -> Bool
  ) async -> Bool {
    let started = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - started < timeoutNanoseconds {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
    return condition()
  }
}
