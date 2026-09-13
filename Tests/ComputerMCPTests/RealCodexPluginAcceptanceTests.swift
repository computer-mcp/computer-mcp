import Darwin
import Foundation
import GRDB
import Testing

@testable import ComputerMCP

/// Uses the installed vendor executable and packaged adapter with isolated homes and a loopback model.
@Suite(
  .serialized, .timeLimit(.minutes(3)),
  .enabled(if: ProcessInfo.processInfo.environment["COMPUTER_MCP_REAL_CODEX_ACCEPTANCE"] == "1"))
struct RealCodexPluginAcceptanceTests {
  @Test
  func skillsListCompletesWithinItsDeadlineAndPinsTheWorkspace() async throws {
    let fixture = try await NativeCodexFixture()
    var active: GatewayRuntime?
    do {
      let gateway = try await fixture.gateway()
      active = gateway
      let started = ContinuousClock.now
      let result = try await fixture.method(gateway, "skills/list", ["forceReload": .bool(false)])
      #expect(started.duration(to: .now) < .seconds(30))
      let entries = try #require(result.objectValue?["data"]?.arrayValue)
      #expect(entries.count == 1)
      #expect(entries.first?.objectValue?["cwd"] == .string(fixture.workspace.rootPath))
      try await fixture.stop(gateway)
      await fixture.remove()
    } catch {
      await active?.shutdown()
      await fixture.remove(retainingEvidence: true)
      throw error
    }
  }

  @Test
  func appListCompletesWithinTheDedicatedBound() async throws {
    let fixture = try await NativeCodexFixture()
    var active: GatewayRuntime?
    do {
      let gateway = try await fixture.gateway()
      active = gateway
      let started = ContinuousClock.now
      let result = try await fixture.method(
        gateway, "app/list", ["forceRefetch": .bool(false), "limit": .number(1)])
      let entries = try #require(result.objectValue?["data"]?.arrayValue)
      #expect(entries.count <= 1)
      #expect(started.duration(to: .now) < .seconds(120))
      try await fixture.stop(gateway)
      await fixture.remove()
    } catch {
      await active?.shutdown()
      await fixture.remove(retainingEvidence: true)
      throw error
    }
  }

  @Test
  func scopedElevationEnablesGitAndLoopbackThenRevocationRestoresTheSandbox() async throws {
    let fixture = try await NativeCodexFixture()
    var active: GatewayRuntime?
    do {
      let gateway = try await fixture.gateway()
      active = gateway
      let start = try await fixture.call(gateway, "thread.start")
      let thread = try #require(start.objectValue?["thread"]?.objectValue?["id"]?.stringValue)
      #expect(start.objectValue?["sandbox"]?.objectValue?["type"] != .string("dangerFullAccess"))
      try fixture.response(
        "safe",
        command:
          "/bin/sleep 2; /usr/bin/touch .git/safe-probe; /usr/bin/curl --silent --show-error --max-time 3 \(fixture.probeURL) > safe-network.txt"
      )
      let safeTurn = try await fixture.startTurn(gateway, thread: thread)
      try await fixture.waitForModel("safe")
      let grant = try fixture.approve(thread: thread, mode: .threadScopedTTL)
      #expect(grant.state == .approved)
      try await fixture.completed(gateway, thread: thread, turn: safeTurn, commandSuccess: false)
      try fixture.commandResult("safe", succeeded: false)
      #expect(!fixture.exists(".git/safe-probe"))
      #expect(fixture.contents("safe-network.txt") != fixture.networkToken)

      try fixture.response(
        "elevated",
        command:
          "/usr/bin/printf 'elevated\\n' > elevated.txt && /usr/bin/git add elevated.txt && /usr/bin/git commit -m 'Scoped plugin acceptance' && /usr/bin/curl --silent --show-error --max-time 3 \(fixture.probeURL) > elevated-network.txt"
      )
      let elevatedTurn = try await fixture.startTurn(gateway, thread: thread)
      try await fixture.completed(gateway, thread: thread, turn: elevatedTurn, commandSuccess: true)
      try fixture.commandResult("elevated", succeeded: true)
      #expect(try fixture.git(["log", "-1", "--pretty=%s"]) == "Scoped plugin acceptance\n")
      #expect(fixture.contents("elevated-network.txt") == fixture.networkToken)
      let active = try #require(try fixture.database.codexElevationGrant(id: grant.id))
      #expect(active.state == .active && active.consumedTurnIDs.contains(elevatedTurn))

      try fixture.revoke(grant.id)
      try fixture.response(
        "restored",
        command:
          "/usr/bin/touch .git/restored-probe; /usr/bin/curl --silent --show-error --max-time 3 \(fixture.probeURL) > restored-network.txt"
      )
      let restored = try await fixture.startTurn(gateway, thread: thread)
      try await fixture.completed(gateway, thread: thread, turn: restored, commandSuccess: false)
      try fixture.commandResult("restored", succeeded: false)
      #expect(!fixture.exists(".git/restored-probe"))
      #expect(fixture.contents("restored-network.txt") != fixture.networkToken)
      try await fixture.release(gateway, thread: thread)
      #expect(try fixture.database.codexElevationGrant(id: grant.id)?.state == .revoked)
      try await fixture.stop(gateway)
      await fixture.remove()
    } catch {
      await active?.shutdown()
      await fixture.remove(retainingEvidence: true)
      throw error
    }
  }

