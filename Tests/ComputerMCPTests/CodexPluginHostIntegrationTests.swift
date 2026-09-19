import Darwin
import Foundation
import Testing

@testable import ComputerMCP

/// Runs a separately built adapter, not an in-process host-service test double.
/// The vendor endpoint is a disposable protocol fixture and never calls a model.
@Suite(
  .serialized, .timeLimit(.minutes(1)),
  .enabled(
    if: ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_CODEX_PLUGIN"] != nil))
struct CodexPluginHostIntegrationTests {
  @Test(arguments: [
    "read", "cross-workspace", "recursive", "observe-write", "no-delegation", "capability-denied",
  ])
  func independentlyBuiltPluginUsesOnlyItsDelegatedHostScope(mode: String) async throws {
    let fixture = try await PluginHostFixture(mode: mode)
    defer { fixture.remove() }
    do {
      let tools = try await fixture.runtime.listToolsAsyncForTest()
      #expect(tools.contains { $0.name == "adapter.codex.app.thread.loaded.list" })
      #expect(!FileManager.default.fileExists(atPath: fixture.vendorReceipt.path))
      let result = try await fixture.runtime.callToolAsync(
        name: "adapter.codex.app.thread.loaded.list",
        arguments: .object(["workspace_id": .string("fixture")]))
      #expect(result.objectValue?["isError"] != .bool(true))
      let response = try await fixture.callbackResponse()
      if mode == "read" {
        #expect(response.objectValue?["result"]?.objectValue?["success"] == .bool(true))
        let encoded = try JSONEncoder().encode(response)
        #expect(String(decoding: encoded, as: UTF8.self).contains("owned-fixture-value"))
        let audit = try #require(
          try fixture.database.auditEvents().first { $0.capabilityID == "file.read" })
        #expect(audit.workspaceID == "fixture")
        #expect(audit.caller == .secureTunnel)
        #expect(audit.profileID == .chatGPTOperate)
        #expect(audit.socketConnectionID == "fixture-origin")
        #expect(audit.requestID.hasPrefix("host:"))
      } else {
        #expect(
          response.objectValue?["error"] != nil
            || response.objectValue?["result"]?.objectValue?["success"] == .bool(false))
        #expect(
          try !fixture.database.auditEvents().contains {
            $0.capabilityID == "file.read" && $0.decision == .allowed
          })
        #expect(
          try String(contentsOf: fixture.root.appendingPathComponent("value.txt"), encoding: .utf8)
            == "owned-fixture-value")
      }
      let receipt = try fixture.receipt()
      #expect(receipt.objectValue?["inherited_host_env"] == .bool(false))
      #expect(receipt.objectValue?["inherited_host_socket"] == .bool(false))
      await fixture.runtime.shutdown()
      try await fixture.requireVendorExit()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }
  @Test
  func reviewedGitDryRunPreservesTheIndexWithoutNativeMutationApproval() async throws {
    let fixture = try await PluginHostFixture(mode: "dry-run")
    defer { fixture.remove() }
    do {
      _ = try await fixture.runtime.callToolAsync(
        name: "adapter.codex.app.thread.loaded.list",
        arguments: .object(["workspace_id": .string("fixture")]))
      let response = try await fixture.callbackResponse()
      #expect(
        response.objectValue?["result"]?.objectValue?["success"] == .bool(true),
        "Dry-run callback response: \(response)")
      let approvals = try await fixture.runtime.callToolAsync(
        name: "adapter.codex.app.approvals.list",
        arguments: .object(["workspace_id": .string("fixture")]))
      #expect(
        approvals.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?[
          "approvals"]?.arrayValue == [])
      let staged = try fixture.git(["diff", "--cached", "--name-only"])
      #expect(staged.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(
        try fixture.database.auditEvents().contains {
          $0.capabilityID == "git.add" && $0.decision == .allowed && $0.workspaceID == "fixture"
        })
      await fixture.runtime.shutdown()
      try await fixture.requireVendorExit()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }
  @Test(arguments: ["approve", "deny", "revoke-before-commit"])
  func writesRequireLocalHostApprovalForTheExactTicket(decision: String) async throws {
    let fixture = try await PluginHostFixture(mode: "write")
    defer { fixture.remove() }
    do {
      _ = try await fixture.runtime.callToolAsync(
        name: "adapter.codex.app.thread.loaded.list",
        arguments: .object(["workspace_id": .string("fixture")]))
      let approval = try await fixture.pendingApproval(capability: "file.replace_text")
      #expect(approval.state == .pendingApproval)
      #expect(
        try String(contentsOf: fixture.root.appendingPathComponent("value.txt"), encoding: .utf8)
          == "owned-fixture-value")
      #expect(
        try !fixture.database.auditEvents().contains { $0.capabilityID == "operations.commit" })
      _ = try fixture.database.resolveOperationApproval(
        id: approval.id, approved: decision != "deny", resolver: .localCLI)
      if decision == "revoke-before-commit" {
        var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
        grant.workspaceIDs.removeAll()
        try fixture.database.saveProfile(grant)
      }
      try fixture.queueCallback(
        id: 901, tool: "operations.commit",
        arguments: [
          "tool": .string("file.replace_text"), "ticket_id": .string(approval.id),
          "arguments": .object([
            "path": .string("value.txt"), "search": .string("owned"),
            "replacement": .string("changed"), "dry_run": .bool(false),
          ]),
        ])
      let response = try await fixture.callbackResponse(id: 901)
      #expect(
        response.objectValue?["result"]?.objectValue?["success"] == .bool(decision == "approve"))
      let value = try String(
        contentsOf: fixture.root.appendingPathComponent("value.txt"), encoding: .utf8)
      #expect(value == (decision == "approve" ? "changed-fixture-value" : "owned-fixture-value"))
      let audits = try fixture.database.auditEvents()
      if decision == "approve" {
        let target = try #require(
          audits.first { $0.capabilityID == "file.replace_text" && $0.decision == .allowed })
        #expect(target.ticketID == approval.id)
        let ticket = try #require(try fixture.database.operationTicket(id: approval.id))
        #expect(ticket.state == .succeeded)
        #expect(target.invocationID == ticket.invocationID)
        #expect(target.parentRequestID == ticket.parentRequestID)
      } else {
        #expect(
          !audits.contains { $0.capabilityID == "file.replace_text" && $0.decision == .allowed })
      }
      await fixture.runtime.shutdown()
      try await fixture.requireVendorExit()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test
  func locallyApprovedGitWorkflowCreatesAHookedCommitAndCleanWorktree() async throws {
    let fixture = try await PluginHostFixture(mode: "governed-git")
    defer { fixture.remove() }
    do {
      _ = try await fixture.runtime.callToolAsync(
        name: "adapter.codex.app.thread.loaded.list",
        arguments: .object(["workspace_id": .string("fixture")]))
      _ = try await fixture.callbackResponse(id: 900)
      let steps: [(String, JSONValue)] = [
        (
          "file.write",
          .object(["path": .string("product.txt"), "content": .string("production-ready\n")])
        ),
        ("git.add", .object(["paths": .array([.string("product.txt")])])),
        ("git.commit", .object(["message": .string("Verify governed plugin Git")])),
      ]
      for (index, step) in steps.enumerated() {
        let prepareID = 1_000 + index * 2
        try fixture.queueCallback(
          id: prepareID, tool: "operations.prepare",
          arguments: ["tool": .string(step.0), "arguments": step.1])
        _ = try await fixture.callbackResponse(id: prepareID)
        let approval = try await fixture.pendingApproval(capability: step.0)
        if index == 0 {
          #expect(
            !FileManager.default.fileExists(
              atPath: fixture.root.appendingPathComponent("product.txt").path))
        } else if index == 1 {
          #expect(try fixture.git(["diff", "--cached", "--name-only"]).stdout.isEmpty)
        } else {
          #expect(
            !FileManager.default.fileExists(
              atPath: fixture.root.appendingPathComponent(".git/hook-ran").path))
        }
        _ = try fixture.database.resolveOperationApproval(
          id: approval.id, approved: true, resolver: .localCLI)
        try fixture.queueCallback(
          id: prepareID + 1, tool: "operations.commit",
          arguments: [
            "tool": .string(step.0), "arguments": step.1, "ticket_id": .string(approval.id),
          ])
        let response = try await fixture.callbackResponse(id: prepareID + 1)
        try #require(response.objectValue?["result"]?.objectValue?["success"] == .bool(true))
        let audits = try fixture.database.auditEvents()
        let target = try #require(
          audits.first { $0.capabilityID == step.0 && $0.decision == .allowed })
        #expect(target.workspaceID == "fixture")
        #expect(target.caller == .secureTunnel)
        #expect(target.socketConnectionID == "fixture-origin")
        #expect(target.ticketID == approval.id)
        #expect(try fixture.database.operationTicket(id: approval.id)?.state == .succeeded)
      }
      #expect(
        FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent(".git/hook-ran").path))
      #expect(try fixture.git(["status", "--porcelain"]).stdout.isEmpty)
      #expect(try fixture.git(["show", "HEAD:product.txt"]).stdout == "production-ready\n")
      #expect(
        try fixture.git(["log", "-1", "--pretty=%s"]).stdout.trimmingCharacters(
          in: .whitespacesAndNewlines) == "Verify governed plugin Git")
      await fixture.runtime.shutdown()
      try await fixture.requireVendorExit()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }
}

