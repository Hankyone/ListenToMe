import AppKit
import Foundation

enum AppSection: String, CaseIterable, Identifiable {
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

  var title: String {
    switch self {
    case .pasted: "Pasted"
    case .copiedFocusChanged: "Copied after focus changed"
    case .copiedNoAccessibility: "Copied because paste access is off"
    case .copiedNoTarget: "Copied"
    case .copiedPasteFailed: "Copied after paste failed"
    }
  }

  var symbolName: String {
    switch self {
    case .pasted: "arrow.down.to.line"
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
}

struct VocabularyItem: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var term: String
  var oftenHeardAs: String

  init(id: UUID = UUID(), term: String, oftenHeardAs: String = "") {
    self.id = id
    self.term = term
    self.oftenHeardAs = oftenHeardAs
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

struct TranscriptionConfiguration: Equatable, Sendable {
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
    var parts: [String] = []

    let cleanBase = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleanBase.isEmpty {
      parts.append(cleanBase)
    }

    if let appName = targetAppName?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !appName.isEmpty
    {
      parts.append("The speaker is dictating into \(appName).")
    }

    let wordGuidance = vocabulary.map { item in
      let term = item.term.trimmingCharacters(in: .whitespacesAndNewlines)
      let heardAs = item.oftenHeardAs.trimmingCharacters(in: .whitespacesAndNewlines)
      if heardAs.isEmpty {
        return term
      }
      return "\(term) (may sound like \(heardAs))"
    }
    .filter { !$0.isEmpty }
    .joined(separator: ", ")

    if !wordGuidance.isEmpty {
      parts.append(
        "When the audio and context indicate these names or terms, use these exact spellings: \(wordGuidance). These are hints only. Never insert a term that was not spoken."
      )
    }

    parts.append(
      """
      If the speaker says "correction", "scratch that", or "I mean" and then restates something, treat that as an edit: replace the immediately preceding wrong phrase with the restatement. Do not keep the cue words or the discarded phrase in the transcript. Continue with whatever they say next. Strip filler sounds and keep the final text paste-ready.
      """
        .trimmingCharacters(in: .whitespacesAndNewlines)
    )

    return parts.joined(separator: "\n\n")
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
  static func outcome(
    target: TargetApplication?,
    frontmostProcessIdentifier: Int32?,
    hasAccessibilityPermission: Bool
  ) -> DeliveryOutcome {
    guard let target else { return .copiedNoTarget }
    guard target.processIdentifier == frontmostProcessIdentifier else {
      return .copiedFocusChanged
    }
    guard hasAccessibilityPermission else {
      return .copiedNoAccessibility
    }
    return .pasted
  }
}
