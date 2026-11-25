import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPTransport
import ComputerMCPTunnels
import ComputerMCPWorktrees
import Darwin
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPPlugins
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct MCPRegistrationControlPlaneTests {
  @Test
  func h12ProjectInventoryRetainsUnavailableWorktreeIdentity() async throws {
    let fixture = try MCPRegistrationControlFixture()
    defer { fixture.remove() }
    let source = DerivedProjectSource(
      id: "removed-source", root: fixture.root.appendingPathComponent("old-source").path,
      registeredAt: Date())
    let worktreeID = UUID()
    let generation = UUID()
    let record = DerivedProjectRecord(
      projectID: "retained-worktree", source: source,
      root: fixture.root.appendingPathComponent("old-checkout").path,
      provenance: .host(worktreeID: worktreeID, storageGeneration: generation),
      state: .sourceUnavailable)
    try fixture.database.derivedProjectStore(inspectNesting: { _ in [] })
      .commit(record, expecting: nil, protecting: nil)

    let inventory = try await fixture.host.projectWorktreeInventory()
    let group = try #require(inventory.first)
    #expect(group.source == source)
    #expect(group.projectName == nil)
    #expect(!group.isInventoryAvailable)
    let row = try #require(group.worktrees.first)
    #expect(row.worktreeID == worktreeID)
    #expect(row.storageGeneration == generation)
    #expect(row.lifecycleRevision == record.revision)
    #expect(row.lifecycleState == .sourceUnavailable)
    #expect(!row.isInspectable)
    await #expect(throws: AppControlPlaneServiceError.recoveryOwnerUnavailable) {
      try await fixture.host.recoveryStores()
    }
  }

  @Test(arguments: [false, true])
  func doctorAndRecoveryShareHostStorageWithoutLaunching(hostConfirmed: Bool) async throws {
    let fixture = try MCPRegistrationControlFixture()
    defer { fixture.remove() }
    try fixture.registerProject()
    let marker = fixture.root.appendingPathComponent("launched")
    let server = MCPServerConfig(
      id: "owned", transport: .stdio, command: "/usr/bin/touch", args: [marker.path],
      allowAnyTool: true)
    let storage = try #require(fixture.database.mcpProcessOwnershipRoot)
    let owner = try MCPProcessOwnership.acquire(
      root: storage, project: fixture.root, registration: "owned")
    try owner.finish(confirmed: false, hostServicesConfirmed: hostConfirmed)
    try await fixture.socket.start()
    do {
      try await fixture.seedRegistration(server)
      let before = try Data(contentsOf: fixture.directories.manifest)
      let result = try await fixture.cli(["doctor", "owned", "--project-id", "fixture"])
      #expect(result.exitCode == 1)
      let report = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
      #expect(report.objectValue?["stage"] == .string("cleanup"))
      #expect(report.objectValue?["catalog_received"] == .bool(false))
      let receipt = try #require(
        report.objectValue?["process_receipts"]?.arrayValue?.first?.objectValue)
      #expect(receipt["recoverable"] == .bool(hostConfirmed))
      let id = try #require(receipt["id"]?.stringValue)
      let digest = try #require(receipt["digest"]?.stringValue)
      let current = try #require(report.objectValue?["current_digest"]?.stringValue)
      let arguments = [
        "recover-process", "owned", "--project-id", "fixture", "--receipt-id", id,
        "--expected-receipt-digest", digest, "--expected-current-digest",
      ]
      #expect(try await fixture.cli(arguments + ["stale"]).exitCode != 0)
      let recovery = try await fixture.cli(arguments + [current])
      #expect((recovery.exitCode == 0) == hostConfirmed)
      let remaining = try MCPProcessOwnership.inspect(
        root: storage, project: fixture.root, registration: "owned")
      #expect(remaining.count == (hostConfirmed ? 0 : 1))
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      #expect(try Data(contentsOf: fixture.directories.manifest) == before)
      await fixture.socket.stop()
    } catch {
      await fixture.socket.stop()
      throw error
    }
  }

  @Test(arguments: ["accept", "refuse", "stall"])
  func doctorRefusesExecutionAndAdmittedHTTPCatalogCleansUpSessions(mode: String) async throws {
    let fixture = try MCPRegistrationControlFixture()
    defer { fixture.remove() }
    let script = fixture.root.appendingPathComponent("doctor_http_server.py")
    let ready = fixture.root.appendingPathComponent("port")
    let methods = fixture.root.appendingPathComponent("http-methods")
    try Data(
      #"""
      import http.server, json, os, sys, time
      class Handler(http.server.BaseHTTPRequestHandler):
          def log_message(self, *args): pass
          def respond(self, code, body=b""):
              self.send_response(code)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(body)))
              self.send_header("Mcp-Session-Id", "doctor-session")
              self.end_headers()
              self.wfile.write(body)
          def record(self, method):
              with open(sys.argv[2], "a") as f: f.write(method + "\n")
          def do_GET(self): self.respond(405)
          def do_DELETE(self):
              self.record("DELETE")
              assert self.headers["Mcp-Session-Id"] == "doctor-session"
              if sys.argv[3] == "stall": time.sleep(30)
              self.respond(405 if sys.argv[3] == "refuse" else 204)
          def do_POST(self):
              req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
              method = req["method"]
              self.record(method)
              if "id" not in req:
                  self.respond(202)
                  return
              if method == "initialize":
                  result = {"protocolVersion": req["params"]["protocolVersion"], "capabilities": {"tools": {}},
                            "serverInfo": {"name": "http-doctor", "version": "2.3.4"}}
              elif method == "tools/list": result = {"tools": []}
              else:
                  self.respond(400)
                  return
              self.respond(200, json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}).encode())
      server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
      with open(sys.argv[1] + ".pending", "w") as f: f.write(str(server.server_port))
      os.replace(sys.argv[1] + ".pending", sys.argv[1])
      server.serve_forever()
      """#.utf8
    ).write(to: script)
    try #require(InvocationExecution.current == nil)
    let administration = ExecutionAdministration(
      mode: .fullAccess,
      environment: try ExecutionEnvironment(
        fullAccessVariables: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path]))
    let process = try ExecutionAdministration.$current.withValue(administration) {
      try ManagedLineProcess(
        launcher: testExecutionLauncher(),
        configuration: .init(
          executable: "/usr/bin/python3",
          arguments: ["-I", script.path, ready.path, methods.path, mode],
          workingDirectory: fixture.root, terminationGraceMilliseconds: 100))
    }
    do {
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      while !FileManager.default.fileExists(atPath: ready.path) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let port = try #require(Int(String(contentsOf: ready, encoding: .utf8)))
      try fixture.registerProject()
      let server = MCPServerConfig(
        id: "http", transport: .streamableHTTP,
        url: "http://127.0.0.1:\(port)/mcp", allowAnyTool: true,
        startupTimeoutMs: 1000, requestTimeoutMs: 1000)
      try await fixture.socket.start()
      try await fixture.seedRegistration(server)
      let before = try Data(contentsOf: fixture.directories.manifest)
      let report = try await fixture.doctorUnavailable("http")
      #expect(report.objectValue?["executable_inspection"] == nil)
      #expect(!FileManager.default.fileExists(atPath: methods.path))
      try await MCPRegistrationAdmissionFixture.withFixture(server: server, root: fixture.root) {
        admitted in
        #expect(try await admitted.discover().arrayValue == [])
        let initialized = try await admitted.initializeResult()
        #expect(initialized.objectValue?["serverInfo"]?.objectValue?["version"] == .string("2.3.4"))
        #expect(initialized.objectValue?["protocolVersion"]?.stringValue != nil)
      }
      let calls = try String(contentsOf: methods, encoding: .utf8)
      #expect(calls.contains("tools/list\n") && calls.contains("DELETE\n"))
      #expect(!calls.contains("tools/call"))
      #expect(try Data(contentsOf: fixture.directories.manifest) == before)
      await fixture.socket.stop()
      await process.close()
      #expect(await process.snapshot().hasExited)
    } catch {
      await fixture.socket.stop()
      await process.close()
      throw error
    }
  }

  @Test(arguments: ["interpreter", "timeout", "invalid-catalog"])
  func doctorInspectsExecutablesAndAdmittedValidationReportsProtocolFailures(mode: String)
    async throws
  {
    let fixture = try MCPRegistrationControlFixture()
    defer { fixture.remove() }
    try fixture.registerProject()
    let script = fixture.root.appendingPathComponent("failure.py")
    let receipt = fixture.root.appendingPathComponent("pid")
    let source =
      mode == "interpreter"
      ? "#!/nonexistent/computer-mcp-test-interpreter\n"
      : #"""
      import json, os, sys, time
      with open(os.path.join(os.environ["HOME"], os.path.basename(sys.argv[2])), "w") as f:
          f.write(str(os.getpid()))
      for line in sys.stdin:
          request = json.loads(line)
          if "id" not in request:
              continue
          if sys.argv[1] == "timeout":
              time.sleep(30)
          if request.get("method") == "initialize":
              result = {"protocolVersion": request["params"]["protocolVersion"], "capabilities": {"tools": {}},
                        "serverInfo": {"name": "failure", "version": "1"}}
          else:
              result = {"tools": "not-a-catalog"}
          print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
      """#
    if mode == "interpreter" {
      try Data(source.utf8).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    } else {
      try writePythonTestExecutable(source, to: script)
    }
    let server = MCPServerConfig(
      id: "failure", transport: .stdio,
      command: script.path,
      args: mode == "interpreter" ? [] : [mode, receipt.path],
      env: ["FIXTURE_SECRET": "must-not-appear-in-report"], allowAnyTool: true,
      startupTimeoutMs: 300, requestTimeoutMs: 300)
    try await fixture.socket.start()
    do {
      try await fixture.seedRegistration(server)
      let before = try Data(contentsOf: fixture.directories.manifest)
      let result = try await fixture.cli(["doctor", "failure", "--project-id", "fixture"])
      #expect(result.exitCode == 1)
      let report = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
      #expect(report.objectValue?["status"] == .string("failed"))
      #expect(report.objectValue?["catalog_received"] == .bool(false))
      #expect(!result.stdout.contains("must-not-appear-in-report"))
      if mode == "interpreter" {
        #expect(report.objectValue?["stage"] == .string("executable"))
        #expect(
          report.objectValue?["executable_inspection"]?.objectValue?["status"]
            == .string("interpreter_unavailable"))
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
      } else {
        #expect(report.objectValue?["stage"] == .string("execution"))
        #expect(report.objectValue?["error_code"] == .string("execution.unavailable"))
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
        let receipt = try await MCPRegistrationAdmissionFixture.withFixture(
          server: server, root: fixture.root
        ) {
          admitted in
          await #expect(throws: (any Error).self) {
            try await admitted.validateConnection()
          }
          return try admitted.providerMarker(receipt)
        }
        let pids = try fixture.processIDs(at: receipt)
        #expect(pids.count == 1 && pids.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH })
      }
      #expect(try Data(contentsOf: fixture.directories.manifest) == before)
      await fixture.socket.stop()
    } catch {
      await fixture.socket.stop()
      throw error
    }
  }

  @Test
  func doctorCannotLaunchAndAdmittedSelectedCatalogRetainsReadOnlyHostContext() async throws {
    let fixture = try MCPRegistrationControlFixture()
    defer { fixture.remove() }
    let script = fixture.root.appendingPathComponent("doctor.py")
    let receipt = fixture.root.appendingPathComponent("doctor-receipt")
    try writePythonTestExecutable(
      #"""
      import json, os, socket, sys
      context = json.loads(os.environ["COMPUTER_MCP_HOST_CONTEXT"])
      assert context["readOnly"] is True
      assert context["profileID"] == "chatgpt-observe"
      assert context["workspace"]["id"] == "fixture"
      assert "processOwnershipRoot" not in context
      import glob
      records = glob.glob(os.path.join(sys.argv[2], "*", "*"))
      records = [p for p in records if os.path.basename(p) != "scope.lock"]
      assert records == [], records
      host = socket.socket(fileno=int(os.environ["COMPUTER_MCP_HOST_FD"]))
      host.settimeout(2)
      channel = host.makefile("rwb")
      def callback(id, method, params):
          channel.write((json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params}) + "\n").encode())
          channel.flush()
          while True:
              reply = json.loads(channel.readline())
              if reply.get("id") == id:
                  return reply
      callback(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "doctor", "version": "1"}})
      channel.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
      channel.flush()
      directory = callback(2, "tools/list", {})
      assert "tools" in directory["result"]
      denied = callback(3, "tools/call", {"name": "file.write", "arguments": {"path": "probe-write", "content": "forbidden"}})
      assert "error" in denied or denied["result"].get("isError") is True
      persistence = callback(4, "tools/call", {"name": "host.diagnostics.snapshot", "arguments": {}})
      assert "error" in persistence or persistence["result"].get("isError") is True
      receipt = os.path.join(os.environ["HOME"], os.path.basename(sys.argv[1]))
      with open(receipt, "a") as f:
          f.write(str(os.getpid()) + "\n")
      for line in sys.stdin:
          request = json.loads(line)
          method = request.get("method", "")
          with open(receipt + ".methods", "a") as f:
              f.write(method + "\n")
          if "id" not in request:
              continue
          if method == "initialize":
              result = {"protocolVersion": request["params"]["protocolVersion"],
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "doctor-fixture", "version": "1.2.3"}}
          elif method == "tools/list":
              result = {"tools": [{"name": "unclassified", "inputSchema": {"type": "object"}}]}
          else:
              raise RuntimeError("Unexpected probe operation")
          print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
      """#, to: script)
    try fixture.registerProject()
    try await fixture.socket.start()
    do {
      for id in ["selected", "unrelated", "disabled"] {
        let server = MCPServerConfig(
          id: id, transport: .stdio, command: script.path,
          args: [
            id == "selected" ? receipt.path : receipt.path + "." + id,
            try #require(fixture.database.mcpProcessOwnershipRoot).path,
          ],
          exposure: .reexport, prefix: id, allowAnyTool: true,
          startupTimeoutMs: 1500, requestTimeoutMs: 1500, hostServices: true,
          enabled: id != "disabled")
        try await fixture.seedRegistration(server)
      }
      let before = try Data(contentsOf: fixture.directories.manifest)
      let report = try await fixture.doctorUnavailable("selected")
      #expect(!FileManager.default.fileExists(atPath: receipt.path))
      #expect(
        report.objectValue?["not_checked"]?.arrayValue?.contains(.string("tool_execution")) == true)
      let authorityDatabase = try fixturePermissionDatabase(
        path: fixture.root.appendingPathComponent("admitted.sqlite").path)
      var selected = try #require(
        fixture.configuration().mcp.servers.first { $0.id == "selected" })
      selected.args[1] = try #require(authorityDatabase.mcpProcessOwnershipRoot).path
      let admittedReceipt = try await MCPRegistrationAdmissionFixture.withFixture(
        server: selected, root: fixture.root, database: authorityDatabase
      ) { admitted in
        let tools = try await admitted.discover()
        #expect(tools.arrayValue?.first?.objectValue?["name"] == .string("unclassified"))
        let initialized = try await admitted.initializeResult()
        #expect(initialized.objectValue?["serverInfo"]?.objectValue?["version"] == .string("1.2.3"))
        #expect(initialized.objectValue?["protocolVersion"]?.stringValue != nil)
        try admitted.checkProviderOwnership()
        return try admitted.providerMarker(receipt)
      }
      let pids = try fixture.processIDs(at: admittedReceipt)
      #expect(pids.count == 1)
      #expect(pids.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH })
      let methods = try String(contentsOfFile: admittedReceipt.path + ".methods", encoding: .utf8)
      #expect(methods.contains("initialize\n") && methods.contains("tools/list\n"))
      #expect(!methods.contains("tools/call"))
      #expect(!FileManager.default.fileExists(atPath: receipt.path + ".unrelated"))
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent("probe-write").path))
      let disabled = try await fixture.cli(["doctor", "disabled", "--project-id", "fixture"])
      #expect(disabled.exitCode == 1)
      let disabledReport = try JSONDecoder().decode(
        JSONValue.self, from: Data(disabled.stdout.utf8))
      #expect(disabledReport.objectValue?["status"] == .string("disabled"))
      #expect(!FileManager.default.fileExists(atPath: receipt.path + ".disabled"))
      #expect(try Data(contentsOf: fixture.directories.manifest) == before)
      await fixture.socket.stop()
    } catch {
      await fixture.socket.stop()
      throw error
    }
  }

  @Test
  func runningRegistrationChangesReplaceRoutesAndReapOwnedProcesses() async throws {
    let source =
      #"""
      import json, os, sys, time
      name, requested = sys.argv[1:]
      starts = os.path.join(os.environ["HOME"], os.path.basename(requested))
      with open(starts, "a") as f:
          f.write(str(os.getpid()) + "\n")
      with open(starts + ".versions", "a") as f:
          f.write(name + "\n")
      for line in sys.stdin:
          request = json.loads(line)
          if "id" not in request:
              continue
          method = request.get("method")
          if method == "initialize":
              result = {"protocolVersion": request["params"]["protocolVersion"],
                        "capabilities": {"tools": {}}, "serverInfo": {"name": "fixture", "version": name}}
          elif method == "tools/list":
              result = {"tools": [{"name": tool, "description": "Read fixture identity",
                                   "inputSchema": {"type": "object", "properties": {}},
                                   "annotations": {"readOnlyHint": True}} for tool in [name, "hold"]]}
          elif method == "tools/call":
              with open(starts + ".invocations", "a") as f:
                  f.write(name + ":" + request["params"]["name"] + "\n")
              if request["params"]["name"] == "hold":
                  with open(starts + ".calls", "a") as f:
                      f.write("hold\n")
                  deadline = time.monotonic() + 10
                  while not os.path.exists(starts + ".release") and time.monotonic() < deadline:
                      time.sleep(0.01)
              result = {"content": [{"type": "text", "text": name}], "isError": False}
          else:
              result = {}
          print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
      """#
    let fixture = try MCPRegistrationControlFixture()
    defer { fixture.remove() }
    let script = fixture.root.appendingPathComponent("server.py")
    let starts = URL(
      fileURLWithPath: try fixture.database.prepareProviderContainer(.localServer("manual")).sandbox
        .home.value
    ).appendingPathComponent("starts")
    try writePythonTestExecutable(source, to: script)
    try fixture.registerProject()
    let input = fixture.root.appendingPathComponent("registration.json")
    var server = MCPServerConfig(
      id: "manual", transport: .stdio, command: script.path,
      args: ["first", fixture.root.appendingPathComponent("starts").path],
      exposure: .reexport, prefix: "manual",
      allowAnyTool: true, startupTimeoutMs: 3000, requestTimeoutMs: 10000,
      toolRisks: ["first": .readOnly, "second": .readOnly, "hold": .readOnly])
    try JSONEncoder().encode(server).write(to: input)
    try await fixture.socket.start()
    var clients: [GatewayClientSession] = []
    do {
      try await fixture.applyLocal(
        .add(server),
        selection: .init(
          permissions: fixturePermissions([.project("fixture"): .granted(.write)]),
          fullAccess: true))
      #expect(!FileManager.default.fileExists(atPath: starts.path))
      try fixture.database.saveProfile(
        .init(
          id: .chatGPTObserve,
          permissions: fixturePermissions([
            .machineInformation: .granted(.access), .skills: .granted(.access),
            .screen: .granted(.access), .desktopControl: .granted(.access),
            .unifiedLogs: .granted(.access), .localNetwork: .granted(.access),
            .project("fixture"): .granted(.write), .mcpServer("manual"): .granted(.all),
            .mcpServer("*"): .granted(.all), .plugin("*"): .granted(.use),
          ]), fullAccess: true, allowedCallers: [.localCLI]))
      try await fixture.gateway.start(profile: .chatGPTObserve)
      let first = try await GatewayClientSession.connectSocket(
        configuration: .init(
          socketURL: fixture.directories.gatewaySocket, clientIdentity: .localCLI))
      clients.append(first)
      #expect(!FileManager.default.fileExists(atPath: starts.path))
      let scope = try #require(await fixture.gateway.controlSessions().first)
      _ = try await fixture.gateway.approveControlSession(
        id: scope.id, expectedRevision: scope.revision)
      try await fixture.discover(first, server: "manual")
      #expect(try await first.listTools().contains { $0.name == "manual.first" })
      let firstPIDs = try fixture.processIDs(at: starts)
      try #require(firstPIDs.count == 1)
      #expect(Darwin.kill(firstPIDs[0], 0) == 0)
      let firstCall = try await first.call(toolName: "manual.first", arguments: .object([:]))
      #expect(firstCall.result.objectValue?["isError"]?.boolValue != true)
      let firstDelegationPIDs = try fixture.processIDs(at: starts)
      #expect(firstDelegationPIDs.count == 2)

      server.args[0] = "second"
      try JSONEncoder().encode(server).write(to: input)
      let preview = try await fixture.json(["configure", "--registration-file", input.path])
      #expect(preview.objectValue?["transport_will_restart"] == .bool(false))
      try await fixture.applyLocal(
        .configure(server),
        selection: .init(
          permissions: fixturePermissions([.project("fixture"): .granted(.write)]),
          fullAccess: true))
      try await fixture.waitForExit(firstDelegationPIDs)
      #expect(await fixture.gateway.snapshot().connectionCount == 1)
      let second = first
      try await fixture.discover(second, server: "manual")
      let currentTools = try await second.listTools().map(\.name)
      #expect(currentTools.contains("manual.second") && !currentTools.contains("manual.first"))
      let secondCall = try await second.call(toolName: "manual.second", arguments: .object([:]))
      #expect(secondCall.result.objectValue?["isError"]?.boolValue != true)
      let missing = try await second.call(toolName: "manual.first", arguments: .object([:]))
      #expect(missing.result.objectValue?["isError"]?.boolValue == true)
      let heldCall = Task {
        do {
          let result = try await second.call(toolName: "manual.hold", arguments: .object([:]))
          return result.result.objectValue?["isError"]?.boolValue == true
        } catch {
          return true
        }
      }
      let calls = URL(fileURLWithPath: starts.path + ".calls")
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while !FileManager.default.fileExists(atPath: calls.path) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(FileManager.default.fileExists(atPath: calls.path))
      try await fixture.apply(["disable", "manual"])
      let allPIDs = try fixture.processIDs(at: starts)
      #expect(allPIDs.count == 4)
      let versions = try String(contentsOfFile: starts.path + ".versions", encoding: .utf8)
        .split(separator: "\n").map(String.init)
      #expect(versions == ["first", "first", "second", "second"])
      try await fixture.waitForExit(allPIDs)
      #expect(try await !second.listTools().contains { $0.name.hasPrefix("manual.") })
      #expect(await heldCall.value == true)

      let disabled = first
      #expect(try await !disabled.listTools().contains { $0.name.hasPrefix("manual.") })
      #expect(try fixture.processIDs(at: starts) == allPIDs)
      #expect(try String(contentsOf: calls, encoding: .utf8) == "hold\n")
      #expect(
        try String(contentsOfFile: starts.path + ".invocations", encoding: .utf8)
          == "first:first\nsecond:second\nsecond:hold\n")
      try await fixture.apply(["remove", "manual"])
      #expect(try fixture.configuration().mcp.servers.isEmpty)
      #expect(FileManager.default.fileExists(atPath: script.path))
      #expect(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))
      for client in clients { await client.disconnect() }
      await fixture.socket.stop()
      await fixture.gateway.stop()
      #expect(allPIDs.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH })
    } catch {
      for client in clients { await client.disconnect() }
      await fixture.socket.stop()
      await fixture.gateway.stop()
      throw error
    }
  }

  @Test
  func ownerCLICompletesReviewedRegistrationLifecycleWithoutStartingDependencies() async throws {
    let fixture = try MCPRegistrationControlFixture()
    defer { fixture.remove() }
    try await fixture.socket.start()
    do {
      let original = try Data(contentsOf: fixture.directories.manifest)
      let server = MCPServerConfig(
        id: "manual", transport: .stdio, command: "/nonexistent/manual-mcp-fixture",
        args: ["", "含 空格", "--value=-3"], env: ["FIXTURE": "retained"],
        exposure: .reexport, prefix: "manual", allowedTools: ["inspect"],
        requestTimeoutMs: 1200, toolRisks: ["inspect": .readOnly], enabled: false)
      let input = fixture.root.appendingPathComponent("registration.json")
      try JSONEncoder().encode(server).write(to: input)
      let add = ["add", "--registration-file", input.path]
      let preview = try await fixture.json(add)
      let digest = try #require(preview.objectValue?["current_digest"]?.stringValue)
      #expect(preview.objectValue?["applied_revision"] == nil)
      #expect(preview.objectValue?["transport_will_restart"] == .bool(false))
      #expect(try Data(contentsOf: fixture.directories.manifest) == original)
      let missingDigest = try await fixture.cli(add + ["--apply"])
      #expect(missingDigest.exitCode != 0)
      #expect(try Data(contentsOf: fixture.directories.manifest) == original)
      _ = try await fixture.json(add + ["--apply", "--expected-current-digest", digest])
      #expect(try fixture.configuration().mcp.servers == [server])
      let shown = try await fixture.json(["show", "manual"])
      let entry = try #require(shown.objectValue?["registrations"]?.arrayValue?.first?.objectValue)
      #expect(entry["origin"] == nil)
      #expect(entry["server"]?.objectValue?["enabled"] == .bool(false))
      #expect(entry["server"] == (try JSONValue.encoded(server)))
      var exportedServer = try #require(entry["server"]?.objectValue)
      let duplicated = try await fixture.cli(add)
      #expect(duplicated.exitCode != 0)
      let stale = try await fixture.cli([
        "enable", "manual", "--apply", "--expected-current-digest", digest,
      ])
      #expect(stale.exitCode != 0)
      #expect(try fixture.configuration().mcp.servers == [server])

      let enable = ["enable", "manual"]
      let current = try await fixture.json(enable)
      let currentDigest = try #require(current.objectValue?["current_digest"]?.stringValue)
      let refused = try await fixture.cli(
        enable + ["--apply", "--expected-current-digest", currentDigest])
      #expect(refused.exitCode != 0)
      #expect(refused.stderr.contains("provider.approval_required"))
      #expect(try fixture.configuration().mcp.servers == [server])
      try await fixture.applyLocal(.enabled(id: "manual", true))
      var enabled = server
      enabled.enabled = true
      #expect(try fixture.configuration().mcp.servers == [enabled])
      enabled.allowAnyTool = true
      enabled.allowedTools = []
      exportedServer["enabled"] = .bool(true)
      exportedServer["allow_any_tool"] = .bool(true)
      exportedServer["allowed_tools"] = .array([])
      try JSONEncoder().encode(JSONValue.object(exportedServer)).write(to: input)
      try await fixture.applyLocal(.configure(enabled))
      #expect(try fixture.configuration().mcp.servers == [enabled])
      try await fixture.apply(["disable", "manual"])
      enabled.enabled = false
      #expect(try fixture.configuration().mcp.servers == [enabled])
      try await fixture.apply(["remove", "manual"])
      #expect(try fixture.configuration().mcp.servers.isEmpty)
      #expect(FileManager.default.fileExists(atPath: input.path))
      #expect(try fixture.database.configurationRevisions().count == 6)
      #expect(await fixture.gateway.snapshot().state == .stopped)
      await fixture.socket.stop()
      await fixture.gateway.stop()
    } catch {
      await fixture.socket.stop()
      await fixture.gateway.stop()
      throw error
    }
  }
}

/// Protocol checks use the same admitted execution path as clients, with one
/// selected registration and an owner-consented read-only project profile.
private struct MCPRegistrationAdmissionFixture: Sendable {
  let configuration: GatewayConfiguration
  let database: GatewayDatabase
  let platform: PlatformServices
  let runtime: GatewayRuntime
  let session: GatewayControlSession
  let caller: ExecutionContext
  let server: MCPServerConfig

  init(server: MCPServerConfig, root: URL, database supplied: GatewayDatabase? = nil) async throws {
    self.server = server
    let root = try ProjectPathResolver.canonicalProject(root)
    let database =
      try supplied
      ?? fixturePermissionDatabase(path: root.appendingPathComponent("admitted.sqlite").path)
    let platform = MacOSPlatform.services(launcher: testExecutionLauncher())
    let grant = ProfileGrant(
      id: .chatGPTObserve,
      permissions: fixturePermissions([
        .project("fixture"): .granted(.read), .mcpServer(server.id): .granted(.read),
      ]), fullAccess: true, allowedCallers: [.localMCP])
    var project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: root.path)
    project.rootPath = root.path
    try database.saveProject(project)
    try database.saveProfile(grant)
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: grant.id),
      profiles: [.init(grant: grant)], mcp: .init(servers: [server]), projectDirectory: root)
    let context = ExecutionContext(
      caller: .localMCP, profileID: grant.id, projectID: project.id,
      trustedPrincipalID: "verified-registration-validator")
    let runtime = try GatewayRuntime(
      configuration: configuration, context: context, database: database,
      registeredProjects: [project], platform: platform, plugins: [])
    let session: GatewayControlSession
    do {
      try await runtime.permissionRuntime.ready()
      let created = try runtime.makeControlSession()
      if server.transport == .stdio {
        try fixtureApproveLocalProvider(
          server, database: database, runtime: runtime.permissionRuntime,
          permissions: fixturePermissions([.project("fixture"): .granted(.read)]), fullAccess: true)
      }
      do {
        _ = try created.approveFullAccess(expectedRevision: created.revision)
        session = created
      } catch {
        created.end()
        throw error
      }
    } catch {
      await runtime.shutdown()
      throw error
    }
    var admitted = context
    admitted.controlSession = session
    self.configuration = configuration
    self.database = database
    self.platform = platform
    self.runtime = runtime
    self.session = session
    caller = admitted
  }

  static func withFixture<Value: Sendable>(
    server: MCPServerConfig, root: URL, database: GatewayDatabase? = nil,
    _ operation: (Self) async throws -> Value
  ) async throws -> Value {
    let fixture = try await Self(server: server, root: root, database: database)
    do {
      let value = try await operation(fixture)
      try await fixture.close()
      return value
    } catch {
      try? await fixture.close()
      throw error
    }
  }

  func discover() async throws -> JSONValue {
    try await call("mcp.tools.list")
  }

  func initializeResult() async throws -> JSONValue {
    let status = try await call("mcp.servers.status")
    return try #require(
      status.objectValue?["servers"]?.arrayValue?.first?.objectValue?["connection"]?
        .objectValue?["initialize"], "\(status)")
  }

  func validateConnection() async throws -> JSONValue {
    let permissions = runtime.permissionRuntime
    let source = try GatewayProviderSource.resolve(
      registration: .init(kind: .mcp, id: server.id), configuration: configuration,
      origins: [:], database: database)
    let prepared = try await permissions.prepareProvider(
      review: source.review,
      registrationID: server.id, authorization: nil, directory: nil, connectionID: nil,
      source: source)
    let discovery: GatewayConfiguration = try {
      var value = configuration
      value.projectDirectory = URL(
        fileURLWithPath: try #require(prepared.providerWorkingDirectory).value)
      return value
    }()
    do {
      let value = try await prepared.withValue {
        try await ComputerMCPProductContracts.validateMCPConnections(
          configuration: discovery, platform: platform)
      }
      try prepared.finishAdmission()
      try await permissions.coordinator.reconcile()
      return value
    } catch {
      try? prepared.finishAdmission()
      try? await permissions.coordinator.reconcile()
      throw error
    }
  }

  func providerMarker(_ original: URL) throws -> URL {
    URL(
      fileURLWithPath: try database.prepareProviderContainer(.localServer(server.id)).sandbox.home
        .value
    )
    .appendingPathComponent(original.lastPathComponent)
  }

  func checkProviderOwnership() throws {
    let root = try #require(database.mcpProcessOwnershipRoot)
    let records = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    )
    .flatMap {
      try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
    }
    .filter { $0.lastPathComponent != "scope.lock" }
    try #require(records.count == 1)
    let record = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: #require(records.first)))
    #expect(record.objectValue?["cleanupFailed"] == .bool(false))
  }

  private func call(_ tool: String) async throws -> JSONValue {
    let result = try await runtime.callToolAsync(
      name: tool,
      arguments: .object(["project_id": .string("fixture"), "server": .string(server.id)]),
      context: .init(session: session))
    try #require(result.objectValue?["isError"] != .bool(true), "\(result)")
    return try #require(
      result.objectValue?["structuredContent"]?.objectValue?["result"], "\(result)")
  }

  private func close() async throws {
    await runtime.shutdown()
    session.end()
    try await runtime.permissionRuntime.coordinator.reconcile()
  }
}

struct MCPRegistrationControlFixture: Sendable {
  let root: URL
  let directories: AppControlPlaneServiceDirectories
  let database: GatewayDatabase
  let gateway: AppGatewayService
  let socket: ControlSocketService
  let host: AppControlPlaneService

  init(launcher makeLauncher: (@Sendable (URL) throws -> ExecutionLauncher)? = nil) throws {
    root = URL(fileURLWithPath: "/private/tmp/cm-mr-\(UUID().uuidString.prefix(8))")
    directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("support"),
      logs: root.appendingPathComponent("logs"))
    try directories.prepare()
    let launcher = try makeLauncher?(root) ?? testExecutionLauncher()
    let platform = MacOSPlatform.services(launcher: launcher)
    database = try fixturePermissionDatabase(path: directories.database.path)
    let permissionControl = try fixturePermissionControl(database: database, platform: platform)
    let bundled = BundledPlugins.load(directory: nil)
    let store = try AtomicManifestStore(
      manifestURL: directories.manifest, database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database, bundledPlugins: bundled,
        applications: platform.applications))
    _ = try store.activate(manifest: GatewayConfiguration(projectDirectory: root).exportedTOML())
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    host = AppControlPlaneService(
      directories: directories, database: database,
      permissionControl: permissionControl, manifestStore: store,
      defaultManifest: DefaultGatewayConfiguration.manifest,
      secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: launcher,
        secretStore: secrets,
        executableSearchDirectories: platform.executableSearchDirectories,
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()
      ),
      launchAtLoginController: SMAppServiceLaunchAtLoginController(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(),
      platform: platform,
      bundledPlugins: bundled)
    gateway = AppGatewayService.live(controlPlane: host, directories: directories)
    socket = ControlSocketService(
      controlPlane: host, gatewayService: gateway, socketURL: directories.controlSocket)
  }

  func cli(_ arguments: [String]) async throws -> CommandResult {
    let executable = try nativeGatewayTestExecutable()
    try #require(InvocationExecution.current == nil)
    try #require(
      !arguments.contains { $0 == "--control-socket" || $0.hasPrefix("--control-socket=") })
    return try await BlockingOperationExecutor(label: "mcp-registration-cli-test").perform {
      let administration = ExecutionAdministration(
        mode: .fullAccess,
        environment: try ExecutionEnvironment(fullAccessVariables: ["PATH": "/usr/bin:/bin"]))
      return try ExecutionAdministration.$current.withValue(administration) {
        try ProcessCommandRunner(
          launcher: testExecutionLauncher(), environment: ["PATH": "/usr/bin:/bin"]
        ).run(
          executable: executable.path,
          arguments: ["mcp"] + arguments + ["--control-socket", directories.controlSocket.path],
          workingDirectory: root, environment: [:], timeoutMilliseconds: 5000,
          maxOutputBytes: 1_048_576)
      }
    }
  }

  func json(_ arguments: [String]) async throws -> JSONValue {
    let result = try await cli(arguments)
    try #require(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
    return try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
  }

  func doctorUnavailable(_ registration: String) async throws -> JSONValue {
    let result = try await cli(["doctor", registration, "--project-id", "fixture"])
    try #require(result.exitCode == 1, "\(result.stdout)\n\(result.stderr)")
    let report = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
    #expect(report.objectValue?["status"] == .string("failed"))
    #expect(report.objectValue?["stage"] == .string("execution"))
    #expect(report.objectValue?["error_code"] == .string("execution.unavailable"))
    #expect(report.objectValue?["catalog_received"] == .bool(false))
    #expect(report.objectValue?["server_version"] == nil)
    #expect(report.objectValue?["protocol_version"] == nil)
    return report
  }

  func apply(_ arguments: [String]) async throws {
    let preview = try await json(arguments)
    let digest = try #require(preview.objectValue?["current_digest"]?.stringValue)
    _ = try await json(arguments + ["--apply", "--expected-current-digest", digest])
  }

  func applyLocal(
    _ change: MCPRegistrationChange, selection: ProviderEnablementSelection = .init()
  ) async throws {
    let operations = AppControlPlaneOperations(controlPlane: host, gatewayService: gateway)
    let preview = try await operations.changeMCPRegistration(change)
    let review = try #require(
      try await host.reviewMCPRegistrationEnablement(change, preview: preview))
    _ = try await operations.changeMCPRegistration(
      change, apply: true, expectedCurrentDigest: preview.currentDigest,
      approval: .init(review: review, selection: selection))
  }

  func discover(_ client: GatewayClientSession, server: String) async throws {
    let project = try await client.call(toolName: "project.list")
    try #require(project.result.objectValue?["isError"] != .bool(true))
    let review = try await host.providerReview(.localServer(server))
    let view = try await host.permissionRequests()
    _ = try await host.approveProvider(
      review, permissions: fixturePermissions([.project("fixture"): .granted(.write)]),
      fullAccess: true,
      expectedProviderRevision: view.providers.first { $0.identity == .localServer(server) }?
        .revision,
      expectedRevision: view.revision, expectedEpoch: #require(view.epoch))
    let report = try await client.call(
      toolName: "mcp.tools.list",
      arguments: .object(["project_id": .string("fixture"), "server": .string(server)]))
    try #require(report.result.objectValue?["isError"] != .bool(true), "\(report.result)")
    _ = try await client.listTools()
  }

  /// Persists registrations for inspection without starting their programs.
  func seedRegistration(_ server: MCPServerConfig) async throws {
    var configuration = try configuration()
    configuration.mcp.servers.append(server)
    _ = try await host.activateManifest(
      configuration.exportedTOML(), expectedDigest: try? await host.configurationDigest())
  }

  func configuration() throws -> GatewayConfiguration {
    try GatewayConfiguration.load(path: directories.manifest.path)
  }

  func registerProject() throws {
    var project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: root.path)
    project.rootPath = try ProjectPathResolver.canonicalProject(root).path
    try database.saveProject(project)
  }

  func transport() -> GatewaySocketTransport {
    .init(configuration: .init(socketURL: directories.gatewaySocket, clientIdentity: .localCLI))
  }

  func processIDs(at url: URL) throws -> [Int32] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try #require(Int32($0))
    }
  }

  func waitForExit(_ pids: [Int32]) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while pids.contains(where: { Darwin.kill($0, 0) == 0 }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(pids.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH })
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
