import Foundation
import Security

struct KeychainStore {
  enum KeychainError: LocalizedError {
    case unhandledStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
      switch self {
      case .unhandledStatus(let status):
        "macOS Keychain returned error \(status)."
      case .invalidData:
        "The saved API key could not be read."
      }
    }
  }

  private let service = "ca.hankyone.ListenToMe"
  private let account = "openai-api-key"

  func saveAPIKey(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      try deleteAPIKey()
      return
    }

    let data = Data(trimmed.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]

    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )

    if updateStatus == errSecSuccess {
      return
    }

    guard updateStatus == errSecItemNotFound else {
      throw KeychainError.unhandledStatus(updateStatus)
    }

    var addQuery = query
    addQuery[kSecValueData as String] = data
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError.unhandledStatus(addStatus)
    }
  }

  func loadAPIKey() throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainError.unhandledStatus(status)
    }
    guard let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      throw KeychainError.invalidData
    }
    return value
  }

  func deleteAPIKey() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unhandledStatus(status)
    }
  }
}