  @Test
  func approvedGrantAppliesAtColdThreadStartAndItsFirstTurn() async throws {
    let fixture = try await NativeCodexFixture()
    var active: GatewayRuntime?
    do {
      let gateway = try await fixture.gateway()
      active = gateway
      let grant = try fixture.approve(thread: nil, mode: .boundedTime)
      let start = try await fixture.call(gateway, "thread.start")
      let thread = try #require(start.objectValue?["thread"]?.objectValue?["id"]?.stringValue)
      #expect(start.objectValue?["sandbox"]?.objectValue?["type"] == .string("dangerFullAccess"))
      let active = try #require(try fixture.database.codexElevationGrant(id: grant.id))
      #expect(active.state == .active && active.threadID == thread)
      let turn = try await fixture.startTurn(gateway, thread: thread)
      try await fixture.completed(gateway, thread: thread, turn: turn)
      let consumed = try #require(try fixture.database.codexElevationGrant(id: grant.id))
      #expect(consumed.consumedTurnIDs.contains(turn))
      let status = try await fixture.call(gateway, "status")
      let runtime = try #require(status.objectValue?["runtime_id"]?.stringValue)
      #expect(consumed.consumedRuntimeIDs.contains(runtime))
      try fixture.revoke(grant.id)
      try await fixture.release(gateway, thread: thread)
      try await fixture.stop(gateway)
      await fixture.remove()
    } catch {
      await active?.shutdown()
      await fixture.remove(retainingEvidence: true)
      throw error
    }
  }

