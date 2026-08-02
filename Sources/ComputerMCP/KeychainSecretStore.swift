import Foundation
import Security

package struct SecretReference: Codable, Equatable, Hashable, Sendable {
  package var account: String

  package init(account: String) throws {
    let normalized = account.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.utf8.count <= 256, !normalized.contains("\0") else {
      throw KeychainSecretStoreError.invalidReference
    }
    self.account = normalized
  }
}

package protocol KeychainAdapter: Sendable {
  func set(service: String, account: String, data: Data) throws
  func get(service: String, account: String) throws -> Data?
  func contains(service: String, account: String) throws -> Bool
  func delete(service: String, account: String) throws
}

extension KeychainAdapter {
  package func contains(service: String, account: String) throws -> Bool {
    try get(service: service, account: account) != nil
  }
}

package struct KeychainSecretStore: Sendable {
  package let service: String
  private let adapter: any KeychainAdapter
  private let operationQueue: BlockingOperationExecutor

  package init(
    service: String = "com.showxu.computer-mcp",
    adapter: any KeychainAdapter = SecurityKeychainAdapter()
  ) throws {
    let normalized = service.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, !normalized.contains("\0") else {
      throw KeychainSecretStoreError.invalidService
    }
    self.service = normalized
    self.adapter = adapter
    self.operationQueue = BlockingOperationExecutor(
      label: "com.showxu.computer-mcp.keychain"
    )
  }

  package func set(_ secret: String, for reference: SecretReference) throws {
    guard !secret.isEmpty, !secret.contains("\0") else {
      throw KeychainSecretStoreError.invalidSecret
    }
    try adapter.set(
      service: service,
      account: reference.account,
      data: Data(secret.utf8)
    )
  }

  package func value(for reference: SecretReference) throws -> String? {
    guard let data = try adapter.get(service: service, account: reference.account) else {
      return nil
    }
    guard let value = String(data: data, encoding: .utf8) else {
      throw KeychainSecretStoreError.invalidStoredSecret
    }
    return value
  }

  package func contains(_ reference: SecretReference) throws -> Bool {
    try adapter.contains(service: service, account: reference.account)
  }

  package func delete(_ reference: SecretReference) throws {
    try adapter.delete(service: service, account: reference.account)
  }

  func setAsynchronously(_ secret: String, for reference: SecretReference) async throws {
    try await operationQueue.perform {
      try set(secret, for: reference)
    }
  }

  func valueAsynchronously(for reference: SecretReference) async throws -> String? {
    try await operationQueue.perform {
      try value(for: reference)
    }
  }

  func containsAsynchronously(_ reference: SecretReference) async throws -> Bool {
    try await operationQueue.perform {
      try contains(reference)
    }
  }

  func deleteAsynchronously(_ reference: SecretReference) async throws {
    try await operationQueue.perform {
      try delete(reference)
    }
  }
}

package final class SecurityKeychainAdapter: KeychainAdapter, @unchecked Sendable {
  package init() {}

  package func set(service: String, account: String, data: Data) throws {
    let query = baseQuery(service: service, account: account)
    let update = [kSecValueData: data] as CFDictionary
    let updateStatus = SecItemUpdate(query as CFDictionary, update)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainSecretStoreError.securityStatus(updateStatus)
    }

    var insertion = query
    insertion[kSecValueData] = data
    insertion[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(insertion as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainSecretStoreError.securityStatus(addStatus)
    }
  }

  package func get(service: String, account: String) throws -> Data? {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      throw KeychainSecretStoreError.securityStatus(status)
    }
    return data
  }

  package func contains(service: String, account: String) throws -> Bool {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnAttributes] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    if status == errSecItemNotFound {
      return false
    }
    guard status == errSecSuccess else {
      throw KeychainSecretStoreError.securityStatus(status)
    }
    return true
  }

  package func delete(service: String, account: String) throws {
    let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainSecretStoreError.securityStatus(status)
    }
  }

  private func baseQuery(service: String, account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }
}

package enum KeychainSecretStoreError: Error, LocalizedError, Equatable {
  case invalidService
  case invalidReference
  case invalidSecret
  case invalidStoredSecret
  case securityStatus(OSStatus)

  package var errorDescription: String? {
    switch self {
    case .invalidService:
      return "The Keychain service identifier is invalid."
    case .invalidReference:
      return "The Keychain secret reference is invalid."
    case .invalidSecret:
      return "The secret must be non-empty and must not contain NUL."
    case .invalidStoredSecret:
      return "The stored Keychain secret is not valid UTF-8."
    case .securityStatus(let status):
      let detail = SecCopyErrorMessageString(status, nil) as String?
      return "Keychain operation failed with status \(status)\(detail.map { ": \($0)" } ?? ".")"
    }
  }
}
