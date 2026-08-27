import Foundation

/// Stores provider API keys in ListenToMe's Application Support folder.
struct APIKeyStore {
  enum StoreError: LocalizedError {
    case unreadable
    case unwritable(String)

    var errorDescription: String? {
      switch self {
      case .unreadable:
        "The saved API key could not be read."
      case .unwritable(let detail):
        "The API key could not be saved. \(detail)"
      }
    }
  }

  private let fileManager: FileManager
  private let rootURL: URL?

  init(
    fileManager: FileManager = .default,
    rootURL: URL? = nil
  ) {
    self.fileManager = fileManager
    self.rootURL = rootURL
  }

  func saveAPIKey(_ value: String, for provider: TranscriptionProvider = .openAI) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      try deleteAPIKey(for: provider)
      return
    }

    let url = try fileURL(for: provider)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    do {
      try Data(trimmed.utf8).write(to: url, options: [.atomic])
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path
      )
    } catch {
      throw StoreError.unwritable(error.localizedDescription)
    }
  }

  /// Whether a key file exists  -  does not read the secret.
  func hasStoredKey(for provider: TranscriptionProvider = .openAI) -> Bool {
    guard let url = try? fileURL(for: provider) else { return false }
    return fileManager.fileExists(atPath: url.path)
  }

  func loadAPIKey(for provider: TranscriptionProvider = .openAI) throws -> String? {
    let url = try fileURL(for: provider)
    guard fileManager.fileExists(atPath: url.path) else {
      return nil
    }
    do {
      let data = try Data(contentsOf: url)
      guard let value = String(data: data, encoding: .utf8) else {
        throw StoreError.unreadable
      }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    } catch let error as StoreError {
      throw error
    } catch {
      throw StoreError.unreadable
    }
  }

  func deleteAPIKey(for provider: TranscriptionProvider = .openAI) throws {
    let url = try fileURL(for: provider)
    guard fileManager.fileExists(atPath: url.path) else { return }
    _ = try fileManager.trashItem(at: url, resultingItemURL: nil)
  }

  private func fileURL(for provider: TranscriptionProvider) throws -> URL {
    if let rootURL {
      return rootURL.appendingPathComponent(provider.keyFileName, isDirectory: false)
    }
    guard
      let root = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw StoreError.unwritable("Application Support is unavailable.")
    }
    return
      root
      .appendingPathComponent("ca.hankyone.ListenToMe", isDirectory: true)
      .appendingPathComponent(provider.keyFileName, isDirectory: false)
  }
}