  @Test
  func threeIndependentConnectionsHandoffTheSameNativeThreadAndGoalWithoutOrphans() async throws {
    let fixture = try await NativeCodexFixture()
    var current: GatewayRuntime?
    do {
      var thread: String?
      var processes: Set<Int32> = []
      for generation in 1...3 {
        let gateway = try await fixture.gateway(connection: generation)
        current = gateway
        if let thread {
          _ = try await fixture.call(gateway, "thread.reclaim", ["thread_id": .string(thread)])
        } else {
          let start = try await fixture.call(gateway, "thread.start")
          let created = try #require(start.objectValue?["thread"]?.objectValue?["id"]?.stringValue)
          thread = created
          _ = try await fixture.call(
            gateway, "goal.set",
            [
              "thread_id": .string(created),
              "objective": .string("Native three-generation handoff"),
              "status": .string("paused"),
            ])
          let turn = try await fixture.startTurn(gateway, thread: created)
          try await fixture.completed(gateway, thread: created, turn: turn)
        }
        let threadID = try #require(thread)
        let read = try await fixture.call(gateway, "thread.read", ["thread_id": .string(threadID)])
        #expect(read.objectValue?["thread"]?.objectValue?["id"] == .string(threadID))
        let goal = try await fixture.call(gateway, "goal.get", ["thread_id": .string(threadID)])
        #expect(
          goal.objectValue?["goal"]?.objectValue?["objective"]
            == .string("Native three-generation handoff"))
        let status = try await fixture.call(gateway, "status")
        let pid = try #require(
          status.objectValue?["process"]?.objectValue?["process_id"]?.numberValue)
        #expect(processes.insert(Int32(pid)).inserted)
        try await fixture.release(gateway, thread: threadID, preservingGoal: true)
        try await fixture.stop(gateway)
        current = nil
      }
      let receipts = try fixture.runtimeReceipts()
      #expect(receipts.count == 3)
      #expect(receipts.allSatisfy { $0.objectValue?["state"] == .string("stopped") })
      let receiptedPIDs = Set(
        receipts.compactMap {
          $0.objectValue?["process"]?.objectValue?["process_id"]?.numberValue.map { Int32($0) }
        })
      #expect(receiptedPIDs == processes)
      #expect(processes.allSatisfy(NativeCodexFixture.exited))
      await fixture.remove()
    } catch {
      await current?.shutdown()
      await fixture.remove(retainingEvidence: true)
      throw error
    }
  }

  @Test(arguments: [false, true])
  func interruptedNativeTurnRecoversWithoutReplayingItsWrite(crashAdapter: Bool) async throws {
    let fixture = try await NativeCodexFixture()
    var current: GatewayRuntime?
    do {
      let first = try await fixture.gateway()
      current = first
      let start = try await fixture.call(first, "thread.start")
      let thread = try #require(start.objectValue?["thread"]?.objectValue?["id"]?.stringValue)
      let objective = "Preserve this goal across an unfinished native turn"
      let originalGoal = try await fixture.call(
        first, "goal.set",
        [
          "thread_id": .string(thread), "objective": .string(objective),
          "status": .string("paused"),
        ])
      try fixture.response(
        "interrupted-write", command: "/usr/bin/printf 'once\\n' >> write-receipt.txt",
        holdAfterCommand: true)
      let interruptedTurn = try await fixture.startTurn(first, thread: thread)
      try await fixture.waitForEvidence("result-interrupted-write.json")
      try fixture.commandResult("interrupted-write", succeeded: true)
      try #require(fixture.contents("write-receipt.txt") == "once\n")

      let oldProcesses = try await fixture.crash(first, adapter: crashAdapter)
      await first.shutdown()
      current = nil
      // A crashed adapter cannot acknowledge its vendor cleanup; its watchdog is independent.
      try await fixture.waitForExit(oldProcesses)

      let second = try await fixture.gateway(connection: 2)
      current = second
      _ = try await fixture.call(second, "thread.reclaim", ["thread_id": .string(thread)])
      let goal = try await fixture.call(second, "goal.get", ["thread_id": .string(thread)])
      #expect(goal.objectValue?["goal"] == originalGoal.objectValue?["goal"])
      let read = try await fixture.call(
        second, "thread.read", ["thread_id": .string(thread), "include_turns": .bool(true)])
      let turns = try #require(read.objectValue?["thread"]?.objectValue?["turns"]?.arrayValue)
      let recovered = try #require(
        turns.first { $0.objectValue?["id"] == .string(interruptedTurn) })
      #expect(recovered.objectValue?["status"] != .string("inProgress"))
      #expect(recovered.objectValue?["status"] != .string("completed"))
      #expect(fixture.contents("write-receipt.txt") == "once\n")

      try fixture.response(
        "recovered-write", command: "/usr/bin/printf 'new\\n' >> write-receipt.txt")
      let nextTurn = try await fixture.startTurn(second, thread: thread)
      #expect(nextTurn != interruptedTurn)
      try await fixture.completed(second, thread: thread, turn: nextTurn, commandSuccess: true)
      try fixture.commandResult("recovered-write", succeeded: true)
      #expect(fixture.contents("write-receipt.txt") == "once\nnew\n")
      try await fixture.release(second, thread: thread, preservingGoal: true)
      try await fixture.stop(second)
      current = nil
      #expect(oldProcesses.allSatisfy(NativeCodexFixture.exited))
      await fixture.remove()
    } catch {
      await current?.shutdown()
      await fixture.remove(retainingEvidence: true)
      throw error
    }
  }
}

