import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPlatform
import ComputerMCPPlatformDarwin
import CryptoKit
import Foundation
import Security

enum StandalonePermissionAuthority {
  static func validateLocation(_ logicalLocation: URL) throws {
    let environment = (try? AppDistributionIdentity.bundled())?.environment ?? .production
    let directories = try AppControlPlaneServiceDirectories.standard(environment: environment)
    guard
      logicalLocation.resolvingSymlinksInPath().path
        != directories.database.resolvingSymlinksInPath().path
    else {
      throw GatewayToolError.invalidArguments(
        "The App database must be accessed through its local control socket. Use a separate --database for standalone service."
      )
    }
    try GatewayDatabase.requireStandaloneDatabase(at: logicalLocation)
  }

  static func configure(_ database: GatewayDatabase, at logicalLocation: URL) throws {
    let identity = try? AppDistributionIdentity.bundled()
    let environment = identity?.environment ?? .production
    let directories = try AppControlPlaneServiceDirectories.standard(environment: environment)
    guard
      logicalLocation.resolvingSymlinksInPath().path
        != directories.database.resolvingSymlinksInPath().path
    else {
      throw GatewayToolError.invalidArguments(
        "The App database must be accessed through its local control socket. Use a separate --database for standalone service."
      )
    }
    try database.claimPermissionComposition(.standalone)
    let keychain: any KeychainAdapter
    if let identity {
      keychain = SecurityKeychainAdapter(accessGroup: identity.keychainAccessGroup)
    } else {
      keychain = StandaloneKeychainAdapter()
    }
    let counter = try KeychainAuthorizationEpochCounter(
      keychain: keychain,
      lockDirectory: directories.runtime.appendingPathComponent("Standalone", isDirectory: true),
      service: environment.keychainService + ".permissions.standalone",
      account: namespace(for: logicalLocation))
    _ = database.permissionStore(counter: counter)
  }

  static func hostDataPaths() throws -> Set<URL> {
    let environment = (try? AppDistributionIdentity.bundled())?.environment ?? .production
    let directories = try AppControlPlaneServiceDirectories.standard(environment: environment)
    return [directories.runtime.appendingPathComponent("Standalone", isDirectory: true)]
  }

  /// The logical location remains stable when its database bytes are replaced.
  /// The watermark and its writer lock live outside the replaceable database tree.
  static func namespace(for logicalLocation: URL) -> String {
    let location = logicalLocation.standardizedFileURL.resolvingSymlinksInPath().path
    return SHA256.hash(data: Data(location.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// A standalone native executable uses the current user's login Keychain.
/// Signed App distributions use their provisioned Data Protection access group.
private struct StandaloneKeychainAdapter: KeychainAdapter {
  func set(service: String, account: String, data: Data) throws {
    try set(service: service, account: account, data: data, authenticationUI: .allow)
  }

  func set(service: String, account: String, data: Data, authenticationUI: KeychainAuthenticationUI)
    throws
  {
    let query = query(service: service, account: account, authenticationUI: authenticationUI)
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw failure(status) }
    var addition = query
    addition[kSecValueData] = data
    let added = SecItemAdd(addition as CFDictionary, nil)
    guard added == errSecSuccess else { throw failure(added) }
  }

  func get(service: String, account: String) throws -> Data? {
    try get(service: service, account: account, authenticationUI: .allow)
  }

  func get(service: String, account: String, authenticationUI: KeychainAuthenticationUI) throws
    -> Data?
  {
    var query = query(service: service, account: account, authenticationUI: authenticationUI)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
    return data
  }

  func contains(service: String, account: String) throws -> Bool {
    try get(service: service, account: account) != nil
  }

  func delete(service: String, account: String) throws {
    let status = SecItemDelete(
      query(service: service, account: account, authenticationUI: .fail) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
  }

  private func query(service: String, account: String, authenticationUI: KeychainAuthenticationUI)
    -> [CFString: Any]
  {
    [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecUseAuthenticationUI: authenticationUI == .fail
        ? kSecUseAuthenticationUIFail : kSecUseAuthenticationUIAllow,
    ]
  }

  private func failure(_ status: OSStatus) -> NSError {
    NSError(
      domain: NSOSStatusErrorDomain, code: Int(status),
      userInfo: [
        NSLocalizedDescriptionKey:
          "Standalone permission authority requires an accessible login Keychain. Unlock it and retry. Keychain status: \(status)."
      ])
  }
}
