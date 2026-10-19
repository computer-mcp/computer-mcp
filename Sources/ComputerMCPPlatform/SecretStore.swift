/// Stores user-owned secret values by reference.
package protocol SecretStore: Sendable {
  func setAsynchronously(_ secret: String, for reference: SecretReference) async throws
  /// Returns `nil` when no value exists; `.fail` reports locked or interactive items
  /// as errors instead of prompting.
  func valueAsynchronously(
    for reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) async throws -> String?
  func containsAsynchronously(
    _ reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) async throws -> Bool
  func deleteAsynchronously(_ reference: SecretReference) async throws
}