private final class NativeCodexFixture: Sendable {
  let root: URL
  let workspace: RegisteredWorkspace
  let database: GatewayDatabase
  let networkToken = UUID().uuidString
  let probeURL: String
  private let model: ManagedLineProcess
  private let adapter: String
  private let config: URL
  private let home: URL

  init() async throws {
    let environment = ProcessInfo.processInfo.environment
    adapter = try #require(environment["COMPUTER_MCP_TEST_CODEX_PLUGIN"])
    let codex = try #require(environment["COMPUTER_MCP_REAL_CODEX_EXECUTABLE"])
    try #require(adapter.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: adapter))
    try #require(codex.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: codex))
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("native-plugin-" + UUID().uuidString).resolvingSymlinksInPath()
    let directory = root.appendingPathComponent("workspace")
    home = root.appendingPathComponent("codex-home")
    for path in [directory, home] {
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    workspace = .init(
      id: UUID().uuidString, displayName: "Native acceptance", rootPath: directory.path)
    database = try GatewayDatabase(path: root.appendingPathComponent("host.sqlite").path)
    try database.saveWorkspace(workspace)
    try database.saveProfile(
      .init(
        id: .chatGPTOperate, capabilityIDs: ["mcp.tools.call"], workspaceIDs: [workspace.id],
        allowedCallers: [.secureTunnel]))
    config = root.appendingPathComponent("adapter.json")
    let modelSource = try #require(
      Bundle.module.url(
        forResource: "ModelServer", withExtension: "py", subdirectory: "Fixtures/NativeCodex"))
    try JSONEncoder().encode(["id": "text"]).write(to: root.appendingPathComponent("response.json"))
    try networkToken.write(
      to: root.appendingPathComponent("network-token"), atomically: true, encoding: .utf8)
    model = try ManagedLineProcess(
      configuration: .init(
        executable: "/usr/bin/python3", arguments: [modelSource.path, root.path],
        environment: ["PATH": "/usr/bin:/bin"], workingDirectory: root))
    do {
      var lines = model.inboundLines.makeAsyncIterator()
      let ready = try #require(try await lines.next())
      let value = try JSONDecoder().decode(JSONValue.self, from: Data(ready.utf8))
      let port = try #require(value.objectValue?["port"]?.numberValue)
      probeURL = "http://127.0.0.1:\(Int(port))/probe"
      let toml = """
        model = "acceptance-fixture"
        model_provider = "fixture"
        cli_auth_credentials_store = "file"
        approval_policy = "never"
        sandbox_mode = "workspace-write"
        web_search = "disabled"
        [model_providers.fixture]
        name = "Isolated native acceptance"
        base_url = "http://127.0.0.1:\(Int(port))/v1"
        wire_api = "responses"
        requires_openai_auth = false
        supports_websockets = false
        request_max_retries = 0
        stream_max_retries = 0
        [analytics]
        enabled = false
        [otel]
        metrics_exporter = "none"
        """
      try toml.write(
        to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
      try JSONEncoder().encode(
        JSONValue.object([
          "enabled": .bool(true), "executable": .string(codex),
          "app_server_enabled": .bool(true), "exec_enabled": .bool(false),
          "mcp_enabled": .bool(false),
          "sandbox": .string("workspace-write"), "approval_policy": .string("never"),
          "app_server_request_timeout_seconds": .number(30),
          "app_server_app_list_timeout_seconds": .number(120),
        ])
      ).write(to: config)
      _ = try git(["init", "-q"])
      _ = try git(["config", "user.name", "Computer MCP Acceptance"])
      _ = try git(["config", "user.email", "acceptance@example.invalid"])
      _ = try git(["config", "commit.gpgsign", "false"])
      _ = try git(["config", "core.hooksPath", directory.appendingPathComponent(".git/hooks").path])
    } catch {
      await model.close()
      try? FileManager.default.removeItem(at: root)
      throw error
    }
  }

  func gateway(connection: Int = 1) async throws -> GatewayRuntime {
    let names: [String: CapabilityRisk] = [
      "codex.app.status": .readOnly, "codex.app.methods.call": .externalWrite,
      "codex.app.thread.start": .workspaceWrite, "codex.app.thread.read": .readOnly,
      "codex.app.thread.release": .workspaceWrite, "codex.app.thread.reclaim": .workspaceWrite,
      "codex.app.turn.start": .workspaceWrite, "codex.app.goal.set": .workspaceWrite,
      "codex.app.goal.get": .readOnly, "codex.app.events.read": .readOnly,
    ]
    return try await GatewayRuntime.make(
      configuration: .init(
        profiles: [
          .init(
            id: .chatGPTOperate, capabilities: ["mcp.tools.call"],
            workspaces: [workspace.id], allowedCallers: [.secureTunnel])
        ],
        mcp: .init(servers: [
          .init(
            id: "native-codex", transport: .stdio, command: adapter,
            args: [
              "--config", config.path, "--state-directory",
              root.appendingPathComponent("adapter-state").path,
            ],
            env: ["CODEX_HOME": home.path], exposure: .reexport, prefix: "",
            allowedTools: names.keys.sorted(), startupTimeoutMs: 10_000, requestTimeoutMs: 130_000,
            toolRisks: names, hostServices: true)
        ])),
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate,
        transportTrace: .init(
          transport: "gateway_socket", socketConnectionID: "native-\(connection)")),
      database: database, registeredWorkspaces: [workspace])
  }

