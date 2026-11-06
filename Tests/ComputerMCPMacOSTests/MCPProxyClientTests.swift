import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)

final class MCPProxyClientTests {
  @Test
  func nativeProxyRequiresAnAdmittedContextBeforeDispatch() async throws {
    let fixture = try fakePersistentMCPServer()
    let root = fixture.script.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = MCPServerConfig(
      id: "unadmitted", transport: .stdio, command: fixture.script.path,
      args: [fixture.startMarker.path, fixture.cancelMarker.path], requestTimeoutMs: 5000)
    let host = MCPHostContext(
      runtimeID: UUID(), context: .init(caller: .localMCP, profileID: .chatGPTOperate),
      projectID: "fixture", rootURL: root, readOnly: true,
      processOwnershipRoot: root.appendingPathComponent("ownership"))
    let client = MCPProxyClient(launcher: testExecutionLauncher(), hostContext: host)
    do {
      #expect(throws: (any Error).self) { try client.listTools(server: server, context: .empty) }
      #expect(throws: PermissionModelError.invalidAuthorization) {
        try client.startToolCall(
          server: server, name: "hang", arguments: .object([:]), requestID: "unadmitted",
          context: .empty)
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.startMarker.path))
      await client.shutdown()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test
  func retiringConnectionReturnsAnErrorToAnUncancelledCaller() async throws {
    let fixture = try fakePersistentMCPServer()
    defer { try? FileManager.default.removeItem(at: fixture.script.deletingLastPathComponent()) }
    let server = MCPServerConfig(
      id: "retiring-call", transport: .stdio, command: fixture.script.path,
      args: [fixture.startMarker.path, fixture.cancelMarker.path], requestTimeoutMs: 5_000)
    let authority = try ProxyExecutionFixture(
      server: server, root: fixture.script.deletingLastPathComponent())
    defer { try? authority.close() }
    let client = authority.client
    let inspection = BlockingOperationExecutor(label: "retiring-call-test")
    _ = try await inspection.perform {
      try client.listTools(server: server, context: authority.context)
    }
    let call = Task {
      try await client.callToolAsync(
        server: server, name: "hang", arguments: .object([:]), requestID: "awaited",
        context: authority.context
      )
    }
    let deadline = ContinuousClock.now + .seconds(3)
    var observed = false
    repeat {
      observed = try await inspection.perform {
        try client.activeRequests(server: server, context: authority.context).objectValue?[
          "requests"]?
          .arrayValue?.count == 1
      }
      if !observed { try await Task.sleep(for: .milliseconds(10)) }
    } while !observed && ContinuousClock.now < deadline
    await client.shutdown()
    try #require(observed)
    await #expect(throws: GatewayToolError.self) { _ = try await call.value }
  }

  @Test
  func testPaginatedCatalogReexportsOnlyAllowedToolsFromLaterPages() async throws {
    try await runBlockingTest {
      let script = try self.fakeLineDelimitedMCPServer(paginated: true)
      defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
      let server = MCPServerConfig(
        id: "paged", transport: .stdio, command: script.path,
        exposure: .reexport, prefix: "paged", allowedTools: ["sample"],
        requestTimeoutMs: 5_000)
      let authority = try ProxyExecutionFixture(
        server: server, root: script.deletingLastPathComponent())
      defer { try? authority.close() }
      let client = authority.client
      let discovered = try client.listTools(server: server, context: authority.context)
      #expect(discovered.map(\.name) == ["hidden", "sample"])
      #expect(discovered.last?.title == "Sample Tool")
      #expect(discovered.last?.annotations?.readOnlyHint == true)
      #expect(discovered.last?.outputSchema?.objectValue?["type"] == .string("object"))

      var configuration = GatewayConfiguration.fixture(mcp: .init(servers: [server]))
      configuration.projectDirectory = script.deletingLastPathComponent()
      let registry = try GatewayProviderRouter(
        registry: MacOSToolProviders().makeProviders(
          toolEnvironment: ToolEnvironment(
            launcher: authority.launcher, configuration: configuration),
          mcpClient: client, hostContext: authority.hostContext))
      defer { try? GatewaySynchronousOperation.run { await registry.shutdown() } }
      _ = try registry.callTool(
        name: "mcp.tools.list", arguments: .object(["server": .string(server.id)]),
        context: authority.context)
      try GatewaySynchronousOperation.run { try await registry.refreshTools(context: .empty) }
      let exposed = try registry.listTools(context: authority.context).map(\.name)
      #expect(exposed.contains("paged.sample"))
      #expect(!exposed.contains("paged.hidden"))
      let result = try registry.callTool(
        name: "paged.sample", arguments: .object([:]), context: authority.context)
      #expect(result.objectValue?["structuredContent"] == .object(["answer": .string("called")]))
      expectThrows(
        try registry.callTool(
          name: "mcp.tools.call",
          arguments: .object([
            "server": .string("paged"), "tool": .string("hidden"), "arguments": .object([:]),
          ]), context: authority.context))
      expectThrows(
        try registry.callTool(
          name: "paged.hidden", arguments: .object([:]), context: authority.context))
    }
  }

