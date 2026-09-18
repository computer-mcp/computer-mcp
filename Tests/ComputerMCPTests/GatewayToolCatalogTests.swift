import Foundation
import Logging
import MCP
import Testing
import os

@testable import ComputerMCP

struct GatewayToolCatalogTests {
  @Test
  func refreshPublishesDefinitionsCapabilitiesAndRoutesTogether() async throws {
    let source = CatalogSourceFixture()
    let router = try GatewayProviderRouter(source: source.providers)
    let oldCapability = try router.capability(named: "sample")
    source.replace(names: ["sample", "added"], revision: 2, risk: .destructive)
    try await router.refreshTools()
    #expect(try router.listTools().map(\.name) == ["sample", "added"])
    #expect(try router.listTools().first?.description == "revision 2")
    #expect(
      try router.listTools().first?.inputSchema.objectValue?["properties"]?.objectValue?[
        "revision"]?.objectValue?["const"] == .number(2))
    #expect(try router.capability(named: "sample").risk == .destructive)
    #expect(try router.callTool(name: "added", arguments: nil) == .number(2))
    #expect(throws: GatewayProviderRouterError.capabilityChanged("sample")) {
      try router.callTool(name: "sample", arguments: nil, expectedCapability: oldCapability)
    }
    source.replace(names: ["added"], revision: 3)
    try await router.refreshTools()
    #expect(throws: GatewayToolError.unknownTool("sample")) {
      try router.callTool(name: "sample", arguments: nil)
    }
    await router.shutdown()
  }

  @Test
  func failedRefreshKeepsLastValidatedSnapshotAndCanRecover() async throws {
    let source = CatalogSourceFixture()
    let router = try GatewayProviderRouter(source: source.providers)
    let events = router.toolChanges()
    source.replace(names: ["collision", "collision"], revision: 2)
    await #expect(throws: GatewayProviderRouterError.duplicateTool("collision")) {
      try await router.refreshTools()
    }
    #expect(try router.listTools().map(\.name) == ["sample"])
    #expect(try router.callTool(name: "sample", arguments: nil) == .number(1))
    #expect(router.lastRefreshError != nil)
    source.replace(names: ["sample"], revision: 1)
    try await router.refreshTools()
    #expect(router.lastRefreshError == nil)
    await router.shutdown()
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() == nil)
  }

  @Test
  func everySubscriberReceivesTheSameChangeAndClosesOnShutdown() async throws {
    let source = CatalogSourceFixture()
    let router = try GatewayProviderRouter(source: source.providers)
    let first = router.toolChanges()
    let second = router.toolChanges()
    source.replace(names: ["sample", "added"], revision: 2)
    try await router.refreshTools()
    #expect(try await Self.nextEvent(first))
    #expect(try await Self.nextEvent(second))
    let closing = router.toolChanges()
    await router.shutdown()
    var iterator = closing.makeAsyncIterator()
    #expect(await iterator.next() == nil)
    await #expect(throws: GatewayProviderRouterError.stopped) { try await router.refreshTools() }
  }

  @Test
  func reorderDoesNotReportACatalogChange() async throws {
    let source = CatalogSourceFixture()
    source.replace(names: ["first", "second"], revision: 1)
    let router = try GatewayProviderRouter(source: source.providers)
    let events = router.toolChanges()
    source.replace(names: ["second", "first"], revision: 1)
    try await router.refreshTools()
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
          try await router.refreshTools()
        }
      }
      for _ in 0..<8 {
        group.addTask {
          for _ in 0..<250 {
            let tools = try router.listTools()
            #expect(tools.map(\.name) == ["left", "right"])
            #expect(tools[0].description == tools[1].description)
            #expect(tools[0].inputSchema == tools[1].inputSchema)
            #expect(try router.callTool(name: "left", arguments: nil).numberValue != nil)
            await Task.yield()
          }
        }
      }
      try await group.waitForAll()
    }
    #expect(try router.callTool(name: "right", arguments: nil) == .number(100))
    await router.shutdown()
  }

  @Test
  func periodicRefreshFindsChangesWithoutDownstreamNotifications() async throws {
    let source = CatalogSourceFixture()
    let router = try GatewayProviderRouter(
      source: source.providers, refreshInterval: .milliseconds(20))
    let events = router.toolChanges()
    source.replace(names: ["new"], revision: 2)
    #expect(try await Self.nextEvent(events))
    #expect(try router.listTools().map(\.name) == ["new"])
    await router.shutdown()
  }

  @Test
  func stoppingWaitsForCancelledRefreshCleanup() async throws {
    let coordinator = GatewayCatalogRefreshCoordinator()
    let started = GatewayToolChangeBroadcaster()
    let startedEvents = started.stream()
    let cancelled = GatewayToolChangeBroadcaster()
    let cancelledEvents = cancelled.stream()
    let completed = OSAllocatedUnfairLock(initialState: false)
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
      completed.withLock { $0 = true }
    }
    #expect(try await Self.nextEvent(cancelledEvents))
    #expect(!completed.withLock { $0 })
    await cleanup.release()
    await stopping.value
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(completed.withLock { $0 })
  }

  @Test(arguments: ["inputSchema", "outputSchema", "annotations", "description"])
  func metadataChangesWithoutRenamingNotify(field: String) async throws {
    let initial = MCPTool(
      name: "sample", description: "unchanged", inputSchema: .object(["type": .string("object")]),
      outputSchema: nil)
    let current = OSAllocatedUnfairLock(initialState: initial)
    let router = try GatewayProviderRouter(source: {
      [CatalogSingleToolFixture(tool: current.withLock { $0 })]
    })
    let events = router.toolChanges()
    let replacement = MCPTool(
      name: initial.name,
      description: field == "description" ? "changed" : initial.description,
      inputSchema: field == "inputSchema"
        ? .object(["type": .string("object"), "additionalProperties": .bool(false)])
        : initial.inputSchema,
      outputSchema: field == "outputSchema" ? .object(["type": .string("object")]) : nil,
      annotations: field == "annotations" ? .init(readOnlyHint: true) : nil)
    current.withLock { $0 = replacement }
    try await router.refreshTools()
    #expect(try await Self.nextEvent(events))
    #expect(try router.listTools() == [replacement])
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
      #expect(try router.listTools().map(\.name) == ["current"])
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
    let events = try #require(router).toolChanges()
    source.replace(names: ["new"], revision: 2)
    invalidations.send()
    #expect(try await Self.nextEvent(events))
    #expect(try router?.listTools().map(\.name) == ["new"])
    await router?.shutdown()
    router = nil
    #expect(weakRouter == nil)
  }

  @Test
  func invalidationDuringDiscoveryGetsAnotherCompletePass() async throws {
    let source = CatalogSourceFixture()
    let pauseNext = OSAllocatedUnfairLock(initialState: false)
    let entered = GatewayToolChangeBroadcaster()
    let enteredEvents = entered.stream()
    let resume = DispatchSemaphore(value: 0)
    let invalidations = GatewayToolChangeBroadcaster()
    let router = try GatewayProviderRouter(
      source: {
        let snapshot = source.providers()
        let pause = pauseNext.withLock { value in
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
    let changes = router.toolChanges()
    source.replace(names: ["intermediate"], revision: 2)
    pauseNext.withLock { $0 = true }
    invalidations.send()
    do {
      #expect(try await Self.nextEvent(enteredEvents))
      source.replace(names: ["latest"], revision: 3)
      invalidations.send()
      resume.signal()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for await _ in changes {
            if try router.listTools().map(\.name) == ["latest"] { return }
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
      #expect(try router.callTool(name: "latest", arguments: nil) == .number(3))
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
      registry: .init(configuration: configuration, mcpClient: client))
    let events = router.toolChanges()
    client.replace(names: ["sample", "hidden"], revision: 1)
    try await router.refreshTools()
    #expect(try router.listTools().contains { $0.name == "fixture.sample" })
    #expect(try !router.listTools().contains { $0.name == "fixture.hidden" })
    await router.shutdown()
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() == nil)
  }

  enum CatalogTransport: CaseIterable, Sendable { case memory, http, socket }

  @Test
  func standaloneStdioGatewayRefreshesAndPreservesMultimodalResults() async throws {
    let fixture = try DynamicMCPProcessFixture()
    defer { fixture.cleanup() }
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .localAdmin),
      workspaces: [.init(id: "fixture", path: fixture.root.path)],
      profiles: [Self.catalogProfile],
      mcp: .init(servers: [fixture.server]), workspaceDirectory: fixture.root)
    let manifest = fixture.root.appendingPathComponent("gateway.toml")
    try Data(configuration.exportedTOML().utf8).write(to: manifest)
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/computer-mcp")
    let transport = try MCPChildProcessTransport(
      server: .init(
        id: "gateway", transport: .stdio, command: executable.path,
        args: ["serve", "stdio", "--config", manifest.path]),
      workingDirectory: fixture.root, environment: [:])
    let client = MCP.Client(name: "stdio-catalog", version: "1")
    let changes = GatewayToolChangeBroadcaster()
    let events = changes.stream()
    await client.onNotification(ToolListChangedNotification.self) { _ in changes.send() }
    do {
      let initialized = try await client.connect(transport: transport)
      #expect(initialized.capabilities.tools?.listChanged == true)
      #expect(try await client.listTools().tools.contains { $0.name == "native.sample" })
      let advance: RequestContext<CallTool.Result> = try await client.callTool(
        name: "native.advance", arguments: [:])
      try #require(try await advance.value.isError != true)
      #expect(try await Self.nextEvent(events))
      let tools = try await client.listTools().tools
      #expect(tools.contains { $0.name == "native.added" })
      #expect(!tools.contains { $0.name == "native.sample" })
      let call: RequestContext<CallTool.Result> = try await client.callTool(
        name: "native.added", arguments: [:])
      let result = try await call.value
      #expect(result.isError == false)
      #expect(
        try JSONValue.encoded(result.content)
          == JSONDecoder().decode(JSONValue.self, from: Data(catalogMultimodalJSON.utf8)))
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
      mcp: .init(servers: [fixture.server]))
    let nativeConfiguration = configuration
    let nativeRuntime = try await BlockingOperationExecutor(label: "catalog-test-native").perform {
      try GatewayRuntime(
        configuration: nativeConfiguration,
        registeredWorkspaces: [
          .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
        ])
    }
    let origin =
      downstreamHTTP
      ? GatewayHTTPRuntime(
        configuration: configuration, registry: nativeRuntime,
        host: "127.0.0.1", port: 0, publicBaseURL: nil) : nil
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
            startupTimeoutMs: 5000, requestTimeoutMs: 5000)
        ]
        let proxyConfiguration = configuration
        runtime = try await BlockingOperationExecutor(label: "catalog-test-proxy").perform {
          try GatewayRuntime(
            configuration: proxyConfiguration,
            registeredWorkspaces: [
              .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
            ])
        }
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
    let http =
      upstream == .http
      ? GatewayHTTPRuntime(
        configuration: configuration, registry: runtime,
        host: "127.0.0.1", port: 0, publicBaseURL: nil, logger: logger) : nil
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
          endpoint: endpoint, configuration: sessionConfiguration, streaming: true, logger: logger)
        clientTransportB = MCPHTTPClientTransport(
          endpoint: endpoint, configuration: sessionConfiguration, streaming: true, logger: logger)
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
      for client in [clientA, clientB] {
        let tools = try await client.listTools().tools
        #expect(tools.contains { $0.name == "native.added" })
        #expect(!tools.contains { $0.name == "native.sample" })
        #expect(tools.first { $0.name == "native.advance" }?.description == "revision 2")
        let advance = try #require(tools.first { $0.name == "native.advance" })
        #expect(
          JSONValue(sdkValue: advance.inputSchema).objectValue?["properties"]?.objectValue?[
            "revision"]?.objectValue?["const"] == .number(2))
        let call: RequestContext<CallTool.Result> = try await client.callTool(
          name: "native.added", arguments: [:])
        let result = try await call.value
        #expect(result.isError == false)
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
        #expect(try JSONValue.encoded(errorResult.content) == expectedContent)
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
      capabilities: ["native.advance", "native.sample", "native.added"],
      workspaces: ["fixture"], allowedCallers: [.localMCP],
      mode: .workspaceOperations, confirmationPolicy: .never)
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

