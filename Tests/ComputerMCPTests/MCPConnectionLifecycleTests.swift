import Darwin
import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MCPConnectionLifecycleTests {
  @Test
  func completedResponseSurvivesNativeExitAndClosedClientIsReleased() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    weak var releasedClient: MCPProxyClient?
    do {
      let client = MCPProxyClient(workingDirectory: fixture.directory)
      releasedClient = client
      let server = fixture.server(version: "first")
      do {
        let result = try await blocking {
          try client.callTool(
            server: server, name: "first",
            arguments: .object([
              "exit_after_response": .bool(true)
            ]))
        }
        #expect(result.objectValue?["isError"] != .bool(true))
        #expect(
          result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"] == .string("done")
        )
        try await fixture.expectAllExited()
        let deadline = ContinuousClock.now + .seconds(1)
        while try client.connectionStatus(server: server).objectValue?["state"]
          == .string("connected"),
          ContinuousClock.now < deadline
        {
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
          try client.connectionStatus(server: server).objectValue?["state"] != .string("connected"))
        await client.shutdown()
      } catch {
        await client.shutdown()
        throw error
      }
    }
    #expect(releasedClient == nil)
  }

  @Test
  func responsiveDescendantIsReapedWithoutSpendingTheTerminationGrace() async throws {
    let transport = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh", arguments: ["-c", "/bin/sleep 30 & printf '%s\\n' \"$!\""],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 30_000))
    do {
      var lines = transport.inboundLines.makeAsyncIterator()
      let ready = try #require(try await lines.next())
      let descendant = try #require(Int32(ready))
      let started = ContinuousClock.now
      await transport.close()
      let stopped = await transport.snapshot()
      let supervisor = try #require(stopped.supervisorProcessID)
      #expect(started.duration(to: .now) < .seconds(5))
      #expect(stopped.state == .stopped)
      #expect(!stopped.terminationEscalated)
      #expect(Darwin.kill(descendant, 0) == -1 && errno == ESRCH)
      #expect(Darwin.kill(supervisor, 0) == -1 && errno == ESRCH)
    } catch {
      await transport.close()
      throw error
    }
  }

  @Test
  func cleanEOFReapsTheSupervisorWithoutSpendingTheTerminationGrace() async throws {
    let transport = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh",
        arguments: ["-c", "printf '%s\\n' \"$$\"; while read line; do :; done"],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 30_000))
    do {
      var lines = transport.inboundLines.makeAsyncIterator()
      let ready = try #require(try await lines.next())
      let processID = try #require(Int32(ready))
      // A delivered command also establishes that child PID publication has
      // completed; stdout alone can arrive during the launch/close race.
      try await transport.sendLine("ready")
      let started = ContinuousClock.now

      await transport.close()

      let stopped = await transport.snapshot()
      let supervisorID = try #require(stopped.supervisorProcessID)
      #expect(started.duration(to: .now) < .seconds(5))
      #expect(stopped.state == .stopped)
      #expect(stopped.exitCode == 0)
      #expect(!stopped.terminationEscalated)
      #expect(Darwin.kill(processID, 0) == -1 && errno == ESRCH)
      #expect(Darwin.kill(supervisorID, 0) == -1 && errno == ESRCH)
    } catch {
      await transport.close()
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
    let owner = Process()
    owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
    owner.arguments = ["30"]
    try owner.run()
    defer { if owner.isRunning { owner.terminate() } }
    let transport = try ManagedLineProcess(
      configuration: .init(
        executable: "/usr/bin/python3",
        arguments: [
          "-c",
          "import os,signal,time; signal.signal(signal.SIGTERM,lambda *_:exit(0)); print(os.getpid(),flush=True); time.sleep(30)",
        ],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 30_000, ownerProcessID: owner.processIdentifier))
    do {
      var lines = transport.inboundLines.makeAsyncIterator()
      let ready = try #require(try await lines.next())
      let child = try #require(Int32(ready))
      owner.terminate()
      let deadline = ContinuousClock.now + .seconds(5)
      while !(await transport.snapshot().hasExited), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let stopped = await transport.snapshot()
      #expect(stopped.hasExited)
      #expect(stopped.exitCode == 0)
      #expect(Darwin.kill(child, 0) == -1 && errno == ESRCH)
      await transport.close()
    } catch {
      await transport.close()
      throw error
    }
  }

  @Test(arguments: ["duplicateID", "unknownCancel", "invalidEvents"])
  func rejectedRequestPreservesUnrelatedWork(failure: String) async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let client = MCPProxyClient(workingDirectory: fixture.directory)
    let server = fixture.server(version: "first")
    do {
      _ = try await blocking {
        try client.startToolCall(
          server: server, name: "hang", arguments: .object([:]), requestID: "sibling")
      }
      try await fixture.waitForCalls(1)
      await #expect(throws: (any Error).self) {
        try await blocking {
          switch failure {
          case "duplicateID":
            return try client.startToolCall(
              server: server, name: "hang", arguments: .object(["changed": .bool(true)]),
              requestID: "sibling")
          case "unknownCancel":
            return try client.cancelRequest(server: server, requestID: "absent", reason: nil)
          default:
            return try client.readEvents(server: server, afterCursor: -1, maxResults: 10)
          }
        }
      }
      let requests = try await blocking { try client.activeRequests(server: server) }
      #expect(requests.objectValue?["requests"]?.arrayValue?.count == 1)
      #expect(
        requests.objectValue?["requests"]?.arrayValue?.first?.objectValue?["request_id"]
          == .string("sibling"))
      let tools = try await blocking { try client.listTools(server: server) }
      #expect(tools.map(\.name) == ["first", "hang"])
      #expect(try fixture.starts().count == 1)
      #expect(try fixture.calls().count == 1)
      #expect(try fixture.cancellations().isEmpty)
      await client.shutdown()
      try await fixture.expectAllExited()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test
  func cancellingAWaitedRequestPreservesItsSiblingAndConnection() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let client = MCPProxyClient(workingDirectory: fixture.directory)
    let server = fixture.server(version: "first")
    do {
      _ = try await blocking {
        try client.startToolCall(
          server: server, name: "hang", arguments: .object([:]), requestID: "sibling")
      }
      let waited = Task {
        try await blocking {
          try client.callTool(
            server: server, name: "hang", arguments: .object([:]), requestID: "waited")
        }
      }
      try await fixture.waitForCalls(2)
      _ = try await blocking {
        try client.cancelRequest(
          server: server, requestID: "waited", reason: "cancel only this request")
      }
      let outcome = await waited.result
      guard case .failure(let error) = outcome else {
        await client.shutdown()
        Issue.record("Cancelled request unexpectedly succeeded.")
        return
      }
      #expect(error is CancellationError)
      let receipt = try client.readRequest(
        server: server, requestID: "waited", offset: 0, maxBytes: 4096)
      #expect(receipt.objectValue?["state"] == .string("outcome_unknown"))
      #expect(receipt.objectValue?["cancellation"] == .string("sent"))
      #expect(receipt.objectValue?["output_state"] == .string("unavailable"))
      #expect(throws: (any Error).self) {
        try client.callTool(
          server: server, name: "hang", arguments: .object([:]), requestID: "waited")
      }
      let observed = try client.startToolCall(
        server: server, name: "hang", arguments: .object([:]), requestID: "waited")
      #expect(observed.objectValue?["state"] == .string("outcome_unknown"))
      #expect(try fixture.calls().count == 2)
      let requests = try await blocking { try client.activeRequests(server: server) }
      #expect(requests.objectValue?["requests"]?.arrayValue?.count == 1)
      #expect(
        requests.objectValue?["requests"]?.arrayValue?.first?.objectValue?["request_id"]
          == .string("sibling"))
      _ = try await blocking { try client.listTools(server: server) }
      #expect(try fixture.starts().count == 1)
      #expect(try fixture.cancellations().count == 1)
      await client.shutdown()
      try await fixture.expectAllExited()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test(arguments: [-32601, -32602, -32050, -32042])
  func remoteRequestErrorsPreserveCodeAndUnrelatedWork(code: Int) async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let client = MCPProxyClient(workingDirectory: fixture.directory)
    let server = fixture.server(version: "first")
    do {
      _ = try await blocking {
        try client.startToolCall(
          server: server, name: "hang", arguments: .object([:]), requestID: "sibling")
      }
      try await fixture.waitForCalls(1)
      do {
        _ = try await blocking {
          try client.callTool(
            server: server, name: "first", arguments: .object(["error_code": .number(Double(code))])
          )
        }
        Issue.record("The fixture's JSON-RPC error was not propagated.")
      } catch let error as MCPError {
        #expect(error.code == code)
        if code == -32042 {
          guard case .urlElicitationRequired(let message, let elicitations) = error else {
            await client.shutdown()
            Issue.record("URL elicitation lost its typed error details.")
            return
          }
          #expect(message == "fixture rejection")
          #expect(elicitations.count == 1)
          #expect(elicitations.first?.elicitationId == "fixture-input")
          #expect(elicitations.first?.url == "https://example.invalid/confirm")
        }
      }
      let requests = try await blocking { try client.activeRequests(server: server) }
      #expect(requests.objectValue?["requests"]?.arrayValue?.count == 1)
      #expect(
        requests.objectValue?["requests"]?.arrayValue?.first?.objectValue?["request_id"]
          == .string("sibling"))
      _ = try await blocking { try client.listTools(server: server) }
      #expect(try fixture.starts().count == 1)
      #expect(try fixture.calls().count == 2)
      #expect(try fixture.cancellations().isEmpty)
      await client.shutdown()
      try await fixture.expectAllExited()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test
  func toolErrorResultPreservesContentAndUnrelatedWork() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let client = MCPProxyClient(workingDirectory: fixture.directory)
    let server = fixture.server(version: "first")
    do {
      _ = try await blocking {
        try client.startToolCall(
          server: server, name: "hang", arguments: .object([:]), requestID: "sibling")
      }
      try await fixture.waitForCalls(1)
      let result = try await blocking {
        try client.callTool(
          server: server, name: "first", arguments: .object(["tool_error": .bool(true)]))
      }
      #expect(result.objectValue?["isError"] == .bool(true))
      #expect(result.objectValue?["structuredContent"] == .object(["accepted": .bool(false)]))
      #expect(
        result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]
          == .string("operation rejected"))
      let requests = try await blocking { try client.activeRequests(server: server) }
      #expect(requests.objectValue?["requests"]?.arrayValue?.count == 1)
      _ = try await blocking { try client.listTools(server: server) }
      #expect(try fixture.starts().count == 1)
      #expect(try fixture.cancellations().isEmpty)
      await client.shutdown()
      try await fixture.expectAllExited()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test
  func concurrentDuplicateIDsDispatchExactlyOneRequest() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let client = MCPProxyClient(workingDirectory: fixture.directory)
    let server = fixture.server(version: "first")
    do {
      _ = try await blocking { try client.listTools(server: server) }
      let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for _ in 0..<32 {
          group.addTask {
            do {
              _ = try await blocking {
                try client.startToolCall(
                  server: server, name: "hang", arguments: .object([:]), requestID: "one-operation")
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
      let requests = try await blocking { try client.activeRequests(server: server) }
      #expect(requests.objectValue?["requests"]?.arrayValue?.count == 1)
      #expect(try fixture.calls().count == 1)
      #expect(try fixture.starts().count == 1)
      await client.shutdown()
      try await fixture.expectAllExited()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test
  func replacementJoinsTheOldGenerationBeforeStartingAndDoesNotReplayWork() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let client = MCPProxyClient(workingDirectory: fixture.directory)
    let original = fixture.server(version: "first")
    do {
      let tools = try await blocking { try client.listTools(server: original) }
      #expect(tools.map(\.name) == ["first", "hang"])
      _ = try await blocking {
        try client.startToolCall(
          server: original, name: "hang", arguments: .object([:]), requestID: "owned-write")
      }
      try await fixture.waitForCalls(1)
      let replacement = fixture.server(version: "second")
      let next = try await blocking { try client.listTools(server: replacement) }
      #expect(next.map(\.name) == ["second", "hang"])
      let starts = try fixture.starts()
      #expect(starts.count == 2)
      #expect(starts.last?.objectValue?["overlap"] == .bool(false))
      #expect(try fixture.calls().count == 1)
      #expect(try fixture.cancellations().count == 1)
      await client.shutdown()
      try await fixture.expectAllExited()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func timeoutRetirementIsJoinedByConcurrentShutdown(startup: Bool) async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let client = MCPProxyClient(workingDirectory: fixture.directory)
    let server = fixture.server(version: "first", holdInitialize: startup, shortDeadline: true)
    let call = Task {
      try await blocking {
        if startup { return try client.listTools(server: server).count }
        _ = try client.callTool(
          server: server, name: "hang", arguments: .object([:]), requestID: "timed-out")
        return 0
      }
    }
    let result = await call.result
    guard case .failure(let error) = result else {
      await client.shutdown()
      Issue.record("The deliberately stalled request unexpectedly completed.")
      return
    }
    #expect(String(describing: error).contains("timed out"))
    async let first: Void = client.shutdown()
    async let second: Void = client.shutdown()
    _ = await (first, second)
    try await fixture.expectAllExited()
    #expect(try fixture.starts().count == 1)
    #expect(try fixture.calls().count == (startup ? 0 : 1))
    #expect(try fixture.cancellations().count == (startup ? 0 : 1))
    let status = try client.connectionStatus(server: server)
    #expect(status.objectValue?["state"] == .string("stopped"))
    await #expect(throws: (any Error).self) {
      try await blocking { try client.listTools(server: server) }
    }
    #expect(try fixture.starts().count == 1)
  }

  @Test
  func timeoutReconnectRefreshesTheCatalogAfterConfirmedRetirement() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let client = MCPProxyClient(workingDirectory: fixture.directory)
    let server = fixture.server(version: "first", shortDeadline: true)
    do {
      await #expect(throws: (any Error).self) {
        try await blocking {
          try client.callTool(
            server: server, name: "hang", arguments: .object([:]), requestID: "one-write")
        }
      }
      try Data("refreshed".utf8).write(to: fixture.directory.appendingPathComponent("version"))
      let tools = try await blocking { try client.listTools(server: server) }
      #expect(tools.map(\.name) == ["refreshed", "hang"])
      #expect(try fixture.starts().count == 2)
      #expect(try fixture.starts().last?.objectValue?["overlap"] == .bool(false))
      #expect(try fixture.calls().count == 1)
      await client.shutdown()
      try await fixture.expectAllExited()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test
  func shutdownDuringInitializeCannotActivateALateConnection() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let client = MCPProxyClient(workingDirectory: fixture.directory)
    let server = fixture.server(version: "first", holdInitialize: true)
    let starting = Task { try await blocking { try client.listTools(server: server) } }
    try await fixture.waitForStarts(1)
    async let first: Void = client.shutdown()
    async let second: Void = client.shutdown()
    _ = await (first, second)
    guard case .failure = await starting.result else {
      Issue.record("A closed generation must not publish initialization.")
      return
    }
    try await fixture.expectAllExited()
    #expect(try fixture.starts().count == 1)
    #expect(try client.connectionStatus(server: server).objectValue?["state"] == .string("stopped"))
  }

  @Test
  func disconnectBeforeTransportConnectDoesNotLaunchAProcess() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let transport = try MCPChildProcessTransport(
      server: fixture.server(version: "first"), workingDirectory: fixture.directory,
      environment: ProcessInfo.processInfo.environment)
    await transport.disconnect()
    await #expect(throws: (any Error).self) { try await transport.connect() }
    #expect(await transport.shutdownConfirmed())
    #expect(try fixture.starts().isEmpty)
  }

  @Test
  func closedChildTransportJoinsStubbornDescendantsForEveryWaiter() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let transport = try MCPChildProcessTransport(
      server: fixture.server(version: "first"), workingDirectory: fixture.directory,
      environment: ProcessInfo.processInfo.environment)
    try await transport.connect()
    try await fixture.waitForStarts(1)
    async let first: Void = transport.disconnect()
    async let second: Void = transport.disconnect()
    _ = await (first, second)
    #expect(await transport.shutdownConfirmed())
    try await fixture.expectAllExited()
    await #expect(throws: (any Error).self) { try await transport.send(Data("{}".utf8)) }
  }
}