private final class PluginHostFixture: Sendable {
  let root: URL
  let database: GatewayDatabase
  let runtime: GatewayRuntime
  let vendorReceipt: URL
  let responseFile: URL

  init(mode: String) async throws {
    let executable = try #require(
      ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_CODEX_PLUGIN"])
    #expect(executable.hasPrefix("/"))
    #expect(FileManager.default.isExecutableFile(atPath: executable))
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "plugin-host-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "owned-fixture-value".write(
      to: root.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
    vendorReceipt = root.appendingPathComponent("vendor.json")
    responseFile = root.appendingPathComponent("callback.json")
    let vendor = root.appendingPathComponent("vendor-fixture")
    try Self.vendorSource.write(to: vendor, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vendor.path)
    let target =
      mode == "recursive"
      ? "adapter.codex.app.thread.loaded.list"
      : mode == "dry-run"
        ? "git.add"
        : ["observe-write", "write"].contains(mode) ? "file.replace_text" : "file.read"
    var arguments: [String: JSONValue] = ["path": .string("value.txt")]
    if mode == "dry-run" {
      arguments = ["paths": .array([.string("value.txt")]), "dry_run": .bool(true)]
    }
    if mode == "cross-workspace" { arguments["workspace_id"] = .string("other") }
    if ["observe-write", "write"].contains(mode) {
      arguments.merge([
        "search": .string("owned"), "replacement": .string("changed"), "dry_run": .bool(false),
      ]) { _, new in new }
    }
    try JSONEncoder().encode(
      JSONValue.object([
        "id": .number(900), "method": .string("item/tool/call"),
        "params": .object([
          "namespace": .string("computer-mcp"),
          "tool": .string(mode == "write" ? "operations.prepare" : target),
          "arguments": mode == "write"
            ? .object(["tool": .string(target), "arguments": .object(arguments)])
            : .object(arguments),
          "callId": .string("fixture-call"), "threadId": .string("fixture-thread"),
          "turnId": .string("fixture-turn"),
        ]),
      ])
    ).write(to: root.appendingPathComponent("callback-request.json"))
    let config = root.appendingPathComponent("adapter.json")
    try JSONEncoder().encode(
      JSONValue.object([
        "enabled": .bool(true), "executable": .string(vendor.path),
        "app_server_enabled": .bool(true), "exec_enabled": .bool(false),
        "app_server_request_timeout_seconds": .number(8),
        "app_server_approval_timeout_seconds": .number(8),
      ])
    ).write(to: config)
    database = try GatewayDatabase(inMemory: ())
    let workspace = RegisteredWorkspace(id: "fixture", displayName: "Fixture", rootPath: root.path)
    try database.saveWorkspace(workspace)
    let profile: GatewayProfileID = mode == "observe-write" ? .chatGPTObserve : .chatGPTOperate
    let permissionMode: GatewayPermissionMode =
      mode == "observe-write" ? .readOnly : .workspaceOperations
    var capabilities = [
      "workspace.list", "workspace.describe", "policy.probe", "file.read", "file.replace_text",
      "mcp.tools.call", "operations.prepare", "operations.commit",
    ]
    if mode == "capability-denied" { capabilities.removeAll { $0 == "file.read" } }
    if mode == "dry-run" { capabilities.append("git.add") }
    if mode == "governed-git" { capabilities += ["file.write", "git.add", "git.commit"] }
    try database.saveProfile(
      .init(
        id: profile, capabilityIDs: Set(capabilities), workspaceIDs: ["fixture"],
        allowedCallers: [.secureTunnel],
        mode: permissionMode,
        confirmationPolicy: mode == "governed-git" ? .allWrites : .riskBased))
    let server = MCPServerConfig(
      id: "fixture-plugin", transport: .stdio, command: executable,
      args: [
        "--config", config.path, "--state-directory",
        root.appendingPathComponent("adapter-state").path,
      ],
      exposure: .reexport, prefix: "adapter",
      allowedTools: [
        "codex.app.thread.loaded.list", "codex.app.approvals.list", "codex.app.approvals.respond",
      ],
      startupTimeoutMs: 10_000, requestTimeoutMs: 12_000,
      toolRisks: [
        "codex.app.thread.loaded.list": .readOnly, "codex.app.approvals.list": .readOnly,
        "codex.app.approvals.respond": .externalWrite,
      ], hostServices: mode != "no-delegation")
    runtime = try await GatewayRuntime.make(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: profile),
        profiles: [
          .init(
            id: profile, capabilities: capabilities, workspaces: ["fixture"],
            allowedCallers: [.secureTunnel],
            mode: permissionMode,
            confirmationPolicy: mode == "governed-git" ? .allWrites : .riskBased)
        ],
        cli: .init(commands: [.init(id: "git", executable: "/usr/bin/git")]),
        mcp: .init(servers: [server]),
        builtin: .init(enabled: [
          "file.read", "file.replace_text", "file.write", "git.add", "git.commit",
        ])),
      context: .init(
        caller: .secureTunnel, profileID: profile,
        transportTrace: .init(transport: "gateway_socket", socketConnectionID: "fixture-origin"),
        trustedPrincipalID: "plugin-host-fixture"),
      database: database, registeredWorkspaces: [workspace])
    if mode == "dry-run" { _ = try git(["init", "--quiet"]) }
    if mode == "governed-git" {
      _ = try git(["init", "--quiet"])
      _ = try git(["config", "user.name", "Computer MCP Test"])
      _ = try git(["config", "user.email", "computer-mcp@example.invalid"])
      _ = try git(["config", "commit.gpgsign", "false"])
      _ = try git(["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path])
      try "*\n!product.txt\n".write(
        to: root.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
      let hook = root.appendingPathComponent(".git/hooks/pre-commit")
      try "#!/bin/sh\n/usr/bin/touch .git/hook-ran\n".write(
        to: hook, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)

    }
  }

  func git(_ arguments: [String]) throws -> CommandResult {
    let result = try ProcessCommandRunner().run(
      executable: "/usr/bin/git", arguments: arguments,
      workingDirectory: root, environment: [:], timeoutMilliseconds: 5_000, maxOutputBytes: 16_384)
    try #require(result.exitCode == 0, "\(result.stderr)")
    return result
  }

  func pendingApproval(capability: String) async throws -> OperationTicket {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if let ticket = try database.operationApprovals(limit: 100).first(where: {
        $0.capabilityID == capability && $0.state == .pendingApproval
      }) {
        return ticket
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let response = try? String(contentsOf: responseFile, encoding: .utf8)
    throw GatewayToolError.executionFailed(
      "The host did not produce a pending operation ticket. Fixture callback: "
        + String((response ?? "No response received").prefix(4096)))
  }

  func queueCallback(id: Int, tool: String, arguments: [String: JSONValue]) throws {
    let request = JSONValue.object([
      "id": .number(Double(id)), "method": .string("item/tool/call"),
      "params": .object([
        "namespace": .string("computer-mcp"), "tool": .string(tool),
        "arguments": .object(arguments),
        "callId": .string("callback-\(id)"), "threadId": .string("fixture-thread"),
        "turnId": .string("fixture-turn"),
      ]),
    ])
    try JSONEncoder().encode(request).write(
      to: root.appendingPathComponent("queued-\(id).json"), options: .atomic)
  }

  func callbackResponse(id: Int? = nil) async throws -> JSONValue {
    let file = id.map { root.appendingPathComponent("callback-\($0).json") } ?? responseFile
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if let data = try? Data(contentsOf: file),
        let value = try? JSONDecoder().decode(JSONValue.self, from: data)
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw GatewayToolError.executionFailed(
      "Disposable vendor did not receive its callback response.")
  }
  func receipt() throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: vendorReceipt))
  }
  func requireVendorExit() async throws {
    let pid = try #require(try receipt().objectValue?["pid"]?.numberValue).rounded()
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if kill(Int32(pid), 0) != 0 && errno == ESRCH { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The receipted disposable vendor process survived gateway shutdown.")
  }
  func remove() { try? FileManager.default.removeItem(at: root) }

  private static let vendorSource = #"""
    #!/usr/bin/python3
    import json, os, pathlib, stat, sys, threading, time
    root = pathlib.Path(__file__).resolve().parent
    def save(name, value):
        target = root / name
        temporary = target.with_suffix('.tmp')
        temporary.write_text(json.dumps(value), encoding='utf-8')
        temporary.replace(target)
    try:
        inherited_socket = stat.S_ISSOCK(os.fstat(3).st_mode)
    except OSError:
        inherited_socket = False
    save('vendor.json', {'pid': os.getpid(), 'inherited_host_env': any(k in os.environ for k in ['COMPUTER_MCP_HOST_FD','COMPUTER_MCP_HOST_CONTEXT']), 'inherited_host_socket': inherited_socket})
    output_lock = threading.Lock()
    def emit(value):
        with output_lock:
            print(json.dumps(value), flush=True)
    def queued_callbacks():
        while True:
            for path in sorted(root.glob('queued-*.json')):
                value = json.loads(path.read_text())
                path.unlink()
                emit(value)
            time.sleep(.01)
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get('method')
        if method == 'initialize':
            result = {'codexHome': str(root), 'platformFamily': 'unix', 'platformOs': 'macos', 'userAgent': 'isolated-protocol-fixture'}
        elif method == 'initialized':
            emit(json.loads((root/'callback-request.json').read_text()))
            threading.Thread(target=queued_callbacks, daemon=True).start()
            continue
        elif method == 'thread/loaded/list':
            result = {'data': [], 'nextCursor': None}
        elif method is None and isinstance(request.get('id'), int) and request['id'] >= 900:
            save('callback.json', request)
            save('callback-' + str(request['id']) + '.json', request)
            continue
        elif method == 'thread/unsubscribe':
            result = {'status': 'unsubscribed'}
        elif 'id' not in request:
            continue
        else:
            emit({'id': request['id'], 'error': {'code': -32601, 'message': 'Fixture method not implemented'}})
            continue
        emit({'id': request['id'], 'result': result})
    """#
}

extension GatewayRuntime {
  fileprivate func listToolsAsyncForTest() async throws -> [MCPTool] {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(with: Result { try self.listTools() }) }
    }
  }
}
