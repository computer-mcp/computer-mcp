import Foundation
import Testing
import os

@testable import ComputerMCP

struct MCPRiskFloorTests {
  @Test
  func hostActionsEnforceTheirOwnRiskFloorAndRejectUnknownDeclarations() throws {
    for (action, risk) in [
      ("diagnostics.snapshot", CapabilityRisk.readOnly),
      ("workspaces.provision", .workspaceWrite), ("workspaces.remove", .destructive),
    ] {
      let tool = MCPTool(
        name: "fixture", description: "Fixture", inputSchema: .object([:]),
        meta: .object([
          "io.github.computer-mcp/risk": .string("read-only"),
          "io.github.computer-mcp/host-action": .string(action),
        ]))
      #expect(try tool.declaredRiskFloor == risk)
    }
    for value in [JSONValue.null, .bool(true), .object([:]), .string("workspace.admin")] {
      let tool = MCPTool(
        name: "fixture", description: "Fixture", inputSchema: .object([:]),
        meta: .object(["io.github.computer-mcp/host-action": value]))
      #expect(throws: (any Error).self) { try tool.declaredRiskFloor }
    }
  }

  @Test(arguments: ["sync", "async", "detached"])
  func sameRiskHostActionChangeCannotFollowAdmission(path: String) async throws {
    let fixture = try RiskFixture(fullAccess: true, risk: .string("workspace-write"))
    defer { fixture.remove() }
    fixture.client.setAction(.string("workspaces.provision"))
    fixture.client.changeActionAfterNextDiscovery(.string("diagnostics.snapshot"))
    var args = arguments(for: "mcp.tools.call").objectValue!
    args["wait_for_result"] = .bool(path != "detached")
    args["request_id"] = .string("semantic-request")
    do {
      if path == "sync" {
        _ = try fixture.runtime.callTool(name: "mcp.tools.call", arguments: .object(args))
      } else {
        _ = try await fixture.runtime.callToolAsync(
          name: "mcp.tools.call", arguments: .object(args))
      }
      Issue.record("An action changed after host admission reached the downstream provider.")
    } catch {
      #expect(error.localizedDescription.contains("mcp.host_action_changed"), "\(error)")
    }
    #expect(fixture.client.calls == 0)
    await fixture.runtime.shutdown()
  }

