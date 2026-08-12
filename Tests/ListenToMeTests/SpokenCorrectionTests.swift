import XCTest

@testable import ListenToMe

final class SpokenCorrectionTests: XCTestCase {
  func testMontrealCorrectionToToronto() {
    let spoken =
      "So, I wanted to plan a trip to Montreal, correction to Toronto, and then we'll see after that what happens."
    XCTAssertEqual(
      SpokenCorrection.apply(spoken),
      "So, I wanted to plan a trip to Toronto, and then we'll see after that what happens."
    )
  }

  func testCorrectionToWithoutCommaWhenPlaceIsCapitalized() {
    XCTAssertEqual(
      SpokenCorrection.apply(
        "I wanted to plan a trip to Montreal correction to Toronto"
      ),
      "I wanted to plan a trip to Toronto"
    )
  }

  func testIMeanReplacesLastWord() {
    XCTAssertEqual(
      SpokenCorrection.apply("Meet me at 5, I mean 6."),
      "Meet me at 6."
    )
  }

  func testScratchThatDropsLastSentence() {
    XCTAssertEqual(
      SpokenCorrection.apply("Hello there. This is wrong scratch that"),
      "Hello there."
    )
  }

  func testScratchThatDropsLastCommaClause() {
    XCTAssertEqual(
      SpokenCorrection.apply("Keep this, drop that scratch that"),
      "Keep this"
    )
  }

  func testStackedCues() {
    XCTAssertEqual(
      SpokenCorrection.apply(
        "a trip to Montreal, correction to Toronto, I mean Vancouver"
      ),
      "a trip to Vancouver"
    )
  }

  func testLeavesProseCorrectionAlone() {
    let prose = "The correction to the bill was mailed yesterday."
    XCTAssertEqual(SpokenCorrection.apply(prose), prose)
  }

  func testLeavesSentenceInitialErrorCorrectionAlone() {
    let prose = "Error correction to improve accuracy is important."
    XCTAssertEqual(SpokenCorrection.apply(prose), prose)
  }

  func testIncompleteCorrectionIsUnchanged() {
    let partial = "a trip to Montreal, correction"
    XCTAssertEqual(SpokenCorrection.apply(partial), partial)
  }

  func testSendToNameCorrection() {
    XCTAssertEqual(
      SpokenCorrection.apply("Send it to John, correction Jane"),
      "Send it to Jane"
    )
  }
}