  func call(_ gateway: GatewayRuntime, _ name: String, _ arguments: [String: JSONValue] = [:])
    async throws -> JSONValue
  {
    var arguments = arguments
    arguments["workspace_id"] = .string(workspace.id)
    let result = try await gateway.callToolAsync(
      name: "codex.app." + name, arguments: .object(arguments))
    try #require(result.objectValue?["isError"] != .bool(true), "\(name): \(result)")
    return try #require(result.objectValue?["structuredContent"]?.objectValue?["result"])
  }

  func method(_ gateway: GatewayRuntime, _ method: String, _ params: [String: JSONValue])
    async throws -> JSONValue
  {
    try await call(gateway, "methods.call", ["method": .string(method), "params": .object(params)])
  }

  func startTurn(_ gateway: GatewayRuntime, thread: String) async throws -> String {
    let result = try await call(
      gateway, "turn.start",
      ["thread_id": .string(thread), "prompt": .string("Run the isolated fixture response.")])
    return try #require(result.objectValue?["turn"]?.objectValue?["id"]?.stringValue)
  }

  func completed(
    _ gateway: GatewayRuntime, thread: String, turn: String, commandSuccess: Bool? = nil
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    var cursor = 0
    var commandExits: [Double] = []
    while ContinuousClock.now < deadline {
      let page = try await call(gateway, "events.read", ["after_cursor": .number(Double(cursor))])
      try JSONEncoder().encode(page).write(
        to: root.appendingPathComponent("events-\(turn)-\(cursor).json"), options: .atomic)
      #expect(page.objectValue?["missed_events"] == .number(0))
      cursor = Int(page.objectValue?["next_cursor"]?.numberValue ?? Double(cursor))
      for event in page.objectValue?["events"]?.arrayValue ?? [] {
        let payload = event.objectValue?["payload"]?.objectValue
        if payload?["method"] == .string("item/completed"),
          let params = payload?["params"]?.objectValue,
          params["threadId"] == .string(thread), params["turnId"] == .string(turn),
          let item = params["item"]?.objectValue,
          item["type"] == .string("commandExecution"),
          let exit = item["exitCode"]?.numberValue
        {
          commandExits.append(exit)
        }
        if payload?["method"] == .string("turn/completed"),
          let completed = payload?["params"]?.objectValue?["turn"]?.objectValue,
          completed["id"] == .string(turn)
        {
          try #require(completed["status"] == .string("completed"), "\(completed)")
          if let commandSuccess {
            if commandSuccess {
              try #require(commandExits.count == 1, "Expected one successful command completion")
            } else {
              // Native sandbox denials may return a tool error without an execution item.
              // The fixture also verifies the exact call's native function_call_output.
              #expect(commandExits.count <= 1)
            }
            if let exit = commandExits.first { #expect((exit == 0) == commandSuccess) }
          }
          return
        }
      }
      try await Task.sleep(for: .milliseconds(30))
    }
    throw GatewayToolError.executionFailed(
      "Native turn \(turn) did not complete in the fixture deadline.")
  }

  func approve(thread: String?, mode: CodexElevationGrantMode) throws -> CodexElevationGrantRecord {
    let pending = try CodexElevationGrantService.request(
      owner: .init(
        workspaceID: workspace.id, profileID: "chatgpt-operate", caller: "secure-tunnel",
        transport: "gateway_socket", socketConnectionID: "native-1", tunnelInstanceID: nil,
        tunnelProfileID: nil),
      database: database, threadID: thread, mode: mode, reason: "Isolated native acceptance",
      maximumDurationSeconds: 300, maximumTurnCount: 5)
    return try CodexElevationGrantService.approve(
      id: pending.id, owner: localOwner, database: database)
  }

  private var localOwner: CodexRuntimeOwner {
    .init(
      workspaceID: workspace.id, profileID: "local-admin", caller: "local-cli",
      transport: "fixture", socketConnectionID: nil, tunnelInstanceID: nil, tunnelProfileID: nil)
  }

  func revoke(_ id: String) throws {
    _ = try CodexElevationGrantService.revoke(id: id, owner: localOwner, database: database)
  }

  func response(_ id: String, command: String, holdAfterCommand: Bool = false) throws {
    try JSONEncoder().encode(
      JSONValue.object([
        "id": .string(id), "command": .string(command),
        "hold_after_command": .bool(holdAfterCommand),
      ])
    ).write(
      to: root.appendingPathComponent("response.json"), options: .atomic)
  }

  func commandResult(_ phase: String, succeeded: Bool) throws {
    let result = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(contentsOf: root.appendingPathComponent("result-\(phase).json")))
    #expect(result.objectValue?["type"] == .string("function_call_output"))
    let output = try #require(result.objectValue?["output"]?.stringValue)
    let pattern = try NSRegularExpression(pattern: "Process exited with code (-?[0-9]+)")
    let range = NSRange(output.startIndex..., in: output)
    let match = try #require(pattern.firstMatch(in: output, range: range))
    let codeRange = try #require(Range(match.range(at: 1), in: output))
    let code = try #require(Int(output[codeRange]))
    #expect((code == 0) == succeeded, "\(phase): \(output)")
  }

