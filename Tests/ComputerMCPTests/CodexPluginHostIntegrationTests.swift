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
    "read", "cross-workspace", "recursive", "observe-write", "no-delegation", "elevated-denied",
  ])
  func independentlyBuiltPluginUsesOnlyItsDelegatedHostScope(mode: String) async throws {
    let fixture = try await PluginHostFixture(mode: mode)
    defer { fixture.remove() }
    do {
      var elevationID: String?
      if mode == "elevated-denied" {
        let request = try CodexElevationGrantService.request(
          owner: .init(
            workspaceID: "fixture", profileID: "chatgpt-operate",
            caller: "secure-tunnel", transport: "gateway_socket",
            socketConnectionID: "fixture-origin",
            tunnelInstanceID: nil, tunnelProfileID: nil), database: fixture.database,
          threadID: "fixture-thread", mode: .threadScopedTTL,
          reason: "Verify independent capability policy",
          maximumDurationSeconds: 300, maximumTurnCount: nil)
        let approved = try CodexElevationGrantService.approve(
          id: request.id,
          owner: .init(
            workspaceID: "fixture", profileID: "local-admin", caller: "local-cli",
            transport: "fixture", socketConnectionID: nil, tunnelInstanceID: nil,
            tunnelProfileID: nil),
          database: fixture.database)
        elevationID = approved.id
      }
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
      if let elevationID {
        #expect(try fixture.database.codexElevationGrant(id: elevationID)?.state == .approved)
      }
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
      #expect(response.objectValue?["result"]?.objectValue?["success"] == .bool(true))
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
  @Test(arguments: ["approve_once", "deny", "revoke-before-approval"])
  func writesNeedLiveApprovalAndHostTickets(decision: String) async throws {
    let fixture = try await PluginHostFixture(mode: "write")
    defer { fixture.remove() }
    do {
      _ = try await fixture.runtime.callToolAsync(
        name: "adapter.codex.app.thread.loaded.list",
        arguments: .object(["workspace_id": .string("fixture")]))
      let approval = try await fixture.pendingApproval()
      #expect(approval["risk"] == .string("destructive"))
      #expect(
        try String(contentsOf: fixture.root.appendingPathComponent("value.txt"), encoding: .utf8)
          == "owned-fixture-value")
      #expect(
        try !fixture.database.auditEvents().contains { $0.capabilityID == "operations.commit" })
      let approvalID = try #require(approval["id"]?.stringValue)
      if decision == "revoke-before-approval" {
        var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
        grant.workspaceIDs.removeAll()
        try fixture.database.saveProfile(grant)
      }
      _ = try await fixture.runtime.callToolAsync(
        name: "adapter.codex.app.approvals.respond",
        arguments: .object([
          "workspace_id": .string("fixture"), "approval_id": .string(approvalID),
          "decision": .string(decision == "deny" ? "deny" : "approve_once"),
        ]))
      let response = try await fixture.callbackResponse()
      #expect(
        response.objectValue?["result"]?.objectValue?["success"]
          == .bool(decision == "approve_once"))
      let value = try String(
        contentsOf: fixture.root.appendingPathComponent("value.txt"), encoding: .utf8)
      #expect(
        value == (decision == "approve_once" ? "changed-fixture-value" : "owned-fixture-value"))
      let audits = try fixture.database.auditEvents()
      if decision == "approve_once" {
        let target = try #require(
          audits.first { $0.capabilityID == "file.replace_text" && $0.decision == .allowed })
        let ticketID = try #require(target.ticketID)
        let ticket = try #require(try fixture.database.operationTicket(id: ticketID))
        #expect(ticket.state == .succeeded)
        #expect(target.invocationID == ticket.invocationID)
        #expect(target.parentRequestID == ticket.parentRequestID)
        #expect(
          audits.contains { $0.capabilityID == "operations.prepare" && $0.ticketID == ticketID })
        #expect(
          audits.contains { $0.capabilityID == "operations.commit" && $0.ticketID == ticketID })
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
  func governedGitWorkflowCreatesAHookedCommitAndCleanWorktree() async throws {
    let fixture = try await PluginHostFixture(mode: "governed-git")
    defer { fixture.remove() }
    do {
      _ = try await fixture.runtime.callToolAsync(
        name: "adapter.codex.app.thread.loaded.list",
        arguments: .object(["workspace_id": .string("fixture")]))
      for (index, capability) in ["file.write", "git.add", "git.commit"].enumerated() {
        let approval = try await fixture.pendingApproval()
        let approvalID = try #require(approval["id"]?.stringValue)
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
        _ = try await fixture.runtime.callToolAsync(
          name: "adapter.codex.app.approvals.respond",
          arguments: .object([
            "workspace_id": .string("fixture"), "approval_id": .string(approvalID),
            "decision": .string("approve_once"),
          ]))
        let response = try await fixture.callbackResponse(id: 900 + index)
        try #require(response.objectValue?["result"]?.objectValue?["success"] == .bool(true))
        let audits = try fixture.database.auditEvents()
        let target = try #require(
          audits.first { $0.capabilityID == capability && $0.decision == .allowed })
        #expect(target.workspaceID == "fixture")
        #expect(target.caller == .secureTunnel)
        #expect(target.socketConnectionID == "fixture-origin")
        if capability != "git.commit" {
          let ticketID = try #require(target.ticketID)
          #expect(try fixture.database.operationTicket(id: ticketID)?.state == .succeeded)
          #expect(
            audits.contains { $0.capabilityID == "operations.commit" && $0.ticketID == ticketID })
        }
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
          "namespace": .string("computer-mcp"), "tool": .string(target),
          "arguments": .object(arguments),
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
        "mcp_enabled": .bool(false),
        "app_server_request_timeout_seconds": .number(8),
        "app_server_approval_timeout_seconds": .number(8),
      ])
    ).write(to: config)
    database = try GatewayDatabase(inMemory: ())
    let workspace = RegisteredWorkspace(id: "fixture", displayName: "Fixture", rootPath: root.path)
    try database.saveWorkspace(workspace)
    let profile: GatewayProfileID = mode == "observe-write" ? .chatGPTObserve : .chatGPTOperate
    var capabilities = [
      "workspace.list", "workspace.describe", "policy.probe", "file.read", "file.replace_text",
      "mcp.tools.call", "operations.prepare", "operations.commit",
    ]
    if mode == "elevated-denied" { capabilities.removeAll { $0 == "file.read" } }
    if mode == "dry-run" { capabilities.append("git.add") }
    if mode == "governed-git" { capabilities += ["file.write", "git.add", "git.commit"] }
    try database.saveProfile(
      .init(
        id: profile, capabilityIDs: Set(capabilities), workspaceIDs: ["fixture"],
        allowedCallers: [.secureTunnel]))
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
            allowedCallers: [.secureTunnel])
        ],
        cli: .init(commands: [.init(id: "git", executable: "/usr/bin/git")]),
        mcp: .init(servers: [server]),
        builtin: .init(enabled: [
          "file.read", "file.replace_text", "file.write", "git.add", "git.commit",
        ])),
      context: .init(
        caller: .secureTunnel, profileID: profile,
        transportTrace: .init(transport: "gateway_socket", socketConnectionID: "fixture-origin")),
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
      let steps: [(String, JSONValue)] = [
        (
          "file.write",
          .object(["path": .string("product.txt"), "content": .string("production-ready\n")])
        ),
        ("git.add", .object(["paths": .array([.string("product.txt")])])),
        ("git.commit", .object(["message": .string("Verify governed plugin Git")])),
      ]
      let requests = steps.enumerated().map { index, step in
        JSONValue.object([
          "id": .number(Double(900 + index)), "method": .string("item/tool/call"),
          "params": .object([
            "namespace": .string("computer-mcp"), "tool": .string(step.0),
            "arguments": step.1, "callId": .string("governed-\(index)"),
            "threadId": .string("fixture-thread"), "turnId": .string("fixture-turn"),
          ]),
        ])
      }
      try JSONEncoder().encode(requests).write(
        to: root.appendingPathComponent("callback-sequence.json"))
    }
  }

  func git(_ arguments: [String]) throws -> CommandResult {
    let result = try ProcessCommandRunner().run(
      executable: "/usr/bin/git", arguments: arguments,
      workingDirectory: root, environment: [:], timeoutMilliseconds: 5_000, maxOutputBytes: 16_384)
    try #require(result.exitCode == 0, "\(result.stderr)")
    return result
  }

  func pendingApproval() async throws -> [String: JSONValue] {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      let result = try await runtime.callToolAsync(
        name: "adapter.codex.app.approvals.list",
        arguments: .object([
          "workspace_id": .string("fixture"), "state": .string("pending"), "limit": .number(10),
        ]))
      if let approval = result.objectValue?["structuredContent"]?.objectValue?["result"]?
        .objectValue?["approvals"]?.arrayValue?.first?.objectValue
      {
        return approval
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw GatewayToolError.executionFailed(
      "The isolated dynamic write did not produce a pending approval.")
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
    import json, os, pathlib, stat, sys
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
    sequence_file = root / 'callback-sequence.json'
    callbacks = json.loads(sequence_file.read_text()) if sequence_file.exists() else [json.loads((root/'callback-request.json').read_text())]
    callback_index = 0
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get('method')
        if method == 'initialize':
            result = {'codexHome': str(root), 'platformFamily': 'unix', 'platformOs': 'macos', 'userAgent': 'isolated-protocol-fixture'}
        elif method == 'initialized':
            print(json.dumps(callbacks[callback_index]), flush=True)
            continue
        elif method == 'thread/loaded/list':
            result = {'data': [], 'nextCursor': None}
        elif method is None and callback_index < len(callbacks) and request.get('id') == callbacks[callback_index]['id']:
            save('callback.json', request)
            save('callback-' + str(request['id']) + '.json', request)
            callback_index += 1
            if callback_index < len(callbacks):
                print(json.dumps(callbacks[callback_index]), flush=True)
            continue
        elif method == 'thread/unsubscribe':
            result = {'status': 'unsubscribed'}
        elif 'id' not in request:
            continue
        else:
            print(json.dumps({'id': request['id'], 'error': {'code': -32601, 'message': 'Fixture method not implemented'}}), flush=True)
            continue
        print(json.dumps({'id': request['id'], 'result': result}), flush=True)
    """#
}

extension GatewayRuntime {
  fileprivate func listToolsAsyncForTest() async throws -> [MCPTool] {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(with: Result { try self.listTools() }) }
    }
  }
}
