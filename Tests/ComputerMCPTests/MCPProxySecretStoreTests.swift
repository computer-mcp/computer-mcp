import ComputerMCPTestSupport
import Testing

@testable import ComputerMCP
@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPPlatform

struct MCPProxySecretStoreTests {
  @Test
  func injectedSecretStoreRetainsNoninteractiveAuthentication() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let store = RecordingSecretStore()
      let client = MCPProxyClient(secretStore: store)
      let endpoint = fixture.endpoint.absoluteString
      let server = MCPServerConfig(
        id: "remote", transport: .http, url: endpoint,
        authentication: .init(endpoint: endpoint, keychainAccount: "mcp.fixture"))
      await #expect(throws: (any Error).self) {
        try await BlockingOperationExecutor(label: "gateway-secret-store-test").perform {
          try client.listTools(server: server, context: .empty)
        }
      }
      await client.shutdown()
      #expect(await store.interactions == [.fail])
      #expect(try fixture.requests().isEmpty)
    }
  }
}

private actor RecordingSecretStore: SecretStore {
  private(set) var interactions: [KeychainAuthenticationUI] = []
  func setAsynchronously(_ secret: String, for reference: SecretReference) async throws {}
  func valueAsynchronously(
    for reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) async throws -> String? {
    interactions.append(authenticationUI)
    return nil
  }
  func containsAsynchronously(
    _ reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) async throws -> Bool { false }
  func deleteAsynchronously(_ reference: SecretReference) async throws {}
}
