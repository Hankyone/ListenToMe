import Foundation

/// Stores the OpenAI API key in ListenToMe's Application Support folder.
/// The only way a key appears here is the user pasting it in Setup.
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

  private let fileName = "openai-api-key"
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func saveAPIKey(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      try deleteAPIKey()
      return
    }

    let url = try fileURL()
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

  /// Whether a key file exists — does not read the secret.
  func hasStoredKey() -> Bool {
    guard let url = try? fileURL() else { return false }
    return fileManager.fileExists(atPath: url.path)
  }

  func loadAPIKey() throws -> String? {
    let url = try fileURL()
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

  func deleteAPIKey() throws {
    let url = try fileURL()
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  private func fileURL() throws -> URL {
    guard
      let root = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw StoreError.unwritable("Application Support is unavailable.")
    }
    return root
      .appendingPathComponent("ca.hankyone.ListenToMe", isDirectory: true)
      .appendingPathComponent(fileName, isDirectory: false)
  }
}
