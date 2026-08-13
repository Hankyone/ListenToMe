import AppKit
import Foundation

@MainActor
final class HistoryStore: ObservableObject {
  /// Recordings older than this are removed on launch.
  nonisolated static let retentionDays = 30

  @Published private(set) var entries: [HistoryEntry] = []

  let rootURL: URL
  let recordingsURL: URL
  private let indexURL: URL

  init(rootURL: URL? = nil) {
    let resolvedRoot: URL
    if let rootURL {
      resolvedRoot = rootURL
    } else {
      let base = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first!
      resolvedRoot = base.appendingPathComponent("ListenToMe", isDirectory: true)
    }

    self.rootURL = resolvedRoot
    recordingsURL = resolvedRoot.appendingPathComponent("Recordings", isDirectory: true)
    indexURL = resolvedRoot.appendingPathComponent("history.json")

    do {
      try FileManager.default.createDirectory(
        at: recordingsURL,
        withIntermediateDirectories: true
      )
      load()
      purgeExpired()
    } catch {
      entries = []
    }
  }

  func newRecordingURL() throws -> URL {
    try FileManager.default.createDirectory(
      at: recordingsURL,
      withIntermediateDirectories: true
    )
    return
      recordingsURL
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("caf")
  }

  func add(_ entry: HistoryEntry) {
    entries.insert(entry, at: 0)
    persist()
  }

  /// Drops entries older than ``retentionDays`` and trashes their audio.
  @discardableResult
  func purgeExpired(
    olderThanDays days: Int = HistoryStore.retentionDays,
    now: Date = Date()
  ) -> Int {
    let cutoff = now.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)
    let expired = entries.filter { $0.createdAt < cutoff }
    guard !expired.isEmpty else { return 0 }

    for entry in expired {
      let audioURL = audioURL(for: entry)
      if FileManager.default.fileExists(atPath: audioURL.path) {
        _ = try? FileManager.default.trashItem(
          at: audioURL,
          resultingItemURL: nil
        )
      }
    }
    let expiredIDs = Set(expired.map(\.id))
    entries.removeAll { expiredIDs.contains($0.id) }
    persist()
    return expired.count
  }

  func updateTranscript(id: UUID, transcript: String) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].transcript = transcript
    persist()
  }

  func remove(id: UUID) {
    guard let entry = entries.first(where: { $0.id == id }) else { return }
    let audioURL = audioURL(for: entry)
    if FileManager.default.fileExists(atPath: audioURL.path) {
      _ = try? FileManager.default.trashItem(at: audioURL, resultingItemURL: nil)
    }
    entries.removeAll { $0.id == id }
    persist()
  }

  func entry(id: UUID?) -> HistoryEntry? {
    guard let id else { return nil }
    return entries.first { $0.id == id }
  }

  func audioURL(for entry: HistoryEntry) -> URL {
    recordingsURL.appendingPathComponent(entry.audioFileName)
  }

  /// CAF header plus a trivial amount of PCM  -  anything smaller is an empty take.
  static let minimumPreservableAudioBytes: Int64 = 4_096

  static func hasPreservableAudio(at url: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let size =
      (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
        as? NSNumber)?.int64Value ?? 0
    return size > minimumPreservableAudioBytes
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: indexURL.path),
      let data = try? Data(contentsOf: indexURL),
      let decoded = try? JSONDecoder.historyDecoder.decode(
        [HistoryEntry].self,
        from: data
      )
    else {
      entries = []
      return
    }
    entries = decoded.sorted { $0.createdAt > $1.createdAt }
  }

  private func persist() {
    do {
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: true
      )
      let data = try JSONEncoder.historyEncoder.encode(entries)
      try data.write(to: indexURL, options: .atomic)
    } catch {
      NSSound.beep()
    }
  }
}

extension JSONEncoder {
  fileprivate static var historyEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var historyDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