private enum CatalogTestError: Error { case timeout }

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
  func listTools() throws -> [MCPTool] { [tool] }
  func capability(for tool: MCPTool) -> CapabilityDescriptor {
    .init(id: tool.name, risk: .externalWrite)
  }
  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue { .null }
}

private final class CatalogSourceFixture: Sendable {
  private let state = OSAllocatedUnfairLock(
    initialState: CatalogProviderFixture(names: ["sample"], revision: 1))

  func providers() -> [any GatewayToolProvider] { [state.withLock { $0 }] }

  func replace(names: [String], revision: Int, risk: CapabilityRisk = .readOnly) {
    state.withLock { $0 = .init(names: names, revision: revision, risk: risk) }
  }
}

private struct CatalogProviderFixture: GatewayToolProvider {
  let id = "fixture"
  let names: [String]
  let revision: Int
  var risk: CapabilityRisk = .readOnly

  func listTools() throws -> [MCPTool] {
    names.map {
      .init(
        name: $0, description: "revision \(revision)",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "revision": .object(["type": .string("integer"), "const": .number(Double(revision))])
          ]),
        ]))
    }
  }
  func capability(for tool: MCPTool) -> CapabilityDescriptor { .init(id: tool.name, risk: risk) }
  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    .number(Double(revision))
  }
}

