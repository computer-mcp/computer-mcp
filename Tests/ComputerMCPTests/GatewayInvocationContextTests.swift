import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPTestSupport
import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import ComputerMCP
@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore

struct GatewayInvocationContextTests {
  @Test(arguments: [false, true])
  func standaloneOwnerCallsKeepLiveSessionAndSelectTheOwnedConnection(envelope: Bool) async throws {
    let fixture = try InvocationFixture(requiresControlSession: true)
    let serving = GatewayControlSessionServing(base: fixture.runtime, session: fixture.session)
    let connectionID = UUID()
    let lease = fixture.runtime.ownedWork.retain(
      .mcpObservation, workspaceID: "fixture", registrationID: "fixture",
      resourceID: "observation", connectionID: connectionID)
    defer { lease.finish() }
    let owner = GatewayOwnerSelection(
      runtimeID: fixture.runtime.generationID, workspaceID: "fixture", ownershipID: lease.id)
    func call(_ tool: String) async throws -> JSONValue {
      let arguments = JSONValue.object([
        "workspace_id": .string("fixture"), "owner": owner.json,
        "tool": .string("mcp.tools.call"), "arguments": .object(fixture.arguments(tool: tool)),
      ])
      if envelope {
        return try await serving.callToolForMCPAsync(
          name: "runtime.owners.call", arguments: arguments, context: .empty)
      }
      return try await serving.callToolAsync(
        name: "runtime.owners.call", arguments: arguments, context: .empty)
    }
    do {
      #expect(GatewayOwnerRouting.call == nil)
      _ = try await call("change")
      try fixture.session.limitAccess(to: .readOnly, expectedRevision: 0)
      let result = try await call("inspect")
      #expect(result.objectValue?["isError"] != .bool(true))
      let observed = try #require(fixture.client.calls.last)
      #expect(observed.session === fixture.session)
      #expect(observed.admission?.reference == .init(serverID: "fixture", toolName: "inspect"))
      let selected = try #require(observed.continuation as? MCPContinuationTarget)
      #expect(selected.connectionID == connectionID)
      #expect(selected.selectedOwnershipID == owner.ownershipID)
      if envelope {
        #expect(try await call("change").objectValue?["isError"] == .bool(true))
      } else {
        await #expect(throws: (any Error).self) { try await call("change") }
      }
      fixture.session.end()
      if envelope {
        #expect(try await call("inspect").objectValue?["isError"] == .bool(true))
      } else {
        await #expect(throws: (any Error).self) { try await call("inspect") }
      }
      #expect(fixture.client.calls.count == 2)
      await fixture.runtime.shutdown()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func directRegistryResolvesInHostScopeAndExecutesWithLiveSession(asynchronous: Bool) async throws
  {
    let fixture = try InvocationFixture(reexportTools: true)
    let configuration = fixture.configuration
    let grant = configuration.profileGrant(for: .localAdmin)
    let executionContext = ExecutionContext(
      caller: .localMCP, profileID: .localAdmin, trustedPrincipalID: "context-client")
    let client = AuthorizedMCPClient(
      base: fixture.client,
      policy: .init(configuration: configuration, grant: grant, derivesObserveGrant: false),
      policyProvider: { session in
        .init(
          configuration: configuration,
          grant: try session?.apply(to: grant, context: executionContext) ?? grant,
          derivesObserveGrant: false)
      })
    let registry = GatewayToolRegistry(configuration: configuration, mcpClient: client)
    let route = InvocationRouteProbe()
    let admission = try #require(
      InvocationAdmission(
        descriptor: .init(
          id: "fixture.inspect", risk: .readOnly,
          mcpReference: .init(serverID: "fixture", toolName: "inspect")),
        hostInvocationID: UUID()))
    let context = InvocationContext(
      admission: admission, session: fixture.session, continuation: route)
    let initialDiscoveries = fixture.client.discoveries.count
    func call(_ tool: String) async throws -> JSONValue {
      if asynchronous {
        return try await registry.callToolAsync(
          name: "fixture." + tool, arguments: .object([:]), context: context)
      }
      return try registry.callTool(
        name: "fixture." + tool, arguments: .object([:]), context: context)
    }
    do {
      try fixture.session.limitAccess(to: .readOnly, expectedRevision: 0)
      _ = try await call("inspect")
      await #expect(throws: (any Error).self) { try await call("change") }
      let discoveries = Array(fixture.client.discoveries.dropFirst(initialDiscoveries))
      #expect(discoveries.count == 2)
      let catalog = try #require(discoveries.first)
      #expect(catalog.admission == nil && catalog.session == nil && catalog.continuation == nil)
      let execution = try #require(discoveries.last)
      #expect(execution.session === fixture.session)
      #expect((execution.continuation as? InvocationRouteProbe) === route)
      fixture.session.end()
      await #expect(throws: (any Error).self) { try await call("inspect") }
      #expect(fixture.client.calls.count == 1)
      let observed = try #require(fixture.client.calls.first)
      #expect(observed.session === fixture.session)
      #expect((observed.continuation as? InvocationRouteProbe) === route)
      #expect(observed.admission?.hostInvocationID == admission.hostInvocationID)
      #expect(observed.admission?.reference == admission.reference)
      await registry.shutdown()
      await fixture.runtime.shutdown()
    } catch {
      await registry.shutdown()
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: ["sync", "async", "background"])
  func downstreamAdmissionSurvivesExecutionBridges(path: String) async throws {
    let fixture = try InvocationFixture()
    let session = fixture.session
    let route = MCPContinuationTarget(
      workspaceID: "fixture", reference: .init(serverID: "fixture", toolName: "inspect"),
      connectionID: UUID(), instanceID: UUID(), resources: [:])
    do {
      var arguments = fixture.arguments(tool: "inspect")
      if path == "background" {
        arguments["wait_for_result"] = .bool(false)
        arguments["request_id"] = .string("background-request")
      }
      if path == "sync" {
        _ = try fixture.runtime.callTool(
          name: "mcp.tools.call", arguments: .object(arguments),
          context: .init(session: session, continuation: route))
      } else {
        _ = try await fixture.runtime.callToolAsync(
          name: "mcp.tools.call", arguments: .object(arguments),
          context: .init(session: session, continuation: route))
      }
      let observed = try #require(fixture.client.calls.first)
      let admission = try #require(observed.admission)
      #expect(admission.reference == .init(serverID: "fixture", toolName: "inspect"))
      #expect(admission.risk == .readOnly)
      #expect(observed.session === session)
      #expect((observed.continuation as? MCPContinuationTarget)?.connectionID == route.connectionID)
      let invocationID = try #require(admission.hostInvocationID)
      #expect(observed.correlationID == invocationID)
      #expect(admission.correlationID(for: fixture.server, tool: "change") == nil)
      var unbound = fixture.server
      unbound.hostServices = false
      #expect(admission.correlationID(for: unbound, tool: "inspect") == nil)
      await fixture.runtime.shutdown()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: ["sync", "async", "fallback", "async-fallback"], [false, true])
  func directRegistryReusesTheHostCatalogWithCallerContext(
    path: String, selectedContinuation: Bool
  ) async throws {
    let fixture = try InvocationFixture(reexportTools: true)
    var configuration = fixture.configuration
    var other = fixture.server
    other.id = "other"
    other.prefix = "other"
    configuration.mcp.servers.insert(other, at: 0)
    let registry = GatewayToolRegistry(configuration: configuration, mcpClient: fixture.client)
    let selected = MCPContinuationTarget(
      workspaceID: "fixture", reference: .init(serverID: fixture.server.id, toolName: "inspect"),
      connectionID: UUID(), instanceID: UUID(), resources: [:])
    let context = InvocationContext(
      session: fixture.session, continuation: selectedContinuation ? selected : nil)
    let initialDiscoveries = fixture.client.discoveries.count
    do {
      _ = try registry.listTools(context: context)
      #expect(
        Array(fixture.client.discoveredServers.dropFirst(initialDiscoveries)) == [
          "other", "fixture",
        ])
      #expect(
        fixture.client.discoveries.dropFirst(initialDiscoveries).allSatisfy {
          $0.admission == nil && $0.session == nil && $0.continuation == nil
        })
      let catalogDiscoveries = fixture.client.discoveries.count
      let result: JSONValue
      switch path {
      case "async":
        result = try await registry.callToolAsync(
          name: "fixture.inspect", arguments: .object([:]), context: context)
      case "fallback":
        result = try registry.callTool(
          definition: .init(
            name: "fixture.inspect", description: "Fixture", inputSchema: .object([:])),
          arguments: .object([:]), context: context)
      case "async-fallback":
        result = try await registry.callToolAsync(
          definition: .init(
            name: "fixture.inspect", description: "Fixture", inputSchema: .object([:])),
          arguments: .object([:]), context: context)
      default:
        result = try registry.callTool(
          name: "fixture.inspect", arguments: .object([:]), context: context)
      }
      #expect(result.objectValue?["isError"] == .bool(false))
      #expect(fixture.client.discoveries.count == catalogDiscoveries)
      let observed = try #require(fixture.client.calls.first)
      #expect(observed.session === fixture.session)
      #expect(
        (observed.continuation as? MCPContinuationTarget)?.connectionID
          == (selectedContinuation ? selected.connectionID : nil))
      #expect(fixture.client.calls.count == 1)
      await registry.shutdown()
      await fixture.runtime.shutdown()
    } catch {
      await registry.shutdown()
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: ["provider", "downstream"])
  func explicitContextSurvivesDetachedAndDefaultBlockingBridges(path: String) async throws {
    let client = InvocationClientSpy()
    let server = MCPServerConfig(id: "fixture", transport: .stdio, hostServices: true)
    let session = GatewayControlSession(
      principalID: "context-client", profileID: .localAdmin, caller: .localMCP)
    let route = InvocationRouteProbe()
    let descriptor = CapabilityDescriptor(
      id: "fixture.inspect", risk: .readOnly,
      mcpReference: .init(serverID: server.id, toolName: "inspect"))
    let admission = try #require(
      InvocationAdmission(descriptor: descriptor, hostInvocationID: UUID()))
    let invocation = ToolInvocation(
      name: "inspect", arguments: .object(["value": .integer(7)]),
      context: .init(admission: admission, session: session, continuation: route))
    let provider = InvocationForwardingProvider(client: client, server: server)
    let result = try await Task.detached {
      if path == "provider" { return try await provider.callToolAsync(invocation) }
      return try await client.callToolAsync(
        server: server, name: invocation.name, arguments: invocation.arguments ?? .null,
        requestID: nil, context: invocation.context)
    }.value
    #expect(result.objectValue?["isError"] == .bool(false))
    let observed = try #require(client.calls.first)
    #expect(observed.name == invocation.name && observed.arguments == invocation.arguments)
    #expect(observed.admission?.hostInvocationID == admission.hostInvocationID)
    #expect(observed.admission?.reference == admission.reference)
    #expect(observed.correlationID == admission.hostInvocationID)
    #expect(observed.session === session)
    #expect((observed.continuation as? InvocationRouteProbe) === route)
  }

