import Darwin
import Foundation
import Testing

@testable import ComputerMCP

/// Actual gateway, actual independently built adapter, private SQLite and Git.
/// Only the vendor protocol is a fixture; no model request or user thread is used.
@Suite(
  .serialized, .timeLimit(.minutes(2)),
  .enabled(
    if: ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_CODEX_PLUGIN"] != nil))
struct CodexPluginBoundServicesTests {
  @Test(arguments: [false, true])
  func stoppedCoreStateMigratesWithoutAdoptingUnboundHistoryAcrossRestart(
    pendingApproval: Bool
  ) async throws {
    let historical = try CodexEmbeddedFixture.read("CodexEmbeddedState-\(pendingApproval)")
    let fixture = try BoundServicesFixture(
      git: true, prefix: "",
      workspaceID: try #require(historical.objectValue?["workspace_id"]?.stringValue))
    defer { fixture.remove() }
    let state = try CodexEmbeddedFixture.state(
      pendingApproval: pendingApproval, root: fixture.root,
      headOID: fixture.git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(
        in: .whitespacesAndNewlines))
    let run = try #require(state.objectValue?["run"])
    let plan = try #require(state.objectValue?["plan"])
    let runID = try #require(run.objectValue?["id"]?.stringValue)
    let planID = try #require(plan.objectValue?["id"]?.stringValue)
    let leaseID = try #require(state.objectValue?["lease_id"]?.stringValue)
    var current: GatewayRuntime?
    do {
      let source = fixture.root.appendingPathComponent("snapshot.sqlite")
      _ = try fixture.sqlite(source, try #require(state.objectValue?["sql"]?.stringValue))
      let original = try Data(contentsOf: source)
      let destination = fixture.root.appendingPathComponent("adapter-state/codex.sqlite")
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: false)
      let preview = try fixture.migrate(source: source, destination: destination)
      #expect(preview.objectValue?["can_apply"] == .bool(true))
      let digest = try #require(preview.objectValue?["plan_digest"]?.stringValue)
      let tables = try #require(preview.objectValue?["plan"]?.objectValue?["tables"]?.arrayValue)
      #expect(tables.count == 7)
      #expect(tables.allSatisfy { ($0.objectValue?["source_rows"]?.intValue ?? 0) > 0 })
      #expect(!FileManager.default.fileExists(atPath: destination.path))
      _ = try fixture.migrate(source: source, destination: destination, digest: digest)
      for table in tables {
        let name = try #require(table.objectValue?["name"]?.stringValue)
        let sourceColumns = try fixture.columns(source, table: name)
        let targetColumns = try fixture.columns(destination, table: name)
        #expect(Set(sourceColumns).isSubset(of: Set(targetColumns)))
        func quote(_ name: String) -> String {
          "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let projection = sourceColumns.map(quote).joined(separator: ",")
        let sql = "SELECT \(projection) FROM \(quote(name)) ORDER BY 1"
        #expect(try fixture.sqlite(source, sql) == fixture.sqlite(destination, sql))
        let addedColumns = targetColumns.filter { !sourceColumns.contains($0) }
        if !addedColumns.isEmpty {
          let filled = addedColumns.map { quote($0) + " IS NOT NULL" }.joined(separator: " OR ")
          #expect(
            try fixture.sqlite(destination, "SELECT count(*) FROM \(quote(name)) WHERE \(filled)")
              .trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        }
      }
      #expect(
        try fixture.sqlite(
          destination, "SELECT count(*) FROM sqlite_schema WHERE name = 'codexElevationGrants'"
        ).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
      let stable = try fixture.migrate(source: source, destination: destination)
      let stableDigest = try #require(stable.objectValue?["plan_digest"]?.stringValue)
      let repeated = try fixture.migrate(
        source: source, destination: destination, digest: stableDigest)
      #expect(repeated.objectValue?["inserted_rows"]?.intValue == 0)

      let migratedBytes = try Data(contentsOf: destination)
      for _ in 0..<2 {
        let runtime = try await fixture.migratedRuntime()
        current = runtime
        let diagnostics = try await fixture.call(runtime, "codex.diagnostics.snapshot")
        let storage = try #require(diagnostics.objectValue?["state_storage"]?.objectValue)
        #expect(storage["scope"] == .string("authorization_subject"))
        #expect(storage["unbound_history_available"] == .bool(true))
        #expect(storage["unbound_history_adopted"] == .bool(false))
        for (tool, arguments) in [
          ("codex.run.read", ["run_id": JSONValue.string(runID)]),
          ("codex.worktree.leases.read", ["lease_id": .string(leaseID)]),
          ("codex.worktree.managed.read", ["managed_worktree_id": .string(planID)]),
          ("codex.app.approvals.read", ["approval_id": .string("migration-approval")]),
        ] {
          await #expect(throws: (any Error).self) {
            try await fixture.call(runtime, tool, arguments)
          }
        }
        await #expect(throws: (any Error).self) {
          try await fixture.call(
            runtime, "codex.app.approvals.respond",
            [
              "approval_id": .string("migration-approval"),
              "response": .object(["decision": .string("accept")]),
            ])
        }
        await #expect(throws: (any Error).self) {
          try await fixture.call(
            runtime, "codex.worktree.provision.perform",
            [
              "plan_id": .string(planID), "expected_revision": plan.objectValue!["revision"]!,
              "confirm_provision": .bool(true),
            ])
        }
        let childID = try #require(plan.objectValue?["workspace_id"]?.stringValue)
        #expect(try fixture.database.derivedWorkspaceRegistration(id: childID) == nil)
        await runtime.shutdown()
        current = nil
      }
      #expect(try Data(contentsOf: source) == original)
      #expect(try Data(contentsOf: destination) == migratedBytes)
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent("vendor.pid").path))
      #expect(
        try fixture.sqlite(
          fixture.root.appendingPathComponent("host.sqlite"),
          "SELECT count(*) FROM codexThreadOwnership"
        ).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
      let changed = try fixture.migrate(source: source, destination: destination)
      #expect(changed.objectValue?["can_apply"] == .bool(true))
      #expect(changed.objectValue?["plan_digest"] == .string(stableDigest))
    } catch {
      await current?.shutdown()
      throw error
    }
  }

  @Test
  func packagedCatalogExposesCodingLifecyclesWithoutStartingVendor() async throws {
    let fixture = try BoundServicesFixture(allCapabilities: true)
    defer { fixture.remove() }
    let catalog = try await fixture.completeCatalog()
    let names = Set(catalog.map(\.name))
    #expect(names.count == catalog.count)
    #expect(
      names.isSuperset(of: [
        "codex.app.thread.start", "codex.app.thread.read", "codex.app.thread.release",
        "codex.app.turn.start", "codex.app.approvals.respond", "codex.app.events.read",
        "codex.exec.start", "codex.exec.result", "codex.exec.cancel",
        "codex.run.read", "codex.worktree.provision.perform", "codex.worktree.remove.perform",
      ]))
    for tool in catalog {
      #expect(tool.inputSchema.objectValue?["type"] == .string("object"))
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("vendor.pid").path))
  }

  @Test(arguments: ["adapter", ""])
  func diagnosticsReflectOnlyTheBoundHostAndDoNotStartVendor(prefix: String) async throws {
    let fixture = try BoundServicesFixture(prefix: prefix)
    defer { fixture.remove() }
    let runtime = try await fixture.runtime()
    do {
      for (workspace, profile, caller, connection, name) in [
        (
          fixture.workspace.id, GatewayProfileID.chatGPTOperate, GatewayCallerKind.secureTunnel,
          "services-origin", "visible.test"
        ),
        (
          fixture.workspace.id, .chatGPTOperate, .secureTunnel, "other-connection",
          "hidden.principal"
        ),
        (fixture.workspace.id, .localAdmin, .localCLI, "services-origin", "hidden.profile"),
        ("other-workspace", .chatGPTOperate, .secureTunnel, "services-origin", "hidden.workspace"),
      ] {
        try fixture.database.recordAudit(
          .init(
            requestID: UUID().uuidString,
            parentRequestID: "fixture-parent", caller: caller,
            principalDigest: AuditEvent.verifiedPrincipalDigest(
              name == "hidden.principal" ? "another-principal" : "bound-services-fixture"),
            transport: "gateway_socket", socketConnectionID: connection, profileID: profile,
            workspaceID: workspace, capabilityID: name, decision: .allowed,
            durationMilliseconds: 37, outputByteCount: 19, outputTruncated: false))
      }
      let result = try await fixture.call(
        runtime, "codex.diagnostics.snapshot", ["limit": .number(1)])
      let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
      #expect(text.contains("visible.test"))
      #expect(
        !text.contains("hidden.principal") && !text.contains("hidden.profile")
          && !text.contains("hidden.workspace"))
      #expect(result.objectValue?["host_diagnostics_available"] == .bool(true))
      let configuration = result.objectValue?["codex_configuration"]?.objectValue
      #expect(configuration?["sandbox_override"] == .string("workspace-write"))
      #expect(configuration?["unspecified_values"] == .string("inherited_from_codex"))
      let audit = try #require(
        result.objectValue?["recent_tool_audits"]?.arrayValue?.first?.objectValue)
      let occurredAt = try #require(audit["occurred_at"]?.stringValue)
      #expect(ISO8601DateFormatter().date(from: occurredAt) != nil)
      #expect(audit["parent_request_id"] == .string("fixture-parent"))
      #expect(audit["transport"] == .string("gateway_socket"))
      #expect(audit["socket_connection_id"] == .string("services-origin"))
      #expect(audit["duration_milliseconds"] == .number(37))
      #expect(audit["output_byte_count"] == .number(19))
      #expect(audit["output_truncated"] == .bool(false))
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent("vendor.pid").path))
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: [false, true], ["adapter", ""])
  func provisionGrantChildLeaseAndTicketedRemovalRoundTripWithoutVendor(
    retryHostFailure: Bool, prefix: String
  ) async throws {
    let fixture = try BoundServicesFixture(git: true, prefix: prefix)
    defer { fixture.remove() }
    let runtime = try await fixture.runtime()
    var childRuntime: GatewayRuntime?
    do {
      let parent = try await fixture.call(
        runtime, "codex.worktree.leases.acquire", ["agent_id": .string("parent-fixture")])
      let parentID = try #require(parent.objectValue?["id"]?.stringValue)
      let plan = try await fixture.call(
        runtime, "codex.worktree.provision.plan",
        [
          "parent_lease_id": .string(parentID), "agent_id": .string("child-fixture"),
          "branch": .string("fixture-child"), "start_point": .string("HEAD"),
        ])
      let id = try #require(plan.objectValue?["id"]?.stringValue)
      let planRevision = try #require(plan.objectValue?["revision"]?.intValue)
      let active = try await fixture.call(
        runtime, "codex.worktree.provision.perform",
        [
          "plan_id": .string(id), "expected_revision": .number(Double(planRevision)),
          "confirm_provision": .bool(true),
        ])
      let workspaceID = try #require(active.objectValue?["workspace_id"]?.stringValue)
      let path = try #require(active.objectValue?["path"]?.stringValue)
      let leaseID = try #require(active.objectValue?["lease_id"]?.stringValue)
      #expect(active.objectValue?["state"] == .string("active"))
      let child = try #require(try fixture.database.workspace(id: workspaceID))
      #expect(child.rootPath == path)
      #expect(path.hasPrefix(fixture.root.appendingPathComponent("Managed Worktrees").path + "/"))
      #expect(try fixture.database.derivedWorkspaceRegistration(id: workspaceID) != nil)
      #expect(try fixture.database.profiles().first?.workspaceIDs.contains(workspaceID) == true)
      await #expect(throws: (any Error).self) {
        _ = try await fixture.call(
          runtime, "codex.worktree.remove.plan", ["managed_worktree_id": .string(id)])
      }
      let childGateway = try await fixture.runtime(workspace: child)
      childRuntime = childGateway
      let lease = try await fixture.call(
        childGateway, "codex.worktree.leases.read", ["lease_id": .string(leaseID)],
        workspaceID: workspaceID)
      _ = try await fixture.call(
        childGateway, "codex.worktree.leases.release",
        [
          "lease_id": .string(leaseID), "expected_revision": lease.objectValue!["revision"]!,
          "reason": .string("Fixture completed"),
        ], workspaceID: workspaceID)
      await childGateway.shutdown()
      childRuntime = nil
      var removal = try await fixture.call(
        runtime, "codex.worktree.remove.plan", ["managed_worktree_id": .string(id)])
      var arguments: [String: JSONValue] = [
        "workspace_id": .string(fixture.workspace.id),
        "managed_worktree_id": .string(id), "expected_revision": removal.objectValue!["revision"]!,
        "confirm_remove": .bool(true),
      ]
      await #expect(throws: (any Error).self) {
        _ = try await fixture.call(runtime, "codex.worktree.remove.perform", arguments)
      }
      if retryHostFailure {
        try fixture.blockRegistrationRemoval(true)
        let preview = try await runtime.callToolAsync(
          name: "operations.prepare",
          arguments: .object([
            "workspace_id": .string(fixture.workspace.id),
            "tool": .string(fixture.exposed("codex.worktree.remove.perform")),
            "arguments": .object(arguments),
          ]))
        let firstTicket = try #require(
          preview.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?[
            "ticket_id"]?.stringValue)
        try fixture.database.resolveOperationApproval(
          id: firstTicket, approved: true, resolver: .localCLI)
        let failed = try await runtime.callToolAsync(
          name: "operations.commit",
          arguments: .object([
            "workspace_id": .string(fixture.workspace.id),
            "tool": .string(fixture.exposed("codex.worktree.remove.perform")),
            "arguments": .object(arguments), "ticket_id": .string(firstTicket),
          ]))
        #expect(failed.objectValue?["isError"] == .bool(true))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try fixture.database.workspace(id: workspaceID) != nil)
        #expect(try fixture.database.derivedWorkspaceRegistration(id: workspaceID) != nil)
        #expect(try fixture.database.profiles().first?.workspaceIDs.contains(workspaceID) == true)
        let unfinished = try await fixture.call(
          runtime, "codex.worktree.managed.read", ["managed_worktree_id": .string(id)])
        #expect(unfinished.objectValue?["state"] == .string("removing"))
        try fixture.blockRegistrationRemoval(false)
        removal = try await fixture.call(
          runtime, "codex.worktree.remove.plan", ["managed_worktree_id": .string(id)])
        arguments["expected_revision"] = removal.objectValue!["revision"]!
      }
      let prepared = try await runtime.callToolAsync(
        name: "operations.prepare",
        arguments: .object([
          "workspace_id": .string(fixture.workspace.id),
          "tool": .string(fixture.exposed("codex.worktree.remove.perform")),
          "arguments": .object(arguments),
        ]))
      let ticket = try #require(
        prepared.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?[
          "ticket_id"]?.stringValue)
      try fixture.database.resolveOperationApproval(id: ticket, approved: true, resolver: .localCLI)
      let removed = try await runtime.callToolAsync(
        name: "operations.commit",
        arguments: .object([
          "workspace_id": .string(fixture.workspace.id),
          "tool": .string(fixture.exposed("codex.worktree.remove.perform")),
          "arguments": .object(arguments), "ticket_id": .string(ticket),
        ]))
      #expect(removed.objectValue?["isError"] != .bool(true))
      #expect(!FileManager.default.fileExists(atPath: path))
      #expect(try fixture.database.workspace(id: workspaceID) == nil)
      #expect(try fixture.database.derivedWorkspaceRegistration(id: workspaceID) == nil)
      #expect(try fixture.database.profiles().first?.workspaceIDs.contains(workspaceID) == false)
      #expect(try fixture.database.operationTicket(id: ticket)?.state == .succeeded)
      let reopened = try GatewayDatabase(
        path: fixture.root.appendingPathComponent("host.sqlite").path)
      #expect(try reopened.workspace(id: workspaceID) == nil)
      #expect(try reopened.derivedWorkspaceRegistration(id: workspaceID) == nil)
      _ = try fixture.git(["show-ref", "--verify", "refs/heads/fixture-child"])
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent("vendor.pid").path))
      await runtime.shutdown()
    } catch {
      await childRuntime?.shutdown()
      await runtime.shutdown()
      throw error
    }
  }
}