private final class MutableCatalogClient: DownstreamMCPClient, Sendable {
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  )
    -> any DownstreamMCPClient
  { self }

  private let state = OSAllocatedUnfairLock(
    initialState: CatalogProviderFixture(names: ["sample"], revision: 1))
  private let changes = GatewayToolChangeBroadcaster()
  func replace(names: [String], revision: Int) {
    state.withLock { $0 = .init(names: names, revision: revision) }
    changes.send()
  }
  func toolChanges() -> AsyncStream<Void> { changes.stream() }
  func shutdown() async { changes.finish() }
  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    try state.withLock { try $0.listTools() }
  }
  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    .null
  }
  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}

private struct DynamicMCPProcessFixture {
  let root: URL
  let server: MCPServerConfig

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = root.appendingPathComponent("dynamic-mcp.py")
    try """
    import json
    import sys
    mixed = json.loads(r'''\(catalogMultimodalJSON)''')
    revision = 1
    for line in sys.stdin:
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
                print(json.dumps({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}), flush=True)
            response["result"] = {"content": [{"type": "text", "text": "called"}], "isError": False}
            if message["params"]["name"] == "added":
                response["result"] = {"content": mixed, "structuredContent": {"revision": revision}, "isError": message["params"].get("arguments", {}).get("fail", False), "_meta": {"provider": "dynamic-fixture"}}
        else:
            response["error"] = {"code": -32601, "message": "not found"}
        print(json.dumps(response), flush=True)
    """.write(to: script, atomically: true, encoding: .utf8)
    server = .init(
      id: "native", transport: .stdio, command: "/usr/bin/python3", args: [script.path],
      exposure: .reexport, prefix: "native", allowAnyTool: true, requestTimeoutMs: 5_000)
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
