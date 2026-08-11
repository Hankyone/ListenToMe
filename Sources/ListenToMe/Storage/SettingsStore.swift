import Foundation

@MainActor
final class SettingsStore: ObservableObject {
  static let defaultBasePrompt = WritingGuidance.defaultBasePrompt

  @Published var showRecordingOverlay: Bool {
    didSet { defaults.set(showRecordingOverlay, forKey: Keys.showRecordingOverlay) }
  }

  @Published var basePrompt: String {
    didSet { defaults.set(basePrompt, forKey: Keys.basePrompt) }
  }

  @Published var delay: TranscriptionDelay {
    didSet { defaults.set(delay.rawValue, forKey: Keys.delay) }
  }

  @Published var languageText: String {
    didSet { defaults.set(languageText, forKey: Keys.languageText) }
  }

  @Published var micProfile: MicProfile {
    didSet { defaults.set(micProfile.rawValue, forKey: Keys.micProfile) }
  }

  /// CoreAudio device UID; empty string follows the system default input.
  @Published var microphoneDeviceUID: String {
    didSet { defaults.set(microphoneDeviceUID, forKey: Keys.microphoneDeviceUID) }
  }

  @Published var apiProvider: APIProvider {
    didSet {
      defaults.set(apiProvider.rawValue, forKey: Keys.apiProvider)
      refreshAPIKeyPresence()
    }
  }

  @Published var hotkey: HotkeySpec {
    didSet {
      guard let data = try? JSONEncoder().encode(hotkey) else { return }
      defaults.set(data, forKey: Keys.hotkey)
    }
  }

  /// True while the Setup pane is capturing a replacement shortcut, so the
  /// live hotkey pauses instead of firing mid-recording. Not persisted.
  @Published var isCapturingHotkey = false

  @Published private(set) var vocabulary: [VocabularyItem] {
    didSet { persistVocabulary() }
  }

  @Published private(set) var hasAPIKey: Bool = false

  private let defaults: UserDefaults
  private let apiKeys: APIKeyStore

  private enum Keys {
    static let showRecordingOverlay = "appearance.showRecordingOverlay"
    static let basePrompt = "transcription.basePrompt"
    static let delay = "transcription.delay"
    static let languageText = "transcription.languages"
    static let vocabulary = "transcription.vocabulary"
    static let micProfile = "transcription.micProfile"
    static let microphoneDeviceUID = "audio.microphoneDeviceUID"
    static let apiProvider = "transcription.apiProvider"
    static let hotkey = "hotkey.spec"
  }

  init(
    defaults: UserDefaults = .standard,
    apiKeys: APIKeyStore = APIKeyStore()
  ) {
    self.defaults = defaults
    self.apiKeys = apiKeys
    showRecordingOverlay =
      defaults.object(forKey: Keys.showRecordingOverlay) as? Bool
      ?? true
    basePrompt =
      defaults.string(forKey: Keys.basePrompt)
      ?? Self.defaultBasePrompt
    delay =
      TranscriptionDelay(
        rawValue: defaults.string(forKey: Keys.delay) ?? ""
      ) ?? .low
    languageText = defaults.string(forKey: Keys.languageText) ?? "en"
    micProfile =
      MicProfile(
        rawValue: defaults.string(forKey: Keys.micProfile) ?? ""
      ) ?? .builtIn
    microphoneDeviceUID =
      defaults.string(forKey: Keys.microphoneDeviceUID)
      ?? MicrophoneInput.systemDefaultID
    apiProvider =
      APIProvider(
        rawValue: defaults.string(forKey: Keys.apiProvider) ?? ""
      ) ?? .openAI

    if let data = defaults.data(forKey: Keys.hotkey),
      let stored = try? JSONDecoder().decode(HotkeySpec.self, from: data)
    {
      hotkey = stored
    } else {
      hotkey = .standard
    }

    if let data = defaults.data(forKey: Keys.vocabulary),
      let items = try? JSONDecoder().decode([VocabularyItem].self, from: data)
    {
      vocabulary = items
    } else {
      vocabulary = []
    }

    // File presence only — never load the secret at launch.
    hasAPIKey = apiKeys.hasStoredKey(provider: apiProvider)
  }

  var languageHints: LanguageHintValidation.Result {
    LanguageHintValidation.parse(languageText)
  }

  /// Codes actually sent to the API (invalid tokens omitted).
  var languages: [String] {
    languageHints.codes
  }

  /// Rewrite regional tags (fr-CA → fr) and surface Setup feedback.
  @discardableResult
  func normalizeLanguageTextIfNeeded() -> LanguageHintValidation.Result {
    let parsed = LanguageHintValidation.parse(
      languageText,
      finalizePending: true
    )
    if parsed.normalizedText != languageText {
      languageText = parsed.normalizedText
    }
    return LanguageHintValidation.parse(languageText, finalizePending: true)
  }

  var transcriptionConfiguration: TranscriptionConfiguration {
    TranscriptionConfiguration(
      basePrompt: basePrompt,
      vocabulary: vocabulary,
      languages: languages,
      delay: delay,
      micProfile: micProfile
    )
  }

  var selectedEngineIsReady: Bool {
    hasAPIKey
  }

  var isUsingDefaultBasePrompt: Bool {
    basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
      == Self.defaultBasePrompt
  }

  func resetBasePrompt() {
    basePrompt = Self.defaultBasePrompt
  }

  func loadAPIKey() throws -> String {
    let value = try apiKeys.loadAPIKey(provider: apiProvider) ?? ""
    let present = !value.isEmpty
    if hasAPIKey != present {
      hasAPIKey = present
    }
    return value
  }

  func saveAPIKey(_ value: String) throws {
    try apiKeys.saveAPIKey(value, provider: apiProvider)
    hasAPIKey = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func refreshAPIKeyPresence() {
    hasAPIKey = apiKeys.hasStoredKey(provider: apiProvider)
  }

  func addVocabulary(term: String, oftenHeardAs: String) -> Bool {
    guard let normalized = VocabularyValidation.normalizedTerm(term) else {
      return false
    }
    guard
      !vocabulary.contains(where: {
        $0.term.localizedCaseInsensitiveCompare(normalized) == .orderedSame
      })
    else {
      return false
    }

    let heardAs = oftenHeardAs.trimmingCharacters(in: .whitespacesAndNewlines)
    vocabulary.append(VocabularyItem(term: normalized, oftenHeardAs: heardAs))
    vocabulary.sort {
      $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending
    }
    return true
  }

  func updateVocabulary(_ item: VocabularyItem) {
    guard let index = vocabulary.firstIndex(where: { $0.id == item.id }),
      let normalized = VocabularyValidation.normalizedTerm(item.term)
    else {
      return
    }
    vocabulary[index].term = normalized
    vocabulary[index].oftenHeardAs = item.oftenHeardAs
      .trimmingCharacters(in: .whitespacesAndNewlines)
    vocabulary.sort {
      $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending
    }
  }

  func removeVocabulary(id: UUID) {
    vocabulary.removeAll { $0.id == id }
  }

  private func persistVocabulary() {
    guard let data = try? JSONEncoder().encode(vocabulary) else { return }
    defaults.set(data, forKey: Keys.vocabulary)
  }
}