final class BoundServicesFixture: Sendable {
  let root: URL
  let workspace: RegisteredWorkspace
  let database: GatewayDatabase
  private let executable: String
  private let config: URL
  private let prefix: String
  init(
    git: Bool = false, prefix: String = "adapter", allCapabilities: Bool = false,
    workspaceID: String? = nil, requestTimeoutSeconds: Int = 10
  ) throws {
    self.prefix = prefix
    executable = try #require(ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_CODEX_PLUGIN"])
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bound-services-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    root = temporary.resolvingSymlinksInPath()
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try "source-fixture".write(
      to: source.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    workspace = .init(
      id: workspaceID ?? UUID().uuidString, displayName: "Bound services fixture",
      rootPath: source.path)
    database = try GatewayDatabase(path: root.appendingPathComponent("host.sqlite").path)
    try database.saveWorkspace(workspace)
    try database.saveProfile(
      .init(
        id: .chatGPTOperate,
        capabilityIDs: [
          "mcp.tools.call", "operations.prepare", "operations.commit", "policy.probe",
        ],
        workspaceIDs: [workspace.id], allowedCallers: [.secureTunnel], mode: .workspaceOperations))
    let vendor = root.appendingPathComponent("vendor-fixture")
    try Self.vendor.write(to: vendor, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vendor.path)
    config = root.appendingPathComponent("adapter.json")
    try JSONEncoder().encode(
      JSONValue.object([
        "enabled": .bool(true), "executable": .string(vendor.path),
        "app_server_enabled": .bool(true),
        "exec_enabled": .bool(allCapabilities),
        "sandbox": .string("workspace-write"),
        "app_server_request_timeout_seconds": .number(Double(requestTimeoutSeconds)),
      ])
    ).write(to: config)
    if git {
      _ = try self.git(["init", "--quiet"])
      _ = try self.git(["add", "source.txt"])
      _ = try self.git([
        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet",
        "-m", "Fixture root",
      ])
    }
  }

  func completeCatalog() async throws -> [MCPTool] {
    let client = MCPProxyClient(workingDirectory: URL(fileURLWithPath: workspace.rootPath))
    let server = MCPServerConfig(
      id: "parity", transport: .stdio, command: executable,
      args: [
        "--config", config.path, "--state-directory",
        root.appendingPathComponent("adapter-state").path,
      ], allowAnyTool: true)
    do {
      let result: [MCPTool] = try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(with: Result { try client.listTools(server: server) })
        }
      }
      await client.shutdown()
      return result
    } catch {
      await client.shutdown()
      throw error
    }
  }

  func runtime(workspace override: RegisteredWorkspace? = nil) async throws -> GatewayRuntime {
    let selected = override ?? workspace
    return try await GatewayRuntime.make(
      configuration: configuration(workspaces: [selected]),
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate,
        transportTrace: .init(transport: "gateway_socket", socketConnectionID: "services-origin"),
        trustedPrincipalID: "bound-services-fixture"),
      database: database, registeredWorkspaces: [selected])
  }

  func configuration(workspaces: [RegisteredWorkspace]) -> GatewayConfiguration {
    let names: [String: CapabilityRisk] = [
      "codex.app.status": .readOnly, "codex.app.thread.loaded.list": .readOnly,
      "codex.diagnostics.snapshot": .readOnly, "codex.app.thread.start": .workspaceWrite,
      "codex.app.turn.start": .workspaceWrite, "codex.app.turn.interrupt": .externalWrite,
      "codex.worktree.leases.acquire": .workspaceWrite, "codex.worktree.leases.read": .readOnly,
      "codex.worktree.leases.release": .workspaceWrite,
      "codex.worktree.provision.plan": .workspaceWrite,
      "codex.worktree.provision.perform": .workspaceWrite,
      "codex.worktree.remove.plan": .workspaceWrite,
      "codex.worktree.remove.perform": .destructive, "codex.worktree.managed.read": .readOnly,
      "codex.run.read": .readOnly, "codex.app.thread.reclaim": .workspaceWrite,
      "codex.app.thread.release": .workspaceWrite,
      "codex.app.approvals.read": .readOnly, "codex.app.approvals.respond": .workspaceWrite,
    ]
    let capabilities = [
      "mcp.tools.call", "operations.prepare", "operations.commit", "policy.probe",
    ]
    return GatewayConfiguration(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
      profiles: [
        .init(
          id: .chatGPTOperate, capabilities: capabilities, workspaces: workspaces.map(\.id),
          allowedCallers: [.secureTunnel], mode: .workspaceOperations)
      ],
      mcp: .init(servers: [
        .init(
          id: "bound-plugin", transport: .stdio, command: executable,
          args: [
            "--config", config.path, "--state-directory",
            root.appendingPathComponent("adapter-state").path,
          ],
          exposure: .reexport, prefix: prefix, allowedTools: names.keys.sorted(),
          startupTimeoutMs: 10_000,
          requestTimeoutMs: 15_000, toolRisks: names, hostServices: true)
      ]))

  }

  func migratedRuntime() async throws -> GatewayRuntime {
    let adapterConfiguration = try JSONDecoder().decode(
      CodexConfigurationImport.self, from: Data(contentsOf: config))
    let original = GatewayConfiguration(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
      profiles: [
        .init(
          id: .chatGPTOperate,
          capabilities: [
            "mcp.tools.call", "operations.prepare", "operations.commit", "policy.probe",
          ],
          workspaces: [workspace.id], allowedCallers: [.secureTunnel], mode: .workspaceOperations)
      ], codex: adapterConfiguration, workspaceDirectory: root)
    let migration = try CodexConfigurationMigration(
      text: original.exportedTOML(), baseURL: root, adapterConfigurationPath: config.path,
      stateDirectory: root.appendingPathComponent("adapter-state").path)
    try JSONEncoder().encode(migration.adapterConfiguration).write(to: config)
    let host = try GatewayConfiguration.load(text: migration.hostTOML, baseURL: root)
    #expect(host.codex == nil)
    #expect(host.profiles == original.profiles)
    let package = try PluginPackage.load(
      at: URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent())
    let resolved = try PluginResolver.resolve(
      package: package, source: .init(kind: .artifact, root: package.root),
      settings: migration.pluginSettings, hostVersion: PluginVersion(ComputerMCPCLI.version),
      architecture: PluginHost.architecture)
    #expect(resolved.diagnostics.isEmpty)
    #expect(resolved.mcpServers.count == 1)
    let composition = try GatewayPluginComposition(configuration: host, plugins: [resolved])
    return try await GatewayRuntime.make(
      configuration: composition.runtimeConfiguration,
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate,
        transportTrace: .init(transport: "gateway_socket", socketConnectionID: "services-origin"),
        trustedPrincipalID: "bound-services-fixture"),
      database: database, registeredWorkspaces: [workspace])
  }
  func exposed(_ name: String) -> String { prefix.isEmpty ? name : prefix + "." + name }

  func sqlite(_ file: URL, _ sql: String) throws -> String {
    try command("/usr/bin/sqlite3", ["-batch", "-quote", file.path, sql]).stdout
  }

  func columns(_ file: URL, table: String) throws -> [String] {
    let sql = "PRAGMA table_info(\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\")"
    let output = try command("/usr/bin/sqlite3", ["-batch", "-json", file.path, sql]).stdout
    let rows = try #require(
      JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)).arrayValue)
    return try rows.map { try #require($0.objectValue?["name"]?.stringValue) }
  }

  func migrate(source: URL, destination: URL, digest: String? = nil) throws -> JSONValue {
    var args = [
      "migrate-state", "--source-snapshot", source.path, "--destination", destination.path,
    ]
    if let digest { args += ["--apply", "--expected-plan-digest", digest] }
    let result = try command(executable, args)
    return try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
  }

  private func command(_ executable: String, _ args: [String]) throws -> CommandResult {
    let result = try ProcessCommandRunner().run(
      executable: executable, arguments: args, workingDirectory: root, environment: [:],
      timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576)
    guard result.exitCode == 0, !result.timedOut, !result.stdoutTruncated, !result.stderrTruncated
    else {
      throw GatewayToolError.executionFailed("Fixture command failed: " + result.stderr)
    }
    return result
  }

  func call(
    _ runtime: GatewayRuntime, _ name: String, _ arguments: [String: JSONValue] = [:],
    workspaceID: String? = nil
  ) async throws -> JSONValue {
    var args = arguments
    args["workspace_id"] = .string(workspaceID ?? workspace.id)
    let result = try await runtime.callToolAsync(name: exposed(name), arguments: .object(args))
    guard result.objectValue?["isError"] != .bool(true),
      let value = result.objectValue?["structuredContent"]?.objectValue?["result"]
    else {
      throw GatewayToolError.executionFailed(
        String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }
    return value
  }
  func requireVendorExit() async throws {
    let text = try String(contentsOf: root.appendingPathComponent("vendor.pid"), encoding: .utf8)
    let pid = try #require(Int32(text))
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if kill(pid, 0) != 0 && errno == ESRCH { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Owned protocol fixture remained after gateway shutdown.")
  }
  func git(_ args: [String]) throws -> CommandResult {
    let result = try ProcessCommandRunner().run(
      executable: "/usr/bin/git", arguments: args,
      workingDirectory: URL(fileURLWithPath: workspace.rootPath),
      environment: ["GIT_TERMINAL_PROMPT": "0"], timeoutMilliseconds: 5_000, maxOutputBytes: 16_384)
    guard result.exitCode == 0 else { throw GatewayToolError.executionFailed(result.stderr) }
    return result
  }
  func blockRegistrationRemoval(_ enabled: Bool) throws {
    let sql =
      enabled
      ? "CREATE TRIGGER fixture_block_unregister BEFORE DELETE ON pluginDerivedWorkspaces BEGIN SELECT RAISE(ABORT,'fixture unregister blocked'); END"
      : "DROP TRIGGER fixture_block_unregister"
    let result = try ProcessCommandRunner().run(
      executable: "/usr/bin/sqlite3",
      arguments: [root.appendingPathComponent("host.sqlite").path, sql], workingDirectory: root,
      environment: [:], timeoutMilliseconds: 5_000, maxOutputBytes: 16_384)
    guard result.exitCode == 0 else {
      throw GatewayToolError.executionFailed(
        "Private fixture fault injection failed: " + result.stderr)
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  private static let vendor = #"""
    #!/usr/bin/python3
    import hashlib, json, os, pathlib, sys
    root = pathlib.Path(__file__).resolve().parent
    cwd = os.getcwd()
    (root/'vendor.pid').write_text(str(os.getpid()))
    thread = {'id':'thread_bound','cwd':cwd,'cliVersion':'fixture','createdAt':1,'updatedAt':1,'ephemeral':False,
              'modelProvider':'fixture','preview':'','sessionId':'fixture-session','source':'appServer','status':{'type':'idle'},'turns':[]}
    if (root/'workspace-thread-ids').exists():
        thread['id'] = 'thread_' + hashlib.sha256(cwd.encode()).hexdigest()[:16]
    count = 0
    loaded = False
    for line in sys.stdin:
        request = json.loads(line)
        with (root/'vendor.jsonl').open('a') as log: log.write(json.dumps(request)+'\n')
        method = request.get('method')
        if method == 'initialize': result = {'codexHome':str(root),'platformFamily':'unix','platformOs':'macos','userAgent':'isolated-fixture'}
        elif method == 'initialized': continue
        elif method in ('thread/start', 'thread/resume'):
            loaded = True
            result = {'thread':thread,'cwd':cwd,'model':'fixture','modelProvider':'fixture','approvalPolicy':'on-request',
                      'approvalsReviewer':'user','sandbox':{'type':'dangerFullAccess' if request['params'].get('sandbox')=='danger-full-access' else 'workspaceWrite'}}
        elif method == 'turn/start':
            count += 1
            result = {'turn':{'id':'turn_'+str(count),'items':[],'status':'inProgress' if count==1 and (root/'active-turn').exists() else 'completed'}}
        elif method == 'thread/read': result = {'thread':thread}
        elif method == 'thread/loaded/list': result = {'data':[thread['id']] if loaded else [],'nextCursor':None}
        elif method == 'thread/unsubscribe':
            loaded = False
            result = {'status':'unsubscribed'}
        elif method == 'turn/interrupt': result = {}
        elif 'id' not in request: continue
        else:
            print(json.dumps({'id':request['id'],'error':{'code':-32601,'message':'fixture method unavailable'}}),flush=True)
            continue
        print(json.dumps({'id':request['id'],'result':result}),flush=True)
    """#
}
