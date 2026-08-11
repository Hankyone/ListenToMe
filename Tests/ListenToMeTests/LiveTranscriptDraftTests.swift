import XCTest

@testable import ListenToMe

@MainActor
final class LiveTranscriptDraftTests: XCTestCase {
  func testDeltasStayTentativeUntilStabilized() async {
    let draft = LiveTranscriptDraft(stabilizeDelayNanoseconds: 50_000_000)
    draft.applyDelta("Hello ")
    XCTAssertEqual(draft.snapshot.committed, "")
    XCTAssertEqual(draft.snapshot.tentative, "Hello ")

    try? await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(draft.snapshot.committed, "Hello ")
    XCTAssertEqual(draft.snapshot.tentative, "")
  }

  func testNewDeltasAfterStabilizeBecomeTentativeTail() async {
    let draft = LiveTranscriptDraft(stabilizeDelayNanoseconds: 40_000_000)
    draft.applyDelta("went to the store")
    try? await Task.sleep(nanoseconds: 70_000_000)
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
}
