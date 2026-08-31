import XCTest

@testable import ListenToMe

final class FieldAwareFormattingTests: XCTestCase {
  func testContinuesMidSentenceWithConservativeLowercasing() {
    XCTAssertEqual(
      formatted("The next part.", before: "This is", mode: .prose),
      " the next part."
    )
    XCTAssertEqual(
      formatted("But it continues.", before: "Earlier, ", mode: .prose),
      "but it continues."
    )
  }

  func testKeepsCapitalizationAfterSentenceAndParagraphBoundaries() {
    XCTAssertEqual(
      formatted("The next sentence.", before: "Earlier.", mode: .prose),
      " The next sentence."
    )
    XCTAssertEqual(
      formatted("The new paragraph.", before: "Earlier.\n", mode: .prose),
      "The new paragraph."
    )
    XCTAssertEqual(
      formatted("The next sentence.", before: "Earlier.”", mode: .prose),
      " The next sentence."
    )
  }

  func testKeepsNamesAcronymsAndProtectedVocabulary() {
    XCTAssertEqual(
      formatted("OpenAI works.", before: "and", mode: .prose),
      " OpenAI works."
    )
    XCTAssertEqual(
      formatted("I agree.", before: "and", mode: .prose),
      " I agree."
    )
    XCTAssertEqual(
      formatted("The Verge reported it.", before: "and", mode: .prose),
      " The Verge reported it."
    )
    XCTAssertEqual(
      formatted(
        "The Hague office.",
        before: "visit",
        mode: .prose,
        protectedTerms: ["The Hague"]
      ),
      " The Hague office."
    )
  }

  func testSearchAndTitleModesRemoveTerminalSentencePunctuation() {
    XCTAssertEqual(
      formatted("best coffee nearby?", before: "", mode: .searchCommand),
      "best coffee nearby"
    )
    XCTAssertEqual(
      formatted("Project Atlas.", before: "", mode: .nameTitle),
      "Project Atlas"
    )
    XCTAssertEqual(
      formatted("Google.com.", before: "", mode: .searchCommand),
      "Google.com"
    )
  }

  func testCodeModeLeavesTranscriptUntouched() {
    XCTAssertEqual(
      formatted("git status.", before: ">", mode: .codeTerminal),
      "git status."
    )
  }

  func testAutomaticClassifierUsesOnlyHighConfidenceMetadata() {
    XCTAssertEqual(
      FieldFormattingClassifier.automaticMode(
        for: descriptor(title: "Address and search bar")
      ),
      .searchCommand
    )
    XCTAssertEqual(
      FieldFormattingClassifier.automaticMode(
        for: descriptor(title: "Rename tab")
      ),
      .nameTitle
    )
    XCTAssertEqual(
      FieldFormattingClassifier.automaticMode(
        for: descriptor(
          app: "Ghostty",
          bundle: "com.mitchellh.ghostty",
          title: nil
        )
      ),
      .codeTerminal
    )
    XCTAssertEqual(
      FieldFormattingClassifier.automaticMode(
        for: descriptor(title: "Message")
      ),
      .prose
    )
    XCTAssertEqual(
      FieldFormattingClassifier.automaticMode(
        for: descriptor(title: "Research notes")
      ),
      .prose
    )
  }

  private func formatted(
    _ text: String,
    before: String,
    mode: FieldFormattingMode,
    protectedTerms: [String] = []
  ) -> String {
    FieldAwareTextFormatter.formatted(
      text,
      for: TextInsertionContext(textBeforeSelection: before),
      mode: mode,
      protectedTerms: protectedTerms
    )
  }

  private func descriptor(
    app: String = "Safari",
    bundle: String? = "com.apple.Safari",
    title: String?
  ) -> FocusedTextFieldDescriptor {
    FocusedTextFieldDescriptor(
      applicationName: app,
      bundleIdentifier: bundle,
      role: "AXTextField",
      subrole: nil,
      identifier: nil,
      title: title,
      accessibilityDescription: nil,
      help: nil,
      placeholder: nil
    )
  }
}

@MainActor
final class FieldFormattingSettingsTests: XCTestCase {
  func testPersistsAndClearsPerFieldOverride() throws {
    let suite = "ListenToMeTests.FieldFormatting.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("listentome-field-tests-\(UUID().uuidString)")
    defer {
      defaults.removePersistentDomain(forName: suite)
      if FileManager.default.fileExists(atPath: root.path) {
        _ = try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
      }
    }

    let field = FocusedTextFieldDescriptor(
      applicationName: "Safari",
      bundleIdentifier: "com.apple.Safari",
      role: "AXTextField",
      subrole: nil,
      identifier: "search-field",
      title: "Search",
      accessibilityDescription: nil,
      help: nil,
      placeholder: nil
    )
    let store = SettingsStore(
      defaults: defaults,
      apiKeys: APIKeyStore(rootURL: root)
    )
    store.setFieldFormattingMode(.nameTitle, for: field)

    let reloaded = SettingsStore(
      defaults: defaults,
      apiKeys: APIKeyStore(rootURL: root)
    )
    XCTAssertEqual(reloaded.fieldFormattingMode(for: field), .nameTitle)

    reloaded.setFieldFormattingMode(.automatic, for: field)
    XCTAssertEqual(reloaded.fieldFormattingMode(for: field), .automatic)
  }
}
