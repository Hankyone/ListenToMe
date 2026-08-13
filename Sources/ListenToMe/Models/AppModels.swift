import AppKit
import Foundation

enum AppSection: String, CaseIterable, Identifiable, Hashable {
  case history
  case vocabulary
  case settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .history: "History"
    case .vocabulary: "Words"
    case .settings: "Setup"
    }
  }

  var symbolName: String {
    switch self {
    case .history: "clock.arrow.circlepath"
    case .vocabulary: "text.book.closed"
    case .settings: "slider.horizontal.3"
    }
  }
}

struct TargetApplication: Codable, Equatable, Sendable {
  let name: String
  let bundleIdentifier: String?
  let processIdentifier: Int32

  init(
    name: String,
    bundleIdentifier: String?,
    processIdentifier: Int32
  ) {
    self.name = name
    self.bundleIdentifier = bundleIdentifier
    self.processIdentifier = processIdentifier
  }

  init(application: NSRunningApplication) {
    name = application.localizedName ?? "Unknown app"
    bundleIdentifier = application.bundleIdentifier
    processIdentifier = application.processIdentifier
  }
}

enum DeliveryOutcome: String, Codable, Sendable {
  case pasted
  case copiedFocusChanged
  case copiedNoAccessibility
  case copiedNoTarget
  case copiedPasteFailed
  /// Audio is on disk; transcription and/or paste did not complete.
  case audioSaved

  var title: String {
    switch self {
    case .pasted: "Pasted"
    case .copiedFocusChanged: "Copied after focus changed"
    case .copiedNoAccessibility: "Copied because paste access is off"
    case .copiedNoTarget: "Copied"
    case .copiedPasteFailed: "Copied after paste failed"
    case .audioSaved: "Audio saved"
    }
  }

  var symbolName: String {
    switch self {
    case .pasted: "arrow.down.to.line"
    case .audioSaved: "waveform"
    default: "doc.on.doc"
    }
  }
}

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let createdAt: Date
  var transcript: String
  let duration: TimeInterval
  let audioFileName: String
  let targetApplication: TargetApplication?
  let deliveryOutcome: DeliveryOutcome

  var shortTargetName: String {
    targetApplication?.name ?? "Clipboard"
  }

  /// List/preview copy when the model never returned text.
  var previewText: String {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    return "Audio saved. Play it back or reprocess."
  }
}

struct VocabularyItem: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var term: String
  /// Comma-separated other spellings the model might hear (Anwar, Anuar).
  var oftenHeardAs: String

  init(id: UUID = UUID(), term: String, oftenHeardAs: String = "") {
    self.id = id
    self.term = term
    self.oftenHeardAs = oftenHeardAs
  }

  var heardAsAliases: [String] {
    let term = self.term.trimmingCharacters(in: .whitespacesAndNewlines)
    return VocabularyAliases.parse(oftenHeardAs).filter {
      $0.localizedCaseInsensitiveCompare(term) != .orderedSame
    }
  }
}

enum VocabularyAliases {
  static func parse(_ raw: String) -> [String] {
    raw
      .split(whereSeparator: { $0 == "," || $0 == ";" })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  static func normalized(_ raw: String) -> String {
    parse(raw).joined(separator: ", ")
  }
}

enum TranscriptionDelay: String, CaseIterable, Identifiable, Codable, Sendable {
  case minimal
  case low
  case medium
  case high
  case xhigh

  var id: String { rawValue }

  var title: String {
    switch self {
    case .minimal: "Fastest"
    case .low: "Fast"
    case .medium: "Balanced"
    case .high: "Accurate"
    case .xhigh: "Most accurate"
    }
  }

  var explanation: String {
    switch self {
    case .minimal: "Shows words as early as possible."
    case .low: "A quick response with a little more context."
    case .medium: "Balances speed and transcript quality."
    case .high: "Waits longer to improve difficult words."
    case .xhigh: "Uses the most audio context before showing text."
    }
  }
}

enum MicProfile: String, CaseIterable, Identifiable, Codable, Sendable {
  case builtIn
  case headset
  case off

  var id: String { rawValue }

  var title: String {
    switch self {
    case .builtIn: "Built-in mic"
    case .headset: "Headset mic"
    case .off: "None"
    }
  }

