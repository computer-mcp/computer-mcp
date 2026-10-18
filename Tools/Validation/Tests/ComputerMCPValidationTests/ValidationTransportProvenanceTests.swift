import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite("Validation transport provenance")
struct ValidationTransportProvenanceTests {
  @Test("Secure Tunnel audit identity is preserved")
  func secureTunnelIdentity() throws {
    let provenance = try ValidationTransportProvenance.authenticatedGatewaySocket(
      auditEvents: [
        audit(
          caller: .secureTunnel,
          tunnelInstanceID: "tunnel-instance-1",
          tunnelProfileID: "computer-mcp"
        ),
        audit(
          requestID: "request-2",
          caller: .secureTunnel,
          tunnelInstanceID: "tunnel-instance-1",
          tunnelProfileID: "computer-mcp"
        ),
      ]
    )

    #expect(provenance.transport == .openAISecureMCPTunnel)
    #expect(provenance.socketConnectionID == "socket-1")
    #expect(provenance.tunnelInstanceID == "tunnel-instance-1")
    #expect(provenance.tunnelProfileID == "computer-mcp")
  }

  @Test("Observed Secure Tunnel execution identity is preserved")
  func observedSecureTunnelIdentity() throws {
    let provenance = try ValidationTransportProvenance.authenticatedGatewaySocket(
      caller: .secureTunnel,
      socketConnectionID: "socket-1",
      tunnelInstanceID: "tunnel-instance-1",
      tunnelProfileID: "computer-mcp"
    )

    #expect(provenance.transport == .openAISecureMCPTunnel)
    #expect(provenance.socketConnectionID == "socket-1")
    #expect(provenance.tunnelInstanceID == "tunnel-instance-1")
    #expect(provenance.tunnelProfileID == "computer-mcp")
  }

  @Test("Observed local MCP execution remains a Gateway Socket run")
  func observedLocalMCPIdentity() throws {
    let provenance = try ValidationTransportProvenance.authenticatedGatewaySocket(
      caller: .localMCP,
      socketConnectionID: "socket-1"
    )

    #expect(provenance.transport == .gatewaySocket)
    #expect(provenance.socketConnectionID == "socket-1")
    #expect(provenance.tunnelInstanceID == nil)
    #expect(provenance.tunnelProfileID == nil)
  }

  @Test("Local MCP audit identity remains a Gateway Socket run")
  func localMCPIdentity() throws {
    let provenance = try ValidationTransportProvenance.authenticatedGatewaySocket(
      auditEvents: [audit(caller: .localMCP)]
    )

    #expect(provenance.transport == .gatewaySocket)
    #expect(provenance.socketConnectionID == "socket-1")
    #expect(provenance.tunnelInstanceID == nil)
    #expect(provenance.tunnelProfileID == nil)
  }

  @Test("Mixed callers are rejected")
  func mixedCallers() {
    expectThrows(
      try ValidationTransportProvenance.authenticatedGatewaySocket(
        auditEvents: [
          audit(caller: .localMCP),
          audit(
            requestID: "request-2",
            caller: .secureTunnel,
            tunnelInstanceID: "tunnel-instance-1",
            tunnelProfileID: "computer-mcp"
          ),
        ]
      )
    ) { error in
      #expect(error as? ValidationTransportProvenanceError == .mixedCallerKinds)
    }
  }

  @Test("Incomplete Secure Tunnel identity is rejected")
  func incompleteSecureTunnelIdentity() {
    expectThrows(
      try ValidationTransportProvenance.authenticatedGatewaySocket(
        auditEvents: [
          audit(
            caller: .secureTunnel,
            tunnelInstanceID: "tunnel-instance-1",
            tunnelProfileID: nil
          )
        ]
      )
    ) { error in
      #expect(
        error as? ValidationTransportProvenanceError == .incompleteSecureTunnelIdentity
      )
    }
  }

  private func audit(
    requestID: String = "request-1",
    caller: GatewayCallerKind,
    tunnelInstanceID: String? = nil,
    tunnelProfileID: String? = nil
  ) -> AuditEvent {
    AuditEvent(
      requestID: requestID,
      caller: caller,
      transport: "gateway_socket",
      socketConnectionID: "socket-1",
      tunnelInstanceID: tunnelInstanceID,
      tunnelProfileID: tunnelProfileID,
      profileID: .chatGPTOperate,
      capabilityID: "system.time",
      decision: .allowed
    )
  }
}
