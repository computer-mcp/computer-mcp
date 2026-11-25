import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPTransport
import Foundation
import Logging
import MCP
import NIOConcurrencyHelpers
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration)
struct GatewayToolCatalogTests {
  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func standaloneHTTPNotificationsSurviveGenerationSwitch(profileChange: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    try database.saveProject(.init(id: "fixture", displayName: "Fixture", rootPath: root.path))
    var profile = ProfileGrantConfig(
      id: .chatGPTObserve, permissions: fixturePermissions([.project("fixture"): .granted(.read)]),
      allowedCallers: [.secureTunnel])
    try database.saveProfile(profile.grant)
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTObserve), profiles: [profile])
    let providers = GenerationCatalogProviders()
    let gateway = try GatewayRuntime(
      configuration: configuration, database: database,
      registeredProjects: try database.projects(), platform: providers.platform)
    let http = GatewayHTTPRuntime(
      configuration: configuration, registry: gateway, host: "127.0.0.1", port: 0,
      publicBaseURL: nil, accessToken: "catalog-generation-token")
    let client = MCP.Client(name: "standalone-generations", version: "1")
    let notifications = GatewayToolChangeBroadcaster()
    let notices = notifications.stream()
    await client.onNotification(ToolListChangedNotification.self) { _ in notifications.send() }
    do {
      try await http.startListening()
      let port = try #require(await http.boundPort())
      let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
      let transport = MCPHTTPClientTransport(
        endpoint: endpoint, streaming: true, bearerToken: { "catalog-generation-token" })
      let initialized = try await client.connect(transport: transport)
      #expect(initialized.capabilities.tools?.listChanged == true)
      #expect(try await client.listTools().tools.contains { $0.name == "sample" })
      let session = try #require(await http.controlSessions().first)
      let first = try #require(providers.latest)
      first.source.replace(names: ["sample", "before"], revision: 2)
      if profileChange {
        profile.grant.fullAccess = true
        try database.saveProfile(profile.grant)
      } else {
        first.changes.send()
      }
      #expect(try await Self.nextEvent(notices))
      #expect(try await client.listTools().tools.contains { $0.name == "before" })

      var refreshedProject = try #require(try database.project(id: "fixture"))
      refreshedProject.displayName = "Refreshed fixture"
      try database.saveProject(refreshedProject)
      #expect(try await !client.listTools().tools.contains { $0.name == "before" })
      // Consume the catalog reset separately so it cannot satisfy the later change assertion.
      #expect(try await Self.nextEvent(notices))
      let second = try #require(providers.latest)
      #expect(second.id != first.id)
      #expect(await http.controlSessions().map(\.id) == [session.id])
      second.source.replace(names: ["sample", "after"], revision: 3)
      if profileChange {
        profile.grant.fullAccess = false
        try database.saveProfile(profile.grant)
      } else {
        second.changes.send()
      }
      #expect(try await Self.nextEvent(notices))
      #expect(try await client.listTools().tools.contains { $0.name == "after" })
      let request: RequestContext<CallTool.Result> = try await client.callTool(name: "project.list")
      let result = try await request.value
      #expect(result.isError != true)
      #expect(String(describing: result.structuredContent).contains("Refreshed fixture"))
      await client.disconnect()
      await http.stop()
      await gateway.shutdown()
    } catch {
      await client.disconnect()
      await http.stop()
      await gateway.shutdown()
      throw error
    }
  }

  @Test
  func explicitCatalogRefreshPublishesProjectlessProviderChanges() async throws {
    let database = try GatewayDatabase(inMemory: ())
    let profile = ProfileGrantConfig(
      id: .chatGPTObserve, permissions: fixturePermissions([:]), allowedCallers: [.localMCP])
    try database.saveProfile(profile.grant)
    let providers = GenerationCatalogProviders(projectID: "unscoped")
    let gateway = try GatewayRuntime(
      configuration: GatewayConfiguration(
        runtime: .init(caller: .localMCP, profileID: profile.id), profiles: [profile]),
      context: .init(
        caller: .localMCP, profileID: profile.id, trustedPrincipalID: "catalog-reader"),
      database: database, registeredProjects: [], platform: providers.platform)
    do {
      let entry = try #require(providers.latest)
      #expect(try await gateway.listToolsAsync(context: .empty).contains { $0.name == "sample" })
      entry.source.replace(names: ["updated"], revision: 2)
      try await gateway.refreshTools(context: .empty)
      let names = try await gateway.listToolsAsync(context: .empty).map(\.name)
      #expect(names.contains("updated"))
      #expect(!names.contains("sample"))
    } catch {
      await gateway.shutdown()
      throw error
    }
    await gateway.shutdown()
  }

  @Test
  func asynchronousAdmissionKeepsAnOlderCallAndCurrentCatalogIndependent() async throws {
    let gateway = AsyncCatalogGateway()
    let server = await MCPRuntimeAdapter.makeGatewayServer(
      configuration: .init(), registry: gateway,
      transportTrace: .init(transport: "async-fixture"))
    let transports = await InMemoryTransport.createConnectedPair()
    let client = MCP.Client(name: "async-admission", version: "1")
    let entered = gateway.entered.stream()
    let changes = GatewayToolChangeBroadcaster()
    let notices = changes.stream()
    await client.onNotification(ToolListChangedNotification.self) { _ in changes.send() }
    var pending: Task<MCP.CallTool.Result, any Error>?
    do {
      try await server.start(transport: transports.server)
      _ = try await client.connect(transport: transports.client)
      pending = Task {
        let request = try await client.send(
          MCP.CallTool.request(.init(name: "read", arguments: ["wait": .bool(true)])))
        return try await request.value
      }
      #expect(try await Self.nextEvent(entered))
      await gateway.replace()
      #expect(try await Self.nextEvent(notices))
      #expect(try await client.listTools().tools.first?.description == "generation 2")
      let currentRequest = try await client.send(MCP.CallTool.request(.init(name: "read")))
      let current = try await currentRequest.value
      #expect(current.structuredContent?.objectValue?["generation"] == .int(2))
      #expect(current.structuredContent?.objectValue?["transport"] == .string("async-fixture"))
      await gateway.release()
      let original = try await pending?.value
      #expect(original?.structuredContent?.objectValue?["generation"] == .int(1))
      await client.disconnect()
      await server.stop()
      await gateway.shutdown()
    } catch {
      await gateway.release()
      pending?.cancel()
      _ = await pending?.result
      await client.disconnect()
      await server.stop()
      await gateway.shutdown()
      throw error
    }
  }

  @Test
  func refreshPublishesDefinitionsCapabilitiesAndRoutesTogether() async throws {
    let source = CatalogSourceFixture()
    let router = try GatewayProviderRouter(source: source.providers)
    let oldCapability = try router.capability(named: "sample", context: .empty)
    source.replace(names: ["sample", "added"], revision: 2, risk: .destructive)
    try await router.refreshTools(context: .empty)
    #expect(try router.listTools(context: .empty).map(\.name) == ["sample", "added"])
    #expect(try router.listTools(context: .empty).first?.description == "revision 2")
    #expect(
      try router.listTools(context: .empty).first?.inputSchema.objectValue?["properties"]?
        .objectValue?[
          "revision"]?.objectValue?["const"] == .number(2))
    #expect(try router.capability(named: "sample", context: .empty).risk == .destructive)
    #expect(try router.callTool(name: "added", arguments: nil, context: .empty) == .number(2))
    #expect(throws: GatewayProviderRouterError.capabilityChanged("sample")) {
      try router.callTool(
        name: "sample", arguments: nil, expectedCapability: oldCapability, context: .empty)
    }
    source.replace(names: ["added"], revision: 3)
    try await router.refreshTools(context: .empty)
    #expect(throws: GatewayToolError.unknownTool("sample")) {
      try router.callTool(name: "sample", arguments: nil, context: .empty)
    }
    await router.shutdown()
  }

  @Test
  func failedRefreshKeepsLastValidatedSnapshotAndCanRecover() async throws {
    let source = CatalogSourceFixture()
    let router = try GatewayProviderRouter(source: source.providers)
    let events = router.toolChanges(context: .empty)
    source.replace(names: ["collision", "collision"], revision: 2)
    await #expect(throws: GatewayProviderRouterError.duplicateTool("collision")) {
      try await router.refreshTools(context: .empty)
    }
    #expect(try router.listTools(context: .empty).map(\.name) == ["sample"])
    #expect(try router.callTool(name: "sample", arguments: nil, context: .empty) == .number(1))
    #expect(router.lastRefreshError != nil)
    source.replace(names: ["sample"], revision: 1)
    try await router.refreshTools(context: .empty)
    #expect(router.lastRefreshError == nil)
    await router.shutdown()
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() == nil)
  }

  @Test
  func everySubscriberReceivesTheSameChangeAndClosesOnShutdown() async throws {
    let source = CatalogSourceFixture()
    let router = try GatewayProviderRouter(source: source.providers)
    let first = router.toolChanges(context: .empty)
    let second = router.toolChanges(context: .empty)
    source.replace(names: ["sample", "added"], revision: 2)
    try await router.refreshTools(context: .empty)
    #expect(try await Self.nextEvent(first))
    #expect(try await Self.nextEvent(second))
    let closing = router.toolChanges(context: .empty)
    await router.shutdown()
    var iterator = closing.makeAsyncIterator()
    #expect(await iterator.next() == nil)
    await #expect(throws: GatewayProviderRouterError.stopped) {
      try await router.refreshTools(context: .empty)
    }
  }

  @Test
  func reorderDoesNotReportACatalogChange() async throws {
    let source = CatalogSourceFixture()
    source.replace(names: ["first", "second"], revision: 1)
    let router = try GatewayProviderRouter(source: source.providers)
    let events = router.toolChanges(context: .empty)
    source.replace(names: ["second", "first"], revision: 1)
    try await router.refreshTools(context: .empty)
    await router.shutdown()
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() == nil)
  }

  @Test
  func concurrentReadersNeverSeeAMixedCatalog() async throws {
    let source = CatalogSourceFixture()
    source.replace(names: ["left", "right"], revision: 1)
    let router = try GatewayProviderRouter(source: source.providers)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for revision in 2...100 {
          source.replace(names: ["left", "right"], revision: revision)
          try await router.refreshTools(context: .empty)
        }
      }
      for _ in 0..<8 {
        group.addTask {
          for _ in 0..<250 {
            let tools = try router.listTools(context: .empty)
            #expect(tools.map(\.name) == ["left", "right"])
            #expect(tools[0].description == tools[1].description)
            #expect(tools[0].inputSchema == tools[1].inputSchema)
            #expect(
              try router.callTool(name: "left", arguments: nil, context: .empty).numberValue != nil)
            await Task.yield()
          }
        }
      }
      try await group.waitForAll()
    }
    #expect(try router.callTool(name: "right", arguments: nil, context: .empty) == .number(100))
    await router.shutdown()
  }

  @Test
  func periodicRefreshFindsChangesWithoutDownstreamNotifications() async throws {
    let source = CatalogSourceFixture()
    let router = try GatewayProviderRouter(
      source: source.providers, refreshInterval: .milliseconds(20))
    let events = router.toolChanges(context: .empty)
    source.replace(names: ["new"], revision: 2)
    #expect(try await Self.nextEvent(events))
    #expect(try router.listTools(context: .empty).map(\.name) == ["new"])
    await router.shutdown()
  }

  @Test
  func stoppingWaitsForCancelledRefreshCleanup() async throws {
    let coordinator = GatewayCatalogRefreshCoordinator()
    let started = GatewayToolChangeBroadcaster()
    let startedEvents = started.stream()
    let cancelled = GatewayToolChangeBroadcaster()
    let cancelledEvents = cancelled.stream()
    let completed = NIOLockedValueBox(false)
    let cleanup = CatalogCleanupGate()
    let task = Task {
      try await coordinator.run {
        let (waiting, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        started.send()
        for await _ in waiting {}
        cancelled.send()
        await cleanup.wait()
        try Task.checkCancellation()
      }
    }
    #expect(try await Self.nextEvent(startedEvents))
    let stopping = Task {
      await coordinator.stop()
      completed.withLockedValue { $0 = true }
    }
    #expect(try await Self.nextEvent(cancelledEvents))
    #expect(!completed.withLockedValue { $0 })
    await cleanup.release()
    await stopping.value
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(completed.withLockedValue { $0 })
  }

  @Test(arguments: ["inputSchema", "outputSchema", "annotations", "description"])
  func metadataChangesWithoutRenamingNotify(field: String) async throws {
    let initial = MCPTool(
      name: "sample", description: "unchanged", inputSchema: .object(["type": .string("object")]),
      outputSchema: nil)
    let current = NIOLockedValueBox(initial)
    let router = try GatewayProviderRouter(source: {
      [CatalogSingleToolFixture(tool: current.withLockedValue { $0 })]
    })
    let events = router.toolChanges(context: .empty)
    let replacement = MCPTool(
      name: initial.name,
      description: field == "description" ? "changed" : initial.description,
      inputSchema: field == "inputSchema"
        ? .object(["type": .string("object"), "additionalProperties": .bool(false)])
        : initial.inputSchema,
      outputSchema: field == "outputSchema" ? .object(["type": .string("object")]) : nil,
      annotations: field == "annotations" ? .init(readOnlyHint: true) : nil)
    current.withLockedValue { $0 = replacement }
    try await router.refreshTools(context: .empty)
    #expect(try await Self.nextEvent(events))
    #expect(try router.listTools(context: .empty) == [replacement])
    await router.shutdown()
  }

  @Test
  func manualSDKListRefreshesAndReportsInvalidCatalogWithoutActivatingIt() async throws {
    let source = CatalogSourceFixture()
    let router = try GatewayProviderRouter(source: source.providers)
    let server = await MCPRuntimeAdapter.makeGatewayServer(configuration: .init(), registry: router)
    let transports = await InMemoryTransport.createConnectedPair()
    let client = MCP.Client(name: "manual-refresh", version: "1")
    do {
      try await server.start(transport: transports.server)
      _ = try await client.connect(transport: transports.client)
      source.replace(names: ["current"], revision: 2)
      #expect(try await client.listTools().tools.map(\.name) == ["current"])
      source.replace(names: ["duplicate", "duplicate"], revision: 3)
      await #expect(throws: (any Error).self) { _ = try await client.listTools() }
      #expect(try router.listTools(context: .empty).map(\.name) == ["current"])
      #expect(router.lastRefreshError != nil)
      source.replace(names: ["recovered"], revision: 4)
      #expect(try await client.listTools().tools.map(\.name) == ["recovered"])
      #expect(router.lastRefreshError == nil)
      await client.disconnect()
      await server.stop()
      await router.shutdown()
    } catch {
      await client.disconnect()
      await server.stop()
      await router.shutdown()
      throw error
    }
  }

  @Test
  func invalidationRefreshesRouterAndMonitoringDoesNotRetainIt() async throws {
    let source = CatalogSourceFixture()
    let invalidations = GatewayToolChangeBroadcaster()
    var router: GatewayProviderRouter? = try .init(
      source: source.providers, invalidations: invalidations.stream())
    weak var weakRouter: GatewayProviderRouter?
    weakRouter = router
    let events = try #require(router).toolChanges(context: .empty)
    source.replace(names: ["new"], revision: 2)
    invalidations.send()
    #expect(try await Self.nextEvent(events))
    #expect(try router?.listTools(context: .empty).map(\.name) == ["new"])
    await router?.shutdown()
    router = nil
    #expect(weakRouter == nil)
  }

  @Test
  func invalidationDuringDiscoveryGetsAnotherCompletePass() async throws {
    let source = CatalogSourceFixture()
    let pauseNext = NIOLockedValueBox(false)
    let entered = GatewayToolChangeBroadcaster()
    let enteredEvents = entered.stream()
    let resume = DispatchSemaphore(value: 0)
    let invalidations = GatewayToolChangeBroadcaster()
    let router = try GatewayProviderRouter(
      source: {
        let snapshot = source.providers()
        let pause = pauseNext.withLockedValue { value in
          let pause = value
          value = false
          return pause
        }
        if pause {
          entered.send()
          guard resume.wait(timeout: .now() + 5) == .success else { throw CatalogTestError.timeout }
        }
        return snapshot
      }, invalidations: invalidations.stream())
    let changes = router.toolChanges(context: .empty)
    source.replace(names: ["intermediate"], revision: 2)
    pauseNext.withLockedValue { $0 = true }
    invalidations.send()
    do {
      #expect(try await Self.nextEvent(enteredEvents))
      source.replace(names: ["latest"], revision: 3)
      invalidations.send()
      resume.signal()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for await _ in changes {
            if try router.listTools(context: .empty).map(\.name) == ["latest"] { return }
          }
          throw CatalogTestError.timeout
        }
        group.addTask {
          try await Task.sleep(for: .seconds(5))
          throw CatalogTestError.timeout
        }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
      #expect(try router.callTool(name: "latest", arguments: nil, context: .empty) == .number(3))
      await router.shutdown()
    } catch {
      resume.signal()
      await router.shutdown()
      throw error
    }
  }

  @Test
  func catalogChangeOutsideTheWhitelistDoesNotNotify() async throws {
    let client = MutableCatalogClient()
    let configuration = GatewayConfiguration(
      mcp: .init(servers: [
        .init(
          id: "fixture", transport: .stdio, command: "/bin/cat", exposure: .reexport,
          prefix: "fixture", allowedTools: ["sample"])
      ]))
    let router = try GatewayProviderRouter(
      registry: MacOSToolProviders().makeProviders(
        toolEnvironment: ToolEnvironment(
          launcher: testExecutionLauncher(), configuration: configuration), mcpClient: client))
    let events = router.toolChanges(context: .empty)
    client.replace(names: ["sample", "hidden"], revision: 1)
    try await router.refreshTools(context: .empty)
    #expect(try router.listTools(context: .empty).contains { $0.name == "fixture.sample" })
    #expect(try !router.listTools(context: .empty).contains { $0.name == "fixture.hidden" })
    await router.shutdown()
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() == nil)
  }

  enum CatalogTransport: CaseIterable, Sendable { case memory, http, socket }

  @Test(arguments: [false, true])
  func requestableDownstreamWritesRemainListedAndCallsRequireAuthority(denied: Bool) async throws {
    let fixture = try DynamicMCPProcessFixture()
    defer { fixture.cleanup() }
    let profile = ProfileGrantConfig(
      id: .localAdmin,
      permissions: fixturePermissions([
        .project("fixture"): .granted(.read),
        .mcpServer("native"): denied ? .denied : .granted(.read),
      ]), allowedCallers: [.localMCP])
    var platform = fixtureHostedPlatform()
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let database = try fixturePermissionDatabase(
      path: fixture.root.appendingPathComponent("host.sqlite").path)
    try database.saveProject(
      .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    try database.saveProfile(profile.grant)
    let runtime = try await GatewayRuntime.make(
      configuration: .init(
        runtime: .init(caller: .localMCP, profileID: .localAdmin), profiles: [profile],
        mcp: .init(servers: [fixture.server]), projectDirectory: fixture.root),
      context: .init(
        caller: .localMCP, profileID: .localAdmin, trustedPrincipalID: "catalog-requestability"),
      database: database, registeredProjects: try database.projects(),
      platform: platform, mcpClient: MutableCatalogClient(),
      bundledPlugins: .init(packages: [], issues: []))
    try fixtureApproveLocalProvider(
      fixture.server, database: database, runtime: database.permissionRuntime(platform: platform),
      permissions: fixturePermissions([.project("fixture"): .granted(.write)]), fullAccess: false)
    do {
      let tool = try #require(
        try runtime.listTools(context: .empty).first { $0.name == "native.sample" })
      #expect(tool.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"] != nil)
      let result = try await runtime.callToolForMCPAsync(
        name: tool.name, arguments: .object([:]), context: .empty)
      #expect(result.objectValue?["isError"] == .bool(true))
      #expect(
        result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]
          == .string(denied ? "permission.denied" : "permission.required"))
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func standaloneStdioCatalogRequiresAdmittedDownstreamDiscovery(granted: Bool) async throws {
    let fixture = try DynamicMCPProcessFixture()
    defer { fixture.cleanup() }
    var permissions = fixturePermissions([.project("fixture"): .granted(.read)])
    if granted { try permissions.set(.granted(.all), for: .mcpServer("native")) }
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .localAdmin),
      projects: [.init(id: "fixture", path: fixture.root.path)],
      profiles: [.init(id: .localAdmin, permissions: permissions, allowedCallers: [.localMCP])],
      mcp: .init(servers: [fixture.server]), projectDirectory: fixture.root)
    let manifest = fixture.root.appendingPathComponent("gateway.toml")
    try Data(configuration.exportedTOML().utf8).write(to: manifest)
    let executable = try nativeGatewayTestExecutable()
    let environment = [
      "PATH": "/usr/bin:/bin", "HOME": fixture.root.path, "TMPDIR": fixture.root.path,
    ]
    let administration = ExecutionAdministration(
      mode: .fullAccess, environment: try ExecutionEnvironment(fullAccessVariables: environment))
    let transport = try MCPChildProcessTransport(
      launcher: testExecutionLauncher(),
      server: .init(
        id: "gateway", transport: .stdio, command: executable.path,
        args: ["serve", "stdio", "--config", manifest.path]),
      workingDirectory: fixture.root, environment: environment)
    let client = MCP.Client(name: "stdio-catalog", version: "1")
    do {
      let initialized = try await ExecutionAdministration.$current.withValue(administration) {
        try await client.connect(transport: transport)
      }
      #expect(initialized.capabilities.tools?.listChanged == true)
      let tools = try await client.listTools().tools
      #expect(!tools.contains { $0.name == "native.sample" })
      let forwarded = try #require(tools.first { $0.name == "mcp.tools.call" })
      #expect(forwarded.annotations.readOnlyHint == false)
      #expect(
        try JSONValue.encoded(forwarded).objectValue?["_meta"]?.objectValue?["computer_mcp"]?
          .objectValue?["requirements"] != nil)
      #expect(!String(describing: tools).contains(fixture.root.path))
      let discovery: RequestContext<CallTool.Result> = try await client.callTool(
        name: "mcp.tools.list", arguments: ["server": .string("native")])
      let refused = try await discovery.value
      #expect(refused.isError == true)
      #expect(
        refused.structuredContent?.objectValue?["error"]?.objectValue?["code"]
          == .string(granted ? "permission.unavailable" : "permission.required"))
      #expect(try await client.listTools().tools.allSatisfy { !$0.name.hasPrefix("native.") })
      await client.disconnect()
      #expect(await transport.shutdownConfirmed())
    } catch {
      await client.disconnect()
      await transport.disconnect()
      throw error
    }
  }

  @Test(arguments: CatalogTransport.allCases, [false, true])
  func nativeDownstreamNotificationReachesTwoSDKClients(
    upstream: CatalogTransport, downstreamHTTP: Bool
  ) async throws {
    let fixture = try DynamicMCPProcessFixture()
    defer { fixture.cleanup() }
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .localAdmin),
      profiles: [Self.catalogProfile],
      mcp: .init(servers: [fixture.server]), projectDirectory: fixture.root)
    let nativeRuntime = try await fixture.runtime(configuration: configuration)
    let origin =
      try downstreamHTTP
      ? CatalogHTTPGatewayFixture(
        configuration: configuration, registry: nativeRuntime, serverID: "native") : nil
    let runtime: GatewayRuntime
    do {
      if let origin {
        try await origin.startListening()
        let port = try #require(await origin.boundPort())
        configuration.mcp.servers = [
          .init(
            id: "bridge", transport: .streamableHTTP, url: "http://127.0.0.1:\(port)/mcp",
            exposure: .reexport, prefix: "",
            allowedTools: ["native.advance", "native.sample", "native.added"],
            startupTimeoutMs: 5000, requestTimeoutMs: 5000,
            authentication: .init(
              endpoint: "http://127.0.0.1:\(port)/mcp", keychainAccount: "catalog-origin"))
        ]
        runtime = try await fixture.runtime(
          configuration: configuration, secretStore: origin.secrets)
      } else {
        runtime = nativeRuntime
      }
    } catch {
      await origin?.stop()
      await nativeRuntime.shutdown()
      throw error
    }
    let first = await MCPRuntimeAdapter.makeGatewayServer(
      configuration: configuration, registry: runtime)
    let second = await MCPRuntimeAdapter.makeGatewayServer(
      configuration: configuration, registry: runtime)
    let transportsA = await InMemoryTransport.createConnectedPair()
    let transportsB = await InMemoryTransport.createConnectedPair()
    let clientA = MCP.Client(name: "catalog-a", version: "1")
    let clientB = MCP.Client(name: "catalog-b", version: "1")
    let noticesA = GatewayToolChangeBroadcaster()
    let noticesB = GatewayToolChangeBroadcaster()
    let eventsA = noticesA.stream()
    let eventsB = noticesB.stream()
    var logger = Logger(label: "catalog-http-test")
    logger.logLevel = .debug
    let serverID = downstreamHTTP ? "bridge" : "native"
    let http =
      try upstream == .http
      ? CatalogHTTPGatewayFixture(
        configuration: configuration, registry: runtime, serverID: serverID, logger: logger) : nil
    let socketRoot = URL(fileURLWithPath: "/tmp/catalog-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let socketConfiguration = GatewaySocketConfiguration(
      socketURL: socketRoot.appendingPathComponent("gateway.sock"))
    let socketConfigurationSnapshot = configuration
    let socket =
      upstream == .socket
      ? GatewaySocketServer(configuration: socketConfiguration) { _ in
        await MCPRuntimeAdapter.makeGatewayServer(
          configuration: socketConfigurationSnapshot, registry: runtime)
      } : nil
    await clientA.onNotification(ToolListChangedNotification.self) { _ in noticesA.send() }
    await clientB.onNotification(ToolListChangedNotification.self) { _ in noticesB.send() }
    do {
      if http == nil { try await Self.discover(runtime, serverID: serverID) }
      let clientTransportA: any Transport
      let clientTransportB: any Transport
      if let http {
        try await http.startListening()
        let port = try #require(await http.boundPort())
        let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 5
        sessionConfiguration.timeoutIntervalForResource = 20
        clientTransportA = MCPHTTPClientTransport(
          endpoint: endpoint, configuration: sessionConfiguration, streaming: true,
          bearerToken: { http.token }, logger: logger)
        clientTransportB = MCPHTTPClientTransport(
          endpoint: endpoint, configuration: sessionConfiguration, streaming: true,
          bearerToken: { http.token }, logger: logger)
      } else if let socket {
        try await socket.start()
        clientTransportA = GatewaySocketTransport(configuration: socketConfiguration)
        clientTransportB = GatewaySocketTransport(configuration: socketConfiguration)
      } else {
        try await first.start(transport: transportsA.server)
        try await second.start(transport: transportsB.server)
        clientTransportA = transportsA.client
        clientTransportB = transportsB.client
      }
      let initialized = try await clientA.connect(transport: clientTransportA)
      _ = try await clientB.connect(transport: clientTransportB)
      #expect(initialized.capabilities.tools?.listChanged == true)
      #expect(try await clientA.listTools().tools.contains { $0.name == "native.sample" })
      #expect(try await clientB.listTools().tools.contains { $0.name == "native.sample" })
      let request: RequestContext<CallTool.Result> = try await clientA.callTool(
        name: "native.advance", arguments: [:])
      let advanced = try await request.value
      try #require(advanced.isError != true, "Downstream advance failed: \(advanced)")
      #expect(try await Self.nextEvent(eventsA))
      #expect(try await Self.nextEvent(eventsB))
      try await origin?.discover()
      if let http {
        try await http.discover()
      } else {
        try await Self.discover(runtime, serverID: serverID)
      }
      for client in [clientA, clientB] {
        let tools = try await client.listTools().tools
        try #require(
          tools.contains { $0.name == "native.added" },
          "Catalog after admitted refresh: \(tools.map(\.name))")
        #expect(!tools.contains { $0.name == "native.sample" })
        #expect(tools.first { $0.name == "native.advance" }?.description == "revision 2")
        #expect(!String(describing: tools).contains(fixture.root.path))
        let advance = try #require(tools.first { $0.name == "native.advance" })
        #expect(
          JSONValue(sdkValue: advance.inputSchema).objectValue?["properties"]?.objectValue?[
            "revision"]?.objectValue?["const"] == .number(2))
        let call: RequestContext<CallTool.Result> = try await client.callTool(
          name: "native.added", arguments: [:])
        let result = try await call.value
        try #require(result.isError == false, "Downstream added returned: \(result)")
        let expectedContent = try JSONDecoder().decode(
          JSONValue.self, from: Data(catalogMultimodalJSON.utf8))
        #expect(try JSONValue.encoded(result.content) == expectedContent)
        #expect(
          result.structuredContent.map(JSONValue.init(sdkValue:))?.objectValue?["revision"]
            == .number(2))
        #expect(result._meta?["provider"] == .string("dynamic-fixture"))
        let failure: RequestContext<CallTool.Result> = try await client.callTool(
          name: "native.added", arguments: ["fail": .bool(true)])
        let errorResult = try await failure.value
        #expect(errorResult.isError == true)
        #expect(
          try JSONValue.encoded(errorResult.content) == expectedContent,
          "Downstream error result: \(errorResult)")
        #expect(
          errorResult.structuredContent.map(JSONValue.init(sdkValue:))?.objectValue?["revision"]
            == .number(2))
      }
      await clientA.disconnect()
      await clientB.disconnect()
      await first.stop()
      await second.stop()
      await http?.stop()
      await socket?.stop()
      if let http { #expect(await http.activeSessionCount() == 0) }
      if let socket { #expect(await socket.connectionCount() == 0) }
      await runtime.shutdown()
      await origin?.stop()
      await nativeRuntime.shutdown()
    } catch {
      await clientA.disconnect()
      await clientB.disconnect()
      await first.stop()
      await second.stop()
      await http?.stop()
      await socket?.stop()
      await runtime.shutdown()
      await origin?.stop()
      await nativeRuntime.shutdown()
      throw error
    }
  }

  private static var catalogProfile: ProfileGrantConfig {
    .init(
      id: .localAdmin,
      permissions: fixturePermissions([
        .project("fixture"): .granted(.write), .mcpServer("native"): .granted(.all),
        .mcpServer("bridge"): .granted(.all),
      ]), fullAccess: true,
      allowedCallers: [.localMCP])
  }

  private static func discover(_ runtime: GatewayRuntime, serverID: String) async throws {
    let result = try await runtime.callToolAsync(
      name: "mcp.tools.list",
      arguments: .object(["project_id": .string("fixture"), "server": .string(serverID)]),
      context: .empty)
    try #require(
      result.objectValue?["isError"] != .bool(true), "Catalog discovery failed: \(result)")
    try await runtime.refreshTools(context: .empty)
  }

  private static func nextEvent(_ stream: AsyncStream<Void>) async throws -> Bool {
    try await withThrowingTaskGroup(of: Bool.self) { group in
      group.addTask {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() != nil
      }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw CatalogTestError.timeout
      }
      defer { group.cancelAll() }
      return try await group.next() ?? false
    }
  }
}