  @Test(arguments: [nil, "projects-v0", "projects-v1"] as [String?])
  func lifecycleDispatchRequiresTheProviderContractMarker(marker: String?) async throws {
    try await runBlockingTest {
      let script = try self.fakeLineDelimitedMCPServer(contract: marker)
      let server = MCPServerConfig(
        id: "contract", transport: .stdio, command: script.path, requestTimeoutMs: 5_000,
        hostServices: true)
      let authority = try ProxyExecutionFixture(
        server: server, root: script.deletingLastPathComponent(), hostTools: MCPHostToolDirectory())
      defer { try? authority.close() }
      let base = try authority.context
      let admission = try #require(
        InvocationAdmission(
          descriptor: .init(
            id: "contract.sample", risk: .projectWrite, requirement: .none,
            mcpReference: .init(serverID: "contract", toolName: "sample"),
            hostServiceAction: .projectProvision),
          hostInvocationID: UUID(), hostOperationID: UUID()))
      let context = InvocationContext(
        admission: admission, session: base.session,
        executionAuthority: base.executionAuthority)
      do {
        _ = try authority.client.callTool(
          server: server, name: "sample", arguments: .object([:]), context: context)
        Issue.record("A lifecycle call without a live host invocation was forwarded.")
      } catch let error as MCPHostServiceContractError {
        // Refused before the host retains the invocation or sends tools/call.
        #expect(marker != "projects-v1")
        #expect(error.observed == marker)
      } catch {
        #expect(marker == "projects-v1", "\(error)")
        #expect(String(describing: error).contains("No matching active host invocation"))
      }
    }
  }

  @Test
  func testStdioProxyUsesLineDelimitedMCPMessages() async throws {
    try await runBlockingTest {
      let script = try self.fakeLineDelimitedMCPServer()
      let server = MCPServerConfig(
        id: "fake-line",
        transport: .stdio,
        command: script.path,
        requestTimeoutMs: 5_000
      )
      let authority = try ProxyExecutionFixture(
        server: server, root: script.deletingLastPathComponent())
      defer { try? authority.close() }
      let client = authority.client

      let tools = try client.listTools(server: server, context: authority.context)
      #expect((tools.map(\.name)) == (["sample"]))
      #expect((tools.first?.title) == ("Sample Tool"))
      #expect(
        (tools.first?.outputSchema)
          == (.object([
            "type": .string("object"),
            "properties": .object(["answer": .object(["type": .string("string")])]),
            "required": .array([.string("answer")]),
          ])))
      #expect((tools.first?.annotations?.readOnlyHint) == (true))
      #expect((tools.first?.annotations?.destructiveHint) == (false))

      let result = try client.callTool(
        server: server,
        name: "sample",
        arguments: .object(["value": .string("x")]), context: authority.context)
      #expect(
        (result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"])
          == (.string("called")))
      #expect(
        (result.objectValue?["structuredContent"]) == (.object(["answer": .string("called")])))
      #expect((result.objectValue?["_meta"]?.objectValue?["provider"]) == (.string("fake")))
      #expect(try client.cachedTools(server: server, context: authority.context) == tools)
      _ = try client.callTool(
        server: server, name: "sample", arguments: .object([:]), context: authority.context)
      #expect(try client.cachedTools(server: server, context: authority.context) == tools)
    }
  }

  @Test
  func testPersistentSessionSupportsResourcesPromptsStatusAndListChangedEvents() async throws {
    try await runBlockingTest {
      let fixture = try self.fakePersistentMCPServer()
      let server = MCPServerConfig(
        id: "persistent",
        transport: .stdio,
        command: fixture.script.path,
        args: [fixture.startMarker.path, fixture.cancelMarker.path],
        requestTimeoutMs: 5_000
      )
      let authority = try ProxyExecutionFixture(
        server: server, root: fixture.script.deletingLastPathComponent())
      defer { try? authority.close() }
      let client = authority.client

      #expect(
        (try client.listTools(server: server, context: authority.context).map(\.name))
          == (["sample", "hang"]))

      let resources = try client.listResources(
        server: server, cursor: nil, context: authority.context)
      #expect(
        (resources.objectValue?["resources"]?.arrayValue?.first?.objectValue?["uri"])
          == (.string("memory://sample")))
      let templates = try client.listResourceTemplates(
        server: server, cursor: nil, context: authority.context)
      #expect(
        (templates.objectValue?["resourceTemplates"]?.arrayValue?.first?.objectValue?[
          "uriTemplate"
        ]) == (.string("memory://{name}")))
      let resource = try client.readResource(
        server: server, uri: "memory://sample", context: authority.context)
      #expect(
        (resource.objectValue?["contents"]?.arrayValue?.first?.objectValue?["text"])
          == (.string("resource-body")))

      let prompts = try client.listPrompts(server: server, cursor: nil, context: authority.context)
      #expect(
        (prompts.objectValue?["prompts"]?.arrayValue?.first?.objectValue?["name"])
          == (.string("sample-prompt")))
      let prompt = try client.getPrompt(
        server: server,
        name: "sample-prompt",
        arguments: ["value": "x"], context: authority.context)
      #expect(
        (prompt.objectValue?["messages"]?.arrayValue?.first?.objectValue?["role"])
          == (.string("user")))

      _ = try client.callTool(
        server: server, name: "sample", arguments: .object([:]), context: authority.context)
      for _ in 0..<20 {
        let events = try client.readEvents(
          server: server, afterCursor: 0, maxResults: 100, context: authority.context)
        if events.objectValue?["events"]?.arrayValue?.contains(where: {
          $0.objectValue?["kind"] == .string("notifications/tools/list_changed")
        }) == true {
          break
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
      let events = try client.readEvents(
        server: server, afterCursor: 0, maxResults: 100, context: authority.context)
      #expect(
        events.objectValue?["events"]?.arrayValue?.contains(where: {
          $0.objectValue?["kind"] == .string("notifications/tools/list_changed")
        }) == true)

      let status = try client.connectionStatus(server: server, context: authority.context)
      #expect((status.objectValue?["state"]) == (.string("connected")))
      #expect((status.objectValue?["persistent_session"]) == (.bool(true)))

      let starts = try String(
        contentsOf: authority.providerMarker(fixture.startMarker), encoding: .utf8)
      #expect((starts) == ("started\nstarted\n"))
    }
  }

  @Test
  func testTimedOutToolCallSendsDownstreamCancellation() async throws {
    try await runBlockingTest {
      let fixture = try self.fakePersistentMCPServer(startupDelaySeconds: 0.3)
      let server = MCPServerConfig(
        id: "cancel",
        transport: .stdio,
        command: fixture.script.path,
        args: [fixture.startMarker.path, fixture.cancelMarker.path],
        startupTimeoutMs: 5_000,
        requestTimeoutMs: 150
      )
      let authority = try ProxyExecutionFixture(
        server: server, root: fixture.script.deletingLastPathComponent())
      defer { try? authority.close() }
      let client = authority.client

      #expect(throws: GatewayToolError.executionFailed("MCP server 'cancel' request timed out.")) {
        try client.callTool(
          server: server,
          name: "hang",
          arguments: .object([:]),
          requestID: "cancel-me", context: authority.context)
      }

      #expect(
        !(try self.waitForNonemptyFile(at: authority.providerMarker(fixture.cancelMarker))
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty))

      var recoveryServer = server
      recoveryServer.requestTimeoutMs = 5_000
      try authority.reconfigure(recoveryServer)
      #expect(
        (try client.listTools(server: recoveryServer, context: authority.context).map(\.name))
          == (["sample", "hang"]))
      let starts = try String(
        contentsOf: authority.providerMarker(fixture.startMarker), encoding: .utf8)
      #expect((starts) == ("started\nstarted\n"))
    }
  }

  @Test
  func testStartedToolCallCanBeListedCancelledAndConnectionReused() async throws {
    try await runBlockingTest {
      let fixture = try self.fakePersistentMCPServer()
      let server = MCPServerConfig(
        id: "started-cancel",
        transport: .stdio,
        command: fixture.script.path,
        args: [fixture.startMarker.path, fixture.cancelMarker.path],
        requestTimeoutMs: 5_000
      )
      let authority = try ProxyExecutionFixture(
        server: server, root: fixture.script.deletingLastPathComponent())
      defer { try? authority.close() }
      let client = authority.client

      _ = try client.listTools(server: server, context: authority.context)
      let started = try client.startToolCall(
        server: server,
        name: "hang",
        arguments: .object([:]),
        requestID: "started-cancel-me", context: authority.context)
      #expect((started.objectValue?["state"]) == (.string("running")))
      #expect((started.objectValue?["request_id"]) == (.string("started-cancel-me")))

      let active = try client.activeRequests(server: server, context: authority.context)
      #expect(
        (active.objectValue?["requests"]?.arrayValue?.first?.objectValue?["request_id"])
          == (.string("started-cancel-me")))

      let cancelled = try client.cancelRequest(
        server: server,
        requestID: "started-cancel-me",
        reason: "test cancellation", context: authority.context)
      #expect(cancelled.objectValue?["cancellation_requested"] == .bool(true))
      #expect(cancelled.objectValue?["execution_stopped"] == .null)
      #expect(cancelled.objectValue?["cancelled"] == nil)
      let pending = try client.activeRequests(server: server, context: authority.context)
        .objectValue?[
          "requests"]?.arrayValue
      #expect(pending?.count == 1)
      #expect(pending?.first?.objectValue?["state"] == .string("cancellation_requested"))
      #expect(throws: (any Error).self) {
        try client.startToolCall(
          server: server, name: "sample", arguments: .object([:]), requestID: "started-cancel-me",
          context: authority.context)
      }

      #expect(
        !(try self.waitForNonemptyFile(at: authority.providerMarker(fixture.cancelMarker))
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty))

      let events = try client.readEvents(
        server: server, afterCursor: 0, maxResults: 100, context: authority.context)
      let kinds = events.objectValue?["events"]?.arrayValue?.compactMap {
        $0.objectValue?["kind"]?.stringValue
      }
      #expect(kinds?.contains("request.started") == true)
      #expect(kinds?.contains("request.cancellation_requested") == true)
      #expect(kinds?.contains("request.cancellation_sent") == true)
      #expect(kinds?.contains("request.cancelled") == false)
      #expect(
        events.objectValue?["events"]?.arrayValue?.filter {
          $0.objectValue?["kind"]?.stringValue?.hasPrefix("request.") == true
        }.allSatisfy { $0.objectValue?["request_id"] == .string("started-cancel-me") } == true)
      #expect(
        (try client.listTools(server: server, context: authority.context).map(\.name))
          == (["sample", "hang"]))
      #expect(
        (try String(contentsOf: authority.providerMarker(fixture.startMarker), encoding: .utf8))
          == ("started\nstarted\n"))
    }
  }

  @Test
  func testLateCompletionAfterStopRequestRemainsObservable() async throws {
    let fixture = try fakePersistentMCPServer()
    defer { try? FileManager.default.removeItem(at: fixture.script.deletingLastPathComponent()) }
    let server = MCPServerConfig(
      id: "late-completion", transport: .stdio, command: fixture.script.path,
      args: [fixture.startMarker.path, fixture.cancelMarker.path], requestTimeoutMs: 5_000)
    let authority = try ProxyExecutionFixture(
      server: server, root: fixture.script.deletingLastPathComponent())
    defer { try? authority.close() }
    let client = authority.client
    do {
      try await runBlockingTest {
        _ = try client.listTools(server: server, context: authority.context)
        _ = try client.startToolCall(
          server: server, name: "hang", arguments: .object([:]), requestID: "late",
          context: authority.context)
        _ = try client.cancelRequest(
          server: server, requestID: "late", reason: "stop", context: authority.context)
        #expect(throws: PermissionModelError.invalidAuthorization) {
          try client.cancelRequest(
            server: server, requestID: "late", reason: "stop again", context: authority.context)
        }
        #expect(
          try client.activeRequests(server: server, context: authority.context).objectValue?[
            "requests"]?
            .arrayValue?.count == 1
        )

        // The fixture only sends the original result after this explicit checkpoint.
        _ = try client.callTool(
          server: server, name: "sample", arguments: .object(["complete_pending": .bool(true)]),
          context: authority.context)
        let deadline = ContinuousClock.now + .seconds(2)
        var completed = false
        repeat {
          let events = try client.readEvents(
            server: server, afterCursor: 0, maxResults: 100, context: authority.context)
          completed =
            events.objectValue?["events"]?.arrayValue?.contains {
              $0.objectValue?["kind"] == .string("request.completed")
                && $0.objectValue?["request_id"] == .string("late")
            } == true
          if !completed { Thread.sleep(forTimeInterval: 0.01) }
        } while !completed && ContinuousClock.now < deadline
        #expect(completed)
        let receipt = try client.readRequest(
          server: server, requestID: "late", offset: 0, maxBytes: 4096, context: authority.context)
        #expect(receipt.objectValue?["state"] == .string("succeeded"))
        #expect(receipt.objectValue?["output_state"] == .string("available"))
        #expect(receipt.objectValue?["result"] != nil)
        #expect(
          try client.startToolCall(
            server: server, name: "hang", arguments: .object([:]), requestID: "late",
            context: authority.context) == receipt)
        #expect(
          try client.callTool(
            server: server, name: "hang", arguments: .object([:]), requestID: "late",
            context: authority.context)
            == receipt.objectValue?["result"])
        #expect(throws: (any Error).self) {
          try client.callTool(
            server: server, name: "sample", arguments: .object([:]), requestID: "late",
            context: authority.context)
        }
        #expect(
          try client.activeRequests(server: server, context: authority.context).objectValue?[
            "requests"]
            == .array([]))
        #expect(
          try String(contentsOf: authority.providerMarker(fixture.cancelMarker), encoding: .utf8)
            .split(separator: "\n").count
            == 1)
        #expect(
          try String(contentsOf: authority.providerMarker(fixture.startMarker), encoding: .utf8)
            == "started\nstarted\n")
      }
    } catch {
      await client.shutdown()
      throw error
    }
    await client.shutdown()
  }

  @Test(arguments: [false, true])
  func requestOwnershipSurvivesCancellationUntilResponseOrConfirmedExit(
    completeBeforeShutdown: Bool
  ) async throws {
    let fixture = try fakePersistentMCPServer()
    let root = fixture.script.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: root) }
    let ownedWork = GatewayOwnedWork()
    let server = MCPServerConfig(
      id: "owned", transport: .stdio, command: fixture.script.path,
      args: [fixture.startMarker.path, fixture.cancelMarker.path], requestTimeoutMs: 5_000)
    let authority = try ProxyExecutionFixture(
      server: server, root: fixture.script.deletingLastPathComponent(), ownedWork: ownedWork)
    defer { try? authority.close() }
    let client = authority.client
    do {
      try await runBlockingTest {
        _ = try client.listTools(server: server, context: authority.context)
        _ = try client.startToolCall(
          server: server, name: "hang", arguments: .object([:]), requestID: "owned-call",
          context: authority.context)
        let record = try #require(ownedWork.snapshot.first { $0.kind == .mcpRequest })
        #expect(record.kind == .mcpRequest)
        #expect(record.projectID == "fixture")
        #expect(record.registrationID == "owned")
        #expect(record.resourceID == "owned-call")
        _ = try client.cancelRequest(
          server: server, requestID: "owned-call", reason: "stop", context: authority.context)
        #expect(ownedWork.snapshot.filter { $0.kind == .mcpRequest } == [record])
        if completeBeforeShutdown {
          _ = try client.callTool(
            server: server, name: "sample", arguments: .object(["complete_pending": .bool(true)]),
            context: authority.context)
          let deadline = ContinuousClock.now + .seconds(2)
          while ownedWork.snapshot.contains(where: { $0.kind == .mcpRequest })
            && ContinuousClock.now < deadline
          {
            Thread.sleep(forTimeInterval: 0.01)
          }
          #expect(!ownedWork.snapshot.contains { $0.kind == .mcpRequest })
          let unknown = try #require(ownedWork.snapshot.first { $0.kind == .mcpUnreportedWork })
          #expect(unknown.uncertain)
          #expect(!ownedWork.closeAdmissionIfDrained())
          #expect(
            try client.connectionStatus(server: server, context: authority.context).objectValue?[
              "state"]
              == .string("connected"))
        }
      }
    } catch {
      await client.shutdown()
      throw error
    }
    await client.shutdown()
    #expect(ownedWork.snapshot.isEmpty)
  }

  @Test
  func testStartupDeadlineIsIndependentOfLongRequestBudget() async throws {
    try await runBlockingTest {
      let fixture = try self.fakePersistentMCPServer(startupDelaySeconds: 0.5)
      let server = MCPServerConfig(
        id: "slow-startup", transport: .stdio, command: fixture.script.path,
        args: [fixture.startMarker.path, fixture.cancelMarker.path],
        startupTimeoutMs: 100, requestTimeoutMs: 5_000)
      let authority = try ProxyExecutionFixture(
        server: server, root: fixture.script.deletingLastPathComponent())
      defer { try? authority.close() }
      let client = authority.client
      #expect(
        throws: GatewayToolError.executionFailed("MCP server 'slow-startup' startup timed out.")
      ) {
        try client.listTools(server: server, context: authority.context)
      }
      let state = try client.connectionStatus(server: server, context: authority.context)
        .objectValue?["state"]
      #expect(state == .string("retiring") || state == .string("not_started"))
      #expect(
        !FileManager.default.fileExists(
          atPath: try authority.providerMarker(fixture.cancelMarker).path))
    }
  }

  @Test func testSynchronousDeduplicationAndReadAfterClientReplacementDoNotDispatchAgain()
    async throws
  {
    let fixture = try fakePersistentMCPServer()
    defer { try? FileManager.default.removeItem(at: fixture.script.deletingLastPathComponent()) }
    let databasePath = fixture.script.deletingLastPathComponent().appendingPathComponent(
      "receipts.sqlite"
    ).path
    let database = try fixturePermissionDatabase(path: databasePath)
    let server = MCPServerConfig(
      id: "retained", transport: .stdio, command: fixture.script.path,
      args: [fixture.startMarker.path, fixture.cancelMarker.path], requestTimeoutMs: 5_000)
    let authority = try ProxyExecutionFixture(
      server: server, root: fixture.script.deletingLastPathComponent(),
      database: database, executionScope: "owner/project")
    defer { try? authority.close() }
    let client = authority.client
    do {
      try await runBlockingTest {
        let result = try client.callTool(
          server: server, name: "counter", arguments: .object([:]), requestID: "once",
          context: authority.context)
        #expect(result.objectValue?["structuredContent"]?.objectValue?["dispatches"] == .number(1))
        #expect(
          try client.callTool(
            server: server, name: "counter", arguments: .object([:]), requestID: "once",
            context: authority.context) == result)
        #expect(
          try client.startToolCall(
            server: server, name: "counter", arguments: .object([:]), requestID: "once",
            context: authority.context
          ).objectValue?["result"] == result)
        let next = try client.callTool(
          server: server, name: "counter", arguments: .object([:]), requestID: "second",
          context: authority.context)
        #expect(next.objectValue?["structuredContent"]?.objectValue?["dispatches"] == .number(2))
        _ = try client.startToolCall(
          server: server, name: "hang", arguments: .object([:]), requestID: "unresolved",
          context: authority.context)
      }
    } catch {
      await client.shutdown()
      throw error
    }
    await client.shutdown()
    let restored = MCPProxyClient(
      launcher: authority.launcher, hostContext: authority.hostContext,
      executionDatabase: try fixturePermissionDatabase(path: databasePath),
      executionScope: "owner/project")
    do {
      try await runBlockingTest {
        let read = try restored.readRequest(
          server: server, requestID: "once", offset: 0, maxBytes: 4096, context: authority.context)
        #expect(read.objectValue?["state"] == .string("succeeded"))
        #expect(
          try restored.callTool(
            server: server, name: "counter", arguments: .object([:]), requestID: "once",
            context: authority.context)
            == read.objectValue?["result"])
        let unknown = try restored.startToolCall(
          server: server, name: "hang", arguments: .object([:]), requestID: "unresolved",
          context: authority.context)
        #expect(unknown.objectValue?["state"] == .string("outcome_unknown"))
        #expect(unknown.objectValue?["cleanup"] == .string("confirmed"))
        #expect(
          try restored.connectionStatus(server: server, context: authority.context).objectValue?[
            "state"]
            == .string("not_started"))
        #expect(
          try String(contentsOf: authority.providerMarker(fixture.startMarker), encoding: .utf8)
            == "started\n")
      }
    } catch {
      await restored.shutdown()
      throw error
    }
    await restored.shutdown()
  }

  @Test
  func closingSelectedHTTPConnectionCannotClaimRemoteWorkStopped() async throws {
    try await runBlockingTest {
      let fixture = try self.fakeHTTPMCPServer()
      let root = fixture.sessionMarker.deletingLastPathComponent()
      defer {
        if fixture.process.isRunning { fixture.process.terminate() }
        #expect(fixture.termination.wait(timeout: .now() + .seconds(5)) == .success)
        try? FileManager.default.removeItem(at: root)
      }
      let work = GatewayOwnedWork()
      let server = MCPServerConfig(
        id: "http", transport: .http,
        url: "http://127.0.0.1:\(fixture.port)/mcp", requestTimeoutMs: 5_000)
      let authority = try ProxyExecutionFixture(
        server: server, root: root, ownedWork: work)
      defer { try? authority.close() }
      let client = authority.client
      _ = try client.callTool(
        server: server, name: "http-sample", arguments: .object([:]), context: authority.context)
      let record = try #require(work.snapshot.first { $0.kind == .mcpUnreportedWork })
      let target = MCPContinuationTarget(
        projectID: "fixture",
        reference: .init(serverID: "http", toolName: "mcp.connections.close"),
        connectionID: try #require(record.connectionID), instanceID: nil, resources: [:],
        selectedOwnershipID: record.id)
      #expect(throws: GatewayToolError.self) {
        try client.closeConnection(server: server, context: authority.context)
      }
      let result = try client.closeConnection(
        server: server, context: .init(continuation: target))
      #expect(result.objectValue?["transport_closed"] == .bool(true))
      #expect(result.objectValue?["managed_process_exit_confirmed"] == .null)
      #expect(result.objectValue?["work_cleanup"] == .string("unknown"))
      #expect(work.snapshot.contains { $0.id == record.id && $0.uncertain })
      #expect(fixture.process.isRunning)
      let before = try String(contentsOf: fixture.sessionMarker, encoding: .utf8)
      #expect(throws: GatewayToolError.self) {
        try client.closeConnection(server: server, context: .init(continuation: target))
      }
      #expect(try String(contentsOf: fixture.sessionMarker, encoding: .utf8) == before)
    }
  }

  @Test
  func testHTTPProxyPreservesNegotiatedSessionAcrossRequests() async throws {
    try await runBlockingTest {
      let fixture = try self.fakeHTTPMCPServer()
      defer {
        fixture.process.terminate()
        #expect(fixture.termination.wait(timeout: .now() + .seconds(5)) == .success)
      }
      let server = MCPServerConfig(
        id: "http",
        transport: .http,
        url: "http://127.0.0.1:\(fixture.port)/mcp",
        requestTimeoutMs: 5_000
      )
      let authority = try ProxyExecutionFixture(
        server: server, root: fixture.sessionMarker.deletingLastPathComponent())
      defer { try? authority.close() }
      let client = authority.client

      #expect(
        (try client.listTools(server: server, context: authority.context).map(\.name))
          == (["http-sample"]))
      let result = try client.callTool(
        server: server,
        name: "http-sample",
        arguments: .object([:]), context: authority.context)
      #expect(
        (result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"])
          == (.string("http-called")))

      let sessions = try String(contentsOf: fixture.sessionMarker, encoding: .utf8)
        .split(separator: "\n")
      #expect((sessions.count) >= (2))
      #expect(sessions.allSatisfy { $0 == "session-1" })
      #expect(
        (try client.connectionStatus(server: server, context: authority.context).objectValue?[
          "state"])
          == (.string("connected")))
    }
  }

  @Test
  func testExitedStdioProviderCannotTerminateGatewayAndNextCallReconnects() async throws {
    let fixture = try fakeExitingMCPServer()
    defer { try? FileManager.default.removeItem(at: fixture.script.deletingLastPathComponent()) }
    let server = MCPServerConfig(
      id: "exiting",
      transport: .stdio,
      command: fixture.script.path,
      args: [fixture.startMarker.path],
      requestTimeoutMs: 5_000
    )
    let authority = try ProxyExecutionFixture(
      server: server, root: fixture.script.deletingLastPathComponent())
    defer { try? authority.close() }
    let client = authority.client
    do {

      let evidence = try await BlockingOperationExecutor(label: "exiting-provider-test").perform {
        let initialCatalog = try client.listTools(server: server, context: authority.context).map(
          \.name)
        let response = try client.callTool(
          server: server, name: "crash", arguments: .object([:]), context: authority.context)
        let deadline = ContinuousClock.now + .seconds(2)
        var state = try client.connectionStatus(server: server, context: authority.context)
          .objectValue?[
            "state"]
        while state == .string("connected"), ContinuousClock.now < deadline {
          Thread.sleep(forTimeInterval: 0.02)
          state = try client.connectionStatus(server: server, context: authority.context)
            .objectValue?["state"]
        }
        let reconnectedCatalog = try client.listTools(server: server, context: authority.context)
          .map(\.name)
        let starts = try String(
          contentsOf: authority.providerMarker(fixture.startMarker), encoding: .utf8)
        return (initialCatalog, response, state, reconnectedCatalog, starts)
      }
      #expect(evidence.0 == ["crash"])
      #expect(
        evidence.1.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]
          == .string("exiting"))
      #expect(evidence.2 != .string("connected"))
      #expect(evidence.3 == ["crash"])
      #expect(evidence.4 == "started\nstarted\n")
    } catch {
      await client.shutdown()
      throw error
    }
    await client.shutdown()
  }

  private func runBlockingTest(_ operation: @escaping () throws -> Void) async throws {
    let operation = BlockingTestOperation(operation)
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result(catching: operation.run))
      }
    }
  }

  private func fakeLineDelimitedMCPServer(paginated: Bool = false, contract: String? = nil)
    throws -> URL
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-mcp.py")
    let text = """
      #!/usr/bin/env python3
      import json
      import sys
      import os

      paginated = \(paginated ? "True" : "False")
      contract = \(contract.map { "\"" + $0 + "\"" } ?? "None")
      for line in sys.stdin:
          message = json.loads(line)
          method = message.get("method")
          if method == "notifications/initialized":
              continue
          response = {"jsonrpc": "2.0", "id": message.get("id")}
          if method == "initialize":
              response["result"] = {
                  "protocolVersion": "2025-11-25",
                  "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fake", "version": "1"},
              }
              if contract is not None:
                  response["result"]["capabilities"]["experimental"] = {
                      "io.github.computer-mcp/host-service-contract": contract
                  }
          elif method == "tools/list":
              cursor = message.get("params", {}).get("cursor")
              if paginated and cursor is None:
                  response["result"] = {
                      "tools": [{"name": "hidden", "inputSchema": {"type": "object"}}],
                      "nextCursor": "",
                  }
                  print(json.dumps(response), flush=True)
                  continue
              if paginated and cursor == "":
                  response["result"] = {"tools": [], "nextCursor": "page-two"}
                  print(json.dumps(response), flush=True)
                  continue
              response["result"] = {
                  "tools": [
                      {
                          "name": "sample",
                          "title": "Sample Tool",
                          "description": "Sample",
                          "inputSchema": {"type": "object"},
                          "outputSchema": {
                              "type": "object",
                              "properties": {"answer": {"type": "string"}},
                              "required": ["answer"],
                          },
                          "annotations": {
                              "readOnlyHint": True,
                              "destructiveHint": False,
                              "openWorldHint": False,
                          },
                      }
                  ]
              }
          elif method == "tools/call":
              response["result"] = {
                  "content": [{"type": "text", "text": "called"}],
                  "structuredContent": {"answer": "called"},
                  "isError": False,
                  "_meta": {"provider": "fake"},
              }
          else:
              response["error"] = {"code": -32601, "message": "not found"}
          print(json.dumps(response, separators=(",", ":")), flush=True)
      """
    try text.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: script.path
    )
    return script
  }

  private func fakePersistentMCPServer(startupDelaySeconds: Double = 0) throws -> (
    script: URL,
    startMarker: URL,
    cancelMarker: URL
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("persistent-mcp.py")
    let startMarker = directory.appendingPathComponent("starts.txt")
    let cancelMarker = directory.appendingPathComponent("cancelled.txt")
    let text = """
      #!/usr/bin/env python3
      import json
      import sys
      import os
      import time

      start_marker = os.path.join(os.environ["HOME"], os.path.basename(sys.argv[1]))
      cancel_marker = os.path.join(os.environ["HOME"], os.path.basename(sys.argv[2]))
      with open(start_marker, "a", encoding="utf-8") as marker:
          marker.write("started\\n")
      pending = []
      dispatches = 0

      for line in sys.stdin:
          message = json.loads(line)
          method = message.get("method")
          if method == "notifications/initialized":
              continue
          if method == "notifications/cancelled":
              with open(cancel_marker, "a", encoding="utf-8") as marker:
                  marker.write(str(message.get("params", {}).get("requestId")) + "\\n")
              continue

          response = {"jsonrpc": "2.0", "id": message.get("id")}
          if method == "initialize":
              time.sleep(\(startupDelaySeconds))
              response["result"] = {
                  "protocolVersion": "2025-11-25",
                  "capabilities": {
                      "tools": {"listChanged": True},
                      "resources": {"listChanged": True},
                      "prompts": {"listChanged": True},
                  },
                  "serverInfo": {"name": "persistent-fake", "version": "1"},
              }
          elif method == "tools/list":
              response["result"] = {
                  "tools": [
                      {"name": "sample", "description": "Sample", "inputSchema": {"type": "object"}},
                      {"name": "hang", "description": "Hangs", "inputSchema": {"type": "object"}},
                  ]
              }
          elif method == "tools/call":
              dispatches += 1
              if message.get("params", {}).get("name") == "hang":
                  pending.append(message["id"])
                  continue
              if message.get("params", {}).get("arguments", {}).get("complete_pending"):
                  for pending_id in pending:
                      print(json.dumps({"jsonrpc": "2.0", "id": pending_id, "result": {
                          "content": [{"type": "text", "text": "completed after stop request"}]
                      }}), flush=True)
                  pending.clear()
              response["result"] = {
                  "content": [{"type": "text", "text": "called"}],
                  "isError": False,
              }
              if message.get("params", {}).get("name") == "counter":
                  response["result"]["structuredContent"] = {"dispatches": dispatches}
          elif method == "resources/list":
              response["result"] = {
                  "resources": [
                      {"uri": "memory://sample", "name": "sample", "mimeType": "text/plain"}
                  ]
              }
          elif method == "resources/templates/list":
              response["result"] = {
                  "resourceTemplates": [
                      {
                          "uriTemplate": "memory://{name}",
                          "name": "memory",
                          "mimeType": "text/plain",
                      }
                  ]
              }
          elif method == "resources/read":
              response["result"] = {
                  "contents": [
                      {
                          "uri": message.get("params", {}).get("uri"),
                          "mimeType": "text/plain",
                          "text": "resource-body",
                      }
                  ]
              }
          elif method == "prompts/list":
              response["result"] = {
                  "prompts": [
                      {
                          "name": "sample-prompt",
                          "description": "Sample",
                          "arguments": [{"name": "value", "required": False}],
                      }
                  ]
              }
          elif method == "prompts/get":
              response["result"] = {
                  "description": "Sample",
                  "messages": [
                      {"role": "user", "content": {"type": "text", "text": "hello"}}
                  ],
              }
          else:
              response["error"] = {"code": -32601, "message": "not found"}

          print(json.dumps(response, separators=(",", ":")), flush=True)
          if method == "tools/list":
              print(
                  json.dumps(
                      {"jsonrpc": "2.0", "method": "notifications/tools/list_changed"},
                      separators=(",", ":"),
                  ),
                  flush=True,
              )
      """
    try text.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: script.path
    )
    return (script, startMarker, cancelMarker)
  }

  private func waitForNonemptyFile(
    at url: URL,
    timeout: TimeInterval = 1
  ) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let contents = try? String(contentsOf: url, encoding: .utf8),
        !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return contents
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  @Test
  func failedCancellationDeliveryRetainsUnknownReceiptAndCannotReplayTheWrite() async throws {
    let fixture = try fakeHTTPMCPServer(failCancellation: true)
    let directory = fixture.sessionMarker.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cleanup = {
      if fixture.process.isRunning { fixture.process.terminate() }
      #expect(fixture.termination.wait(timeout: .now() + .seconds(5)) == .success)
    }
    do {
      let database = try GatewayDatabase(inMemory: ())
      let ownedWork = GatewayOwnedWork()
      let server = MCPServerConfig(
        id: "cancel-failure", transport: .http,
        url: "http://127.0.0.1:\(fixture.port)/mcp", requestTimeoutMs: 5_000)
      let authority = try ProxyExecutionFixture(
        server: server, root: directory, ownedWork: ownedWork, database: database,
        executionScope: "cancel-failure")
      defer { try? authority.close() }
      let client = authority.client
      let waiting = Task {
        try await client.callToolAsync(
          server: server, name: "http-sample", arguments: .object([:]), requestID: "write-once",
          context: authority.context)
      }
      do {
        let marker = directory.appendingPathComponent("call-started.txt")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        waiting.cancel()
        await #expect(throws: (any Error).self) { _ = try await waiting.value }
        let receipt = try client.readRequest(
          server: server, requestID: "write-once", offset: 0, maxBytes: 4096,
          context: authority.context)
        #expect(receipt.objectValue?["state"] == .string("outcome_unknown"))
        #expect(receipt.objectValue?["cancellation"] == .string("failed"))
        #expect(receipt.objectValue?["cleanup"] != .string("confirmed"))
        #expect(receipt.objectValue?["output_state"] == .string("unavailable"))
        #expect(Set(ownedWork.snapshot.map(\.kind)) == [.mcpRequest, .mcpUnreportedWork])
        #expect(ownedWork.snapshot.allSatisfy { $0.uncertain })
        #expect(throws: (any Error).self) {
          try client.callTool(
            server: server, name: "http-sample", arguments: .object([:]), requestID: "write-once",
            context: authority.context)
        }
        let repeated = try client.startToolCall(
          server: server, name: "http-sample", arguments: .object([:]), requestID: "write-once",
          context: authority.context)
        #expect(repeated.objectValue?["state"] == .string("outcome_unknown"))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "called\n")
        try Data().write(to: directory.appendingPathComponent("release.txt"))
        await client.shutdown()
        // Remote completion was not observed even though the transport has closed.
        #expect(Set(ownedWork.snapshot.map(\.kind)) == [.mcpRequest, .mcpUnreportedWork])
        #expect(ownedWork.snapshot.allSatisfy { $0.uncertain })
      } catch {
        waiting.cancel()
        try? Data().write(to: directory.appendingPathComponent("release.txt"))
        await client.shutdown()
        _ = await waiting.result
        throw error
      }
    } catch {
      try await runBlockingTest(cleanup)
      throw error
    }
    try await runBlockingTest(cleanup)
  }

  private func fakeHTTPMCPServer(failCancellation: Bool = false) throws -> (
    process: Process,
    termination: DispatchSemaphore,
    port: Int,
    sessionMarker: URL
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("http-mcp.py")
    let portFile = directory.appendingPathComponent("port.txt")
    let sessionMarker = directory.appendingPathComponent("sessions.txt")
    let text = """
      #!/usr/bin/env python3
      import json
      import sys
      import os
      import pathlib
      import time
      from http.server import BaseHTTPRequestHandler
      from socketserver import ThreadingTCPServer

      port_file = sys.argv[1]
      session_marker = sys.argv[2]
      fail_cancellation = sys.argv[3] == "true"
      root = pathlib.Path(session_marker).parent

      class Handler(BaseHTTPRequestHandler):
          protocol_version = "HTTP/1.1"

          def do_POST(self):
              length = int(self.headers.get("Content-Length", "0"))
              message = json.loads(self.rfile.read(length))
              method = message.get("method")
              session = self.headers.get("Mcp-Session-Id")
              if session:
                  with open(session_marker, "a", encoding="utf-8") as marker:
                      marker.write(session + "\\n")

              if method == "notifications/initialized":
                  self.send_response(202)
                  self.send_header("Mcp-Session-Id", "session-1")
                  self.send_header("Content-Length", "0")
                  self.end_headers()
                  return

              if method == "notifications/cancelled" and fail_cancellation:
                  self.send_response(500)
                  self.send_header("Content-Length", "0")
                  self.end_headers()
                  return

              response = {"jsonrpc": "2.0", "id": message.get("id")}
              if method == "initialize":
                  response["result"] = {
                      "protocolVersion": "2025-11-25",
                      "capabilities": {"tools": {}},
                      "serverInfo": {"name": "http-fake", "version": "1"},
                  }
              elif method == "tools/list":
                  response["result"] = {
                      "tools": [
                          {
                              "name": "http-sample",
                              "description": "HTTP sample",
                              "inputSchema": {"type": "object"},
                          }
                      ]
                  }
              elif method == "tools/call":
                  if fail_cancellation:
                      with (root / "call-started.txt").open("a") as marker:
                          marker.write("called\\n")
                      deadline = time.monotonic() + 10
                      while not (root / "release.txt").exists() and time.monotonic() < deadline:
                          time.sleep(0.01)
                  response["result"] = {
                      "content": [{"type": "text", "text": "http-called"}],
                      "isError": False,
                  }
              else:
                  response["error"] = {"code": -32601, "message": "not found"}

              body = json.dumps(response, separators=(",", ":")).encode("utf-8")
              self.send_response(200)
              self.send_header("Content-Type", "application/json")
              self.send_header("Mcp-Session-Id", "session-1")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)
              self.wfile.flush()

          def log_message(self, format, *args):
              pass

      server = ThreadingTCPServer(("127.0.0.1", 0), Handler)
      with open(port_file, "w", encoding="utf-8") as file:
          file.write(str(server.server_address[1]))
      server.serve_forever()
      """
    try text.write(to: script, atomically: true, encoding: .utf8)

    let process = Process()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "python3", script.path, portFile.path, sessionMarker.path,
      failCancellation ? "true" : "false",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errorPipe
    // Async callers can resume on another thread. Observe termination before
    // launch rather than waiting on a thread-local run loop during cleanup.
    let termination = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in termination.signal() }
    try process.run()

    for _ in 0..<200 where !FileManager.default.fileExists(atPath: portFile.path) {
      Thread.sleep(forTimeInterval: 0.01)
    }
    guard
      let portText = try? String(contentsOf: portFile, encoding: .utf8),
      let port = Int(portText)
    else {
      let wasRunning = process.isRunning
      process.terminate()
      guard termination.wait(timeout: .now() + .seconds(5)) == .success else {
        throw GatewayToolError.executionFailed(
          "Fake HTTP MCP server did not report termination after startup failure: \(directory.path)"
        )
      }
      let stderr =
        String(
          data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
          encoding: .utf8
        ) ?? ""
      throw GatewayToolError.executionFailed(
        "Fake HTTP MCP server failed to start (running: \(wasRunning), status: \(process.terminationStatus), directory: \(directory.path)): \(stderr)"
      )
    }
    return (process, termination, port, sessionMarker)
  }

  private func fakeExitingMCPServer() throws -> (
    script: URL,
    startMarker: URL
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("exiting-mcp.py")
    let startMarker = directory.appendingPathComponent("starts.txt")
    let text = """
      #!/usr/bin/env python3
      import json
      import sys
      import os

      with open(os.path.join(os.environ["HOME"], os.path.basename(sys.argv[1])), "a", encoding="utf-8") as marker:
          marker.write("started\\n")

      for line in sys.stdin:
          message = json.loads(line)
          method = message.get("method")
          if method == "notifications/initialized":
              continue
          response = {"jsonrpc": "2.0", "id": message.get("id")}
          if method == "initialize":
              response["result"] = {
                  "protocolVersion": "2025-11-25",
                  "capabilities": {"tools": {}},
                  "serverInfo": {"name": "exiting-fake", "version": "1"},
              }
          elif method == "tools/list":
              response["result"] = {
                  "tools": [
                      {"name": "crash", "description": "Exit", "inputSchema": {"type": "object"}}
                  ]
              }
          elif method == "tools/call":
              response["result"] = {
                  "content": [{"type": "text", "text": "exiting"}],
                  "isError": False,
              }
              print(json.dumps(response, separators=(",", ":")), flush=True)
              sys.exit(86)
          else:
              response["error"] = {"code": -32601, "message": "not found"}
          print(json.dumps(response, separators=(",", ":")), flush=True)
      """
    try text.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: script.path
    )
    return (script, startMarker)
  }
}

