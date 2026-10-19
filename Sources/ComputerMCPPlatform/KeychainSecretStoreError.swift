import Foundation

package enum KeychainSecretStoreError: Error, LocalizedError, Equatable {
  case invalidService
  case invalidAccessGroup
  case invalidReference
  case invalidSecret
  case invalidStoredSecret
  case securityStatus(Int32, message: String?)

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
    case .securityStatus(let status, let message):
      return "Keychain operation failed with status \(status)\(message.map { ": \($0)" } ?? ".")"
    }
  }
}