  @Test
  func sameRiskHostActionChangeInvalidatesPreparedTicket() async throws {
    let fixture = try RiskFixture(fullAccess: true, risk: .string("workspace-write"))
    defer { fixture.remove() }
    fixture.client.setAction(.string("workspaces.provision"))
    let prepared = try fixture.runtime.callTool(
      name: "operations.prepare",
      arguments: .object([
        "tool": .string("mcp.tools.call"), "arguments": arguments(for: "mcp.tools.call"),
      ]))
    let ticket = try #require(
      prepared.objectValue?["structuredContent"]?.objectValue?["result"]?
        .objectValue?["ticket_id"]?.stringValue)
    #expect(try fixture.database.operationTicket(id: ticket)?.state == .prepared)
    fixture.client.setAction(.string("diagnostics.snapshot"))
    do {
      _ = try await fixture.runtime.callToolAsync(
        name: "operations.commit",
        arguments: .object([
          "ticket_id": .string(ticket), "tool": .string("mcp.tools.call"),
          "arguments": arguments(for: "mcp.tools.call"),
        ]))
      Issue.record("An unchanged risk must not let an approval change its semantic action.")
    } catch {
      #expect(error.localizedDescription.contains("operations.ticket_arguments_mismatch"))
    }
    #expect(try fixture.database.operationTicket(id: ticket)?.state == .prepared)
    #expect(fixture.client.calls == 0)
    await fixture.runtime.shutdown()
  }

  @Test(arguments: [false, true])
  func consumedTicketCannotChangeActionBeforeTargetAdmission(asynchronous: Bool) async throws {
    let fixture = try RiskFixture(fullAccess: true, risk: .string("workspace-write"))
    defer { fixture.remove() }
    fixture.client.setAction(.string("workspaces.provision"))
    let prepared = try fixture.runtime.callTool(
      name: "operations.prepare",
      arguments: .object([
        "tool": .string("mcp.tools.call"), "arguments": arguments(for: "mcp.tools.call"),
      ]))
    let ticket = try #require(
      prepared.objectValue?["structuredContent"]?.objectValue?["result"]?
        .objectValue?["ticket_id"]?.stringValue)
    fixture.client.changeActionAfterNextDiscovery(.string("diagnostics.snapshot"))
    let args = JSONValue.object([
      "ticket_id": .string(ticket), "tool": .string("mcp.tools.call"),
      "arguments": arguments(for: "mcp.tools.call"),
    ])
    do {
      if asynchronous {
        _ = try await fixture.runtime.callToolAsync(name: "operations.commit", arguments: args)
      } else {
        _ = try fixture.runtime.callTool(name: "operations.commit", arguments: args)
      }
      Issue.record("A consumed ticket changed its reviewed action before target admission.")
    } catch {
      #expect(error.localizedDescription.contains("operations.ticket_arguments_mismatch"))
    }
    #expect(fixture.client.calls == 0)
    #expect(try fixture.database.operationTicket(id: ticket)?.state == .failed)
    await fixture.runtime.shutdown()
  }

  @Test
  func pendingReceiptReadsUseCurrentGrantWithoutProviderDiscovery() throws {
    let server = MCPServerConfig(
      id: "vendor", transport: .stdio, command: "/bin/cat", allowAnyTool: true,
      toolRisks: ["inspect": .readOnly])
    let configuration = GatewayConfiguration(mcp: .init(servers: [server]))
    func policy(tools: Bool) -> MCPToolAccessPolicy {
      .init(
        configuration: configuration,
        grant: .init(
          id: .chatGPTOperate,
          capabilityIDs: tools ? ["mcp.requests.read", "mcp.tools.call"] : ["mcp.requests.read"],
          allowedCallers: [.secureTunnel], mode: .workspaceOperations),
        derivesObserveGrant: false)
    }
    let current = OSAllocatedUnfairLock(initialState: policy(tools: true))
    let base = RiskCatalogClient(risk: .string("read-only"))
    base.suspendDiscovery()
    let client = AuthorizedMCPClient(
      base: base, policy: policy(tools: true), policyProvider: { current.withLock { $0 } })
    let receipt = try client.readRequest(
      server: server, requestID: "pending", offset: 0, maxBytes: 1024)
    #expect(receipt.objectValue?["tool"] == .string("inspect"))
    let revoked = policy(tools: false)
    current.withLock { $0 = revoked }
    do {
      _ = try client.readRequest(server: server, requestID: "pending", offset: 0, maxBytes: 1024)
      Issue.record("A revoked tool grant must deny its execution receipt.")
    } catch {
      #expect(error.localizedDescription.contains("policy.capability_denied"))
    }
  }

  @Test
  func metadataCannotLowerHostPolicyAndInvalidDeclarationsFailClosed() throws {
    let reference = MCPToolReference(serverID: "vendor", toolName: "inspect")
    let configuration = GatewayConfiguration(
      mcp: .init(servers: [
        .init(
          id: "vendor", transport: .stdio, command: "/bin/cat", allowAnyTool: true,
          toolRisks: ["inspect": .destructive])
      ]))
    func tool(_ meta: JSONValue?) -> MCPTool {
      .init(name: "inspect", description: "Fixture", inputSchema: .object([:]), meta: meta)
    }
    #expect(try configuration.mcpRisk(for: reference, declaredBy: tool(nil)) == .destructive)
    #expect(
      try configuration.mcpRisk(
        for: reference, declaredBy: tool(.object(["unrelated": .bool(true)]))) == .destructive)
    #expect(
      try configuration.mcpRisk(
        for: reference,
        declaredBy: tool(.object(["io.github.computer-mcp/risk": .string("read-only")])))
        == .destructive)
    #expect(
      try configuration.mcpRisk(
        for: reference,
        declaredBy: tool(.object(["io.github.computer-mcp/risk": .string("full-shell")])))
        == .fullShell)
    for value in [JSONValue.null, .bool(false), .integer(0), .string("unknown"), .object([:])] {
      #expect(throws: (any Error).self) {
        try configuration.mcpRisk(
          for: reference, declaredBy: tool(.object(["io.github.computer-mcp/risk": value])))
      }
    }
    #expect(throws: (any Error).self) {
      try configuration.mcpRisk(for: reference, declaredBy: tool(.string("malformed metadata")))
    }
  }

  @Test(arguments: ["mcp.tools.call", "vendor.inspect", "review.inspect"])
  func publisherRiskCannotBeDowngradedByConfiguration(tool: String) async throws {
    let fixture = try RiskFixture(fullAccess: false, risk: .string("full-shell"))
    defer { fixture.remove() }
    do {
      #expect(
        try !fixture.runtime.listTools().contains {
          $0.name == "vendor.inspect" || $0.name == "review.inspect"
        })
      await #expect(throws: (any Error).self) {
        try await fixture.runtime.callToolAsync(name: tool, arguments: arguments(for: tool))
      }
      #expect(fixture.client.calls == 0)
      await fixture.runtime.shutdown()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: ["mcp.tools.call", "vendor.inspect", "review.inspect"])
  func declaredRiskRequiresConsentAndApprovedExecutionStillWorks(tool: String) async throws {
    let fixture = try RiskFixture(fullAccess: true, risk: .string("full-shell"))
    defer { fixture.remove() }
    do {
      do {
        _ = try await fixture.runtime.callToolAsync(name: tool, arguments: arguments(for: tool))
        Issue.record("A configured read-only override must not bypass publisher risk consent.")
      } catch {
        #expect(error.localizedDescription.contains("operations.approval_required"))
      }
      #expect(fixture.client.calls == 0)
      let prepared = try fixture.runtime.callTool(
        name: "operations.prepare",
        arguments: .object([
          "tool": .string(tool), "arguments": arguments(for: tool),
        ]))
      let ticket = try #require(
        prepared.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["ticket_id"]?.stringValue)
      #expect(try fixture.database.operationTicket(id: ticket)?.state == .pendingApproval)
      try fixture.database.resolveOperationApproval(id: ticket, approved: true, resolver: .localCLI)
      _ = try await fixture.runtime.callToolAsync(
        name: "operations.commit",
        arguments: .object([
          "ticket_id": .string(ticket), "tool": .string(tool), "arguments": arguments(for: tool),
        ]))
      #expect(fixture.client.calls == 1)
      await fixture.runtime.shutdown()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: ["sync", "async", "detached"])
  func riskChangeBetweenAdmissionAndDispatchCannotBypassConsent(path: String) async throws {
    let fixture = try RiskFixture(fullAccess: true, risk: .string("read-only"))
    defer { fixture.remove() }
    fixture.client.raiseAfterNextDiscovery()
    var arguments = arguments(for: "mcp.tools.call").objectValue!
    arguments["wait_for_result"] = .bool(path != "detached")
    arguments["request_id"] = .string("fixture-request")
    do {
      if path == "sync" {
        _ = try fixture.runtime.callTool(name: "mcp.tools.call", arguments: .object(arguments))
      } else {
        _ = try await fixture.runtime.callToolAsync(
          name: "mcp.tools.call", arguments: .object(arguments))
      }
      Issue.record("An unreviewed risk increase reached execution.")
    } catch {
      #expect(error.localizedDescription.contains("mcp.risk_changed"), "\(error)")
    }
    #expect(fixture.client.calls == 0)
    await fixture.runtime.shutdown()
  }

  @Test
  func invalidRiskAfterFailedRefreshCannotUseOldCatalog() async throws {
    let fixture = try RiskFixture(fullAccess: true, risk: .string("read-only"))
    defer { fixture.remove() }
    fixture.client.setRisk(.string("unknown-risk"))
    await #expect(throws: (any Error).self) { try await fixture.runtime.refreshTools() }
    for tool in ["mcp.tools.call", "vendor.inspect", "review.inspect"] {
      await #expect(throws: (any Error).self) {
        try await fixture.runtime.callToolAsync(name: tool, arguments: arguments(for: tool))
      }
    }
    #expect(fixture.client.calls == 0)
    await fixture.runtime.shutdown()
  }

  @Test
  func policyProbeUsesTheSelectedWorkspaceCatalog() async throws {
    let fixture = try RiskFixture(
      fullAccess: true, risk: .string("read-only"), secondWorkspace: true)
    defer { fixture.remove() }
    do {
      for tool in ["mcp.tools.call", "vendor.inspect", "review.inspect"] {
        for (workspace, risk) in [("fixture", "read-only"), ("second", "full-shell")] {
          let response = try await fixture.runtime.callToolAsync(
            name: "policy.probe",
            arguments: .object([
              "workspace_id": .string(workspace), "capability_id": .string(tool),
              "arguments": arguments(for: tool),
            ]))
          #expect(
            response.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["risk"]
              == .string(risk))
        }
      }
      #expect(fixture.client.calls == 0)
      await fixture.runtime.shutdown()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test
  func riskIncreaseInvalidatesPreparedTicket() async throws {
    let fixture = try RiskFixture(fullAccess: true, risk: .string("workspace-write"))
    defer { fixture.remove() }
    do {
      let prepared = try fixture.runtime.callTool(
        name: "operations.prepare",
        arguments: .object([
          "tool": .string("mcp.tools.call"), "arguments": arguments(for: "mcp.tools.call"),
        ]))
      let ticket = try #require(
        prepared.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["ticket_id"]?.stringValue)
      #expect(try fixture.database.operationTicket(id: ticket)?.state == .prepared)
      fixture.client.setRisk(.string("full-shell"))
      await #expect(throws: (any Error).self) {
        try await fixture.runtime.callToolAsync(
          name: "operations.commit",
          arguments: .object([
            "ticket_id": .string(ticket), "tool": .string("mcp.tools.call"),
            "arguments": arguments(for: "mcp.tools.call"),
          ]))
      }
      #expect(fixture.client.calls == 0)
      await fixture.runtime.shutdown()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }

  private func arguments(for tool: String) -> JSONValue {
    tool == "mcp.tools.call"
      ? .object([
        "server": .string("vendor"), "tool": .string("inspect"), "arguments": .object([:]),
      ])
      : .object([:])
  }
}

