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
    // Replace any prior item (including ones created by an older signing
    // identity) so Keychain does not keep an ACL that prompts for a password.
    try deleteAPIKey()

    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: data,
    ]
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
    // Stale items from an older signing identity (e.g. local ad-hoc builds)
    // can fail auth against the released app. Treat that as "no key".
    if status == errSecAuthFailed
      || status == errSecInteractionNotAllowed
      || status == errSecUserCanceled
    {
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
