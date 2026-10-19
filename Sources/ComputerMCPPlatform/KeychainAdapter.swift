import Foundation

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
