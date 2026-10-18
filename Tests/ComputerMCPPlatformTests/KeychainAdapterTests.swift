#if os(Windows)
  import Foundation
  import Testing

  @testable import ComputerMCPPlatform

  @Suite
  struct KeychainAdapterTests {
    @Test
    func dataProtectionKeychainOperationsReportUnsupported() {
      let adapter = SecurityKeychainAdapter(accessGroup: "test-group")
      #expect(throws: KeychainSecretStoreError.unsupportedPlatform) {
        try adapter.set(service: "test-service", account: "test-account", data: Data([1]))
      }
      #expect(throws: KeychainSecretStoreError.unsupportedPlatform) {
        try adapter.get(service: "test-service", account: "test-account")
      }
      #expect(throws: KeychainSecretStoreError.unsupportedPlatform) {
        try adapter.contains(service: "test-service", account: "test-account")
      }
      for interaction in [KeychainAuthenticationUI.allow, .fail] {
        #expect(throws: KeychainSecretStoreError.unsupportedPlatform) {
          try adapter.get(
            service: "test-service", account: "test-account", authenticationUI: interaction)
        }
        #expect(throws: KeychainSecretStoreError.unsupportedPlatform) {
          try adapter.contains(
            service: "test-service", account: "test-account", authenticationUI: interaction)
        }
      }
      #expect(throws: KeychainSecretStoreError.unsupportedPlatform) {
        try adapter.delete(service: "test-service", account: "test-account")
      }
    }
  }
#endif
