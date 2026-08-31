import Foundation

enum FieldFormattingMode: String, Codable, CaseIterable, Sendable {
  case automatic
  case prose
  case searchCommand
  case nameTitle
  case codeTerminal

  var title: String {
    switch self {
    case .automatic: "Auto"
    case .prose: "Prose"
    case .searchCommand: "Search or Command"
    case .nameTitle: "Name or Title"
    case .codeTerminal: "Code or Terminal"
    }
  }

  var compactTitle: String {
    switch self {
    case .automatic: "Auto"
    case .prose: "Prose"
    case .searchCommand: "Search"
    case .nameTitle: "Name"
    case .codeTerminal: "Code"
    }
  }
}

struct FocusedTextFieldDescriptor: Equatable, Sendable {
  let applicationName: String
  let bundleIdentifier: String?
  let role: String?
  let subrole: String?
  let identifier: String?
  let title: String?
  let accessibilityDescription: String?
  let help: String?
  let placeholder: String?

  var persistenceKey: String {
    let app = normalized(bundleIdentifier ?? applicationName)
    let stableIdentifier = normalized(identifier)
    if !stableIdentifier.isEmpty {
      return [app, "id", stableIdentifier].joined(separator: "\u{1F}")
    }

    return [
      app,
      normalized(role),
      normalized(subrole),
      normalized(title),
      normalized(accessibilityDescription),
      normalized(help),
      normalized(placeholder),
    ].joined(separator: "\u{1F}")
  }

  var menuContextTitle: String {
    let fieldName =
      firstMeaningfulLabel
      ?? FieldFormattingClassifier.automaticMode(
        for: self
      ).title
    return Self.truncated("For \(applicationName): \(fieldName)", limit: 30)
  }

  fileprivate var accessibilityText: String {
    [
      role,
      subrole,
      identifier,
      title,
      accessibilityDescription,
      help,
      placeholder,
    ]
    .compactMap { $0 }
    .joined(separator: " ")
    .lowercased()
  }

  private var firstMeaningfulLabel: String? {
    [title, accessibilityDescription, placeholder, help]
      .compactMap { value in
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      }
      .first
  }

  private func normalized(_ value: String?) -> String {
    guard let value else { return "" }
    return
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static func truncated(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    return String(value.prefix(max(1, limit - 1))) + "…"
  }
}

enum FieldFormattingClassifier {
  static func automaticMode(
    for descriptor: FocusedTextFieldDescriptor
  ) -> FieldFormattingMode {
    let metadata = descriptor.accessibilityText
    let subrole = descriptor.subrole?.lowercased() ?? ""
    let role = descriptor.role?.lowercased() ?? ""

    if role.contains("searchfield")
      || subrole.contains("searchfield")
      || containsWord(metadata, "search")
      || containsAny(
        metadata,
        [
          "address bar", "address and search", "location bar", "url field",
          "search query",
        ]
      )
    {
      return .searchCommand
    }

    if containsAny(
      metadata,
      [
        "rename", "tab name", "document name", "file name", "filename",
        "window title", "project name", "workspace name", "task name",
        "new name", "name your",
      ]
    ) || hasStandaloneMetadataValue("name", in: descriptor)
      || hasStandaloneMetadataValue("title", in: descriptor)
    {
      return .nameTitle
    }

    if containsAny(
      metadata,
      [
        "terminal", "console", "command line", "shell input", "source code",
        "code editor",
      ]
    ) || isTerminalApplication(descriptor) {
      return .codeTerminal
    }

    if role.contains("textarea") {
      return .prose
    }

    return .prose
  }

  private static func containsAny(
    _ value: String,
    _ needles: [String]
  ) -> Bool {
    needles.contains { value.contains($0) }
  }

  private static func containsWord(_ value: String, _ word: String) -> Bool {
    value.split { character in
      !character.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0)
      }
    }.contains(Substring(word))
  }

  private static func hasStandaloneMetadataValue(
    _ expected: String,
    in descriptor: FocusedTextFieldDescriptor
  ) -> Bool {
    [
      descriptor.title,
      descriptor.accessibilityDescription,
      descriptor.help,
      descriptor.placeholder,
    ].contains { value in
      value?.trimmingCharacters(in: .whitespacesAndNewlines)
        .localizedCaseInsensitiveCompare(expected) == .orderedSame
    }
  }

  private static func isTerminalApplication(
    _ descriptor: FocusedTextFieldDescriptor
  ) -> Bool {
    let app = [descriptor.bundleIdentifier, descriptor.applicationName]
      .compactMap { $0 }
      .joined(separator: " ")
      .lowercased()
    return containsAny(
      app,
      ["ghostty", "iterm", "terminal", "kitty", "alacritty", "wezterm"]
    )
  }
}

