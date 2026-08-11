import Foundation
import Testing

@testable import ComputerMCP

@Suite
final class ProductReadinessTests {
  private let startedAt = Date(timeIntervalSince1970: 2_000)

  @Test
  func testLocalJourneyTransitionsFromBlockedToReadyAndVerified() {
    var input = baseInput()
    input.cliInstallation = nil

    let blocked = ProductReadinessEvaluator.evaluate(journey: .local, input: input)
    #expect(blocked.status == .blocked)
    #expect(blocked.nextAction?.redactedTarget == "home")

    input.cliInstallation = installedCLI()
    let ready = ProductReadinessEvaluator.evaluate(journey: .local, input: input)
    #expect(ready.status == .ready)
    #expect(ready.checks.first?.id == "app.control_socket")

    input.auditEvents = [
      AuditEvent(
        occurredAt: startedAt.addingTimeInterval(1),
        requestID: "local-request",
        caller: .localMCP,
        profileID: .localAdmin,
        capabilityID: "system.time",
        decision: .allowed
      )
    ]
    let verified = ProductReadinessEvaluator.evaluate(journey: .local, input: input)
    #expect(verified.status == .verified)
    #expect(verified.verifiedRequest?.requestID == "local-request")
  }

  @Test
  func testChatGPTVerificationRequiresCurrentMatchingTunnelIdentity() {
    var input = baseInput()
    input.openAITunnels = [readyOpenAITunnel()]
    input.auditEvents = [
      AuditEvent(
        occurredAt: startedAt.addingTimeInterval(-1),
        requestID: "stale",
        caller: .secureTunnel,
        tunnelInstanceID: "chatgpt",
        tunnelProfileID: "computer-mcp",
        profileID: .chatGPTObserve,
        capabilityID: "system.time",
        decision: .allowed
      ),
      AuditEvent(
        occurredAt: startedAt.addingTimeInterval(2),
        requestID: "wrong-profile",
        caller: .secureTunnel,
        tunnelInstanceID: "chatgpt",
        tunnelProfileID: "other-profile",
        profileID: .chatGPTObserve,
        capabilityID: "system.time",
        decision: .allowed
      ),
    ]

    let ready = ProductReadinessEvaluator.evaluate(journey: .chatgpt, input: input)
    #expect(ready.status == .ready)
    #expect(ready.verifiedRequest == nil)

    input.auditEvents.append(
      AuditEvent(
        occurredAt: startedAt.addingTimeInterval(3),
        requestID: "verified-chatgpt",
        caller: .secureTunnel,
        tunnelInstanceID: "chatgpt",
        tunnelProfileID: "computer-mcp",
        profileID: .chatGPTObserve,
        capabilityID: "system.time",
        decision: .allowed
      )
    )
    let verified = ProductReadinessEvaluator.evaluate(journey: .chatgpt, input: input)
    #expect(verified.status == .verified)
    #expect(verified.verifiedRequest?.requestID == "verified-chatgpt")
  }

  @Test
  func testCloudflareRevocationImmediatelyDropsReadiness() throws {
    var input = baseInput()
    input.gateway.profileID = .cloudflareObserve
    input.cloudflareTunnels = [try readyCloudflareTunnel(accessTokenPresent: true)]
    input.auditEvents = [
      AuditEvent(
        occurredAt: startedAt.addingTimeInterval(1),
        requestID: "verified-cloudflare",
        caller: .cloudflareTunnel,
        tunnelInstanceID: "cloudflare",
        tunnelProfileID: "production",
        profileID: .cloudflareObserve,
        capabilityID: "system.time",
        decision: .allowed
      )
    ]

    let verified = ProductReadinessEvaluator.evaluate(journey: .cloudflare, input: input)
    #expect(verified.status == .verified)

    input.cloudflareTunnels = [try readyCloudflareTunnel(accessTokenPresent: false)]
    let revoked = ProductReadinessEvaluator.evaluate(journey: .cloudflare, input: input)
    #expect(revoked.status == .blocked)
    #expect(revoked.verifiedRequest == nil)
  }

  @Test
  func testNotConfiguredAndJSONSchemaRemainStableAndRedacted() throws {
    let snapshot = ProductReadinessEvaluator.evaluate(
      journey: .chatgpt,
      input: baseInput()
    )
    #expect(snapshot.status == .notConfigured)
    #expect(snapshot.schemaVersion == 1)

    let data = try JSONEncoder().encode(snapshot)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["schema_version"] as? Int == 1)
    #expect(object["generated_at"] != nil)
    #expect(object["journey"] as? String == "chatgpt")
    let checks = try #require(object["checks"] as? [[String: Any]])
    let firstCheck = try #require(checks.first)
    #expect(Set(firstCheck.keys) == ["id", "status", "required", "summary", "detail"])
    #expect(String(decoding: data, as: UTF8.self).contains("secret") == false)
  }

  private func baseInput() -> ProductReadinessInput {
    ProductReadinessInput(
      generatedAt: startedAt.addingTimeInterval(10),
      gateway: AppGatewayServiceSnapshot(
        state: .running,
        profileID: .localAdmin,
        socketPath: "/private/tmp/computer-mcp.sock",
        processIdentifier: 123,
        startedAt: startedAt,
        connectionCount: 0,
        lastError: nil
      ),
      cliInstallation: installedCLI(),
      workspaceCount: 1,
      openAITunnels: [],
      cloudflareTunnels: [],
      auditEvents: []
    )
  }

  private func installedCLI() -> EmbeddedCLIInstallationStatus {
    EmbeddedCLIInstallationStatus(
      state: .installed,
      destination: "/Users/example/.local/bin/computer-mcp",
      target: "/Applications/Computer MCP.app/Contents/Resources/computer-mcp",
      destinationDirectoryIsOnPath: true
    )
  }

  private func readyOpenAITunnel() -> OpenAITunnelReadinessInput {
    OpenAITunnelReadinessInput(
      configuration: OpenAITunnelConfiguration(
        id: "chatgpt",
        tunnelClientProfile: "computer-mcp",
        tunnelID: "tunnel-id",
        gatewayProfile: .chatGPTObserve,
        manifestPath: "/Applications/Computer MCP.app/manifest.json",
        gatewayExecutablePath: "/Applications/Computer MCP.app/Contents/Resources/computer-mcp"
      ),
      status: OpenAITunnelStatus(
        profileID: "chatgpt",
        state: .running,
        sessionID: "session",
        processID: 124,
        startedAt: startedAt
      ),
      dependencyAvailable: true,
      credentialReady: true
    )
  }

  private func readyCloudflareTunnel(
    accessTokenPresent: Bool
  ) throws -> CloudflareTunnelReadinessInput {
    CloudflareTunnelReadinessInput(
      configuration: CloudflareTunnelConfiguration(
        id: "cloudflare",
        tunnelName: "production",
        publicHostname: "mcp.example.com",
        gatewayProfile: .cloudflareObserve,
        tunnelTokenReference: try SecretReference(
          account: "cloudflare.cloudflare.tunnel-token"
        ),
        accessTokenReference: try SecretReference(
          account: "cloudflare.cloudflare.access-token"
        )
      ),
      status: CloudflareTunnelStatus(
        profileID: "cloudflare",
        state: .running,
        processID: 125,
        originURL: "http://127.0.0.1:8765/mcp",
        publicURL: "https://mcp.example.com/mcp",
        metricsURL: "http://127.0.0.1:20241/metrics",
        startedAt: startedAt,
        lastError: nil
      ),
      dependencyAvailable: true,
      tunnelTokenPresent: true,
      accessTokenPresent: accessTokenPresent
    )
  }
}
