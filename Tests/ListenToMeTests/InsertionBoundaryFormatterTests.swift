import XCTest

@testable import ListenToMe

final class InsertionBoundaryFormatterTests: XCTestCase {
  func testAddsSpaceAfterSentencePunctuation() {
    XCTAssertEqual(
      formatted("This starts a new sentence.", before: "."),
      " This starts a new sentence."
    )
    XCTAssertEqual(formatted("Really", before: "?"), " Really")
    XCTAssertEqual(formatted("Yes", before: "!"), " Yes")
  }

  func testAddsSpaceAfterClausePunctuation() {
    XCTAssertEqual(formatted("then continue", before: ","), " then continue")
    XCTAssertEqual(formatted("the details", before: ":"), " the details")
    XCTAssertEqual(formatted("however", before: ";"), " however")
  }

  func testDoesNotDuplicateExistingWhitespace() {
    XCTAssertEqual(formatted("Continue", before: " "), "Continue")
    XCTAssertEqual(formatted("Continue", before: "\n"), "Continue")
    XCTAssertEqual(formatted(" Continue", before: "."), " Continue")
  }

  func testAddsBoundaryBetweenAdjacentWords() {
    XCTAssertEqual(formatted("world", before: "o"), " world")
    XCTAssertEqual(formatted("beautiful", before: "o", after: "w"), " beautiful ")
  }

  func testKeepsCharactersThatShouldRemainAttached() {
    XCTAssertEqual(formatted("example.com", before: "/"), "example.com")
    XCTAssertEqual(formatted("name", before: "@"), "name")
    XCTAssertEqual(formatted("word", before: "("), "word")
    XCTAssertEqual(formatted(".", before: "d"), ".")
  }

  func testAddsOrSuppressesTrailingBoundaryForFollowingText() {
    XCTAssertEqual(formatted("replacement", after: "w"), "replacement ")
    XCTAssertEqual(formatted("replacement", after: "."), "replacement")
    XCTAssertEqual(formatted("replacement ", after: "w"), "replacement ")
  }

  func testLeavesTextUnchangedWithoutContext() {
    XCTAssertEqual(formatted("Standalone"), "Standalone")
    XCTAssertEqual(formatted(""), "")
  }

  private func formatted(
    _ text: String,
    before: Character? = nil,
    after: Character? = nil
  ) -> String {
    InsertionBoundaryFormatter.formatted(
      text,
      for: TextInsertionContext(
        characterBeforeSelection: before,
        characterAfterSelection: after
      )
    )
  }
}