private enum CatalogTestError: Error { case timeout, invalidPrincipal }

private final class CatalogHTTPGatewayFixture: Sendable {
  let token: String
  let secrets: CatalogFixtureSecrets
  private let listener: GatewayHTTPRuntime
  private let runtime: GatewayRuntime
  private let catalogSession: GatewayControlSession
  private let serverID: String

  init(
    configuration: GatewayConfiguration, registry: GatewayRuntime, serverID: String,
    logger: Logger? = nil
  ) throws {
    let token = UUID().uuidString
    self.token = token
    let credential = HTTPAccessTokenCredential(token: token)
    let principal = try #require(credential.principalID(for: token))
    let bound = try registry.authenticatedSession(
      principalID: principal, transportTrace: .init(transport: "http"), requiresControlSession: true
    )
    let catalogSession = try bound.makeControlSession()
    // One saved trust identity authorizes the shared downstream connection. Each
    // HTTP connection restores that identity without replacing standing consent.
    _ = try catalogSession.approveFullAccess(
      lifetime: .alwaysAllowClient, expectedRevision: catalogSession.revision)
    self.runtime = bound
    self.catalogSession = catalogSession
    self.serverID = serverID
    secrets = CatalogFixtureSecrets(values: ["catalog-origin": token])
    listener = GatewayHTTPRuntime(
      configuration: configuration,
      source: .managed(
        .init(
          makeSession: { incomingPrincipal in
            guard incomingPrincipal == principal else { throw CatalogTestError.invalidPrincipal }
            let session = try bound.makeControlSession()
            try #require(session.snapshot.fullAccessConsent?.lifetime == .alwaysAllowClient)
            return GatewayControlSessionServing(base: bound, session: session)
          }, closeSession: { _ in },
          shutdown: {
            catalogSession.end()
            await bound.shutdown()
          })),
      host: "127.0.0.1", port: 0, publicBaseURL: nil, accessCredential: credential, logger: logger)
  }

