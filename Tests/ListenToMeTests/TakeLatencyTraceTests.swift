import XCTest

@testable import ListenToMe

final class TakeLatencyTraceTests: XCTestCase {
  func testFirstMarkWins() {
    let trace = TakeLatencyTrace()
    trace.mark("hotkey")
    Thread.sleep(forTimeInterval: 0.02)
    trace.mark("hotkey")
    trace.mark("mic")
    let shot = trace.finish()
    XCTAssertEqual(shot.marks.map(\.name), ["hotkey", "mic"])
    XCTAssertGreaterThanOrEqual(shot.millisecondsByName["mic"] ?? -1, 0)
  }

  func testLineIncludesNotesAndMarks() {
    let trace = TakeLatencyTrace()
    trace.note("path", "warm")
    trace.mark("hotkey")
    let line = trace.finish().line
    XCTAssertTrue(line.contains("path=warm"))
    XCTAssertTrue(line.contains("hotkey="))
  }
}
