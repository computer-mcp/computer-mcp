import Darwin
import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct MCPRegistrationControlPlaneTests {
  @Test(arguments: [false, true])
  func doctorAndRecoveryShareHostStorageWithoutLaunching(hostConfirmed: Bool) async throws {
    let fixture = try MCPRegistrationControlFixture()
    defer { fixture.remove() }
    try fixture.database.saveWorkspace(
      .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    let marker = fixture.root.appendingPathComponent("launched")
    let server = MCPServerConfig(
      id: "owned", transport: .stdio, command: "/usr/bin/touch", args: [marker.path],
      allowAnyTool: true)
    let input = fixture.root.appendingPathComponent("registration.json")
    try JSONEncoder().encode(server).write(to: input)
    let storage = try #require(fixture.database.mcpProcessOwnershipRoot)
    let owner = try MCPProcessOwnership.acquire(
      root: storage, workspace: fixture.root, registration: "owned")
    try owner.finish(confirmed: false, hostServicesConfirmed: hostConfirmed)
    try await fixture.socket.start()
    do {
      try await fixture.apply(["add", "--registration-file", input.path])
      let before = try Data(contentsOf: fixture.directories.manifest)
      let result = try await fixture.cli(["doctor", "owned", "--workspace-id", "fixture"])
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
        "recover-process", "owned", "--workspace-id", "fixture", "--receipt-id", id,
        "--expected-receipt-digest", digest, "--expected-current-digest",
      ]
      #expect(try await fixture.cli(arguments + ["stale"]).exitCode != 0)
      let recovery = try await fixture.cli(arguments + [current])
      #expect((recovery.exitCode == 0) == hostConfirmed)
      let remaining = try MCPProcessOwnership.inspect(
        root: storage, workspace: fixture.root, registration: "owned")
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
  func doctorChecksHTTPCatalogAndRequestsBoundedSessionCleanup(mode: String) async throws {
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
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/usr/bin/python3", arguments: [script.path, ready.path, methods.path, mode],
        workingDirectory: fixture.root, terminationGraceMilliseconds: 100))
    do {
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      while !FileManager.default.fileExists(atPath: ready.path) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let port = try #require(Int(String(contentsOf: ready, encoding: .utf8)))
      try fixture.database.saveWorkspace(
        .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
      let server = MCPServerConfig(
        id: "http", transport: .streamableHTTP,
        url: "http://127.0.0.1:\(port)/mcp", allowAnyTool: true,
        startupTimeoutMs: 1000, requestTimeoutMs: 1000)
      let input = fixture.root.appendingPathComponent("registration.json")
      try JSONEncoder().encode(server).write(to: input)
      try await fixture.socket.start()
      try await fixture.apply(["add", "--registration-file", input.path])
      let report = try await fixture.json(["doctor", "http", "--workspace-id", "fixture"])
      #expect(report.objectValue?["status"] == .string("passed"))
      #expect(report.objectValue?["server_version"] == .string("2.3.4"))
      #expect(report.objectValue?["executable_inspection"] == nil)
      let calls = try String(contentsOf: methods, encoding: .utf8)
      #expect(calls.contains("tools/list\n") && calls.contains("DELETE\n"))
      #expect(!calls.contains("tools/call"))
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
  func doctorReportsLaunchAndProtocolFailuresWithoutChangingConfiguration(mode: String) async throws
  {
    let fixture = try MCPRegistrationControlFixture()
    defer { fixture.remove() }
    try fixture.database.saveWorkspace(
      .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    let script = fixture.root.appendingPathComponent("failure.py")
    let receipt = fixture.root.appendingPathComponent("pid")
    let source =
      mode == "interpreter"
      ? "#!/nonexistent/computer-mcp-test-interpreter\n"
      : #"""
      import json, os, sys, time
      with open(sys.argv[2], "w") as f:
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
    try Data(source.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let server = MCPServerConfig(
      id: "failure", transport: .stdio,
      command: mode == "interpreter" ? script.path : "/usr/bin/python3",
      args: mode == "interpreter" ? [] : [script.path, mode, receipt.path],
      env: ["FIXTURE_SECRET": "must-not-appear-in-report"], allowAnyTool: true,
      startupTimeoutMs: 300, requestTimeoutMs: 300)
    let input = fixture.root.appendingPathComponent("registration.json")
    try JSONEncoder().encode(server).write(to: input)
    try await fixture.socket.start()
    do {
      try await fixture.apply(["add", "--registration-file", input.path])
      let before = try Data(contentsOf: fixture.directories.manifest)
      let result = try await fixture.cli(["doctor", "failure", "--workspace-id", "fixture"])
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
  func doctorChecksOnlySelectedRegistrationAndClosesItsProcess() async throws {
    let fixture = try MCPRegistrationControlFixture()
    defer { fixture.remove() }
    let script = fixture.root.appendingPathComponent("doctor.py")
    let receipt = fixture.root.appendingPathComponent("doctor-receipt")
    try Data(
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
      assert len(records) == 1, records
      with open(records[0]) as f:
          assert json.load(f)["cleanupFailed"] is False
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
      assert not any(t["name"].startswith("host.") for t in directory["result"]["tools"])
      denied = callback(3, "tools/call", {"name": "file.write", "arguments": {"path": "probe-write", "content": "forbidden"}})
      assert "error" in denied or denied["result"].get("isError") is True
      persistence = callback(4, "tools/call", {"name": "host.diagnostics.snapshot", "arguments": {}})
      assert "error" in persistence or persistence["result"].get("isError") is True
      with open(sys.argv[1], "a") as f:
          f.write(str(os.getpid()) + "\n")
      for line in sys.stdin:
          request = json.loads(line)
          method = request.get("method", "")
          with open(sys.argv[1] + ".methods", "a") as f:
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
      """#.utf8
    ).write(to: script)
    try fixture.database.saveWorkspace(
      .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    let input = fixture.root.appendingPathComponent("registration.json")
    try await fixture.socket.start()
    do {
      for id in ["selected", "unrelated", "disabled"] {
        let server = MCPServerConfig(
          id: id, transport: .stdio, command: "/usr/bin/python3",
          args: [
            script.path, id == "selected" ? receipt.path : receipt.path + "." + id,
            try #require(fixture.database.mcpProcessOwnershipRoot).path,
          ],
          exposure: .reexport, prefix: id, allowAnyTool: true,
          startupTimeoutMs: 1500, requestTimeoutMs: 1500, hostServices: true,
          enabled: id != "disabled")
        try JSONEncoder().encode(server).write(to: input)
        try await fixture.apply(["add", "--registration-file", input.path])
      }
      let before = try Data(contentsOf: fixture.directories.manifest)
      let report = try await fixture.json(["doctor", "selected", "--workspace-id", "fixture"])
      #expect(report.objectValue?["status"] == .string("passed"))
      #expect(report.objectValue?["catalog_received"] == .bool(true))
      #expect(report.objectValue?["server_version"] == .string("1.2.3"))
      #expect(report.objectValue?["protocol_version"]?.stringValue != nil)
      #expect(
        report.objectValue?["not_checked"]?.arrayValue?.contains(.string("tool_execution")) == true)
      let pids = try fixture.processIDs(at: receipt)
      #expect(pids.count == 1)
      #expect(pids.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH })
      let methods = try String(contentsOfFile: receipt.path + ".methods", encoding: .utf8)
      #expect(methods.contains("initialize\n") && methods.contains("tools/list\n"))
      #expect(!methods.contains("tools/call"))
      #expect(!FileManager.default.fileExists(atPath: receipt.path + ".unrelated"))
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent("probe-write").path))
      let disabled = try await fixture.cli(["doctor", "disabled", "--workspace-id", "fixture"])
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
    let fixture = try MCPRegistrationControlFixture()
    defer { fixture.remove() }
    let script = fixture.root.appendingPathComponent("server.py")
    let starts = fixture.root.appendingPathComponent("starts")
    try Data(
      #"""
      import json, os, sys, time
      name, starts = sys.argv[1:]
      with open(starts, "a") as f:
          f.write(str(os.getpid()) + "\n")
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
              if request["params"]["name"] == "hold":
                  with open(starts + ".calls", "a") as f:
                      f.write("hold\n")
                  time.sleep(60)
              result = {"content": [{"type": "text", "text": name}], "isError": False}
          else:
              result = {}
          print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
      """#.utf8
    ).write(to: script)
    try fixture.database.saveWorkspace(
      .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path))
    let input = fixture.root.appendingPathComponent("registration.json")
    var server = MCPServerConfig(
      id: "manual", transport: .stdio, command: "/usr/bin/python3",
      args: [script.path, "first", starts.path], exposure: .reexport, prefix: "manual",
      allowAnyTool: true, startupTimeoutMs: 3000, requestTimeoutMs: 3000,
      toolRisks: ["first": .readOnly, "second": .readOnly, "hold": .readOnly])
    try JSONEncoder().encode(server).write(to: input)
    try await fixture.socket.start()
    var clients: [Client] = []
    do {
      try await fixture.apply(["add", "--registration-file", input.path])
      try fixture.database.saveProfile(
        .init(
          id: .chatGPTObserve, capabilityIDs: ["*"], workspaceIDs: ["fixture"],
          allowedCallers: [.localCLI], mcpServerIDs: ["manual"]))
      try await fixture.gateway.start(profile: .chatGPTObserve)
      let first = Client(name: "registration-first", version: "1")
      clients.append(first)
      _ = try await first.connect(transport: fixture.transport())
      #expect(try await first.listTools().tools.contains { $0.name == "manual.first" })
      let firstPIDs = try fixture.processIDs(at: starts)
      try #require(firstPIDs.count == 1)
      let firstCall = try await first.callTool(name: "manual.first", arguments: [:])
      #expect(firstCall.isError != true)

      server.args[1] = "second"
      try JSONEncoder().encode(server).write(to: input)
      let preview = try await fixture.json(["configure", "--registration-file", input.path])
      #expect(preview.objectValue?["transport_will_restart"] == .bool(true))
      let digest = try #require(preview.objectValue?["current_digest"]?.stringValue)
      _ = try await fixture.json([
        "configure", "--registration-file", input.path, "--apply", "--expected-current-digest",
        digest,
      ])
      #expect(firstPIDs.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH })
      await first.disconnect()

      let second = Client(name: "registration-second", version: "1")
      clients.append(second)
      _ = try await second.connect(transport: fixture.transport())
      let currentTools = try await second.listTools().tools.map(\.name)
      #expect(currentTools.contains("manual.second") && !currentTools.contains("manual.first"))
      let secondCall = try await second.callTool(name: "manual.second", arguments: [:])
      #expect(secondCall.isError != true)
      let missing = try await second.callTool(name: "manual.first", arguments: [:])
      #expect(missing.isError == true)
      let heldCall = Task {
        do {
          let result = try await second.callTool(name: "manual.hold", arguments: [:])
          return result.isError == true
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
      #expect(allPIDs.count == 2)
      #expect(allPIDs.allSatisfy { Darwin.kill($0, 0) == -1 && errno == ESRCH })
      await #expect(throws: (any Error).self) { try await second.listTools() }
      await second.disconnect()
      #expect(await heldCall.value)

      let disabled = Client(name: "registration-disabled", version: "1")
      clients.append(disabled)
      _ = try await disabled.connect(transport: fixture.transport())
      #expect(try await !disabled.listTools().tools.contains { $0.name.hasPrefix("manual.") })
      #expect(try fixture.processIDs(at: starts) == allPIDs)
      #expect(try String(contentsOf: calls, encoding: .utf8) == "hold\n")
      try await fixture.apply(["remove", "manual"])
      #expect(try fixture.configuration().mcp.servers.isEmpty)
      #expect(FileManager.default.fileExists(atPath: script.path))
      #expect(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))
      for client in clients { await client.disconnect() }
      await fixture.socket.stop()
      await fixture.gateway.stop()
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
      let duplicated = try await fixture.cli(add)
      #expect(duplicated.exitCode != 0)
      let stale = try await fixture.cli([
        "enable", "manual", "--apply", "--expected-current-digest", digest,
      ])
      #expect(stale.exitCode != 0)
      #expect(try fixture.configuration().mcp.servers == [server])

      try await fixture.apply(["enable", "manual"])
      var enabled = server
      enabled.enabled = true
      #expect(try fixture.configuration().mcp.servers == [enabled])
      enabled.allowAnyTool = true
      enabled.allowedTools = []
      try JSONEncoder().encode(enabled).write(to: input)
      try await fixture.apply(["configure", "--registration-file", input.path])
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

struct MCPRegistrationControlFixture: Sendable {
  let root: URL
  let directories: AppControlPlaneServiceDirectories
  let database: GatewayDatabase
  let gateway: AppGatewayService
  let socket: ControlSocketService
  let host: AppControlPlaneService

  init() throws {
    root = URL(fileURLWithPath: "/private/tmp/cm-mr-\(UUID().uuidString.prefix(8))")
    directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("support"),
      logs: root.appendingPathComponent("logs"))
    try directories.prepare()
    database = try GatewayDatabase(path: directories.database.path)
    let bundled = BundledPlugins.load(directory: nil)
    let store = try AtomicManifestStore(
      manifestURL: directories.manifest, database: database,
      loader: GatewayManifestConfigurationLoader(database: database, bundledPlugins: bundled))
    _ = try store.activate(manifest: GatewayConfiguration(workspaceDirectory: root).exportedTOML())
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    host = AppControlPlaneService(
      directories: directories, database: database, manifestStore: store,
      secretStore: secrets, openAITunnelSupervisor: OpenAITunnelSupervisor(secretStore: secrets),
      bundledPlugins: bundled)
    gateway = AppGatewayService.live(controlPlane: host, directories: directories)
    socket = ControlSocketService(
      controlPlane: host, gatewayService: gateway, socketURL: directories.controlSocket)
  }

  func cli(_ arguments: [String]) async throws -> CommandResult {
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/computer-mcp")
    return try await BlockingOperationExecutor(label: "mcp-registration-cli-test").perform {
      try ProcessCommandRunner().run(
        executable: executable.path,
        arguments: ["mcp"] + arguments + ["--control-socket", directories.controlSocket.path],
        workingDirectory: root, environment: [:], timeoutMilliseconds: 5000,
        maxOutputBytes: 1_048_576)
    }
  }

  func json(_ arguments: [String]) async throws -> JSONValue {
    let result = try await cli(arguments)
    try #require(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
    return try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
  }

  func apply(_ arguments: [String]) async throws {
    let preview = try await json(arguments)
    let digest = try #require(preview.objectValue?["current_digest"]?.stringValue)
    _ = try await json(arguments + ["--apply", "--expected-current-digest", digest])
  }

  func configuration() throws -> GatewayConfiguration {
    try GatewayConfiguration.load(path: directories.manifest.path)
  }

  func transport() -> GatewaySocketTransport {
    .init(configuration: .init(socketURL: directories.gatewaySocket, clientIdentity: .localCLI))
  }

  func processIDs(at url: URL) throws -> [Int32] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try #require(Int32($0))
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