  func discover() async throws {
    let result = try await runtime.callToolAsync(
      name: "mcp.tools.list",
      arguments: .object(["project_id": .string("fixture"), "server": .string(serverID)]),
      context: .init(session: catalogSession))
    try #require(
      result.objectValue?["isError"] != .bool(true), "Catalog discovery failed: \(result)")
    try await runtime.refreshTools(context: .init(session: catalogSession))
  }

  func startListening() async throws {
    try await discover()
    try await listener.startListening()
  }
  func boundPort() async -> Int? { await listener.boundPort() }
  func activeSessionCount() async -> Int { await listener.activeSessionCount() }
  func stop() async { await listener.stop() }
}

private actor CatalogFixtureSecrets: SecretStore {
  var values: [String: String]
  init(values: [String: String]) { self.values = values }
  func setAsynchronously(_ secret: String, for reference: SecretReference) {
    values[reference.account] = secret
  }
  func valueAsynchronously(
    for reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) -> String? { values[reference.account] }
  func containsAsynchronously(
    _ reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) -> Bool { values[reference.account] != nil }
  func deleteAsynchronously(_ reference: SecretReference) { values[reference.account] = nil }
}

private actor CatalogCleanupGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  func wait() async {
    guard !released else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

private struct CatalogSingleToolFixture: GatewayToolProvider {
  let id = "fixture"
  let tool: MCPTool
  func definitions() throws -> [ToolDefinition] {
    [.init(tool: tool, capability: .init(id: tool.name, risk: .externalWrite, requirement: .none))]
  }
  func callTool(_ invocation: ToolInvocation) throws -> JSONValue { .null }
}

private final class GenerationCatalogProviders: GatewayToolProviderFactory, Sendable {
  struct Entry: Sendable {
    let id = UUID()
    let source = CatalogSourceFixture()
    let changes = GatewayToolChangeBroadcaster()
  }
  private let projectID: String

  init(projectID: String = "fixture") { self.projectID = projectID }

  var platform: PlatformServices {
    let base = fixtureHostedPlatform()
    return PlatformServices(
      launcher: base.launcher, projectGrants: base.projectGrants,
      pluginDirectories: base.pluginDirectories, applications: base.applications,
      toolProviders: self, managementToolNames: base.managementToolNames,
      executableSearchDirectories: base.executableSearchDirectories,
      gitExecutable: base.gitExecutable,
      fileChanges: base.fileChanges, permissionPolicyReader: base.permissionPolicyReader,
      executionProxy: base.executionProxy, hostDataPaths: base.hostDataPaths)
  }

  private let entries = NIOLockedValueBox<[Entry]>([])
  var latest: Entry? { entries.withLockedValue { $0.last } }

  func makeProviders(
    configuration: GatewayConfiguration, commandRunner: any CommandRunning,
    processManager: any ProcessManaging, shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient, hostContext: MCPHostContext
  ) -> GatewayToolRegistry {
    let entry = Entry()
    if hostContext.launchMetadata.project.id == projectID {
      entries.withLockedValue { $0.append(entry) }
    }
    return GatewayToolRegistry(
      providers: entry.source.providers, invalidations: entry.changes.stream(),
      downstreamPolicy: { _, _ in throw CatalogTestError.invalidPrincipal },
      shutdown: { entry.changes.finish() })
  }
}

private final class CatalogSourceFixture: Sendable {
  private let state = NIOLockedValueBox(CatalogProviderFixture(names: ["sample"], revision: 1))

  func providers() -> [any GatewayToolProvider] {
    [state.withLockedValue { $0 }]
  }

  func replace(names: [String], revision: Int, risk: CapabilityRisk = .readOnly) {
    state.withLockedValue { $0 = .init(names: names, revision: revision, risk: risk) }
  }
}

private struct CatalogProviderFixture: GatewayToolProvider {
  let id = "fixture"
  let names: [String]
  let revision: Int
  var risk: CapabilityRisk = .readOnly

  func definitions() throws -> [ToolDefinition] {
    names.map {
      ToolDefinition(
        tool: MCPTool(
          name: $0, description: "revision \(revision)",
          inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
              "revision": .object(["type": .string("integer"), "const": .number(Double(revision))])
            ]),
          ])),
        capability: .init(id: $0, risk: risk, requirement: .none))
    }
  }
  func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    .number(Double(revision))
  }
}