  @Test(arguments: [false, true])
  func builtinDiscoveryCarriesLiveSessionAndRouteWithNilAdmission(asynchronous: Bool) async throws {
    let fixture = try InvocationFixture()
    let route = InvocationRouteProbe()
    let admission = try #require(
      InvocationAdmission(
        descriptor: .init(
          id: "fixture.inspect", risk: .readOnly,
          mcpReference: .init(serverID: "fixture", toolName: "inspect"))))
    let context = InvocationContext(
      admission: admission, session: fixture.session, continuation: route)
    let arguments = JSONValue.object([
      "server": .string("fixture"), "workspace_id": .string("fixture"),
    ])
    do {
      if asynchronous {
        _ = try await fixture.runtime.callToolAsync(
          name: "mcp.tools.list", arguments: arguments, context: context)
      } else {
        _ = try fixture.runtime.callTool(
          name: "mcp.tools.list", arguments: arguments, context: context)
      }
      let observed = try #require(fixture.client.discoveries.last)
      #expect(observed.admission == nil)
      #expect(observed.session === fixture.session)
      #expect((observed.continuation as? InvocationRouteProbe) === route)
      #expect(fixture.client.calls.isEmpty)
      await fixture.runtime.shutdown()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func emptyContextCannotInheritThePreviousCallSession(asynchronous: Bool) async throws {
    let fixture = try InvocationFixture(requiresControlSession: true)
    let context = InvocationContext(session: fixture.session)
    let arguments = JSONValue.object(fixture.arguments(tool: "inspect"))
    do {
      _ = try await fixture.runtime.callToolAsync(
        name: "mcp.tools.call", arguments: arguments, context: context)
      #expect(fixture.client.calls.count == 1)
      do {
        if asynchronous {
          _ = try await fixture.runtime.callToolAsync(
            name: "mcp.tools.call", arguments: arguments, context: .empty)
        } else {
          _ = try fixture.runtime.callTool(
            name: "mcp.tools.call", arguments: arguments, context: .empty)
        }
        Issue.record("A call without its required session reached the provider.")
      } catch {
        #expect(error.localizedDescription.contains("policy.control_session_required"))
      }
      fixture.session.end()
      await #expect(throws: (any Error).self) {
        try await fixture.runtime.callToolAsync(
          name: "mcp.tools.call", arguments: arguments, context: context)
      }
      #expect(fixture.client.calls.count == 1)
      await fixture.runtime.shutdown()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test
  func sessionRefreshKeepsTheSharedCatalogIndependentOfItsRestrictions() async throws {
    let fixture = try InvocationFixture(reexportTools: true)
    let restricted = GatewayControlSessionServing(base: fixture.runtime, session: fixture.session)
    let other = GatewayControlSessionServing(
      base: fixture.runtime,
      session: GatewayControlSession(
        principalID: "context-client", profileID: .localAdmin, caller: .localMCP))
    do {
      let change = try #require(
        try await other.listToolsAsync(context: .empty).first {
          $0.mcpReference?.toolName == "change"
        })
      try fixture.session.limitAccess(to: .readOnly, expectedRevision: 0)
      try await restricted.refreshTools(context: .empty)
      #expect(
        try await restricted.listToolsAsync(context: .empty).contains { $0.name == change.name }
          == false)
      #expect(try await other.listToolsAsync(context: .empty).contains { $0.name == change.name })
      let catalogContext = try #require(fixture.client.discoveries.last)
      #expect(
        catalogContext.admission == nil && catalogContext.session == nil
          && catalogContext.continuation == nil)
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
        name: "mcp.tools.call", arguments: .object(fixture.arguments(tool: "change")),
        context: .empty)
      #expect(fixture.client.calls.count == 1)
      try fixture.session.limitAccess(to: .readOnly, expectedRevision: 0)
      await #expect(throws: (any Error).self) {
        try await serving.callToolAsync(
          name: "mcp.tools.call", arguments: .object(fixture.arguments(tool: "change")),
          context: .empty)
      }
      #expect(fixture.client.calls.count == 1)
      _ = try await serving.callToolAsync(
        name: "mcp.tools.call", arguments: .object(fixture.arguments(tool: "inspect")),
        context: .empty)
      #expect(fixture.client.calls.count == 2)
      fixture.session.end()
      await #expect(throws: (any Error).self) {
        try await serving.callToolAsync(
          name: "mcp.tools.call", arguments: .object(fixture.arguments(tool: "inspect")),
          context: .empty)
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
          return try await fixture.runtime.callToolAsync(
            name: "workspace.list", arguments: nil, context: .empty)
        }
        return try fixture.runtime.callTool(name: "workspace.list", arguments: nil, context: .empty)
      }
      let requestID = try #require(
        result.objectValue?["_meta"]?.objectValue?["computer_mcp"]?.objectValue?["request_id"]?
          .stringValue)
      let audit = try #require(fixture.database.auditEvents().first { $0.requestID == requestID })
      #expect(audit.transport == trace.transport)
      #expect(audit.socketConnectionID == trace.socketConnectionID)
      #expect(audit.tunnelInstanceID == trace.tunnelInstanceID)
      #expect(audit.tunnelProfileID == trace.tunnelProfileID)
      _ = try await fixture.runtime.callToolAsync(
        name: "workspace.list", arguments: nil, context: .empty)
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
  let configuration: GatewayConfiguration
  let runtime: GatewayRuntime
  let session = GatewayControlSession(
    principalID: "context-client", profileID: .localAdmin, caller: .localMCP)
  let server: MCPServerConfig

  init(requiresControlSession: Bool = false, reexportTools: Bool = false) throws {
    server = MCPServerConfig(
      id: "fixture", transport: .stdio, command: "/unused/context-provider",
      exposure: reexportTools ? .reexport : .gateway, prefix: reexportTools ? "fixture" : nil,
      allowedTools: ["inspect", "change"],
      toolRisks: ["inspect": .readOnly, "change": .workspaceWrite], hostServices: true)
    workspace = try ScopedTemporaryDirectory()
    database = try GatewayDatabase(inMemory: ())
    client = InvocationClientSpy()
    configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .localAdmin),
      profiles: [
        .init(
          id: .localAdmin, capabilities: ["*"], workspaces: ["fixture"],
          allowedCallers: [.localMCP], mode: .workspaceOperations, confirmationPolicy: .never)
      ],
      mcp: .init(servers: [server]), workspaceDirectory: workspace.url)
    runtime = try GatewayRuntime(
      configuration: configuration,
      context: .init(
        caller: .localMCP, profileID: .localAdmin, trustedPrincipalID: "context-client"),
      database: database,
      registeredWorkspaces: [
        .init(id: "fixture", displayName: "Fixture", rootPath: workspace.url.path)
      ],
      platform: MacOSPlatform.services, mcpClient: client, plugins: [],
      bundledPlugins: .init(packages: [], issues: []),
      requiresControlSession: requiresControlSession)
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
    let name: String
    let arguments: JSONValue
    let admission: InvocationAdmission?
    let session: (any GatewaySessionAuthority)?
    let correlationID: UUID?
    let continuation: (any ContinuationRoute)?
  }
  private let catalogs = NIOLockedValueBox([(serverID: String, context: InvocationContext)]())
  var discoveries: [InvocationContext] { catalogs.withLockedValue { $0.map(\.context) } }
  var discoveredServers: [String] { catalogs.withLockedValue { $0.map(\.serverID) } }
  private let observations = NIOLockedValueBox([Observation]())
  var calls: [Observation] { observations.withLockedValue { $0 } }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  ) -> any DownstreamMCPClient { self }
  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    catalogs.withLockedValue { $0.append((server.id, context)) }
    return ["inspect", "change"].map {
      MCPTool(name: $0, description: "Fixture", inputSchema: .object(["type": .string("object")]))
    }
  }
  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    let admission = context.admission
    observations.withLockedValue {
      $0.append(
        .init(
          name: name, arguments: arguments, admission: admission, session: context.session,
          correlationID: admission?.correlationID(for: server, tool: name),
          continuation: context.continuation))
    }
    return .object(["content": .array([]), "isError": .bool(false)])
  }
  func startToolCall(
    server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String,
    context: InvocationContext
  )
    throws -> JSONValue
  {
    try callTool(server: server, name: name, arguments: arguments, context: context)
  }
  func listResources(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?, context: InvocationContext)
    throws -> JSONValue
  { .null }
  func readResource(server: MCPServerConfig, uri: String, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func getPrompt(
    server: MCPServerConfig, name: String, arguments: [String: String]?, context: InvocationContext
  ) throws
    -> JSONValue
  { .null }
}

private final class InvocationRouteProbe: ContinuationRoute {}

private struct InvocationForwardingProvider: GatewayToolProvider {
  let id = "context-forwarder"
  let client: any DownstreamMCPClient
  let server: MCPServerConfig

  func definitions() throws -> [ToolDefinition] { [] }

  func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    try client.callTool(
      server: server, name: invocation.name, arguments: invocation.arguments ?? .null,
      context: invocation.context)
  }
}
