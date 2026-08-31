import Foundation

struct TextInsertionContext: Equatable, Sendable {
  let textBeforeSelection: String
  let characterAfterSelection: Character?
  let field: FocusedTextFieldDescriptor?

  var characterBeforeSelection: Character? {
    textBeforeSelection.last
  }

  init(
    characterBeforeSelection: Character? = nil,
    characterAfterSelection: Character? = nil,
    textBeforeSelection: String? = nil,
    field: FocusedTextFieldDescriptor? = nil
  ) {
    self.textBeforeSelection =
      textBeforeSelection ?? characterBeforeSelection.map(String.init) ?? ""
    self.characterAfterSelection = characterAfterSelection
    self.field = field
  }
}

/// Joins a transcript to the text touching the caret without changing the
/// transcript itself. The surrounding text never leaves the Mac.
enum InsertionBoundaryFormatter {
  private static let charactersThatAttachToFollowingText: Set<Character> = [
    "(", "[", "{", "/", "\\", "@", "#", "$", "€", "£", "¥", "_", "-", "‑", "–", "—",
  ]

  private static let charactersThatAttachToPrecedingText: Set<Character> = [
    ".", ",", ":", ";", "!", "?", "…", ")", "]", "}", "%", "‰", "/", "\\", "@", "#", "_",
    "-", "‑", "–", "—", "'", "’", "\"", "”",
  ]

  static func formatted(
    _ text: String,
    for context: TextInsertionContext
  ) -> String {
    guard !text.isEmpty else { return text }

    var result = text
    if let before = context.characterBeforeSelection,
      let first = result.first,
      needsSpace(between: before, and: first)
    {
      result.insert(" ", at: result.startIndex)
    }

    if let last = result.last,
      let after = context.characterAfterSelection,
      needsSpace(between: last, and: after)
    {
      result.append(" ")
    }

    return result
  }

  private static func needsSpace(
    between left: Character,
    and right: Character
  ) -> Bool {
    guard !isWhitespace(left), !isWhitespace(right) else { return false }
    guard !charactersThatAttachToFollowingText.contains(left) else {
      return false
    }
    guard !charactersThatAttachToPrecedingText.contains(right) else {
      return false
    }
    return true
  }

  private static func isWhitespace(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy {
      CharacterSet.whitespacesAndNewlines.contains($0)
    }
  }
}