private final class MutableCatalogClient: DownstreamMCPClient, Sendable {
  func cachedTools(server: MCPServerConfig, context: InvocationContext) -> [MCPTool]? {
    try? listTools(server: server, context: context)
  }

  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  )
    -> any DownstreamMCPClient
  { self }

  private let state = NIOLockedValueBox(CatalogProviderFixture(names: ["sample"], revision: 1))
  private let changes = GatewayToolChangeBroadcaster()
  func replace(names: [String], revision: Int) {
    state.withLockedValue { $0 = .init(names: names, revision: revision) }
    changes.send()
  }
  func toolChanges() -> AsyncStream<Void> { changes.stream() }
  func shutdown() async { changes.finish() }
  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    try state.withLockedValue { try $0.definitions().map(\.tool) }
  }
  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    .null
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

private struct DynamicMCPProcessFixture: Sendable {
  let root: URL
  let server: MCPServerConfig

  private static let program = """
    import json
    import sys
    import os
    from pathlib import Path
    mixed = json.loads(r'''\(catalogMultimodalJSON)''')
    state = Path(os.environ["HOME"]) / "catalog-revision"
    if not state.exists(): state.write_text("1")
    for line in sys.stdin:
        revision = int(state.read_text())
        message = json.loads(line)
        method = message.get("method", "")
        if method.startswith("notifications/"):
            continue
        response = {"jsonrpc": "2.0", "id": message["id"]}
        if method == "initialize":
            response["result"] = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {"listChanged": True}}, "serverInfo": {"name": "dynamic-fixture", "version": "1"}}
        elif method == "tools/list":
            names = ["advance", "sample" if revision == 1 else "added"]
            response["result"] = {"tools": [{"name": name, "description": "revision " + str(revision), "inputSchema": {"type": "object", "properties": {"revision": {"type": "integer", "const": revision}}}} for name in names]}
        elif method == "tools/call":
            if message["params"]["name"] == "advance":
                revision = 2
                state.write_text("2")
                print(json.dumps({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}), flush=True)
            response["result"] = {"content": [{"type": "text", "text": "called"}], "isError": False}
            if message["params"]["name"] == "added":
                response["result"] = {"content": mixed, "structuredContent": {"revision": revision}, "isError": message["params"].get("arguments", {}).get("fail", False), "_meta": {"provider": "dynamic-fixture"}}
        else:
            response["error"] = {"code": -32601, "message": "not found"}
        print(json.dumps(response), flush=True)
    """

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let script = root.appendingPathComponent("dynamic-mcp.py")
    try writePythonTestExecutable(Self.program, to: script)
    server = .init(
      id: "native", transport: .stdio, command: script.path,
      exposure: .reexport, prefix: "native", allowAnyTool: true, requestTimeoutMs: 5_000)
  }

  func runtime(configuration: GatewayConfiguration, secretStore: (any SecretStore)? = nil)
    async throws -> GatewayRuntime
  {
    try await BlockingOperationExecutor(label: "catalog-test-runtime").perform {
      let database = try fixturePermissionDatabase(
        path: root.appendingPathComponent(UUID().uuidString + ".sqlite").path)
      let projectRoot = root.appendingPathComponent("project")
      try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
      let project = ComputerMCPCore.RegisteredProject(
        id: "fixture", displayName: "Fixture", rootPath: projectRoot.path)
      try database.saveProject(project)
      let grant = configuration.profileGrant(for: .localAdmin)
      try database.saveProfile(grant)
      let launcher = testExecutionLauncher()
      var platform = MacOSPlatform.services(launcher: launcher)
      platform.permissionPolicyReader = TestManagedPolicyReader()
      let context = try fixtureConsentedContext(
        database: database, grant: grant, caller: .localMCP,
        principalID: "catalog-fixture", projectID: project.id, platform: platform)
      let runtime = try GatewayRuntime(
        configuration: configuration, context: context, database: database,
        registeredProjects: [project], platform: platform,
        mcpClient: MCPProxyClient(launcher: launcher, secretStore: secretStore),
        bundledPlugins: .init(packages: [], issues: []))
      _ = try runtime.makeControlSession()
      for server in configuration.mcp.servers where server.transport == .stdio {
        try fixtureApproveLocalProvider(
          server, database: database, runtime: database.permissionRuntime(platform: platform),
          permissions: fixturePermissions([.project("fixture"): .granted(.write)]), fullAccess: true
        )
      }
      if let session = context.controlSession as? GatewayControlSession {
        _ = try session.approveFullAccess(expectedRevision: session.revision)
      }
      return runtime
    }
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private let catalogMultimodalJSON = #"""
  [
    {"type":"text","text":"Unicode 你好","annotations":{"audience":["user"],"priority":0.5},"_meta":{"fixture":"text"}},
    {"type":"image","data":"AAH/","mimeType":"image/png","_meta":{"fixture":"image"}},
    {"type":"audio","data":"AAEC","mimeType":"audio/wav"},
    {"type":"resource_link","uri":"memory://item","name":"item","mimeType":"text/plain","description":"Fixture resource"},
    {"type":"resource","resource":{"uri":"memory://text","mimeType":"text/plain","text":"resource body"}},
    {"type":"resource","resource":{"uri":"memory://binary","mimeType":"application/octet-stream","blob":"AP8="}}
  ]
  """#

private actor AsyncCatalogGateway: GatewayAsyncToolServing {
  nonisolated let entered = GatewayToolChangeBroadcaster()
  private nonisolated let changes = GatewayToolChangeBroadcaster()
  private var generation: Int64 = 1
  private var waiter: CheckedContinuation<Void, Never>?

  func listToolsAsync(context: InvocationContext) async throws -> [MCPTool] {
    [
      MCPTool(
        name: "read", description: "generation \(generation)",
        inputSchema: .object(["type": .string("object")]))
    ]
  }

  func callToolAsync(name: String, arguments: JSONValue?, context: InvocationContext) async throws
    -> JSONValue
  {
    let admitted = generation
    if arguments?.objectValue?["wait"] == .bool(true) {
      entered.send()
      await withCheckedContinuation { waiter = $0 }
    }
    return .object([
      "content": .array([]),
      "structuredContent": .object([
        "generation": .integer(admitted),
        "transport": MCPRuntimeAdapter.requestTrace.map { .string($0.transport) } ?? .null,
      ]),
    ])
  }

  nonisolated func toolChanges(context: InvocationContext) -> AsyncStream<Void> { changes.stream() }
  func replace() {
    generation += 1
    changes.send()
  }
  func release() {
    waiter?.resume()
    waiter = nil
  }
  func shutdown() {
    release()
    changes.finish()
    entered.finish()
  }
}
