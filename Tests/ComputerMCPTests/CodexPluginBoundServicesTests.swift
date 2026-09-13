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
  func stoppedCoreStateMigratesAndContinuesThroughThePluginAcrossRestart(
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
      let hostGrant = try fixture.requestGrant(threadID: nil)
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
        // Names originate from the adapter's validated fixed domain-table report.
        let sql =
          "SELECT * FROM \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\" ORDER BY 1"
        #expect(try fixture.sqlite(source, sql) == fixture.sqlite(destination, sql))
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

      for generation in 0..<2 {
        let runtime = try await fixture.migratedRuntime()
        current = runtime
        #expect(
          try await fixture.call(runtime, "codex.run.read", ["run_id": .string(runID)]) == run)
        let loadedLease = try await fixture.call(
          runtime, "codex.worktree.leases.read", ["lease_id": .string(leaseID)])
        #expect(loadedLease.objectValue?["id"] == .string(leaseID))
        let loadedPlan = try await fixture.call(
          runtime, "codex.worktree.managed.read", ["managed_worktree_id": .string(planID)])
        #expect(loadedPlan == plan)
        let approval = try await fixture.call(
          runtime, "codex.app.approvals.read", ["approval_id": .string("migration-approval")])
        #expect(approval.objectValue?["approval"]?.objectValue?["state"] == .string("interrupted"))
        await #expect(throws: (any Error).self) {
          try await fixture.call(
            runtime, "codex.app.approvals.respond",
            [
              "approval_id": .string("migration-approval"), "decision": .string("approve_once"),
            ])
        }
        _ = try await fixture.call(
          runtime, "codex.app.thread.reclaim", ["thread_id": .string("thread_bound")])
        _ = try await fixture.call(
          runtime, "codex.app.turn.start",
          [
            "thread_id": .string("thread_bound"),
            "prompt": .string("Fixture continuation \(generation)"),
            "worktree_lease_id": .string(leaseID),
          ])
        _ = try await fixture.call(
          runtime, "codex.app.thread.release", ["thread_id": .string("thread_bound")])
        if generation == 1 {
          let provisioned = try await fixture.call(
            runtime, "codex.worktree.provision.perform",
            [
              "plan_id": .string(planID), "expected_revision": plan.objectValue!["revision"]!,
              "confirm_provision": .bool(true),
            ])
          #expect(provisioned.objectValue?["state"] == .string("active"))
          let childID = try #require(provisioned.objectValue?["workspace_id"]?.stringValue)
          #expect(try fixture.database.derivedWorkspaceRegistration(id: childID) != nil)
        }
        await runtime.shutdown()
        current = nil
        try await fixture.requireVendorExit()
      }
      #expect(try Data(contentsOf: source) == original)
      #expect(
        try fixture.sqlite(
          fixture.root.appendingPathComponent("host.sqlite"),
          "SELECT count(*) FROM codexThreadOwnership"
        ).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
      #expect(try fixture.database.codexElevationGrant(id: hostGrant.id)?.state == .invalidated)
      let changed = try fixture.migrate(source: source, destination: destination)
      #expect(changed.objectValue?["can_apply"] == .bool(false))
      let beforeRejectedImport = try Data(contentsOf: destination)
      #expect(throws: (any Error).self) {
        try fixture.migrate(source: source, destination: destination, digest: digest)
      }
      #expect(try Data(contentsOf: destination) == beforeRejectedImport)
    } catch {
      await current?.shutdown()
      throw error
    }
  }

  @Test
  func packagedCatalogMatchesTheDomainAndLeavesApprovalsWithTheHost() async throws {
    let fixture = try BoundServicesFixture(allCapabilities: true)
    defer { fixture.remove() }
    do {
      let entries = try CodexEmbeddedFixture.catalog()
      let prior = Dictionary(
        uniqueKeysWithValues: try entries.map { entry in
          let tool = try #require(entry.objectValue?["tool"])
          return (try #require(tool.objectValue?["name"]?.stringValue), tool)
        })
      let current = Dictionary(
        uniqueKeysWithValues: try await fixture.completeCatalog().map { ($0.name, $0.json) })
      let hostApprovalNames = Set(
        ["request", "list", "read", "approve", "deny", "revoke", "effective"].map {
          "codex.app.elevation." + $0
        })
      let hostTools = try CodexElevationTools(
        owner: nil, database: nil
      ).listTools()
      #expect(Set(hostTools.map(\.name)) == hostApprovalNames)
      #expect(Set(current.keys).isDisjoint(with: hostApprovalNames))
      #expect(Set(prior.keys).subtracting(current.keys).isEmpty)
      #expect(
        Set(current.keys).subtracting(prior.keys).allSatisfy { $0.hasPrefix("codex.protocol.") })
      var changed: [String: [String]] = [:]
      for name in Set(prior.keys).intersection(current.keys).sorted() {
        let old = prior[name]!
        let new = current[name]!
        var fields: [String] = []
        if old.objectValue?["inputSchema"] != new.objectValue?["inputSchema"] {
          fields.append("inputSchema")
        }
        if old.objectValue?["outputSchema"] != new.objectValue?["outputSchema"] {
          fields.append("outputSchema")
        }
        if old.objectValue?["annotations"] != new.objectValue?["annotations"] {
          fields.append("annotations")
        }
        if !fields.isEmpty { changed[name] = fields }
      }
      print(
        "Codex catalog parity: core=\(prior.count), plugin=\(current.count), hostApproval=\(hostApprovalNames.count), changed=\(changed)"
      )
      #expect(changed.isEmpty)
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent("vendor.pid").path))
    } catch {
      throw error
    }
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
          "hidden.connection"
        ),
        (fixture.workspace.id, .localAdmin, .localCLI, "services-origin", "hidden.profile"),
        ("other-workspace", .chatGPTOperate, .secureTunnel, "services-origin", "hidden.workspace"),
      ] {
        try fixture.database.recordAudit(
          .init(
            requestID: UUID().uuidString,
            parentRequestID: "fixture-parent", caller: caller,
            transport: "gateway_socket", socketConnectionID: connection, profileID: profile,
            workspaceID: workspace, capabilityID: name, decision: .allowed,
            durationMilliseconds: 37, outputByteCount: 19, outputTruncated: false))
      }
      let own = try fixture.requestGrant(threadID: nil)
      _ = try fixture.approve(own.id)
      let other = try fixture.requestGrant(threadID: nil, connection: "other-connection")
      let result = try await fixture.call(
        runtime, "codex.diagnostics.snapshot", ["limit": .number(1)])
      let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
      #expect(text.contains("visible.test"))
      #expect(
        !text.contains("hidden.connection") && !text.contains("hidden.profile")
          && !text.contains("hidden.workspace"))
      #expect(text.contains(own.id) && !text.contains(other.id))
      #expect(result.objectValue?["host_diagnostics_available"] == .bool(true))
      let elevation = result.objectValue?["elevation"]?.objectValue
      #expect(elevation?["configured_default_sandbox"] == .string("workspace-write"))
      #expect(elevation?["requested_sandbox"] == .string("danger-full-access"))
      #expect(elevation?["effective_next_eligible_start"] == .string("danger-full-access"))
      #expect(elevation?["active_turn_unchanged"] == .bool(true))
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

  @Test(arguments: [
    "approved", "pending", "revoked", "expires-before-commit", "revoked-before-commit",
  ])
  func nativeActivationUsesOnlyAnExistingLocallyApprovedLiveGrant(state: String) async throws {
    let fixture = try BoundServicesFixture()
    defer { fixture.remove() }
    let runtime = try await fixture.runtime()
    do {
      let grant = try fixture.requestGrant(threadID: nil)
      if state != "pending" { _ = try fixture.approve(grant.id) }
      if state == "revoked" { try fixture.revoke(grant.id) }
      let needsPause = state.hasSuffix("before-commit")
      if needsPause { try Data().write(to: fixture.root.appendingPathComponent("pause-start")) }
      let call = Task { try await fixture.call(runtime, "codex.app.thread.start") }
      if needsPause {
        try await fixture.waitForFile("start-received")
        let held = try #require(try fixture.database.codexElevationGrant(id: grant.id))
        #expect(held.inFlightClaimID != nil)
        if state == "expires-before-commit" {
          _ = try fixture.database.updateCodexElevationGrant(id: grant.id) { value in
            value.expiresAt = Date().addingTimeInterval(-1)
          }
        } else {
          try fixture.revoke(grant.id)
        }
        try Data().write(to: fixture.root.appendingPathComponent("release-start"))
      }
      let response = await call.result
      if needsPause {
        if case .success = response {
          Issue.record("A no-longer-effective elevation was accepted.")
        }
        try await fixture.requireVendorExit()
      } else {
        let value = try response.get()
        #expect(value.objectValue?["thread"]?.objectValue?["id"] == .string("thread_bound"))
      }
      let requests = try fixture.vendorRequests()
      let start = try #require(
        requests.first { $0.objectValue?["method"] == .string("thread/start") })
      #expect(
        start.objectValue?["params"]?.objectValue?["sandbox"]
          == .string(state == "approved" || needsPause ? "danger-full-access" : "workspace-write"))
      let stored = try #require(try fixture.database.codexElevationGrant(id: grant.id))
      if state == "approved" {
        #expect(stored.state == .active)
        #expect(stored.threadID == "thread_bound")
        #expect(stored.inFlightClaimID == nil)
        #expect(!stored.consumedRuntimeIDs.isEmpty)
      } else if state == "pending" {
        #expect(stored.state == .pending)
      } else {
        #expect(!stored.state.isEffective)
      }
      await runtime.shutdown()
      if state == "approved" {
        #expect(try fixture.database.codexElevationGrant(id: grant.id)?.state == .invalidated)
      }
      try await fixture.requireVendorExit()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func nativeNamesRetainHostActivationAndAuditWithoutAnExtraProviderLayer() async throws {
    let fixture = try BoundServicesFixture(prefix: "")
    defer { fixture.remove() }
    let runtime = try await fixture.runtime()
    do {
      let capability = try runtime.capabilityDescriptor(named: "codex.app.thread.start")
      #expect(
        capability.mcpReference
          == .init(serverID: "bound-plugin", toolName: "codex.app.thread.start"))
      let grant = try fixture.requestGrant(threadID: nil)
      _ = try fixture.approve(grant.id)
      let result = try await fixture.call(runtime, "codex.app.thread.start")
      #expect(result.objectValue?["thread"]?.objectValue?["id"] == .string("thread_bound"))
      #expect(try fixture.database.codexElevationGrant(id: grant.id)?.state == .active)
      #expect(
        try fixture.database.auditEvents().contains {
          $0.capabilityID == "codex.app.thread.start" && $0.decision == .allowed
        })
      await runtime.shutdown()
      #expect(try fixture.database.codexElevationGrant(id: grant.id)?.state == .invalidated)
      try await fixture.requireVendorExit()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func threadReleaseInvalidatesItsHostGrantThroughThePlugin() async throws {
    let fixture = try BoundServicesFixture(prefix: "")
    defer { fixture.remove() }
    let runtime = try await fixture.runtime()
    do {
      _ = try await fixture.call(runtime, "codex.app.thread.start")
      let grant = try fixture.requestGrant(threadID: "thread_bound", mode: .threadScopedTTL)
      _ = try fixture.approve(grant.id)
      _ = try await fixture.call(
        runtime, "codex.app.thread.release", ["thread_id": .string("thread_bound")])
      #expect(try fixture.database.codexElevationGrant(id: grant.id)?.state == .invalidated)
      await runtime.shutdown()
      try await fixture.requireVendorExit()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: ["thread-start", "first-turn", "later-turn"])
  func nextTurnClaimIsConsumedOnceAndLaterSafeTurnsDoNotReclaimIt(activation: String) async throws {
    let fixture = try BoundServicesFixture()
    defer { fixture.remove() }
    let runtime = try await fixture.runtime()
    do {
      if activation != "thread-start" {
        _ = try await fixture.call(runtime, "codex.app.thread.start")
      }
      if activation == "later-turn" {
        try Data().write(to: fixture.root.appendingPathComponent("active-turn"))
        _ = try await fixture.call(
          runtime, "codex.app.turn.start",
          [
            "thread_id": .string("thread_bound"), "prompt": .string("Start with safe permissions"),
          ])
        let status = try await fixture.call(runtime, "codex.app.status")
        #expect(
          status.objectValue?["threads"]?.arrayValue?.first?.objectValue?["active_turn_id"]
            == .string("turn_1"))
      }
      let requestsBeforeApproval = activation == "thread-start" ? [] : try fixture.vendorRequests()
      let grant = try fixture.requestGrant(
        threadID: activation == "thread-start" ? nil : "thread_bound", mode: .nextTurn)
      _ = try fixture.approve(grant.id)
      if activation == "thread-start" {
        #expect(
          !FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("vendor.jsonl").path))
      } else {
        #expect(try fixture.vendorRequests() == requestsBeforeApproval)
      }
      if activation == "thread-start" {
        _ = try await fixture.call(runtime, "codex.app.thread.start")
        let started = try #require(
          try fixture.vendorRequests().last { $0.objectValue?["method"] == .string("thread/start") }
        )
        #expect(
          started.objectValue?["params"]?.objectValue?["sandbox"] == .string("danger-full-access"))
        let bound = try #require(try fixture.database.codexElevationGrant(id: grant.id))
        #expect(bound.state == .active && bound.threadID == "thread_bound")
      }
      _ = try await fixture.call(
        runtime, "codex.app.turn.start",
        ["thread_id": .string("thread_bound"), "prompt": .string("Protocol fixture only")])
      let after = try #require(try fixture.database.codexElevationGrant(id: grant.id))
      #expect(after.state == .consumed && after.consumedTurnCount == 1)
      _ = try await fixture.call(
        runtime, "codex.app.turn.start",
        ["thread_id": .string("thread_bound"), "prompt": .string("Second fixture turn")])
      let turns = try fixture.vendorRequests().filter {
        $0.objectValue?["method"] == .string("turn/start")
      }
      let offset = activation == "later-turn" ? 1 : 0
      #expect(turns.count == 2 + offset)
      if offset == 1 {
        #expect(
          turns[0].objectValue?["params"]?.objectValue?["sandboxPolicy"]?.objectValue?["type"]
            == .string("workspaceWrite"))
      }
      #expect(
        turns[offset].objectValue?["params"]?.objectValue?["sandboxPolicy"]?.objectValue?["type"]
          == .string("dangerFullAccess"))
      #expect(
        turns[offset + 1].objectValue?["params"]?.objectValue?["sandboxPolicy"]?.objectValue?[
          "type"]
          == .string("workspaceWrite"))
      #expect(try fixture.database.codexElevationGrant(id: grant.id)?.consumedTurnCount == 1)
      await runtime.shutdown()
      try await fixture.requireVendorExit()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func unconfirmedElevatedTurnInvalidatesItsClaimAndStopsBeforeHostShutdown() async throws {
    let fixture = try BoundServicesFixture(requestTimeoutSeconds: 1)
    defer { fixture.remove() }
    let runtime = try await fixture.runtime()
    do {
      _ = try await fixture.call(runtime, "codex.app.thread.start")
      let grant = try fixture.requestGrant(threadID: "thread_bound", mode: .nextTurn)
      _ = try fixture.approve(grant.id)
      try Data().write(to: fixture.root.appendingPathComponent("hang-turn"))
      await #expect(throws: (any Error).self) {
        try await fixture.call(
          runtime, "codex.app.turn.start",
          [
            "thread_id": .string("thread_bound"), "prompt": .string("Ambiguous fixture outcome"),
          ])
      }
      let record = try #require(try fixture.database.codexElevationGrant(id: grant.id))
      #expect(record.state == .invalidated && record.inFlightClaimID == nil)
      let status = try await fixture.call(runtime, "codex.app.status")
      #expect(status.objectValue?["runtime_state"] == .string("stopped"))
      try await fixture.requireVendorExit()
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
        workspaceIDs: [workspace.id], allowedCallers: [.secureTunnel]))
    let vendor = root.appendingPathComponent("vendor-fixture")
    try Self.vendor.write(to: vendor, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vendor.path)
    config = root.appendingPathComponent("adapter.json")
    try JSONEncoder().encode(
      JSONValue.object([
        "enabled": .bool(true), "executable": .string(vendor.path),
        "app_server_enabled": .bool(true),
        "exec_enabled": .bool(allCapabilities), "mcp_enabled": .bool(allCapabilities),
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
        transportTrace: .init(transport: "gateway_socket", socketConnectionID: "services-origin")),
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
          allowedCallers: [.secureTunnel])
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
          workspaces: [workspace.id], allowedCallers: [.secureTunnel])
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
        transportTrace: .init(transport: "gateway_socket", socketConnectionID: "services-origin")),
      database: database, registeredWorkspaces: [workspace])
  }
  func exposed(_ name: String) -> String { prefix.isEmpty ? name : prefix + "." + name }

  func sqlite(_ file: URL, _ sql: String) throws -> String {
    try command("/usr/bin/sqlite3", ["-batch", "-quote", file.path, sql]).stdout
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
  func requestGrant(
    threadID: String?, connection: String = "services-origin",
    mode: CodexElevationGrantMode = .boundedTime
  ) throws -> CodexElevationGrantRecord {
    try CodexElevationGrantService.request(
      owner: .init(
        workspaceID: workspace.id, profileID: "chatgpt-operate",
        caller: "secure-tunnel", transport: "gateway_socket", socketConnectionID: connection,
        tunnelInstanceID: nil, tunnelProfileID: nil), database: database, threadID: threadID,
      mode: mode,
      reason: "Disposable host-service validation", maximumDurationSeconds: 300,
      maximumTurnCount: nil)
  }
  func approve(_ id: String) throws -> CodexElevationGrantRecord {
    try CodexElevationGrantService.approve(
      id: id,
      owner: .init(
        workspaceID: workspace.id,
        profileID: "local-admin", caller: "local-cli", transport: "fixture",
        socketConnectionID: nil,
        tunnelInstanceID: nil, tunnelProfileID: nil), database: database)
  }
  func revoke(_ id: String) throws {
    _ = try database.updateCodexElevationGrant(id: id) { value in
      value.state = .revoked
      value.revokedAt = Date()
      value.updatedAt = Date()
    }
  }
  func waitForFile(_ name: String) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
      if FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw GatewayToolError.executionFailed("Fixture did not publish expected protocol checkpoint.")
  }
  func vendorRequests() throws -> [JSONValue] {
    try String(contentsOf: root.appendingPathComponent("vendor.jsonl"), encoding: .utf8).split(
      separator: "\n"
    )
    .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
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
    import hashlib, json, os, pathlib, sys, time
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
            (root/'start-received').touch()
            if (root/'pause-start').exists():
                deadline = time.monotonic() + 8
                while not (root/'release-start').exists() and time.monotonic() < deadline: time.sleep(.01)
            result = {'thread':thread,'cwd':cwd,'model':'fixture','modelProvider':'fixture','approvalPolicy':'on-request',
                      'approvalsReviewer':'user','sandbox':{'type':'dangerFullAccess' if request['params'].get('sandbox')=='danger-full-access' else 'workspaceWrite'}}
        elif method == 'turn/start':
            count += 1
            if (root/'hang-turn').exists(): time.sleep(30)
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
