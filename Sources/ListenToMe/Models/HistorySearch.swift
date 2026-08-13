import Foundation

enum HistorySearch {
  static func matching(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return entries }
    return entries.filter { entry in
      entry.transcript.localizedCaseInsensitiveContains(needle)
    }
  }
}