  var explanation: String {
    switch self {
    case .builtIn: "Room noise reduction tuned for the Mac's own microphone."
    case .headset: "Noise reduction tuned for a mic close to your mouth."
    case .off: "Send the raw microphone signal."
    }
  }

  /// The `noise_reduction` type OpenAI applies before transcription.
  var noiseReductionType: String? {
    switch self {
    case .builtIn: "far_field"
    case .headset: "near_field"
    case .off: nil
    }
  }
}

enum OverlayLayout: String, CaseIterable, Identifiable, Codable, Sendable {
  case compact
  case wide
  case tall

  var id: String { rawValue }

  var title: String {
    switch self {
    case .compact: "Standard"
    case .wide: "Wide"
    case .tall: "Tall"
    }
  }

  var explanation: String {
    switch self {
    case .compact: "Compact plate while you talk."
    case .wide: "Twice as wide, so more of the live transcript stays on one line."
    case .tall: "Twice as tall, so more lines of the live transcript stay visible."
    }
  }

  var panelSize: CGSize {
    switch self {
    case .compact: CGSize(width: 420, height: 58)
    case .wide: CGSize(width: 840, height: 58)
    case .tall: CGSize(width: 420, height: 116)
    }
  }

  var lineLimit: Int {
    switch self {
    case .compact, .wide: 2
    case .tall: 5
    }
  }
}

enum OpenAIService {
  static let keyPlaceholder = "sk-…"
  static let createKeyLabel = "Create an OpenAI API key"
  static let keyFileName = "openai-api-key"
  static let createKeyURL = URL(string: "https://platform.openai.com/api-keys")!
}

enum WritingGuidance {
  static let defaultBasePrompt = """
    One speaker, live, inserting at the caret. Written English at the insertion point: sentence case; standard punctuation; Arabic numerals (42, 3.14, 1,000) unless the words themselves are the content; emails, URLs, and paths as user@host and https://..., not spoken at/dot/slash. Drop um, uh, er; keep like, you know, so, well when they belong in the sentence. Keep wording, order, and register. Homophones follow the destination app and listed spellings. End with one trailing space, never a newline.
    """
    .trimmingCharacters(in: .whitespacesAndNewlines)

  /// Spoken "scratch that" / "I mean" so the model rewrites instead of
  /// transcribing the cue words. Always appended; not user-editable.
  static let correctionPrompt = """
    Spoken revision — correction, scratch that, or I mean: emit only the restatement of the immediately preceding phrase; omit the cue and the discarded span.
    """
    .trimmingCharacters(in: .whitespacesAndNewlines)

  /// Older factory text, so Reset stays disabled and we migrate to the compact default.
  static let previousDefaultBasePrompts: [String] = [
    """
    Lightly polish spoken dictation into clean written text. Keep the speaker's meaning and wording; do not invent content. Add natural punctuation and capitalization — these are not spoken aloud. Remove filler such as um, uh, er, and filler uses of like and you know. Prefer exact spellings from the custom-word list and surrounding context for names and technical terms. When the text continues typing in place, end with one trailing space.
    """
    .trimmingCharacters(in: .whitespacesAndNewlines),
    """
    Polish dictation lightly. Keep meaning and wording; don't invent. Add punctuation and capitalization (unspoken). Strip filler (um, uh, er, like, you know). Prefer listed spellings. If typing in place, end with one space.
    """
    .trimmingCharacters(in: .whitespacesAndNewlines),
    """
    Polish dictation lightly. Keep meaning and wording; don't invent. Add punctuation and capitalization (unspoken). Strip filler (um, uh, er, you know). Prefer listed spellings. If typing in place, end with one space.
    """
    .trimmingCharacters(in: .whitespacesAndNewlines),
  ]

  static func isFactoryDefault(_ prompt: String) -> Bool {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == defaultBasePrompt
      || previousDefaultBasePrompts.contains(trimmed)
  }
}

struct TranscriptionConfiguration: Equatable, Sendable {
  /// OpenAI realtime `session.audio.input.transcription.prompt` max length.
  static let realtimePromptLimit = 1024

  var basePrompt: String
  var vocabulary: [VocabularyItem]
  var languages: [String]
  var delay: TranscriptionDelay
  var micProfile: MicProfile = .builtIn
  var targetAppName: String?

