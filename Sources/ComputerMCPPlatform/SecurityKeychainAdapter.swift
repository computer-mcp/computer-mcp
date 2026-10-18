import Foundation

#if os(macOS)
  import LocalAuthentication
  import Security

  package final class SecurityKeychainAdapter: KeychainAdapter, Sendable {
    private let accessGroup: String

    package init(accessGroup: String) {
      self.accessGroup = accessGroup
    }

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
      try get(service: service, account: account, authenticationUI: .allow)
    }

    package func get(
      service: String,
      account: String,
      authenticationUI: KeychainAuthenticationUI
    ) throws -> Data? {
      var query = baseQuery(service: service, account: account)
      apply(authenticationUI, to: &query)
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
      try contains(service: service, account: account, authenticationUI: .allow)
    }

    package func contains(
      service: String,
      account: String,
      authenticationUI: KeychainAuthenticationUI
    ) throws -> Bool {
      var query = baseQuery(service: service, account: account)
      apply(authenticationUI, to: &query)
      query[kSecMatchLimit] = kSecMatchLimitOne
      let status = SecItemCopyMatching(query as CFDictionary, nil)
      if status == errSecItemNotFound {
        return false
      }
      if authenticationUI == .fail, status == errSecInteractionNotAllowed {
        return true
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

    package func baseQuery(service: String, account: String) -> [CFString: Any] {
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecAttrAccessGroup: accessGroup,
        kSecUseDataProtectionKeychain: true,
      ]
    }

    private func apply(
      _ authenticationUI: KeychainAuthenticationUI,
      to query: inout [CFString: Any]
    ) {
      if authenticationUI == .fail {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext] = context
      }
    }
  }

#else
  package final class SecurityKeychainAdapter: KeychainAdapter, Sendable {
    package init(accessGroup: String) {}

    package func set(service: String, account: String, data: Data) throws {
      throw KeychainSecretStoreError.unsupportedPlatform
    }

    package func get(service: String, account: String) throws -> Data? {
      throw KeychainSecretStoreError.unsupportedPlatform
    }

    package func contains(service: String, account: String) throws -> Bool {
      throw KeychainSecretStoreError.unsupportedPlatform
    }

    package func delete(service: String, account: String) throws {
      throw KeychainSecretStoreError.unsupportedPlatform
    }
  }
#endif
