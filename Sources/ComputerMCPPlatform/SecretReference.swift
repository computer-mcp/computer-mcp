import Foundation

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
