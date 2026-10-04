import ComputerMCPPlatform
import Foundation

package typealias KeychainAdapter = ComputerMCPPlatform.KeychainAdapter
package typealias KeychainAuthenticationUI = ComputerMCPPlatform.KeychainAuthenticationUI
package typealias KeychainSecretStoreError = ComputerMCPPlatform.KeychainSecretStoreError
package typealias SecurityKeychainAdapter = ComputerMCPPlatform.SecurityKeychainAdapter

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

package struct KeychainSecretStore: Sendable {
  package let service: String
  package let accessGroup: String
  private let adapter: any KeychainAdapter
  private let operationQueue: BlockingOperationExecutor

  package init(
    service: String,
    accessGroup: String
  ) throws {
    try self.init(
      service: service,
      accessGroup: accessGroup,
      adapter: SecurityKeychainAdapter(accessGroup: accessGroup)
    )
  }

  package init(
    service: String,
    accessGroup: String,
    adapter: any KeychainAdapter
  ) throws {
    let normalized = service.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, !normalized.contains("\0") else {
      throw KeychainSecretStoreError.invalidService
    }
    let normalizedAccessGroup = accessGroup.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !normalizedAccessGroup.isEmpty,
      normalizedAccessGroup.utf8.count <= 256,
      !normalizedAccessGroup.contains("\0")
    else {
      throw KeychainSecretStoreError.invalidAccessGroup
    }
    self.service = normalized
    self.accessGroup = normalizedAccessGroup
    self.adapter = adapter
    self.operationQueue = BlockingOperationExecutor(
      label: "\(normalized).keychain"
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

  package func value(
    for reference: SecretReference,
    authenticationUI: KeychainAuthenticationUI = .allow
  ) throws -> String? {
    guard
      let data = try adapter.get(
        service: service,
        account: reference.account,
        authenticationUI: authenticationUI
      )
    else {
      return nil
    }
    guard let value = String(data: data, encoding: .utf8) else {
      throw KeychainSecretStoreError.invalidStoredSecret
    }
    return value
  }

  package func contains(
    _ reference: SecretReference,
    authenticationUI: KeychainAuthenticationUI = .fail
  ) throws -> Bool {
    try adapter.contains(
      service: service,
      account: reference.account,
      authenticationUI: authenticationUI
    )
  }

  package func delete(_ reference: SecretReference) throws {
    try adapter.delete(service: service, account: reference.account)
  }

  func setAsynchronously(_ secret: String, for reference: SecretReference) async throws {
    try await operationQueue.perform {
      try set(secret, for: reference)
    }
  }

  func valueAsynchronously(
    for reference: SecretReference,
    authenticationUI: KeychainAuthenticationUI = .allow
  ) async throws -> String? {
    try await operationQueue.perform {
      try value(for: reference, authenticationUI: authenticationUI)
    }
  }

  func containsAsynchronously(
    _ reference: SecretReference,
    authenticationUI: KeychainAuthenticationUI = .fail
  ) async throws -> Bool {
    try await operationQueue.perform {
      try contains(reference, authenticationUI: authenticationUI)
    }
  }

  func deleteAsynchronously(_ reference: SecretReference) async throws {
    try await operationQueue.perform {
      try delete(reference)
    }
  }
}