  var keywords: [String] {
    vocabulary.map(\.term)
  }

  var prompt: String {
    let cleanBase = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)

    let appLine: String?
    if let appName = targetAppName?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !appName.isEmpty
    {
      appLine = "Destination: \(appName)."
    } else {
      appLine = nil
    }

    let wordGuidance = vocabulary.map { item in
      let term = item.term.trimmingCharacters(in: .whitespacesAndNewlines)
      let aliases = item.heardAsAliases
      if aliases.isEmpty {
        return term
      }
      return "\(term) (\(aliases.joined(separator: ", ")))"
    }
    .filter { !$0.isEmpty }
    .joined(separator: "; ")

    let wordsLine: String?
    if wordGuidance.isEmpty {
      wordsLine = nil
    } else {
      wordsLine =
        "If spoken, spell: \(wordGuidance)."
    }

    return Self.clampedPrompt(
      base: cleanBase,
      appLine: appLine,
      wordsLine: wordsLine,
      correction: WritingGuidance.correctionPrompt,
      limit: Self.realtimePromptLimit
    )
  }

  /// Shrinks writing guidance, then custom-word hints, so a long target-app
  /// name cannot blow the realtime 1024-character prompt cap.
  static func clampedPrompt(
    base: String,
    appLine: String?,
    wordsLine: String?,
    correction: String,
    limit: Int
  ) -> String {
    func assemble(base: String, words: String?) -> String {
      [base, appLine ?? "", words ?? "", correction]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    var base = base
    var words = wordsLine
    var result = assemble(base: base, words: words)
    if result.utf8.count <= limit { return result }

    let withoutBase = assemble(base: "", words: words)
    if withoutBase.utf8.count <= limit {
      let budget = max(0, limit - withoutBase.utf8.count - (withoutBase.isEmpty ? 0 : 1))
      base = utf8Prefix(base, budget)
      return assemble(base: base, words: words)
    }

    base = ""
    result = assemble(base: base, words: words)
    if result.utf8.count <= limit { return result }

    let withoutWords = assemble(base: "", words: nil)
    if withoutWords.utf8.count <= limit {
      let budget = max(0, limit - withoutWords.utf8.count - (withoutWords.isEmpty ? 0 : 1))
      words = utf8Prefix(words ?? "", budget)
      return assemble(base: "", words: words)
    }

    return utf8Prefix(withoutWords, limit)
  }

  private static func utf8Prefix(_ string: String, _ maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    if string.utf8.count <= maxBytes { return string }
    var truncated = string
    while truncated.utf8.count > maxBytes, !truncated.isEmpty {
      truncated.removeLast()
    }
    return truncated.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum RecordingPhase: Equatable {
  case idle
  case connecting
  case recording
  case finishing
  case delivered(DeliveryOutcome)
  case failed

  var isBusy: Bool {
    switch self {
    case .connecting, .recording, .finishing: true
    default: false
    }
  }

  var isRecording: Bool {
    self == .recording
  }
}

enum VocabularyValidation {
  static func normalizedTerm(_ value: String) -> String? {
    let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty,
      !term.contains("<"),
      !term.contains(">"),
      !term.contains("\n"),
      !term.contains("\r")
    else {
      return nil
    }
    return term
  }
}

enum DeliveryPolicy {
  /// Whether we should attempt insert/paste after reactivating the target.
  /// Focus is checked *after* activation in `TextDeliveryService` — finishing a
  /// recording often leaves another process frontmost briefly.
  static func canAttemptPaste(
    target: TargetApplication?,
    hasAccessibilityPermission: Bool
  ) -> DeliveryOutcome {
    guard target != nil else { return .copiedNoTarget }
    guard hasAccessibilityPermission else {
      return .copiedNoAccessibility
    }
    return .pasted
  }

  static func outcome(
    target: TargetApplication?,
    frontmostProcessIdentifier: Int32?,
    hasAccessibilityPermission: Bool
  ) -> DeliveryOutcome {
    let attempt = canAttemptPaste(
      target: target,
      hasAccessibilityPermission: hasAccessibilityPermission
    )
    guard attempt == .pasted, let target else { return attempt }
    guard target.processIdentifier == frontmostProcessIdentifier else {
      return .copiedFocusChanged
    }
    return .pasted
  }
}
