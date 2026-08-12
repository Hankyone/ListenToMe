import Foundation

/// Keeps failure copy short and actionable so banners never dump raw API JSON
/// into the UI (and stretch windows).
enum UserFacingError {
  static let maxLength = 220

  static func message(from raw: String) -> String {
    let trimmed = raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")

    guard !trimmed.isEmpty else {
      return "Something went wrong. Try again, or check Setup."
    }

    if looksLikeLanguageProblem(trimmed) {
      return
        "That language code isn’t supported. In Setup, use codes like en or fr — not regional tags like fr-CA."
    }

    if trimmed.localizedCaseInsensitiveContains("401")
      || trimmed.localizedCaseInsensitiveContains("unauthorized")
      || trimmed.localizedCaseInsensitiveContains("invalid api key")
      || trimmed.localizedCaseInsensitiveContains("incorrect api key")
    {
      return "The API key was rejected. Paste a valid key in Setup."
    }

    if trimmed.localizedCaseInsensitiveContains("429")
      || trimmed.localizedCaseInsensitiveContains("rate limit")
    {
      return "The API rate-limited this request. Wait a moment and try again."
    }

    if trimmed.localizedCaseInsensitiveContains("insufficient_quota")
      || trimmed.localizedCaseInsensitiveContains("quota")
      || trimmed.localizedCaseInsensitiveContains("billing")
    {
      return "The API account is out of quota. Check billing for that provider."
    }

    if trimmed.localizedCaseInsensitiveContains("timed out")
      || trimmed.localizedCaseInsensitiveContains("timeout")
    {
      return "The connection timed out before transcription finished."
    }

    if looksLikePromptTooLong(trimmed) {
      return
        "Writing guidance was too long for live transcription. It’s trimmed automatically now — try again."
    }

    if looksLikeLengthLimit(trimmed) {
      return
        "Live transcription hit a length limit. Your audio is saved in History — play it back or hit Reprocess."
    }

    if trimmed.localizedCaseInsensitiveContains("internet")
      || trimmed.localizedCaseInsensitiveContains("network")
      || trimmed.localizedCaseInsensitiveContains("offline")
      || trimmed.localizedCaseInsensitiveContains("not connected")
    {
      return "The network connection dropped. Your audio stayed on this Mac."
    }

    return truncate(trimmed)
  }

  private static func looksLikeLanguageProblem(_ message: String) -> Bool {
    let lower = message.lowercased()
    let mentionsLanguage =
      lower.contains("language") || lower.contains("languages")
    let looksInvalid =
      lower.contains("invalid")
      || lower.contains("unsupported")
      || lower.contains("not supported")
      || lower.contains("unknown")
    // Common rejected regional examples show up in the raw message.
    let looksRegional =
      message.range(
        of: #"[a-z]{2}-[A-Za-z]{2}"#,
        options: .regularExpression
      ) != nil
    return mentionsLanguage && (looksInvalid || looksRegional)
  }

  private static func looksLikePromptTooLong(_ message: String) -> Bool {
    let lower = message.lowercased()
    return lower.contains("prompt")
      && (lower.contains("too long")
        || lower.contains("maximum length")
        || lower.contains("max length"))
  }

  private static func looksLikeLengthLimit(_ message: String) -> Bool {
    let lower = message.lowercased()
    if lower.contains("too long")
      || lower.contains("too large")
      || lower.contains("max duration")
      || lower.contains("maximum duration")
      || lower.contains("audio_too_long")
    {
      return true
    }
    return lower.contains("buffer")
      && (lower.contains("limit")
        || lower.contains("exceed")
        || lower.contains("full")
        || lower.contains("large"))
  }

  private static func truncate(_ message: String) -> String {
    guard message.count > maxLength else { return message }
    let end = message.index(message.startIndex, offsetBy: maxLength - 1)
    return String(message[..<end]).trimmingCharacters(in: .whitespaces) + "…"
  }
}
