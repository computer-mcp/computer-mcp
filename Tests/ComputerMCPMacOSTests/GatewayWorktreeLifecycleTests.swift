import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPTransport
import Foundation
import MCP
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPProcess

@Suite(.nativeIntegration, .serialized)
struct GatewayWorktreeLifecycleTests {
  @Test func forwardedLifecycleUsesTheSameSandboxAuthority() async throws {
    let fixture = try FixedHostFixture(fullAccess: false, lifecycle: true, callback: true)
    try await fixture.run { fixture in
      try await fixture.initializeRepository()
      let created = try await fixture.runtime.callHostTool(
        name: "git.worktree_add", arguments: ["name": .string("callback")],
        projectID: "fixture", origin: "lifecycle-callback", requestID: UUID().uuidString)
      try #require(created.objectValue?["isError"] != .bool(true), "\(created)")
      let branch = try #require(
        created.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["branch"]?
          .stringValue)
      let refused = try await fixture.runtime.callHostTool(
        name: "git.branch_delete", arguments: ["name": .string(branch), "force": .bool(true)],
        projectID: "fixture", origin: "lifecycle-callback", requestID: UUID().uuidString)
      #expect(refused.objectValue?["isError"] == .bool(true))
    }
  }

  /// Sandboxed callback work runs in the worktree under the provider's own approval, with no
  /// Full access consent on either side. Narrowing the provider's approval or the delegating
  /// client's grant ends that work; the parent's exit does not.
  @Test(arguments: ["provider", "delegator", "exit"])
  func sandboxedCallbackWorkFollowsItsProviderAuthority(cause: String) async throws {
    let fixture = try FixedHostFixture(fullAccess: false, lifecycle: true, callback: true)
    try await fixture.run { fixture in
      try await fixture.initializeRepository()
      let created = try await fixture.call("git.worktree_add", ["name": .string("provider")])
      let made = try #require(
        created.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue,
        "\(created)")
      let projectID = try #require(made["project_id"]?.stringValue)
      let worktree = try ProjectPathResolver.canonicalProject(
        URL(fileURLWithPath: try #require(made["path"]?.stringValue)))
      // The derived project exists from the next generation on.
      let generation = try await fixture.runtime.refreshedGeneration()
      let runtime = generation.permissionRuntime
      let registration = try #require(fixture.configuration.mcp.servers.first)
      let review = try fixtureApproveLocalProvider(
        registration, database: fixture.database, runtime: runtime,
        permissions: fixturePermissions([.project("fixture"): .granted(.write)]),
        fullAccess: false)
      var context = ExecutionContext(
        caller: .localMCP, profileID: .chatGPTOperate, projectID: projectID,
        trustedPrincipalID: fixture.session.principalID)
      context.controlSession = fixture.session
      let subject = try GatewayPermissionSubject(context: context)
      let decision = try runtime.service.admit(
        subject: subject, tool: "provider.operation", projectID: projectID,
        argumentsDigest: "sandboxed-parent",
        requirements: .init(
          actions: [
            .init(requirement: .init(.mcpServer(registration.id), .all)),
            .init(requirement: .init(.project("fixture"), .write), scope: .project("fixture")),
          ], mode: .sandbox, sandboxProjectID: "fixture"),
        connectionID: fixture.session.id)
      guard case .allowed(let proof) = decision else {
        Issue.record("Parent admission failed: \(decision)")
        return
      }
      let parent = try await runtime.prepareProvider(
        review: review, registrationID: registration.id, authorization: proof,
        directory: worktree, connectionID: fixture.session.id)
      guard case .sandbox = parent.mode else {
        Issue.record("The provider parent is not sandboxed")
        return
      }
      let directory = MCPHostToolDirectory()
      directory.attach(generation)
      var host = MCPHostContext(
        runtimeID: UUID(), context: context, projectID: projectID, rootURL: worktree,
        readOnly: false, tools: directory)
      host.providerExecution = parent
      let channel = try MCPHostSession(context: host, server: registration)
      let peer = MCP.Client(name: "sandboxed-callback", version: "1")
      let transport = try MCPInheritedSocketTransport(
        takingOwnershipOf: #require(channel.providerChannel).takeEndpoint())
      do {
        _ = try await peer.connect(transport: transport)
        let escape = fixture.root.appendingPathComponent("escape")
        let script =
          "echo ready > ready; (echo escaped > '\(escape.path)') 2>/dev/null; exec /bin/cat"
        let request: RequestContext<MCP.CallTool.Result> = try await peer.callTool(
          name: "process.spawn",
          arguments: ["id": .string("fixture"), "argv": .array([.string("-c"), .string(script)])])
        let response = try await request.value
        let result = try JSONValue.sdkToolResult(
          content: response.content, structuredContent: response.structuredContent,
          isError: response.isError, meta: response._meta)
        try #require(result.objectValue?["isError"] != .bool(true), "\(result)")
        let payload = result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue
        let processID = try #require(payload?["process_id"]?.stringValue, "\(result)")
        let ready = worktree.appendingPathComponent("ready")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        #expect(!FileManager.default.fileExists(atPath: escape.path))
        let child = try runtime.store.readWithDatabase { _, ledger in
          try #require(
            ledger.executions.values.first { execution in
              execution.id != parent.executionID
                && execution.authorizationIDs.contains { id in
                  ledger.authorizations[id]?.basis.contains(.execution(parent.executionID))
                    == true
                }
            })
        }
        switch cause {
        case "provider":
          let owner = try GatewayPermissionOwner(
            context: .init(
              caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "callback-owner"),
            validate: {})
          let view = try runtime.service.view(owner: owner)
          let approval = try #require(view.providers.first { $0.identity == review.identity })
          _ = try runtime.service.approveProvider(
            review, permissions: fixturePermissions([:]), fullAccess: false, owner: owner,
            expectedProviderRevision: approval.revision, expectedRevision: view.revision,
            expectedEpoch: #require(view.epoch))
        case "delegator":
          try runtime.store.transactionWithDatabase { _, ledger in
            _ = try ledger.setPermission(
              .notGranted, for: .mcpServer(registration.id), principal: subject.principal,
              expectedRevision: ledger.revision)
          }
        default: try parent.finishAdmission()
        }
        try await runtime.coordinator.reconcile()
        let survives = cause == "exit"
        let state = try runtime.store.readWithDatabase { _, ledger in
          try #require(ledger.executions[child.id])
        }
        #expect(state.isRunning == survives)
        #expect(state.revoked == !survives)
        if survives {
          let write = try await generation.callToolForMCPAsync(
            name: "process.write",
            arguments: .object([
              "project_id": .string(projectID), "process_id": .string(processID),
              "text": .string("still-running"),
            ]), context: .init(session: fixture.session))
          #expect(write.objectValue?["isError"] != .bool(true), "\(write)")
        }
        await peer.disconnect()
        await channel.close()
        await generation.shutdown()
      } catch {
        await peer.disconnect()
        await channel.close()
        await generation.shutdown()
        throw error
      }
    }
  }

  @Test func lifecycleToolsFollowTheDerivedProjectAcrossGenerations() async throws {
    let fixture = try FixedHostFixture(fullAccess: false, lifecycle: true)
    try await fixture.run { fixture in
      try await fixture.initializeRepository()
      let generations = GatewayStandaloneGenerations(fixture.runtime)
      do {
        func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
          let result = try await generations.callToolForMCPAsync(
            name: name, arguments: .object(arguments), context: .empty)
          try #require(result.objectValue?["isError"] != .bool(true), "\(result)")
          return try #require(result.objectValue?["structuredContent"]?.objectValue?["result"])
        }
        let created = try await call("git.worktree_add", ["name": .string("remote")])
        let id = try #require(created.objectValue?["project_id"]?.stringValue)
        let branch = try #require(created.objectValue?["branch"]?.stringValue)
        let inventory = try await call("git.worktree_list", ["project_id": .string(id)])
        #expect(inventory.objectValue?["worktrees"]?.arrayValue?.count == 2)
        let refused = try await generations.callToolForMCPAsync(
          name: "git.branch_delete",
          arguments: .object([
            "project_id": .string("fixture"), "name": .string(branch),
            "force": .bool(true), "dry_run": .bool(false), "confirm_delete": .bool(true),
          ]), context: .empty)
        #expect(refused.objectValue?["isError"] == .bool(true))
        _ = try await call(
          "git.merge", ["project_id": .string("fixture"), "branch": .string(branch)])
        let removed = try await call("git.worktree_remove", ["project_id": .string(id)])
        #expect(removed.objectValue?["terminationWarnings"] == .array([]))
        let deleted = try await call(
          "git.branch_delete",
          [
            "project_id": .string("fixture"),
            "name": .string(branch), "dry_run": .bool(false), "confirm_delete": .bool(true),
          ])
        #expect(deleted.objectValue?["deleted"] == .bool(true))
        await generations.shutdown()
      } catch {
        await generations.shutdown()
        throw error
      }
    }
  }
}
