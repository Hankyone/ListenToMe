import Foundation

/// File and live models sometimes echo `transcription.prompt` instead of
/// (or on top of) what was spoken. Never paste that scaffolding.
enum TranscriptSanitizer {
  private static let fingerprints = [
    "End with one trailing space, never a newline",
    "If spoken, spell:",
    "keep the restatement, drop the cue",
    "correction / scratch that / I mean",
    "Context: ###",
  ]

  static func spokenText(from transcript: String, prompt: String) -> String {
    var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "" }

    if !prompt.isEmpty {
      if text == prompt { return "" }
      text = text.replacingOccurrences(of: prompt, with: " ")
    }

    for fingerprint in fingerprints {
      text = text.replacingOccurrences(of: fingerprint, with: " ")
    }

    text = stripDestinationLines(text)
    text = text.replacingOccurrences(of: "###", with: " ")
    return collapseWhitespace(text)
  }

  private static func stripDestinationLines(_ text: String) -> String {
    let pattern = #"Destination:\s*.+?\.(?:\s|$)"#
    guard
      let regex = try? NSRegularExpression(
        pattern: pattern,
        options: [.caseInsensitive]
      )
    else {
      return text
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(
      in: text,
      range: range,
      withTemplate: " "
    )
  }

  private static func collapseWhitespace(_ text: String) -> String {
    text
      .replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