private func blocking<T: Sendable>(
  _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      continuation.resume(with: Result(catching: operation))
    }
  }
}

private struct LifecycleFixture: Sendable {
  let directory: URL
  let script: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mcp-lifecycle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    script = directory.appendingPathComponent("peer.py")
    try Data(
      #"""
      #!/usr/bin/env python3
      import json, os, pathlib, signal, subprocess, sys, time
      root = pathlib.Path(sys.argv[1])
      def append(name, value):
          with (root / name).open("a", encoding="utf-8") as handle:
              handle.write(json.dumps(value) + "\n")
      def exists(pid):
          try:
              os.kill(pid, 0)
              return True
          except ProcessLookupError:
              return False
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      previous = []
      if (root / "starts").exists():
          previous = [json.loads(line) for line in (root / "starts").read_text().splitlines()]
      child = subprocess.Popen(
          ["/bin/sh", "-c", "trap '' TERM; while :; do /bin/sleep 1; done"],
          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
      append("starts", {
          "pid": os.getpid(), "child": child.pid,
          "supervisor": os.getppid(),
          "overlap": any(exists(item["pid"]) for item in previous)})
      for line in sys.stdin:
          message = json.loads(line)
          method = message.get("method")
          if method == "notifications/cancelled":
              append("cancellations", message["params"]["requestId"])
              continue
          if "id" not in message:
              continue
          result = {}
          if method == "initialize":
              while os.environ.get("HOLD_INITIALIZE") == "1":
                  time.sleep(0.01)
              result = {
                  "protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "owned-lifecycle-fixture", "version": "1"}}
          elif method == "tools/list":
              version = ((root / "version").read_text() if (root / "version").exists()
                         else os.environ["CATALOG_VERSION"])
              result = {"tools": [
                  {"name": name, "inputSchema": {"type": "object"}}
                  for name in [version, "hang"]]}
          elif method == "tools/call":
              append("calls", message["params"]["name"])
              if message["params"]["name"] == "hang":
                  continue
              arguments = message["params"].get("arguments", {})
              if "error_code" in arguments:
                  error = {"code": arguments["error_code"], "message": "fixture rejection"}
                  if error["code"] == -32042:
                      error["data"] = {"elicitations": [{
                          "mode": "url", "elicitationId": "fixture-input",
                          "url": "https://example.invalid/confirm", "message": "fixture input"}]}
                  print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "error": error}), flush=True)
                  continue
              result = {"content": [{"type": "text", "text": "done"}]}
              if arguments.get("tool_error"):
                  result = {"content": [{"type": "text", "text": "operation rejected"}],
                            "structuredContent": {"accepted": False}, "isError": True}
          print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
          if method == "tools/call" and arguments.get("exit_after_response"):
              os._exit(0)
      while True:
          time.sleep(0.01)
      """#.utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
  }

  func server(version: String, holdInitialize: Bool = false, shortDeadline: Bool = false)
    -> MCPServerConfig
  {
    MCPServerConfig(
      id: "owned-lifecycle", transport: .stdio, command: script.path,
      args: [directory.path],
      env: ["CATALOG_VERSION": version, "HOLD_INITIALIZE": holdInitialize ? "1" : "0"],
      startupTimeoutMs: holdInitialize && shortDeadline ? 1_000 : 10_000,
      requestTimeoutMs: shortDeadline ? 1_000 : 10_000)
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
    try await wait { pids.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH } }
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}
