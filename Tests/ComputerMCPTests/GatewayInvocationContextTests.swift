import ComputerMCPTestSupport
import Foundation
import Testing
import os

@testable import ComputerMCP
@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore

struct GatewayInvocationContextTests {
  @Test(arguments: ["sync", "async", "background"])
  func downstreamAdmissionSurvivesExecutionBridges(path: String) async throws {
    let fixture = try InvocationFixture()
    let session = fixture.session
    do {
      try await GatewaySessionScope.$current.withValue(session) {
        var arguments = fixture.arguments(tool: "inspect")
        if path == "background" {
          arguments["wait_for_result"] = .bool(false)
          arguments["request_id"] = .string("background-request")
        }
        if path == "sync" {
          _ = try fixture.runtime.callTool(name: "mcp.tools.call", arguments: .object(arguments))
        } else {
          _ = try await fixture.runtime.callToolAsync(
            name: "mcp.tools.call", arguments: .object(arguments))
        }
      }
      let observed = try #require(fixture.client.calls.first)
      let admission = try #require(observed.admission)
      #expect(admission.reference == .init(serverID: "fixture", toolName: "inspect"))
      #expect(admission.risk == .readOnly)
      #expect(observed.session === session)
      let invocationID = try #require(admission.hostInvocationID)
      #expect(observed.correlationID == invocationID)
      #expect(admission.correlationID(for: fixture.server, tool: "change") == nil)
      var unbound = fixture.server
      unbound.hostServices = false
      #expect(admission.correlationID(for: unbound, tool: "inspect") == nil)
      #expect(MCPInvocationAdmission.current == nil)
      #expect(GatewaySessionScope.current == nil)
      await fixture.runtime.shutdown()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test
  func downstreamCallsReadLiveSessionRestrictionsAndRevocation() async throws {
    let fixture = try InvocationFixture()
    let serving = GatewayControlSessionServing(base: fixture.runtime, session: fixture.session)
    do {
      _ = try await serving.callToolAsync(
        name: "mcp.tools.call", arguments: .object(fixture.arguments(tool: "change")))
      #expect(fixture.client.calls.count == 1)
      try fixture.session.limitAccess(to: .readOnly, expectedRevision: 0)
      await #expect(throws: (any Error).self) {
        try await serving.callToolAsync(
          name: "mcp.tools.call", arguments: .object(fixture.arguments(tool: "change")))
      }
      #expect(fixture.client.calls.count == 1)
      _ = try await serving.callToolAsync(
        name: "mcp.tools.call", arguments: .object(fixture.arguments(tool: "inspect")))
      #expect(fixture.client.calls.count == 2)
      fixture.session.end()
      await #expect(throws: (any Error).self) {
        try await serving.callToolAsync(
          name: "mcp.tools.call", arguments: .object(fixture.arguments(tool: "inspect")))
      }
      #expect(fixture.client.calls.count == 2)
      #expect(fixture.client.calls.allSatisfy { $0.session === fixture.session })
      await fixture.runtime.shutdown()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func requestTraceReachesAuditWithoutLeakingToTheNextCall(asynchronous: Bool) async throws {
    let fixture = try InvocationFixture()
    let trace = GatewayTransportTrace(
      transport: "gateway_socket", socketConnectionID: "trace-connection",
      tunnelInstanceID: "trace-instance", tunnelProfileID: "trace-profile")
    do {
      let result = try await MCPRuntimeAdapter.$requestTrace.withValue(trace) {
        if asynchronous {
          return try await fixture.runtime.callToolAsync(name: "workspace.list", arguments: nil)
        }
        return try fixture.runtime.callTool(name: "workspace.list", arguments: nil)
      }
      let requestID = try #require(
        result.objectValue?["_meta"]?.objectValue?["computer_mcp"]?.objectValue?["request_id"]?
          .stringValue)
      let audit = try #require(fixture.database.auditEvents().first { $0.requestID == requestID })
      #expect(audit.transport == trace.transport)
      #expect(audit.socketConnectionID == trace.socketConnectionID)
      #expect(audit.tunnelInstanceID == trace.tunnelInstanceID)
      #expect(audit.tunnelProfileID == trace.tunnelProfileID)
      _ = try await fixture.runtime.callToolAsync(name: "workspace.list", arguments: nil)
      let next = try #require(fixture.database.auditEvents().first { $0.requestID != requestID })
      #expect(next.transport == nil)
      #expect(next.socketConnectionID == nil)
      #expect(next.tunnelInstanceID == nil)
      #expect(next.tunnelProfileID == nil)
      await fixture.runtime.shutdown()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }
}

private struct InvocationFixture {
  let workspace: ScopedTemporaryDirectory
  let database: GatewayDatabase
  let client: InvocationClientSpy
  let runtime: GatewayRuntime
  let session = GatewayControlSession(
    principalID: "context-client", profileID: .localAdmin, caller: .localMCP)
  let server = MCPServerConfig(
    id: "fixture", transport: .stdio, command: "/unused/context-provider",
    allowedTools: ["inspect", "change"],
    toolRisks: ["inspect": .readOnly, "change": .workspaceWrite], hostServices: true)

  init() throws {
    workspace = try ScopedTemporaryDirectory()
    database = try GatewayDatabase(inMemory: ())
    client = InvocationClientSpy()
    runtime = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .localMCP, profileID: .localAdmin),
        profiles: [
          .init(
            id: .localAdmin, capabilities: ["*"], workspaces: ["fixture"],
            allowedCallers: [.localMCP], mode: .workspaceOperations, confirmationPolicy: .never)
        ],
        mcp: .init(servers: [server]), workspaceDirectory: workspace.url),
      context: .init(
        caller: .localMCP, profileID: .localAdmin, trustedPrincipalID: "context-client"),
      database: database,
      registeredWorkspaces: [
        .init(id: "fixture", displayName: "Fixture", rootPath: workspace.url.path)
      ],
      mcpClient: client, plugins: [], bundledPlugins: .init(packages: [], issues: []))
  }

  func arguments(tool: String) -> [String: JSONValue] {
    [
      "server": .string("fixture"), "tool": .string(tool), "workspace_id": .string("fixture"),
      "arguments": .object([:]),
    ]
  }
}

// Uses the protocol's asynchronous bridge so the observation occurs after its dispatch hop.
private final class InvocationClientSpy: DownstreamMCPClient, Sendable {
  struct Observation: Sendable {
    let admission: MCPInvocationAdmission?
    let session: (any GatewaySessionAuthority)?
    let correlationID: UUID?
  }
  private let observations = OSAllocatedUnfairLock(initialState: [Observation]())
  var calls: [Observation] { observations.withLock { $0 } }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  ) -> any DownstreamMCPClient { self }
  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    ["inspect", "change"].map {
      MCPTool(name: $0, description: "Fixture", inputSchema: .object(["type": .string("object")]))
    }
  }
  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    let admission = MCPInvocationAdmission.current
    observations.withLock {
      $0.append(
        .init(
          admission: admission, session: GatewaySessionScope.current,
          correlationID: admission?.correlationID(for: server, tool: name)))
    }
    return .object(["content": .array([]), "isError": .bool(false)])
  }
  func startToolCall(server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String)
    throws -> JSONValue
  {
    try callTool(server: server, name: name, arguments: arguments)
  }
  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}
