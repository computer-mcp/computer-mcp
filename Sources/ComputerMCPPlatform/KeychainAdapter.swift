import Foundation

#if os(macOS)
  import Security
#endif

package enum KeychainAuthenticationUI: Equatable, Sendable {
  case allow
  case fail
}

package protocol KeychainAdapter: Sendable {
  func set(service: String, account: String, data: Data) throws
  func get(service: String, account: String) throws -> Data?
  func get(
    service: String,
    account: String,
    authenticationUI: KeychainAuthenticationUI
  ) throws -> Data?
  func contains(service: String, account: String) throws -> Bool
  func contains(
    service: String,
    account: String,
    authenticationUI: KeychainAuthenticationUI
  ) throws -> Bool
  func delete(service: String, account: String) throws
}

extension KeychainAdapter {
  package func get(
    service: String,
    account: String,
    authenticationUI: KeychainAuthenticationUI
  ) throws -> Data? {
    try get(service: service, account: account)
  }

  package func contains(service: String, account: String) throws -> Bool {
    try get(service: service, account: account) != nil
  }

  package func contains(
    service: String,
    account: String,
    authenticationUI: KeychainAuthenticationUI
  ) throws -> Bool {
    try contains(service: service, account: account)
  }
}

package enum KeychainSecretStoreError: Error, LocalizedError, Equatable {
  case invalidService
  case invalidAccessGroup
  case invalidReference
  case invalidSecret
  case invalidStoredSecret
  case securityStatus(Int32)
  case unsupportedPlatform

  package var errorDescription: String? {
    switch self {
    case .invalidService:
      return "The Keychain service identifier is invalid."
    case .invalidAccessGroup:
      return "The Keychain access group identifier is invalid."
    case .invalidReference:
      return "The Keychain secret reference is invalid."
    case .invalidSecret:
      return "The secret must be non-empty and must not contain NUL."
    case .invalidStoredSecret:
      return "The stored Keychain secret is not valid UTF-8."
    case .unsupportedPlatform:
      return "Data Protection Keychain is unavailable on this platform."
    case .securityStatus(let status):
      #if os(macOS)
        let detail = SecCopyErrorMessageString(status, nil) as String?
      #else
        let detail: String? = nil
      #endif
      return "Keychain operation failed with status \(status)\(detail.map { ": \($0)" } ?? ".")"
    }
  }
}
