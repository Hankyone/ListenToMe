import Foundation

/// OpenAI transcription language hints: ISO 639-1 (`fr`), selected ISO 639-3
/// (`yue`, `cmn`, …), and regional Chinese locales (`zh-cn`). Regional tags like
/// `fr-CA` are rejected by the API  -  we normalize those to the base language.
enum LanguageHintValidation {
  struct Result: Equatable, Sendable {
    /// Rewritten field text (regional codes collapsed, tokens re-joined).
    var normalizedText: String
    /// Codes safe to send to the API.
    var codes: [String]
    /// Short status for Setup (nil when the field is fine as-is).
    var message: String?
    /// True when something in the field cannot be used  -  block dictation.
    var isBlocking: Bool
  }

  private static let allowedISO6393: Set<String> = [
    "eng", "spa", "yue", "cmn",
  ]

  private static let allowedZHLocales: Set<String> = [
    "zh-cn", "zh-tw", "zh-hk",
  ]

  static func parse(
    _ text: String,
    provider: TranscriptionProvider = .openAI,
    finalizePending: Bool = false
  ) -> Result {
    let rawTokens =
      text
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    guard !rawTokens.isEmpty else {
      return Result(normalizedText: "", codes: [], message: nil, isBlocking: false)
    }

    var codes: [String] = []
    var displayTokens: [String] = []
    var corrected: [String] = []
    var invalid: [String] = []
    var seen = Set<String>()

    for raw in rawTokens {
      switch classify(raw, provider: provider) {
      case .valid(let code):
        displayTokens.append(code)
        if seen.insert(code).inserted {
          codes.append(code)
        }
      case .corrected(let from, let to):
        displayTokens.append(to)
        corrected.append(from)
        if seen.insert(to).inserted {
          codes.append(to)
        }
      case .pending(let token):
        if finalizePending {
          displayTokens.append(token)
          invalid.append(token)
        } else {
          // Still typing a regional tag  -  keep the text, don't send it yet.
          displayTokens.append(token)
        }
      case .invalid(let token):
        displayTokens.append(token)
        invalid.append(token)
      }
    }

    let normalizedText = displayTokens.joined(separator: ", ")
    let message: String?
    let isBlocking: Bool

    if !invalid.isEmpty {
      isBlocking = true
      let listed = invalid.map { "“\($0)”" }.joined(separator: ", ")
      message =
        provider == .gemini
        ? "\(listed) isn’t a valid BCP-47 language code. Use codes like en, fr-CA, or zh-HK."
        : "\(listed) isn’t a supported language code. Use ISO codes like en or fr, or zh-cn / zh-tw / zh-hk for Chinese locales."
    } else if !corrected.isEmpty {
      isBlocking = false
      let listed = corrected.map { "“\($0)”" }.joined(separator: ", ")
      message =
        "OpenAI doesn’t accept regional codes like \(listed). Using the base language instead."
    } else {
      isBlocking = false
      message = nil
    }

    return Result(
      normalizedText: normalizedText,
      codes: codes,
      message: message,
      isBlocking: isBlocking
    )
  }

  private enum Classification {
    case valid(String)
    case corrected(from: String, to: String)
    case pending(String)
    case invalid(String)
  }

  private static func classify(
    _ raw: String,
    provider: TranscriptionProvider
  ) -> Classification {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !token.isEmpty else { return .invalid(raw) }

    if provider == .gemini {
      if matches(token, pattern: #"^[a-z]{2,3}(-[a-z0-9]{2,8})*$"#) {
        return .valid(token)
      }
      if matches(token, pattern: #"^[a-z]{2,3}-$"#) {
        return .pending(token)
      }
      return .invalid(token)
    }

    if allowedZHLocales.contains(token) {
      return .valid(token)
    }

    if matches(token, pattern: #"^[a-z]{2}$"#) {
      return .valid(token)
    }

    if allowedISO6393.contains(token) {
      return .valid(token)
    }

    // fr-CA, en-US, pt-BR → base ISO 639-1 (zh-* handled above).
    if let base = firstCapture(token, pattern: #"^([a-z]{2})-[a-z0-9]{2,8}$"#) {
      return .corrected(from: token, to: base)
    }

    // Incomplete regional while typing ("fr-", "fr-c")  -  don't flash errors yet.
    if matches(token, pattern: #"^[a-z]{2}-[a-z0-9]{0,1}$"#) {
      return .pending(token)
    }

    return .invalid(token)
  }

  private static func matches(_ value: String, pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
  }

  private static func firstCapture(_ value: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return nil
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = regex.firstMatch(in: value, range: range),
      match.numberOfRanges > 1,
      let captureRange = Range(match.range(at: 1), in: value)
    else {
      return nil
    }
    return String(value[captureRange])
  }
}
