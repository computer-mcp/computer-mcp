import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite("Validation socket catalog configuration")
struct ValidationSocketCatalogConfigurationTests {
  @Test("OpenAI catalog inspection authenticates as the observed Secure Tunnel")
  func openAITunnelIdentity() throws {
    let socketURL = URL(fileURLWithPath: "/tmp/computer-mcp-validation/gateway.sock")
    let configuration = try ValidationSocketCatalogConfiguration.resolve(
      socketURL: socketURL,
      provenance: ValidationTransportProvenance(
        transport: .openAISecureMCPTunnel,
        tunnelInstanceID: "tunnel-instance-1",
        tunnelProfileID: "computer-mcp",
        socketConnectionID: "socket-1"
      )
    )

    #expect(configuration.socketURL == socketURL)
    #expect(
      configuration.clientIdentity
        == .secureTunnel(
          credentialFile: URL(
            fileURLWithPath: socketURL.path + ".openai-tunnel-auth"
          ),
          tunnelInstanceID: "tunnel-instance-1",
          tunnelProfileID: "computer-mcp"
        ))
  }

  @Test("OpenAI catalog inspection rejects incomplete Tunnel provenance")
  func missingOpenAITunnelProvenance() {
    #expect(throws: ValidationSocketCatalogConfigurationError.missingOpenAITunnelProvenance) {
      try ValidationSocketCatalogConfiguration.resolve(
        socketURL: URL(fileURLWithPath: "/tmp/computer-mcp-validation/gateway.sock"),
        provenance: ValidationTransportProvenance(
          transport: .openAISecureMCPTunnel,
          tunnelInstanceID: "tunnel-instance-1"
        )
      )
    }
  }

  @Test("Local catalog transports keep their explicit caller identities")
  func localIdentities() throws {
    let socketURL = URL(fileURLWithPath: "/tmp/computer-mcp-validation/gateway.sock")
    let gateway = try ValidationSocketCatalogConfiguration.resolve(
      socketURL: socketURL,
      provenance: ValidationTransportProvenance(transport: .gatewaySocket)
    )
    let control = try ValidationSocketCatalogConfiguration.resolve(
      socketURL: socketURL,
      provenance: ValidationTransportProvenance(transport: .controlSocket)
    )

    #expect(gateway.clientIdentity == .localMCP)
    #expect(control.clientIdentity == .localCLI)
  }
}
