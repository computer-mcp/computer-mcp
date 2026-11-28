import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import MCP
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

@Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(1)))
struct MCPConnectionLifecycleTests {
  #if canImport(Darwin)
    // Connected MCP transports inherit an ownership descriptor, supported only on Darwin.
    @Test
    func completedResponseSurvivesNativeExitAndClosedClientIsReleased() async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      weak var releasedClient: MCPProxyClient?
      do {
        let client = MCPProxyClient(
          launcher: testExecutionLauncher(), workingDirectory: fixture.directory,
          environment: fixture.environment)
        releasedClient = client
        let server = fixture.server(version: "first")
        do {
          let result = try await blocking(fixture, server: server) { context in
            try client.callTool(
              server: server, name: "first",
              arguments: .object([
                "exit_after_response": .bool(true)
              ]), context: context)
          }
          #expect(result.objectValue?["isError"] != .bool(true))
          #expect(
            result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]
              == .string("done")
          )
          try await fixture.expectAllExited()
          let deadline = ContinuousClock.now + .seconds(1)
          while try client.connectionStatus(
            server: server, context: fixture.context(server: server)
          ).objectValue?["state"]
            == .string("connected"),
            ContinuousClock.now < deadline
          {
            try await Task.sleep(for: .milliseconds(10))
          }
          #expect(
            try client.connectionStatus(server: server, context: fixture.context(server: server))
              .objectValue?["state"]
              != .string("connected"))
          await client.shutdown()
          try await fixture.finish()
        } catch {
          await client.shutdown()
          try await fixture.finish()
          throw error
        }
      }
      #expect(releasedClient == nil)
    }
  #endif

  @Test
  func responsiveDescendantIsReapedWithoutSpendingTheTerminationGrace() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let administration = ExecutionAdministration(
      mode: .fullAccess,
      environment: try .init(fullAccessVariables: fixture.environment))
    let transport = try ExecutionAdministration.$current.withValue(administration) {
      try ManagedLineProcess(
        launcher: testExecutionLauncher(),
        configuration: .init(
          executable: "/bin/sh", arguments: ["-c", "/bin/sleep 30 & printf '%s\\n' \"$!\""],
          environment: fixture.environment, workingDirectory: fixture.directory,
          terminationGraceMilliseconds: 30_000))
    }
    do {
      var lines = transport.inboundLines.makeAsyncIterator()
      let ready = try #require(try await lines.next())
      let descendant = try #require(Int32(ready))
      let started = ContinuousClock.now
      await transport.close()
      try await fixture.finish()
      let stopped = await transport.snapshot()
      let supervisor = try #require(stopped.supervisorProcessID)
      #expect(started.duration(to: .now) < .seconds(5))
      #expect(stopped.state == .stopped)
      #expect(!stopped.terminationEscalated)
      #expect(kill(descendant, 0) == -1 && errno == ESRCH)
      #expect(kill(supervisor, 0) == -1 && errno == ESRCH)
    } catch {
      await transport.close()
      try await fixture.finish()
      throw error
    }
  }

  @Test
  func cleanEOFReapsTheSupervisorWithoutSpendingTheTerminationGrace() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let administration = ExecutionAdministration(
      mode: .fullAccess,
      environment: try .init(fullAccessVariables: fixture.environment))
    let transport = try ExecutionAdministration.$current.withValue(administration) {
      try ManagedLineProcess(
        launcher: testExecutionLauncher(),
        configuration: .init(
          executable: "/bin/sh",
          arguments: ["-c", "printf '%s\\n' \"$$\"; while read line; do :; done"],
          environment: fixture.environment, workingDirectory: fixture.directory,
          terminationGraceMilliseconds: 30_000))
    }
    do {
      var lines = transport.inboundLines.makeAsyncIterator()
      let ready = try #require(try await lines.next())
      let processID = try #require(Int32(ready))
      // A delivered command also establishes that child PID publication has
      // completed; stdout alone can arrive during the launch/close race.
      try await transport.sendLine("ready")
      let started = ContinuousClock.now

      await transport.close()
      try await fixture.finish()

      let stopped = await transport.snapshot()
      let supervisorID = try #require(stopped.supervisorProcessID)
      #expect(started.duration(to: .now) < .seconds(5))
      #expect(stopped.state == .stopped)
      #expect(stopped.exitCode == 0)
      #expect(!stopped.terminationEscalated)
      #expect(kill(processID, 0) == -1 && errno == ESRCH)
      #expect(kill(supervisorID, 0) == -1 && errno == ESRCH)
    } catch {
      await transport.close()
      try await fixture.finish()
      throw error
    }
  }

  @Test(arguments: [0, 1_000, 30_000])
  func sharedProcessPreservesAcceptedHostTerminationBudgets(grace: Int) throws {
    let configuration = ManagedLineProcess.Configuration(
      executable: "/bin/sh", workingDirectory: FileManager.default.temporaryDirectory,
      terminationGraceMilliseconds: grace, killGraceMilliseconds: 30_000)
    try configuration.validate()
  }

  @Test
  func hostDeathReapsResponsiveCommandAndItsLongDeadlineTimer() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let owner = Process()
    owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
    owner.arguments = ["30"]
    owner.environment = fixture.environment
    owner.currentDirectoryURL = fixture.directory
    try owner.run()
    defer {
      if owner.isRunning { owner.terminate() }
      owner.waitUntilExit()
    }
    let administration = ExecutionAdministration(
      mode: .fullAccess,
      environment: try .init(fullAccessVariables: fixture.environment))
    let transport = try ExecutionAdministration.$current.withValue(administration) {
      try ManagedLineProcess(
        launcher: testExecutionLauncher(),
        configuration: .init(
          executable: try testExecutable("python3"),
          arguments: [
            "-c",
            "import os,signal,time; signal.signal(signal.SIGTERM,lambda *_:exit(0)); print(os.getpid(),flush=True); time.sleep(30)",
          ],
          environment: fixture.environment, workingDirectory: fixture.directory,
          terminationGraceMilliseconds: 30_000, ownerProcessID: owner.processIdentifier))
    }
    do {
      var lines = transport.inboundLines.makeAsyncIterator()
      let ready = try #require(try await lines.next())
      let child = try #require(Int32(ready))
      #if canImport(Darwin)
        owner.terminate()
      #elseif canImport(Glibc) || canImport(Musl)
        // Foundation Process can inherit a blocked SIGTERM mask from its launching thread.
        try #require(kill(owner.processIdentifier, SIGKILL) == 0)
        owner.waitUntilExit()
      #endif
      let deadline = ContinuousClock.now + .seconds(5)
      while !(await transport.snapshot().hasExited), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let stopped = await transport.snapshot()
      #expect(stopped.hasExited)
      #expect(stopped.exitCode == 0)
      #expect(kill(child, 0) == -1 && errno == ESRCH)
      await transport.close()
      try await fixture.finish()
    } catch {
      await transport.close()
      try await fixture.finish()
      throw error
    }
  }

  #if canImport(Darwin)
    // Connected MCP transports inherit an ownership descriptor, supported only on Darwin.
    @Test(arguments: ["duplicateID", "unknownCancel", "foreignAuthority", "invalidEvents"])
    func rejectedRequestPreservesUnrelatedWork(failure: String) async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let foreignFixture = try failure == "foreignAuthority" ? LifecycleFixture() : nil
      defer { foreignFixture?.remove() }
      let client = MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: fixture.directory,
        environment: fixture.environment)
      let server = fixture.server(version: "first")
      do {
        _ = try await blocking(fixture, server: server) { context in
          try client.startToolCall(
            server: server, name: "hang", arguments: .object([:]), requestID: "sibling",
            context: context)
        }
        try await fixture.waitForCalls(1)
        await #expect(throws: (any Error).self) {
          try await blocking(foreignFixture ?? fixture, server: server) { context in
            switch failure {
            case "duplicateID":
              return try client.startToolCall(
                server: server, name: "hang", arguments: .object(["changed": .bool(true)]),
                requestID: "sibling", context: context)
            case "unknownCancel":
              return try client.cancelRequest(
                server: server, requestID: "absent", reason: nil, context: context)
            case "foreignAuthority":
              do {
                return try client.cancelRequest(
                  server: server, requestID: "sibling", reason: nil, context: context)
              } catch {
                #expect((error as? PermissionModelError) == .invalidAuthorization)
                throw error
              }
            default:
              return try client.readEvents(
                server: server, afterCursor: -1, maxResults: 10, context: context)
            }
          }
        }
        try await foreignFixture?.finish()
        let requests = try await blocking(fixture, server: server) { context in
          try client.activeRequests(server: server, context: context)
        }
        #expect(requests.objectValue?["requests"]?.arrayValue?.count == 1)
        #expect(
          requests.objectValue?["requests"]?.arrayValue?.first?.objectValue?["request_id"]
            == .string("sibling"))
        let tools = try await blocking(fixture, server: server) { context in
          try client.listTools(server: server, context: context)
        }
        #expect(tools.map(\.name) == ["first", "hang"])
        #expect(try fixture.starts().count == 1)
        #expect(try fixture.calls().count == 1)
        #expect(try fixture.cancellations().isEmpty)
        await client.shutdown()
        try await fixture.finish()
        try await fixture.expectAllExited()
      } catch {
        await client.shutdown()
        try await foreignFixture?.finish()
        try await fixture.finish()
        throw error
      }
    }

    @Test
    func cancellingAWaitedRequestPreservesItsSiblingAndConnection() async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let client = MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: fixture.directory,
        environment: fixture.environment)
      let server = fixture.server(version: "first")
      do {
        _ = try await blocking(fixture, server: server) { context in
          try client.startToolCall(
            server: server, name: "hang", arguments: .object([:]), requestID: "sibling",
            context: context)
        }
        let waited = Task {
          try await blocking(fixture, server: server) { context in
            try client.callTool(
              server: server, name: "hang", arguments: .object([:]), requestID: "waited",
              context: context)
          }
        }
        try await fixture.waitForCalls(2)
        _ = try await blocking(fixture, server: server) { context in
          try client.cancelRequest(
            server: server, requestID: "waited", reason: "cancel only this request",
            context: context
          )
        }
        let outcome = await waited.result
        guard case .failure(let error) = outcome else {
          await client.shutdown()
          try await fixture.finish()
          Issue.record("Cancelled request unexpectedly succeeded.")
          return
        }
        #expect(error is CancellationError)
        let receipt = try await blocking(fixture, server: server) { context in
          try client.readRequest(
            server: server, requestID: "waited", offset: 0, maxBytes: 4096, context: context)
        }
        #expect(receipt.objectValue?["state"] == .string("outcome_unknown"))
        #expect(receipt.objectValue?["cancellation"] == .string("sent"))
        #expect(receipt.objectValue?["output_state"] == .string("unavailable"))
        await #expect(throws: (any Error).self) {
          try await blocking(fixture, server: server) { context in
            try client.callTool(
              server: server, name: "hang", arguments: .object([:]), requestID: "waited",
              context: context)
          }
        }
        let observed = try await blocking(fixture, server: server) { context in
          try client.startToolCall(
            server: server, name: "hang", arguments: .object([:]), requestID: "waited",
            context: context)
        }
        #expect(observed.objectValue?["state"] == .string("outcome_unknown"))
        #expect(try fixture.calls().count == 2)
        let requests = try await blocking(fixture, server: server) { context in
          try client.activeRequests(server: server, context: context)
        }
        #expect(requests.objectValue?["requests"]?.arrayValue?.count == 1)
        #expect(
          requests.objectValue?["requests"]?.arrayValue?.first?.objectValue?["request_id"]
            == .string("sibling"))
        _ = try await blocking(fixture, server: server) { context in
          try client.listTools(server: server, context: context)
        }
        #expect(try fixture.starts().count == 1)
        #expect(try fixture.cancellations().count == 1)
        await client.shutdown()
        try await fixture.finish()
        try await fixture.expectAllExited()
      } catch {
        await client.shutdown()
        try await fixture.finish()
        throw error
      }
    }

    @Test(arguments: [-32601, -32602, -32050, -32042])
    func remoteRequestErrorsPreserveCodeAndUnrelatedWork(code: Int) async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let client = MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: fixture.directory,
        environment: fixture.environment)
      let server = fixture.server(version: "first")
      do {
        _ = try await blocking(fixture, server: server) { context in
          try client.startToolCall(
            server: server, name: "hang", arguments: .object([:]), requestID: "sibling",
            context: context)
        }
        try await fixture.waitForCalls(1)
        do {
          _ = try await blocking(fixture, server: server) { context in
            try client.callTool(
              server: server, name: "first",
              arguments: .object(["error_code": .number(Double(code))]), context: context)
          }
          Issue.record("The fixture's JSON-RPC error was not propagated.")
        } catch let error as MCPError {
          #expect(error.code == code)
          if code == -32042 {
            guard case .urlElicitationRequired(let message, let elicitations) = error else {
              await client.shutdown()
              try await fixture.finish()
              Issue.record("URL elicitation lost its typed error details.")
              return
            }
            #expect(message == "fixture rejection")
            #expect(elicitations.count == 1)
            #expect(elicitations.first?.elicitationId == "fixture-input")
            #expect(elicitations.first?.url == "https://example.invalid/confirm")
          }
        }
        let requests = try await blocking(fixture, server: server) { context in
          try client.activeRequests(server: server, context: context)
        }
        #expect(requests.objectValue?["requests"]?.arrayValue?.count == 1)
        #expect(
          requests.objectValue?["requests"]?.arrayValue?.first?.objectValue?["request_id"]
            == .string("sibling"))
        _ = try await blocking(fixture, server: server) { context in
          try client.listTools(server: server, context: context)
        }
        #expect(try fixture.starts().count == 1)
        #expect(try fixture.calls().count == 2)
        #expect(try fixture.cancellations().isEmpty)
        await client.shutdown()
        try await fixture.finish()
        try await fixture.expectAllExited()
      } catch {
        await client.shutdown()
        try await fixture.finish()
        throw error
      }
    }

    @Test
    func toolErrorResultPreservesContentAndUnrelatedWork() async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let client = MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: fixture.directory,
        environment: fixture.environment)
      let server = fixture.server(version: "first")
      do {
        _ = try await blocking(fixture, server: server) { context in
          try client.startToolCall(
            server: server, name: "hang", arguments: .object([:]), requestID: "sibling",
            context: context)
        }
        try await fixture.waitForCalls(1)
        let result = try await blocking(fixture, server: server) { context in
          try client.callTool(
            server: server, name: "first", arguments: .object(["tool_error": .bool(true)]),
            context: context)
        }
        #expect(result.objectValue?["isError"] == .bool(true))
        #expect(result.objectValue?["structuredContent"] == .object(["accepted": .bool(false)]))
        #expect(
          result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]
            == .string("operation rejected"))
        let requests = try await blocking(fixture, server: server) { context in
          try client.activeRequests(server: server, context: context)
        }
        #expect(requests.objectValue?["requests"]?.arrayValue?.count == 1)
        _ = try await blocking(fixture, server: server) { context in
          try client.listTools(server: server, context: context)
        }
        #expect(try fixture.calls() == [.string("hang"), .string("first")])
        #expect(try fixture.starts().count == 1)
        #expect(try fixture.cancellations().isEmpty)
        await client.shutdown()
        try await fixture.finish()
        try await fixture.expectAllExited()
      } catch {
        await client.shutdown()
        try await fixture.finish()
        throw error
      }
    }

    @Test
    func concurrentDuplicateIDsDispatchExactlyOneRequest() async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let client = MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: fixture.directory,
        environment: fixture.environment)
      let server = fixture.server(version: "first")
      do {
        _ = try await blocking(fixture, server: server) { context in
          try client.listTools(server: server, context: context)
        }
        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
          for _ in 0..<32 {
            group.addTask {
              do {
                _ = try await blocking(fixture, server: server) { context in
                  try client.startToolCall(
                    server: server, name: "hang", arguments: .object([:]),
                    requestID: "one-operation",
                    context: context)
                }
                return true
              } catch {
                return false
              }
            }
          }
          var count = 0
          for await success in group where success { count += 1 }
          return count
        }
        #expect(accepted == 32)
        try await fixture.waitForCalls(1)
        let requests = try await blocking(fixture, server: server) { context in
          try client.activeRequests(server: server, context: context)
        }
        #expect(requests.objectValue?["requests"]?.arrayValue?.count == 1)
        #expect(try fixture.calls().count == 1)
        #expect(try fixture.starts().count == 1)
        await client.shutdown()
        try await fixture.finish()
        try await fixture.expectAllExited()
      } catch {
        await client.shutdown()
        try await fixture.finish()
        throw error
      }
    }

    @Test
    func replacementJoinsTheOldGenerationBeforeStartingAndDoesNotReplayWork() async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let client = MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: fixture.directory,
        environment: fixture.environment)
      let original = fixture.server(version: "first")
      do {
        let tools = try await blocking(fixture, server: original) { context in
          try client.listTools(server: original, context: context)
        }
        #expect(tools.map(\.name) == ["first", "hang"])
        _ = try await blocking(fixture, server: original) { context in
          try client.startToolCall(
            server: original, name: "hang", arguments: .object([:]), requestID: "owned-write",
            context: context)
        }
        try await fixture.waitForCalls(1)
        let replacement = fixture.server(version: "second")
        let next = try await blocking(fixture, server: replacement) { context in
          try client.listTools(server: replacement, context: context)
        }
        #expect(next.map(\.name) == ["second", "hang"])
        let starts = try fixture.starts()
        #expect(starts.count == 2)
        #expect(starts.last?.objectValue?["overlap"] == .bool(false))
        #expect(try fixture.calls().count == 1)
        #expect(try fixture.cancellations().count == 1)
        await client.shutdown()
        try await fixture.finish()
        try await fixture.expectAllExited()
      } catch {
        await client.shutdown()
        try await fixture.finish()
        throw error
      }
    }

    @Test(arguments: [false, true])
    func timeoutRetirementIsJoinedByConcurrentShutdown(startup: Bool) async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let client = MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: fixture.directory,
        environment: fixture.environment)
      let server = fixture.server(version: "first", holdInitialize: startup, shortDeadline: true)
      let call = Task {
        try await blocking(fixture, server: server) { context in
          if startup { return try client.listTools(server: server, context: context).count }
          _ = try client.callTool(
            server: server, name: "hang", arguments: .object([:]), requestID: "timed-out",
            context: context)
          return 0
        }
      }
      let result = await call.result
      guard case .failure(let error) = result else {
        await client.shutdown()
        try await fixture.finish()
        Issue.record("The deliberately stalled request unexpectedly completed.")
        return
      }
      #expect(String(describing: error).contains("timed out"))
      async let first: Void = client.shutdown()
      async let second: Void = client.shutdown()
      _ = await (first, second)
      try await fixture.finish()
      try await fixture.expectAllExited()
      #expect(try fixture.starts().count == 1)
      #expect(try fixture.calls().count == (startup ? 0 : 1))
      #expect(try fixture.cancellations().count == (startup ? 0 : 1))
      let status = try client.connectionStatus(
        server: server, context: fixture.context(server: server))
      #expect(status.objectValue?["state"] == .string("stopped"))
      await #expect(throws: (any Error).self) {
        try await blocking(fixture, server: server) { context in
          try client.listTools(server: server, context: context)
        }
      }
      #expect(try fixture.starts().count == 1)
    }

    @Test(arguments: [false, true])
    func asyncCallCancellationStopsDiscoveryBeforeToolForwarding(inheritedStop: Bool) async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let base = MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: fixture.directory,
        environment: fixture.environment)
      var server = fixture.server(version: "first")
      server.allowedTools = ["first"]
      server.toolRisks = ["first": .readOnly]
      let configured = server
      var permissions = Permissions.newPrincipal
      try permissions.set(.granted(.read), for: .mcpServer(server.id))
      let client = AuthorizedMCPClient(
        base: base,
        policy: .init(
          configuration: .init(mcp: .init(servers: [server])),
          grant: .init(id: .localAdmin, permissions: permissions, allowedCallers: [.localMCP])))
      let flag = DiscoveryStopFlag()
      let changes = base.toolChanges()
      let notifications = Task { () -> Int in
        var count = 0
        for await _ in changes { count += 1 }
        return count
      }
      let hold = fixture.directory.appendingPathComponent("hold-list")
      try Data().write(to: hold)
      let prepared = try fixture.scope.prepared(variables: server.env)
      let request = Task {
        try await client.callToolAsync(
          server: configured, name: "first", arguments: .object([:]), requestID: nil,
          context: .init(executionAuthority: prepared, isDiscoveryCancelled: { flag.stopped }))
      }
      do {
        try await fixture.waitForHeldList()
        if inheritedStop { flag.stop() } else { request.cancel() }
        try FileManager.default.removeItem(at: hold)
        do {
          _ = try await request.value
          Issue.record("Stopped async discovery forwarded the actual tool")
        } catch { #expect(error is CancellationError) }
        #expect(try fixture.calls().isEmpty)
        #expect(try base.cachedTools(server: server, context: .empty) == nil)
        await base.shutdown()
        #expect(await notifications.value == 0)
        try await fixture.finish()
        try await fixture.expectAllExited()
      } catch {
        flag.stop()
        request.cancel()
        try? FileManager.default.removeItem(at: hold)
        _ = await request.result
        await base.shutdown()
        _ = await notifications.value
        try await fixture.finish()
        throw error
      }
    }

    @Test
    func stoppedDiscoveryDoesNotPublishTheInFlightCatalog() async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let client = MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: fixture.directory,
        environment: fixture.environment)
      let server = fixture.server(version: "first")
      let flag = DiscoveryStopFlag()
      let changes = client.toolChanges()
      let notifications = Task { () -> Int in
        var count = 0
        for await _ in changes { count += 1 }
        return count
      }
      let hold = fixture.directory.appendingPathComponent("hold-list")
      try Data().write(to: hold)
      let request = Task {
        try await blocking(fixture, server: server) { context in
          try client.listTools(
            server: server,
            context: .init(
              executionAuthority: context.executionAuthority,
              isDiscoveryCancelled: { flag.stopped }))
        }
      }
      do {
        try await fixture.waitForHeldList()
        flag.stop()
        try FileManager.default.removeItem(at: hold)
        do {
          _ = try await request.value
          Issue.record("A stopped waiter published an in-flight catalog")
        } catch { #expect(error is CancellationError) }
        #expect(try client.cachedTools(server: server, context: .empty) == nil)
        #expect(try fixture.calls().isEmpty)
        await client.shutdown()
        let count = await notifications.value
        #expect(count == 0)
        try await fixture.finish()
        try await fixture.expectAllExited()
      } catch {
        flag.stop()
        try? FileManager.default.removeItem(at: hold)
        _ = await request.result
        await client.shutdown()
        _ = await notifications.value
        try await fixture.finish()
        throw error
      }
    }

    @Test
    func timeoutReconnectRefreshesTheCatalogAfterConfirmedRetirement() async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let client = MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: fixture.directory,
        environment: fixture.environment)
      let server = fixture.server(version: "first", shortDeadline: true)
      do {
        await #expect(throws: (any Error).self) {
          try await blocking(fixture, server: server) { context in
            try client.callTool(
              server: server, name: "hang", arguments: .object([:]), requestID: "one-write",
              context: context)
          }
        }
        try Data("refreshed".utf8).write(to: fixture.directory.appendingPathComponent("version"))
        let tools = try await blocking(fixture, server: server) { context in
          try client.listTools(server: server, context: context)
        }
        #expect(tools.map(\.name) == ["refreshed", "hang"])
        #expect(try fixture.starts().count == 2)
        #expect(try fixture.starts().last?.objectValue?["overlap"] == .bool(false))
        #expect(try fixture.calls().count == 1)
        await client.shutdown()
        try await fixture.finish()
        try await fixture.expectAllExited()
      } catch {
        await client.shutdown()
        try await fixture.finish()
        throw error
      }
    }

    @Test
    func shutdownDuringInitializeCannotActivateALateConnection() async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let client = MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: fixture.directory,
        environment: fixture.environment)
      let server = fixture.server(version: "first", holdInitialize: true)
      let starting = Task {
        try await blocking(fixture, server: server) { context in
          try client.listTools(server: server, context: context)
        }
      }
      do {
        try await fixture.waitForStarts(1)
        async let first: Void = client.shutdown()
        async let second: Void = client.shutdown()
        _ = await (first, second)
        try await fixture.finish()
        guard case .failure = await starting.result else {
          Issue.record("A closed generation must not publish initialization.")
          return
        }
        try await fixture.expectAllExited()
        #expect(try fixture.starts().count == 1)
        #expect(
          try client.connectionStatus(server: server, context: fixture.context(server: server))
            .objectValue?["state"]
            == .string("stopped"))
      } catch {
        await client.shutdown()
        _ = await starting.result
        try await fixture.finish()
        throw error
      }
    }

  #endif

  @Test
  func disconnectBeforeTransportConnectDoesNotLaunchAProcess() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let transport = try MCPChildProcessTransport(
      launcher: testExecutionLauncher(),
      server: fixture.server(version: "first"), workingDirectory: fixture.directory,
      environment: ProcessInfo.processInfo.environment)
    await transport.disconnect()
    await #expect(throws: (any Error).self) { try await transport.connect() }
    #expect(await transport.shutdownConfirmed())
    #expect(try fixture.starts().isEmpty)
    try await fixture.finish()
  }

  #if canImport(Darwin)
    // Connected MCP transports inherit an ownership descriptor, supported only on Darwin.
    @Test
    func closedChildTransportJoinsStubbornDescendantsForEveryWaiter() async throws {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let server = fixture.server(version: "first")
      let environment = fixture.environment.merging(server.env) { _, value in value }
      let transport = try MCPChildProcessTransport(
        launcher: testExecutionLauncher(),
        server: server, workingDirectory: fixture.directory, environment: environment)
      do {
        let administration = ExecutionAdministration(
          mode: .fullAccess, environment: try .init(fullAccessVariables: environment))
        try await ExecutionAdministration.$current.withValue(administration) {
          try await transport.connect()
        }
        try await fixture.waitForStarts(1)
        async let first: Void = transport.disconnect()
        async let second: Void = transport.disconnect()
        _ = await (first, second)
        try await fixture.finish()
        #expect(await transport.shutdownConfirmed())
        try await fixture.expectAllExited()
        await #expect(throws: (any Error).self) { try await transport.send(Data("{}".utf8)) }
      } catch {
        await transport.disconnect()
        try await fixture.finish()
        throw error
      }
    }
  #endif
}

