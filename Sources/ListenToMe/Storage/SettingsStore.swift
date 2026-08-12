import Foundation

@MainActor
final class SettingsStore: ObservableObject {
  static let defaultBasePrompt = WritingGuidance.defaultBasePrompt

  @Published var showRecordingOverlay: Bool {
    didSet { defaults.set(showRecordingOverlay, forKey: Keys.showRecordingOverlay) }
  }

  /// Soft start/stop chimes when dictation begins and ends.
  @Published var playDictationSounds: Bool {
    didSet { defaults.set(playDictationSounds, forKey: Keys.playDictationSounds) }
  }

  /// Tap the shortcut → keep listening until you tap it again.
  @Published var tapStartsHandsFree: Bool {
    didSet { defaults.set(tapStartsHandsFree, forKey: Keys.tapStartsHandsFree) }
  }

  /// Hold the shortcut → speak until release (push-to-talk).
  @Published var holdIsPushToTalk: Bool {
    didSet { defaults.set(holdIsPushToTalk, forKey: Keys.holdIsPushToTalk) }
  }

  /// While holding, Space locks hands-free so you can release and keep talking.
  @Published var spaceLocksHandsFree: Bool {
    didSet { defaults.set(spaceLocksHandsFree, forKey: Keys.spaceLocksHandsFree) }
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

  /// Preferred microphones in order — first available device wins at capture time.
  /// Empty string entries mean “System Default”.
  @Published var microphonePriorityUIDs: [String] {
    didSet { defaults.set(microphonePriorityUIDs, forKey: Keys.microphonePriorityUIDs) }
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
    static let playDictationSounds = "appearance.playDictationSounds"
    static let tapStartsHandsFree = "hotkey.tapStartsHandsFree"
    static let holdIsPushToTalk = "hotkey.holdIsPushToTalk"
    static let spaceLocksHandsFree = "hotkey.spaceLocksHandsFree"
    static let basePrompt = "transcription.basePrompt"
    static let delay = "transcription.delay"
    static let languageText = "transcription.languages"
    static let vocabulary = "transcription.vocabulary"
    static let micProfile = "transcription.micProfile"
    static let microphoneDeviceUID = "audio.microphoneDeviceUID"
    static let microphonePriorityUIDs = "audio.microphonePriorityUIDs"
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
    playDictationSounds =
      defaults.object(forKey: Keys.playDictationSounds) as? Bool
      ?? true
    tapStartsHandsFree =
      defaults.object(forKey: Keys.tapStartsHandsFree) as? Bool
      ?? true
    holdIsPushToTalk =
      defaults.object(forKey: Keys.holdIsPushToTalk) as? Bool
      ?? true
    spaceLocksHandsFree =
      defaults.object(forKey: Keys.spaceLocksHandsFree) as? Bool
      ?? true
    let storedPrompt =
      defaults.string(forKey: Keys.basePrompt)
      ?? Self.defaultBasePrompt
    if WritingGuidance.isFactoryDefault(storedPrompt) {
      basePrompt = Self.defaultBasePrompt
      if storedPrompt != Self.defaultBasePrompt {
        defaults.set(Self.defaultBasePrompt, forKey: Keys.basePrompt)
      }
    } else {
      basePrompt = storedPrompt
    }
    delay =
      TranscriptionDelay(
        rawValue: defaults.string(forKey: Keys.delay) ?? ""
      ) ?? .low
    languageText = defaults.string(forKey: Keys.languageText) ?? "en"
    micProfile =
      MicProfile(
        rawValue: defaults.string(forKey: Keys.micProfile) ?? ""
      ) ?? .builtIn
    let migratedPriority: [String]
    if let stored = defaults.array(forKey: Keys.microphonePriorityUIDs) as? [String],
      !stored.isEmpty
    {
      migratedPriority = stored
    } else if let legacy = defaults.string(forKey: Keys.microphoneDeviceUID) {
      // Migrate the old single-mic setting into a priority list.
      migratedPriority =
        legacy == MicrophoneInput.systemDefaultID
        ? [MicrophoneInput.systemDefaultID]
        : [legacy, MicrophoneInput.systemDefaultID]
      defaults.set(migratedPriority, forKey: Keys.microphonePriorityUIDs)
    } else {
      migratedPriority = [MicrophoneInput.systemDefaultID]
    }
    microphonePriorityUIDs = migratedPriority

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
    hasAPIKey = apiKeys.hasStoredKey()
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

  /// First microphone in the priority list that is currently attached (or System Default).
  func preferredMicrophoneUID(
    from available: [MicrophoneInput] = MicrophoneInputCatalog.listInputs()
  ) -> String {
    let availableIDs = Set(available.map(\.id))
    for uid in microphonePriorityUIDs {
      if uid == MicrophoneInput.systemDefaultID {
        return uid
      }
      if availableIDs.contains(uid) {
        return uid
      }
    }
    return MicrophoneInput.systemDefaultID
  }

  func addMicrophoneToPriority(_ uid: String) {
    guard !microphonePriorityUIDs.contains(uid) else { return }
    // Keep System Default as the last fallback when inserting real devices.
    if uid == MicrophoneInput.systemDefaultID {
      microphonePriorityUIDs.append(uid)
      return
    }
    if let defaultIndex = microphonePriorityUIDs.firstIndex(
      of: MicrophoneInput.systemDefaultID
    ) {
      microphonePriorityUIDs.insert(uid, at: defaultIndex)
    } else {
      microphonePriorityUIDs.append(uid)
    }
  }

  func removeMicrophoneFromPriority(at index: Int) {
    guard microphonePriorityUIDs.indices.contains(index) else { return }
    microphonePriorityUIDs.remove(at: index)
    if microphonePriorityUIDs.isEmpty {
      microphonePriorityUIDs = [MicrophoneInput.systemDefaultID]
    }
  }

  func moveMicrophonePriority(from index: Int, direction: Int) {
    let target = index + direction
    guard microphonePriorityUIDs.indices.contains(index),
      microphonePriorityUIDs.indices.contains(target)
    else {
      return
    }
    microphonePriorityUIDs.swapAt(index, target)
  }

  var isUsingDefaultBasePrompt: Bool {
    WritingGuidance.isFactoryDefault(basePrompt)
  }

  func resetBasePrompt() {
    basePrompt = Self.defaultBasePrompt
  }

  func loadAPIKey() throws -> String {
    let value = try apiKeys.loadAPIKey() ?? ""
    let present = !value.isEmpty
    if hasAPIKey != present {
      hasAPIKey = present
    }
    return value
  }

  func saveAPIKey(_ value: String) throws {
    try apiKeys.saveAPIKey(value)
    hasAPIKey = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func refreshAPIKeyPresence() {
    hasAPIKey = apiKeys.hasStoredKey()
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

    let heardAs = VocabularyAliases.normalized(oftenHeardAs)
    vocabulary.append(VocabularyItem(term: normalized, oftenHeardAs: heardAs))
    vocabulary.sort {
      $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending
    }
    return true
  }

  func updateVocabulary(_ item: VocabularyItem) -> Bool {
    guard let index = vocabulary.firstIndex(where: { $0.id == item.id }),
      let normalized = VocabularyValidation.normalizedTerm(item.term)
    else {
      return false
    }
    let duplicate = vocabulary.contains {
      $0.id != item.id
        && $0.term.localizedCaseInsensitiveCompare(normalized) == .orderedSame
    }
    guard !duplicate else { return false }

    vocabulary[index].term = normalized
    vocabulary[index].oftenHeardAs = VocabularyAliases.normalized(item.oftenHeardAs)
    vocabulary.sort {
      $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending
    }
    return true
  }

  func removeVocabulary(id: UUID) {
    vocabulary.removeAll { $0.id == id }
  }

  private func persistVocabulary() {
    guard let data = try? JSONEncoder().encode(vocabulary) else { return }
    defaults.set(data, forKey: Keys.vocabulary)
  }
}