private struct RiskFixture {
  let root: URL
  let database: GatewayDatabase
  let client: RiskCatalogClient
  let runtime: GatewayRuntime

  init(fullAccess: Bool, risk: JSONValue, secondWorkspace: Bool = false) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try GatewayDatabase(inMemory: ())
    let second = root.appendingPathComponent("second")
    var workspaces: [RegisteredWorkspace] = [
      .init(id: "fixture", displayName: "Fixture", rootPath: root.path)
    ]
    if secondWorkspace {
      try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
      workspaces.append(.init(id: "second", displayName: "Second", rootPath: second.path))
    }
    client = RiskCatalogClient(risk: risk, scopedHighRisk: secondWorkspace ? second.path : nil)
    runtime = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
        profiles: [
          .init(
            id: .chatGPTOperate, capabilities: ["*"], workspaces: workspaces.map(\.id),
            allowedCallers: [.secureTunnel], fullShellEnabled: fullAccess,
            mode: fullAccess ? .localFullAccess : .readOnly, confirmationPolicy: .riskBased)
        ],
        mcp: .init(servers: [
          .init(
            id: "vendor", transport: .stdio, command: "/bin/cat", exposure: .reexport,
            prefix: "vendor", allowAnyTool: true, toolRisks: ["inspect": .readOnly])
        ]),
        tools: [.init(name: "review.inspect", adapter: .mcp, source: "vendor", tool: "inspect")]),
      database: database,
      registeredWorkspaces: workspaces,
      mcpClient: client)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class RiskCatalogClient: DownstreamMCPClient, Sendable {
  private struct State {
    var risk: JSONValue
    var raiseAfterDiscovery = false
    var discoverySuspended = false
    var calls = 0
    var action: JSONValue?
    var nextAction: JSONValue?
  }
  private let state: OSAllocatedUnfairLock<State>
  private let scopedHighRisk: String?
  init(risk: JSONValue, scopedHighRisk: String? = nil) {
    state = .init(initialState: State(risk: risk))
    self.scopedHighRisk = scopedHighRisk
  }
  var calls: Int { state.withLock { $0.calls } }
  func setRisk(_ risk: JSONValue) { state.withLock { $0.risk = risk } }
  func setAction(_ action: JSONValue) { state.withLock { $0.action = action } }
  func changeActionAfterNextDiscovery(_ action: JSONValue) {
    state.withLock { $0.nextAction = action }
  }
  func raiseAfterNextDiscovery() { state.withLock { $0.raiseAfterDiscovery = true } }
  func suspendDiscovery() { state.withLock { $0.discoverySuspended = true } }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  ) -> any DownstreamMCPClient {
    workingDirectory.path == scopedHighRisk ? RiskCatalogClient(risk: .string("full-shell")) : self
  }
  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    try state.withLock { state in
      guard !state.discoverySuspended else {
        throw GatewayToolError.executionFailed("Provider is waiting for an active operation.")
      }
      let risk = state.risk
      var metadata = ["io.github.computer-mcp/risk": risk]
      metadata["io.github.computer-mcp/host-action"] = state.action
      if let nextAction = state.nextAction {
        state.action = nextAction
        state.nextAction = nil
      }
      if state.raiseAfterDiscovery {
        state.risk = .string("full-shell")
        state.raiseAfterDiscovery = false
      }
      return [
        .init(
          name: "inspect", description: "Fixture",
          inputSchema: .object(["type": .string("object")]),
          meta: .object(metadata))
      ]
    }
  }
  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    state.withLock { $0.calls += 1 }
    return .object(["content": .array([]), "isError": .bool(false)])
  }
  func startToolCall(server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String)
    throws -> JSONValue
  {
    try callTool(server: server, name: name, arguments: arguments)
  }
  func readRequest(server: MCPServerConfig, requestID: String, offset: Int, maxBytes: Int) throws
    -> JSONValue
  {
    .object(["tool": .string("inspect"), "state": .string("running")])
  }
  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}