/// Each protocol scenario admits only its reviewed command and arguments. The fixed
/// programs never create descendants; the native fixture backend enforces that boundary.
final class ProxyExecutionFixture: @unchecked Sendable {
  let client: MCPProxyClient
  let launcher: ExecutionLauncher
  let database: GatewayDatabase
  let hostContext: MCPHostContext
  private let runtime: GatewayPermissionRuntime
  let callerContext: ExecutionContext
  private let root: URL
  private let projectRoot: URL
  private var server: MCPServerConfig
  private let scratch: URL
  private let lock = NSLock()
  private var preparedContexts: [PreparedExecutionContext] = []

  init(
    server: MCPServerConfig, root: URL, ownedWork: GatewayOwnedWork? = nil,
    database suppliedDatabase: GatewayDatabase? = nil, executionScope: String? = nil,
    additionalPermissions: [Permission: PermissionState] = [:],
    hostTools: MCPHostToolDirectory? = nil
  ) throws {
    self.root = try ProjectPathResolver.canonicalProject(root)
    self.server = server
    projectRoot = self.root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    let platform: PlatformServices
    if server.transport == .stdio, let command = server.command {
      let script: String
      let arguments: [String]
      if command == "/usr/bin/python3", let first = server.args.first {
        script = first
        arguments = Array(server.args.dropFirst())
      } else {
        script = command
        arguments = server.args
      }
      launcher = fixtureProtocolExecutionLauncher(
        root: self.root, scripts: [try String(contentsOfFile: script, encoding: .utf8)],
        arguments: [arguments])
      var native = MacOSPlatform.services(launcher: launcher)
      native.permissionPolicyReader = TestManagedPolicyReader()
      platform = native
    } else {
      var hosted = fixtureHostedPlatform()
      hosted.permissionPolicyReader = TestManagedPolicyReader()
      platform = hosted
      launcher = hosted.launcher
    }
    database =
      try suppliedDatabase
      ?? fixturePermissionDatabase(path: self.root.appendingPathComponent("proxy.sqlite").path)
    var permissions: [Permission: PermissionState] = [
      .project("fixture"): .granted(.write), .mcpServer(server.id): .granted(.all),
    ]
    permissions.merge(additionalPermissions) { _, supplied in supplied }
    let profile = ProfileGrant(
      id: .chatGPTOperate, permissions: fixturePermissions(permissions),
      fullAccess: true, allowedCallers: [.localMCP])
    try database.saveProfile(profile)
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: projectRoot.path)
    try database.saveProject(project)
    runtime = try database.permissionRuntime(platform: platform)
    var pathRules: Set<PathRule> = [
      .init(root: try CanonicalPath(projectRoot.path), kind: .userData),
      .init(
        root: try CanonicalPath(self.root.appendingPathComponent("ownership").path), kind: .hostData
      ),
    ]
    if let containers = database.providerContainerRoot {
      pathRules.insert(.init(root: try CanonicalPath(containers.path), kind: .hostData))
    }
    if let ownership = database.mcpProcessOwnershipRoot {
      pathRules.insert(
        .init(root: try CanonicalPath(ownership.resolvingSymlinksInPath().path), kind: .hostData))
    }
    if let file = database.fileURL {
      for suffix in ["", "-wal", "-shm", ".executions"] {
        pathRules.insert(
          .init(root: try CanonicalPath(file.path + suffix), kind: .hostData))
      }
    }
    try runtime.service.configureEnvironment(
      PathEnvironmentSnapshot(
        projects: [.init(id: project.id, root: CanonicalPath(projectRoot.path))], rules: pathRules),
      trustedHosts: [], expectedProjects: database.projects(), expectedConfigurationRevision: nil)
    if server.transport == .stdio {
      try fixtureApproveLocalProvider(
        server, database: database, runtime: runtime,
        permissions: fixturePermissions(permissions), fullAccess: true)
    }
    callerContext = try fixtureConsentedContext(
      database: database, grant: profile, caller: .localMCP, principalID: "verified-proxy-fixture",
      projectID: "fixture", platform: platform)
    scratch = self.root.appendingPathComponent("execution-scratch")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    var host = MCPHostContext(
      runtimeID: UUID(), context: callerContext, projectID: "fixture", rootURL: projectRoot,
      readOnly: false, tools: hostTools,
      processOwnershipRoot: self.root.appendingPathComponent("ownership"),
      executionDatabase: database)
    host.ownedWork = ownedWork
    if server.transport == .stdio {
      let database = database
      let runtime = runtime
      host.providerSource = { selected in
        let review = try GatewayProviderReview(
          server: selected, configuration: database.configurationState())
        return MCPProviderExecutionSource(
          digest: review.sourceDigest,
          prepareDiscovery: { replacement, caller in
            try GatewaySynchronousOperation.run {
              try await runtime.prepareProvider(
                review: review, registrationID: selected.id,
                authorization: nil, directory: nil, connectionID: nil,
                mcpDiscovery: true, discoveryReplacement: replacement, discoveryCaller: caller)
            }
          })
      }
    }
    hostContext = host
    client = MCPProxyClient(
      launcher: launcher, workingDirectory: self.root, hostContext: host,
      executionDatabase: database, executionScope: executionScope)
    try GatewaySynchronousOperation.run { [runtime] in try await runtime.ready() }
  }

  var context: InvocationContext {
    get throws {
      let prepared = try GatewaySynchronousOperation.run { [self] in
        let requirements = try InvocationRequirements(
          actions: [
            .init(requirement: .init(.project("fixture"), .write)),
            .init(requirement: .init(.mcpServer(server.id), .all)),
          ], mode: .fullAccess(.standing), sandboxProjectID: "fixture")
        let admission = try runtime.service.admit(
          subject: GatewayPermissionSubject(context: callerContext), tool: "proxy.protocol",
          projectID: "fixture", argumentsDigest: MCPExecutionRecord.digest(try .encoded(server)),
          requirements: requirements, connectionID: callerContext.controlSession?.id)
        guard case .allowed(let authorization) = admission else {
          throw PermissionModelError.invalidAuthorization
        }
        if server.transport == .stdio {
          return try await runtime.prepareProvider(
            review: GatewayProviderReview(
              server: server, configuration: database.configurationState()),
            registrationID: server.id, authorization: authorization, directory: projectRoot,
            connectionID: callerContext.controlSession?.id)
        }
        return try await runtime.coordinator.prepare(
          authorizationID: authorization.id,
          context: .init(
            directory: SandboxPath(projectRoot.path), temporaryDirectory: SandboxPath(scratch.path),
            purpose: .remoteService), connectionID: callerContext.controlSession?.id)
      }
      lock.withLock { preparedContexts.append(prepared) }
      return InvocationContext(session: callerContext.controlSession, executionAuthority: prepared)
    }
  }

  func reconfigure(_ server: MCPServerConfig) throws {
    try fixtureApproveLocalProvider(
      server, database: database, runtime: runtime,
      permissions: fixturePermissions([
        .project("fixture"): .granted(.write), .mcpServer(server.id): .granted(.all),
      ]), fullAccess: true)
    self.server = server
  }

  func providerMarker(_ original: URL) throws -> URL {
    let container = try database.prepareProviderContainer(.localServer(server.id))
    return URL(fileURLWithPath: try container.sandbox.home.value).appendingPathComponent(
      original.lastPathComponent)
  }

  func continuing(_ target: MCPContinuationTarget) throws -> InvocationContext {
    let admitted = try context
    let retained = try hostContext.ownedWork?.continuations.execution(for: target)
    return InvocationContext(
      session: admitted.session, continuation: target,
      executionAuthority: retained ?? admitted.executionAuthority)
  }

  func close() throws {
    try GatewaySynchronousOperation.run { [self] in
      await client.shutdown()
      for prepared in lock.withLock({ preparedContexts }) { try prepared.finishAdmission() }
      try await runtime.coordinator.reconcile()
      (callerContext.controlSession as? GatewayControlSession)?.end()
    }
  }
}

private final class BlockingTestOperation: @unchecked Sendable {
  private let operation: () throws -> Void

  init(_ operation: @escaping () throws -> Void) {
    self.operation = operation
  }

  func run() throws {
    try operation()
  }
}