private func blocking<T: Sendable>(
  _ fixture: LifecycleFixture, server: MCPServerConfig,
  _ operation: @escaping @Sendable (InvocationContext) throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      continuation.resume(
        with: Result {
          let prepared = try fixture.scope.prepared(variables: server.env)
          return try InvocationExecution.$current.withValue(prepared) {
            try operation(InvocationContext(executionAuthority: prepared))
          }
        })
    }
  }
}

private final class DiscoveryStopFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var stopped: Bool { lock.withLock { value } }
  func stop() { lock.withLock { value = true } }
}

private struct LifecycleFixture: Sendable {
  let directory: URL
  let script: URL
  let scope: MCPConnectionFixtureScope

  init() throws {
    directory = try ProjectPathResolver.canonicalProject(FileManager.default.temporaryDirectory)
      .appendingPathComponent(
        "mcp-lifecycle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    scope = try MCPConnectionFixtureScope(directory: directory)
    script = directory.appendingPathComponent("peer.pl")
    try Data(
      #"""
      #!/usr/bin/perl
      use strict;
      use warnings;
      use Errno qw(ESRCH);
      use JSON::PP qw(decode_json encode_json);
      use POSIX qw(_exit);
      use Time::HiRes qw(usleep);

      my ($root) = @ARGV;
      $| = 1;
      $SIG{TERM} = 'IGNORE';
      $SIG{PIPE} = 'IGNORE';

      sub append_record {
        my ($name, $value) = @_;
        open my $file, '>>', "$root/$name" or die "open $name: $!";
        print {$file} encode_json($value), "\n" or die "write $name: $!";
        close $file or die "close $name: $!";
      }

      sub process_exists {
        my ($pid) = @_;
        return 1 if kill 0, $pid;
        return 0 if $! == ESRCH;
        die "probe process $pid: $!";
      }

      my @previous;
      if (-e "$root/starts") {
        open my $file, '<', "$root/starts" or die "open starts: $!";
        @previous = map { decode_json($_) } <$file>;
      }

      my $child = fork();
      die "fork descendant: $!" unless defined $child;
      if ($child == 0) {
        $SIG{PIPE} = 'DEFAULT';
        open STDIN, '<', '/dev/null' or die "redirect stdin: $!";
        open STDOUT, '>', '/dev/null' or die "redirect stdout: $!";
        open STDERR, '>', '/dev/null' or die "redirect stderr: $!";
        exec '/bin/sh', '-c', "trap '' TERM; while :; do /bin/sleep 1; done";
        die "exec descendant: $!";
      }

      my $overlap = JSON::PP::false;
      for my $start (@previous) {
        if (process_exists($start->{pid})) {
          $overlap = JSON::PP::true;
          last;
        }
      }
      append_record('starts', {
        pid => $$, child => $child, supervisor => getppid(), overlap => $overlap,
      });

      while (my $line = <STDIN>) {
        my $message = decode_json($line);
        my $method = $message->{method} // '';
        if ($method eq 'notifications/cancelled') {
          append_record('cancellations', $message->{params}{requestId});
          next;
        }
        next unless exists $message->{id};

        my $response = {jsonrpc => '2.0', id => $message->{id}, result => {}};
        my $exit_after_response;
        if ($method eq 'initialize') {
          usleep(10_000) while ($ENV{HOLD_INITIALIZE} // '') eq '1';
          $response->{result} = {
            protocolVersion => '2025-11-25', capabilities => {tools => {}},
            serverInfo => {name => 'owned-lifecycle-fixture', version => '1'},
          };
        } elsif ($method eq 'tools/list') {
          if (-e "$root/hold-list") {
            append_record('held-lists', $$);
            usleep(10_000) while -e "$root/hold-list";
          }
          my $version = $ENV{CATALOG_VERSION};
          if (-e "$root/version") {
            open my $file, '<:encoding(UTF-8)', "$root/version" or die "open version: $!";
            local $/;
            $version = <$file> // '';
          }
          $response->{result} = {
            tools => [map { {name => $_, inputSchema => {type => 'object'}} } ($version, 'hang')],
          };
        } elsif ($method eq 'tools/call') {
          my $name = $message->{params}{name};
          append_record('calls', $name);
          next if $name eq 'hang';
          my $arguments = $message->{params}{arguments} // {};
          if (exists $arguments->{error_code}) {
            my $error = {code => $arguments->{error_code}, message => 'fixture rejection'};
            if ($error->{code} == -32042) {
              $error->{data} = {elicitations => [{
                mode => 'url', elicitationId => 'fixture-input',
                url => 'https://example.invalid/confirm', message => 'fixture input',
              }]};
            }
            delete $response->{result};
            $response->{error} = $error;
          } else {
            $response->{result} = {content => [{type => 'text', text => 'done'}]};
            if ($arguments->{tool_error}) {
              $response->{result} = {
                content => [{type => 'text', text => 'operation rejected'}],
                structuredContent => {accepted => JSON::PP::false}, isError => JSON::PP::true,
              };
            }
            $exit_after_response = $arguments->{exit_after_response};
          }
        }
        print encode_json($response), "\n" or die "write response: $!";
        _exit(0) if $exit_after_response;
      }

      usleep(10_000) while 1;
      """#.utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
  }

  func server(version: String, holdInitialize: Bool = false, shortDeadline: Bool = false)
    -> MCPServerConfig
  {
    MCPServerConfig(
      id: "owned-lifecycle", transport: .stdio, command: "/bin/sh",
      args: [
        "-c", "exec 3<&0; \"$@\" <&3 3<&- & peer=$!; exec 3<&-; wait \"$peer\"",
        "owned-lifecycle", script.path, directory.path,
      ],
      env: ["CATALOG_VERSION": version, "HOLD_INITIALIZE": holdInitialize ? "1" : "0"],
      startupTimeoutMs: holdInitialize && shortDeadline ? 1_000 : 10_000,
      requestTimeoutMs: shortDeadline ? 1_000 : 10_000, hostServices: false)
  }

  func starts() throws -> [JSONValue] { try records("starts") }
  func calls() throws -> [JSONValue] { try records("calls") }
  func cancellations() throws -> [JSONValue] { try records("cancellations") }

  private func records(_ name: String) throws -> [JSONValue] {
    let path = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: path.path) else { return [] }
    return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
  }

  func waitForStarts(_ count: Int) async throws {
    try await wait { try starts().count >= count }
  }

  func waitForHeldList() async throws {
    try await wait { try records("held-lists").count == 1 }
  }

  func waitForCalls(_ count: Int) async throws {
    try await wait { try calls().count >= count }
  }

  private func wait(_ predicate: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(try predicate()) {
      guard ContinuousClock.now < deadline else {
        throw GatewayToolError.executionFailed(
          "Owned lifecycle fixture did not reach its checkpoint.")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func expectAllExited() async throws {
    let pids = try starts().flatMap { value in
      ["pid", "child", "supervisor"].compactMap { value.objectValue?[$0]?.numberValue }.map(
        Int32.init)
    }
    #expect(!pids.isEmpty)
    try await wait { pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
  }

  var environment: [String: String] {
    [
      "PATH": "/usr/bin:/bin", "HOME": directory.path,
      "TMPDIR": directory.path + "/", "TMP": directory.path, "TEMP": directory.path,
    ]
  }

  func context(server: MCPServerConfig) throws -> InvocationContext {
    .init(executionAuthority: try scope.prepared(variables: server.env))
  }

  func finish() async throws { try await scope.finish() }

  func remove() {
    guard scope.joined else {
      Issue.record("Unjoined lifecycle fixture retained at \(directory.path)")
      return
    }
    try? FileManager.default.removeItem(at: directory)
  }
}