enum FieldAwareTextFormatter {
  static func formatted(
    _ text: String,
    for context: TextInsertionContext,
    mode: FieldFormattingMode,
    protectedTerms: [String] = []
  ) -> String {
    guard !text.isEmpty else { return text }

    switch mode {
    case .automatic, .prose:
      let continued = continuationAdjusted(
        text,
        textBeforeSelection: context.textBeforeSelection,
        protectedTerms: protectedTerms
      )
      return InsertionBoundaryFormatter.formatted(continued, for: context)

    case .searchCommand:
      let cleaned = removingTerminalSentencePunctuation(from: text)
      let continued = continuationAdjusted(
        cleaned,
        textBeforeSelection: context.textBeforeSelection,
        protectedTerms: protectedTerms
      )
      return InsertionBoundaryFormatter.formatted(continued, for: context)

    case .nameTitle:
      let cleaned = removingTerminalSentencePunctuation(from: text)
      return InsertionBoundaryFormatter.formatted(cleaned, for: context)

    case .codeTerminal:
      return text
    }
  }

  private static let safeContinuationWords: Set<String> = [
    "A", "An", "And", "As", "At", "Because", "But", "By", "For", "From",
    "He", "If", "In", "Is", "It", "Its", "Of", "On", "Or", "She", "So",
    "That", "The", "Then", "They", "This", "Those", "To", "We", "When",
    "Where", "Which", "While", "Who", "With", "You",
  ]

  private static let openingCharacters = CharacterSet.whitespacesAndNewlines
    .union(CharacterSet(charactersIn: "\"'“”‘’([{"))
  private static let closingCharacters: Set<Character> = [
    "\"", "'", "”", "’", ")", "]", "}",
  ]

  private static func continuationAdjusted(
    _ text: String,
    textBeforeSelection: String,
    protectedTerms: [String]
  ) -> String {
    guard isMidSentence(textBeforeSelection) else { return text }
    guard !protectedTerms.contains(where: { protectedPrefix($0, in: text) }) else {
      return text
    }

    var tokenStart = text.startIndex
    while tokenStart < text.endIndex {
      let scalarView = String(text[tokenStart]).unicodeScalars
      if scalarView.allSatisfy({ openingCharacters.contains($0) }) {
        tokenStart = text.index(after: tokenStart)
      } else {
        break
      }
    }
    guard tokenStart < text.endIndex else { return text }

    var tokenEnd = tokenStart
    while tokenEnd < text.endIndex,
      text[tokenEnd].unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) })
    {
      tokenEnd = text.index(after: tokenEnd)
    }
    let token = String(text[tokenStart..<tokenEnd])
    guard safeContinuationWords.contains(token), token != "I" else { return text }
    guard !nextWordStartsWithUppercase(in: text, after: tokenEnd) else {
      return text
    }

    var result = text
    result.replaceSubrange(tokenStart..<tokenEnd, with: token.lowercased())
    return result
  }

  private static func nextWordStartsWithUppercase(
    in text: String,
    after index: String.Index
  ) -> Bool {
    var cursor = index
    while cursor < text.endIndex {
      let character = text[cursor]
      if character.unicodeScalars.allSatisfy({
        CharacterSet.whitespacesAndNewlines.contains($0)
      }) {
        cursor = text.index(after: cursor)
        continue
      }
      return character.unicodeScalars.contains {
        CharacterSet.uppercaseLetters.contains($0)
      }
    }
    return false
  }

  private static func isMidSentence(_ textBeforeSelection: String) -> Bool {
    guard
      let currentLine = textBeforeSelection.split(
        omittingEmptySubsequences: false,
        whereSeparator: { $0 == "\n" || $0 == "\r" }
      ).last
    else {
      return false
    }

    var characters = Array(currentLine)
    while let last = characters.last,
      last.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) })
        || closingCharacters.contains(last)
    {
      characters.removeLast()
    }
    guard let previous = characters.last else { return false }
    return ![".", "?", "!", "…"].contains(previous)
  }

  private static func protectedPrefix(_ term: String, in text: String) -> Bool {
    let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return false }

    let candidate = text.trimmingCharacters(in: openingCharacters)
    guard candidate.count >= normalized.count else { return false }
    let end = candidate.index(candidate.startIndex, offsetBy: normalized.count)
    guard candidate[..<end].localizedCaseInsensitiveCompare(normalized) == .orderedSame
    else {
      return false
    }
    guard end < candidate.endIndex else { return true }
    return !candidate[end].unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0)
    }
  }

  private static func removingTerminalSentencePunctuation(from text: String) -> String {
    var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { return result }

    var suffix = ""
    while let last = result.last, closingCharacters.contains(last) {
      suffix.insert(last, at: suffix.startIndex)
      result.removeLast()
    }
    while let last = result.last, [".", "?", "!", "…"].contains(last) {
      result.removeLast()
    }
    return result + suffix
  }
}
