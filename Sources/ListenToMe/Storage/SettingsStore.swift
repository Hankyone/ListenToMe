import Foundation

@MainActor
final class SettingsStore: ObservableObject {
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
  private let keychain: KeychainStore

  private enum Keys {
    static let showRecordingOverlay = "appearance.showRecordingOverlay"
    static let basePrompt = "transcription.basePrompt"
    static let delay = "transcription.delay"
    static let languageText = "transcription.languages"
    static let vocabulary = "transcription.vocabulary"
    static let micProfile = "transcription.micProfile"
    static let hotkey = "hotkey.spec"
  }

  init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
    self.defaults = defaults
    self.keychain = keychain
    showRecordingOverlay =
      defaults.object(forKey: Keys.showRecordingOverlay) as? Bool
      ?? true
    basePrompt =
      defaults.string(forKey: Keys.basePrompt)
      ?? """
      Write natural, polished dictation. Keep the speaker's meaning, paragraph breaks, punctuation, and capitalization. Do not add ideas that were not spoken. Omit filler words such as um, uh, er, like (when filler), and you know. Prefer clean sentences. When the dictation is meant to continue typing in place, end with a single trailing space.
      """
        .trimmingCharacters(in: .whitespacesAndNewlines)
    delay =
      TranscriptionDelay(
        rawValue: defaults.string(forKey: Keys.delay) ?? ""
      ) ?? .low
    languageText = defaults.string(forKey: Keys.languageText) ?? "en"
    micProfile =
      MicProfile(
        rawValue: defaults.string(forKey: Keys.micProfile) ?? ""
      ) ?? .builtIn

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

    refreshAPIKeyStatus()
  }

  var languages: [String] {
    languageText
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
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

  func loadAPIKey() throws -> String {
    try keychain.loadAPIKey() ?? ""
  }

  func saveAPIKey(_ value: String) throws {
    try keychain.saveAPIKey(value)
    refreshAPIKeyStatus()
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

  private func refreshAPIKeyStatus() {
    hasAPIKey = ((try? keychain.loadAPIKey()) ?? nil)?.isEmpty == false
  }

  private func persistVocabulary() {
    guard let data = try? JSONEncoder().encode(vocabulary) else { return }
    defaults.set(data, forKey: Keys.vocabulary)
  }
}
