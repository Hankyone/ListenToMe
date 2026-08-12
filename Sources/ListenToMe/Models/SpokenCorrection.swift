import Foundation

/// Applies spoken edit cues the live STT model usually transcribes literally.
///
/// "Montreal, correction to Toronto" becomes "Toronto" in place — the prompt
/// alone does not make `gpt-live-transcribe` rewrite.
enum SpokenCorrection {
  private enum CueKind {
    case replace
    case delete
  }

  private struct Cue {
    var kind: CueKind
    var range: Range<String.Index>
  }

  private static let functionWords: Set<String> = [
    "a", "an", "at", "for", "from", "in", "of", "on", "the", "to", "with",
  ]

  private static let clauseStarters: Set<String> = [
    "and", "because", "but", "or", "plus", "so", "then",
  ]

  private static let cueExpressions: [(NSRegularExpression, CueKind)] = {
    let patterns: [(String, CueKind)] = [
      (#"(?:,|\.|;)?\s*\bscratch that\b"#, .delete),
      (#"(?:,|\.|;)?\s*\bforget that\b"#, .delete),
      (#"(?:,|\.|;)?\s*\bdelete that\b"#, .delete),
      (#"(?:,|\.|;)?\s*\bno[, ]+i mean\b"#, .replace),
      (#"(?:,|\.|;)?\s*\bi mean\b"#, .replace),
      (#"(?:,|\.|;)?\s*\bcorrection\b"#, .replace),
    ]
    return patterns.map { pattern, kind in
      let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      return (regex, kind)
    }
  }()

  static func apply(_ text: String) -> String {
    var current = text
    for _ in 0..<12 {
      guard let next = applyFirstCue(in: current), next != current else { break }
      current = next
    }
    return normalizeSpacing(current)
  }

  private static func applyFirstCue(in text: String) -> String? {
    guard let cue = firstCue(in: text) else { return nil }
    let before = String(text[..<cue.range.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let after = String(text[cue.range.upperBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    switch cue.kind {
    case .delete:
      return join(deletingLastPhrase(before), after)
    case .replace:
      let (replacement, continuation) = splitRestatement(after)
      guard !replacement.isEmpty else { return nil }
      return join(replacingLastSpan(before, with: replacement), continuation)
    }
  }

  private static func firstCue(in text: String) -> Cue? {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    var best: Cue?
    for (regex, kind) in cueExpressions {
      let match = regex.firstMatch(in: text, options: [], range: full)
      guard let match, let range = Range(match.range, in: text) else { continue }
      if kind == .replace, regex.pattern.contains("correction"),
        !isPlausibleCorrection(in: text, cue: range)
      {
        continue
      }
      if best == nil || range.lowerBound < best!.range.lowerBound {
        best = Cue(kind: kind, range: range)
      }
    }
    return best
  }

  /// Avoid rewriting prose like "the correction to the bill".
  private static func isPlausibleCorrection(
    in text: String,
    cue: Range<String.Index>
  ) -> Bool {
    let cueText = text[cue]
    if let first = cueText.first(where: { !$0.isWhitespace }),
      ",.;:".contains(first)
    {
      return true
    }

    let before = text[..<cue.lowerBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let previousWords = wordTokens(in: String(before))
    guard previousWords.count >= 2,
      let previous = previousWords.last,
      previous.first?.isUppercase == true
    else {
      return false
    }

    let after = text[cue.upperBound...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return after.hasPrefix("to ") || after.hasPrefix("to,") || after == "to"
  }

  private static func splitRestatement(_ after: String) -> (String, String) {
    let trimmed = after.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ("", "") }
    if let first = trimmed.first, ",.;:!?".contains(first) {
      return ("", trimmed)
    }

    var tokens: [String] = []
    var index = trimmed.startIndex
    var continuationStart: String.Index?

    while index < trimmed.endIndex {
      while index < trimmed.endIndex, trimmed[index].isWhitespace {
        index = trimmed.index(after: index)
      }
      guard index < trimmed.endIndex else { break }

      if ",.;:!?".contains(trimmed[index]) {
        continuationStart = index
        break
      }

      var end = index
      while end < trimmed.endIndex,
        !trimmed[end].isWhitespace,
        !",.;:!?".contains(trimmed[end])
      {
        end = trimmed.index(after: end)
      }
      let token = String(trimmed[index..<end])
      if !tokens.isEmpty, clauseStarters.contains(token.lowercased()) {
        continuationStart = index
        break
      }
      tokens.append(token)
      index = end
    }

    let replacement = tokens.joined(separator: " ")
    let continuation: String
    if let continuationStart {
      continuation = String(trimmed[continuationStart...])
        .trimmingCharacters(in: .whitespaces)
    } else {
      continuation = ""
    }
    return (replacement, continuation)
  }

  private static func replacingLastSpan(
    _ before: String,
    with replacement: String
  ) -> String {
    let before = before.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !before.isEmpty else { return replacement }
    guard !replacement.isEmpty else { return before }

    let replacementWords = wordTokens(in: replacement)
    if let first = replacementWords.first?.lowercased(),
      functionWords.contains(first),
      let span = lastWordRange(in: before, matching: first)
    {
      let prefix = String(before[..<span.lowerBound])
        .trimmingCharacters(in: .whitespaces)
      return prefix.isEmpty ? replacement : prefix + " " + replacement
    }

    if let last = lastWordRange(in: before) {
      let prefix = String(before[..<last.lowerBound])
        .trimmingCharacters(in: .whitespaces)
      return prefix.isEmpty ? replacement : prefix + " " + replacement
    }
    return replacement
  }

  private static func deletingLastPhrase(_ before: String) -> String {
    let before = before.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !before.isEmpty else { return "" }

    if let range = before.range(
      of: #"[.!?]\s+\S"#,
      options: [.regularExpression, .backwards]
    ) {
      let period = before[range].first.map { String($0) } ?? "."
      let head = String(before[..<range.lowerBound])
        .trimmingCharacters(in: .whitespaces)
      return head.isEmpty ? "" : head + period
    }

    if let comma = before.lastIndex(of: ",") {
      return String(before[..<comma]).trimmingCharacters(in: .whitespaces)
    }

    if let span = lastFunctionWordRange(in: before) {
      return String(before[..<span.lowerBound])
        .trimmingCharacters(in: .whitespaces)
    }

    if let last = lastWordRange(in: before) {
      return String(before[..<last.lowerBound])
        .trimmingCharacters(in: .whitespaces)
    }
    return ""
  }

  private static func lastFunctionWordRange(
    in text: String
  ) -> Range<String.Index>? {
    let tokens = wordTokens(in: text)
    guard let word = tokens.last(where: { functionWords.contains($0.lowercased()) })
    else { return nil }
    return lastWordRange(in: text, matching: word)
  }

  private static func lastWordRange(in text: String) -> Range<String.Index>? {
    lastWordRange(in: text, matching: nil)
  }

  private static func lastWordRange(
    in text: String,
    matching needle: String?
  ) -> Range<String.Index>? {
    var index = text.endIndex
    while index > text.startIndex {
      index = text.index(before: index)
      if text[index].isWhitespace { continue }
      let end = text.index(after: index)
      var start = index
      while start > text.startIndex {
        let previous = text.index(before: start)
        if text[previous].isWhitespace { break }
        start = previous
      }
      let token = String(text[start..<end])
        .trimmingCharacters(in: CharacterSet.punctuationCharacters)
      if let needle {
        if token.caseInsensitiveCompare(needle) == .orderedSame {
          return start..<end
        }
      } else {
        return start..<end
      }
      index = start
    }
    return nil
  }

  private static func wordTokens(in text: String) -> [String] {
    text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
  }

  private static func join(_ head: String, _ tail: String) -> String {
    let head = head.trimmingCharacters(in: .whitespacesAndNewlines)
    let tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
    if tail.isEmpty { return head }
    if head.isEmpty { return tail }
    if let first = tail.first, ",.;:!?".contains(first) {
      return head + tail
    }
    return head + " " + tail
  }

  private static func normalizeSpacing(_ text: String) -> String {
    var result = text
    while result.contains("  ") {
      result = result.replacingOccurrences(of: "  ", with: " ")
    }
    result = result.replacingOccurrences(of: " ,", with: ",")
    result = result.replacingOccurrences(of: " .", with: ".")
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