  func waitForModel(_ phase: String) async throws {
    try await waitForEvidence("started-" + phase)
  }

  func waitForEvidence(_ filename: String) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if FileManager.default.fileExists(atPath: root.appendingPathComponent(filename).path) {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw GatewayToolError.executionFailed(
      "Native fixture evidence did not arrive: \(filename).")
  }

  func crash(_ gateway: GatewayRuntime, adapter: Bool) async throws -> [Int32] {
    let status = try await call(gateway, "status")
    try #require(status.objectValue?["workspace"] == .string(workspace.rootPath))
    let process = try #require(status.objectValue?["process"]?.objectValue)
    let pids = try ["process_id", "supervisor_process_id", "parent_process_id"].map {
      Int32(try #require(process[$0]?.numberValue))
    }
    let target = pids[adapter ? 2 : 0]
    // Only a descendant of this test process may receive the injected failure.
    var ancestor = target
    var visited: Set<Int32> = []
    while ancestor != getpid() {
      try #require(ancestor > 1)
      let firstVisit = visited.insert(ancestor).inserted
      try #require(firstVisit)
      try #require(visited.count <= 12)
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
      try #require(proc_pidinfo(ancestor, PROC_PIDTBSDINFO, 0, &info, size) == size)
      ancestor = Int32(info.pbi_ppid)
    }
    try #require(target != getpid() && kill(target, SIGKILL) == 0)
    if !adapter {
      let deadline = ContinuousClock.now + .seconds(10)
      while ContinuousClock.now < deadline {
        let state = try await call(gateway, "status")
        if state.objectValue?["connection_state"] != .string("running"),
          Self.exited(pids[0]), Self.exited(pids[1])
        {
          #expect(
            state.objectValue?["connection_generation"]
              == status.objectValue?["connection_generation"])
          #expect(state.objectValue?["last_request_failure"]?.objectValue != nil)
          return pids
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      throw GatewayToolError.executionFailed("Native crash did not retire its owned generation.")
    }
    return pids
  }

  func waitForExit(_ pids: [Int32]) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if pids.allSatisfy(Self.exited) { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw GatewayToolError.executionFailed("Crashed fixture processes did not exit: \(pids).")
  }

  func release(_ gateway: GatewayRuntime, thread: String, preservingGoal: Bool = false) async throws
  {
    let result = try await call(gateway, "thread.release", ["thread_id": .string(thread)])
    #expect(result.objectValue?["final_classification"] == .string("released_persisted"))
    #expect(result.objectValue?["externally_claimable"] == .bool(true))
    #expect(result.objectValue?["computer_mcp_writer_ownership_remaining"] == .bool(false))
    if preservingGoal {
      #expect(result.objectValue?["goal_preservation"] == .string("persisted-and-unchanged"))
    }
  }

  func stop(_ gateway: GatewayRuntime) async throws {
    let status = try await call(gateway, "status")
    let process = try #require(status.objectValue?["process"]?.objectValue)
    let pids = try ["process_id", "supervisor_process_id", "parent_process_id"].map {
      Int32(try #require(process[$0]?.numberValue))
    }
    await gateway.shutdown()
    #expect(
      pids.allSatisfy(Self.exited), "Owned native or adapter process survived shutdown: \(pids)")
  }

  func runtimeReceipts() throws -> [JSONValue] {
    var configuration = Configuration()
    configuration.readonly = true
    let inspection = try DatabaseQueue(
      path: root.appendingPathComponent("adapter-state/codex.sqlite").path,
      configuration: configuration)
    defer { try? inspection.close() }
    return try inspection.read { db in
      try String.fetchAll(db, sql: "SELECT payloadJSON FROM codexRuntimeLeases").map {
        try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
      }
    }
  }

  func git(_ arguments: [String]) throws -> String {
    let result = try ProcessCommandRunner().run(
      executable: "/usr/bin/git", arguments: arguments,
      workingDirectory: URL(fileURLWithPath: workspace.rootPath),
      environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
      timeoutMilliseconds: 5_000, maxOutputBytes: 16_384)
    try #require(result.exitCode == 0, "\(result.stderr)")
    return result.stdout
  }

  func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(
      atPath: URL(fileURLWithPath: workspace.rootPath).appendingPathComponent(path).path)
  }
  func contents(_ path: String) -> String? {
    try? String(
      contentsOf: URL(fileURLWithPath: workspace.rootPath).appendingPathComponent(path),
      encoding: .utf8)
  }
  static func exited(_ pid: Int32) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
  func remove(retainingEvidence: Bool = false) async {
    await model.close()
    let snapshot = await model.snapshot()
    #expect(snapshot.state == .stopped)
    if retainingEvidence {
      print("Native acceptance failure evidence retained: \(root.path)")
      return
    }
    if let receipts = try? runtimeReceipts() {
      let stopped = receipts.allSatisfy { receipt in
        guard let process = receipt.objectValue?["process"]?.objectValue
        else { return false }
        return ["process_id", "supervisor_process_id", "parent_process_id"].allSatisfy {
          guard let pid = process[$0]?.numberValue else { return false }
          return Self.exited(Int32(pid))
        }
      }
      guard stopped else {
        Issue.record("Native acceptance cleanup unconfirmed; evidence retained at \(root.path)")
        return
      }
    }
    try? FileManager.default.removeItem(at: root)
  }
}
