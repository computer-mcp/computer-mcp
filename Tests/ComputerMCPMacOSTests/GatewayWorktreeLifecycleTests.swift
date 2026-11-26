import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlugins
import ComputerMCPTestSupport
import ComputerMCPTransport
import ComputerMCPWorktrees
import Foundation
import MCP
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPProcess

@Suite(.nativeIntegration, .serialized)
struct GatewayWorktreeLifecycleTests {
  @Test func removingWorktreeJoinsOnlyItsProviderProcess() async throws {
    let root = try WorktreeProviderFixtureReceipts.createRoot(
      for: ProcessInfo.processInfo.processIdentifier)
    let child = try await #require(
      processExitsWith: .success, observing: [\.standardOutputContent],
      "Worktree fixture root retained on child failure at \(root.identity.path)"
    ) {
      do { try await Self.runWorktreeProviderChild() } catch {
        // Swift Testing forwards issues. A failed child emits no deletion receipt.
        Issue.record(error)
      }
    }
    do {
      let receipts = try WorktreeProviderFixtureReceipts.decode(child.standardOutputContent)
      try receipts.verifyAndRemove(root)
    } catch {
      Issue.record("Worktree fixture cleanup failed at \(root.identity.path)")
      throw error
    }
  }

  private static func runWorktreeProviderChild() async throws {
    let root = try WorktreeProviderFixtureReceipts.openParentRoot()
    let fixture = try FixedHostFixture(
      fullAccess: false, lifecycle: true, callback: true, isolatedRoot: root.url)
    let receipts: WorktreeProviderFixtureReceipts
    do {
      receipts = try await exerciseWorktreeProviders(fixture, root: root)
    } catch {
      fixture.session.end()
      await fixture.runtime.shutdown()
      throw error
    }
    fixture.session.end()
    await fixture.runtime.shutdown()
    try await receipts.waitForCommit(fixture, root: root)
    try receipts.report()
  }

  private static func exerciseWorktreeProviders(
    _ fixture: FixedHostFixture, root: WorktreeDirectory
  ) async throws -> WorktreeProviderFixtureReceipts {
    try await fixture.initializeRepository()
    let generations = GatewayStandaloneGenerations(fixture.runtime)
    var processes: [ManagedLineProcess] = []
    var consumerRuntime: GatewayRuntime?
    let receipts: WorktreeProviderFixtureReceipts
    do {
      func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let result = try await generations.callToolForMCPAsync(
          name: name, arguments: .object(arguments), context: .init(session: fixture.session))
        try #require(result.objectValue?["isError"] == .bool(false), "\(result)")
        return try #require(result.objectValue?["structuredContent"]?.objectValue?["result"])
      }
      func create(_ name: String) async throws -> (id: String, directory: URL) {
        let result = try await call("git.worktree_add", ["name": .string(name)])
        let id = try #require(result.objectValue?["project_id"]?.stringValue)
        let path = try #require(result.objectValue?["path"]?.stringValue)
        return (id, try ProjectPathResolver.canonicalProject(URL(fileURLWithPath: path)))
      }
      let target = try await create("provider-target")
      let sibling = try await create("provider-sibling")
      let runtime = fixture.runtime.permissionRuntime
      let server = try #require(fixture.configuration.mcp.servers.first)
      let packages = try PluginStoreFixture()
      defer { packages.cleanup() }
      let packageRoot = try packages.makePackage(
        directory: "provider-sibling",
        text: PluginManifestFixture.header + """
          [[skills]]
          id = 'guidance'
          path = 'skills'
          """)
      let store = PluginStore(database: fixture.database, platform: fixture.platform)
      _ = try await store.registerDevelopment(
        at: packageRoot, expectedRevision: store.snapshot().revision)
      try fixtureApprovePlugin(
        PluginPackage.load(at: packageRoot), database: fixture.database,
        runtime: runtime, permissions: .newPrincipal)
      let consumer = try await GatewayRuntime.make(
        configuration: fixture.configuration,
        context: .init(
          caller: .localMCP, profileID: .chatGPTOperate, projectID: sibling.id,
          trustedPrincipalID: "provider-sibling-consumer"),
        database: fixture.database, platform: fixture.platform,
        mcpClient: CatalogDiscoveryStub(), bundledPlugins: .init(packages: [], issues: []))
      consumerRuntime = consumer
      let consumerSession = try consumer.makeControlSession()
      defer { consumerSession.end() }
      let projects = try await consumer.callToolForMCPAsync(
        name: "project.list", arguments: nil, context: .init(session: consumerSession))
      try #require(projects.objectValue?["isError"] == .bool(false), "\(projects)")
      try fixtureApproveLocalProvider(
        server, database: fixture.database, runtime: runtime,
        permissions: fixturePermissions([.project("fixture"): .granted(.read)]),
        fullAccess: false)
      let skillRoot = try CanonicalPath(
        ProjectPathResolver.canonicalProject(packageRoot.appendingPathComponent("skills")).path)
      let skillRule = try runtime.store.readWithDatabase { _, ledger in
        try #require(
          ledger.environment.paths?.pathRules.first {
            $0.root == skillRoot && $0.kind == .skillLibrary
          })
      }

      func start(_ project: (id: String, directory: URL)) async throws -> PreparedExecutionContext {
        var context = ExecutionContext(
          caller: .localMCP, profileID: .chatGPTOperate, projectID: project.id,
          trustedPrincipalID: consumerSession.principalID)
        context.controlSession = consumerSession
        let subject = try GatewayPermissionSubject(context: context)
        let decision = try runtime.service.admit(
          subject: subject, tool: "provider.operation", projectID: project.id,
          argumentsDigest: project.id,
          requirements: .init(
            actions: [
              .init(requirement: .init(.mcpServer(server.id), .all)),
              .init(requirement: .init(.project("fixture"), .read), scope: .project("fixture")),
            ], paths: [.init(path: try CanonicalPath(project.directory.path), operation: .read)],
            mode: .sandbox, sandboxProjectID: "fixture"),
          connectionID: consumerSession.id)
        guard case .allowed(let proof) = decision else {
          Issue.record("Provider admission failed: \(decision)")
          throw PermissionModelError.invalidAuthorization
        }
        let prepared = try await runtime.prepareProvider(
          review: GatewayProviderReview(
            server: server, configuration: fixture.database.configurationState()),
          registrationID: server.id, authorization: proof,
          directory: project.directory, connectionID: consumerSession.id)
        processes.append(
          try prepared.withValue {
            try ManagedLineProcess(
              launcher: fixture.platform.launcher,
              configuration: .init(executable: "/bin/cat", workingDirectory: project.directory))
          })
        return prepared
      }
      let targetExecution = try await start(target)
      let siblingExecution = try await start(sibling)
      let targetProcess = processes[0]
      let siblingProcess = processes[1]
      var targetLines = targetProcess.inboundLines.makeAsyncIterator()
      var siblingLines = siblingProcess.inboundLines.makeAsyncIterator()
      try await targetProcess.sendLine("target")
      try await siblingProcess.sendLine("sibling")
      try #require(try await targetLines.next() == "target")
      try #require(try await siblingLines.next() == "sibling")
      try targetExecution.finishAdmission()
      try siblingExecution.finishAdmission()
      let targetPID = try #require(await targetProcess.snapshot().processID)
      let siblingPID = try #require(await siblingProcess.snapshot().processID)
      try #require(targetPID != siblingPID)
      let targetIdentity = try #require(DarwinProcessIdentity.current(pid: targetPID)?.identity)
      let siblingIdentity = try #require(DarwinProcessIdentity.current(pid: siblingPID)?.identity)
      try runtime.store.readWithDatabase { _, ledger in
        try #require(ledger.executions[targetExecution.executionID]?.isRunning == true)
        try #require(ledger.executions[siblingExecution.executionID]?.isRunning == true)
      }

      let removed = try await call("git.worktree_remove", ["project_id": .string(target.id)])
      try #require(removed.objectValue?["terminationWarnings"] == .array([]))
      try #require(DarwinProcessIdentity.current(pid: targetPID)?.identity != targetIdentity)
      try #require(try fixture.database.project(id: target.id) == nil)
      let registeredSibling = try #require(try fixture.database.project(id: sibling.id))
      try #require(
        try ProjectPathResolver.canonicalProject(URL(fileURLWithPath: registeredSibling.rootPath))
          == ProjectPathResolver.canonicalProject(sibling.directory))
      try runtime.store.readWithDatabase { _, ledger in
        try #require(
          ledger.environment.paths?.pathRules.first { $0.root == skillRoot } == skillRule)
        try #require(ledger.executions[targetExecution.executionID]?.isRunning == false)
        try #require(ledger.executions[targetExecution.executionID]?.revoked == true)
        try #require(ledger.executions[siblingExecution.executionID]?.isRunning == true)
        try #require(ledger.executions[siblingExecution.executionID]?.revoked == false)
      }
      try #require(DarwinProcessIdentity.current(pid: siblingPID)?.identity == siblingIdentity)
      try await siblingProcess.sendLine("after removal")
      try #require(try await siblingLines.next() == "after removal")
      receipts = try WorktreeProviderFixtureReceipts.capture(
        root: root, runtime: runtime, sessions: [fixture.session, consumerSession],
        target: (target.id, targetExecution.executionID, targetIdentity),
        sibling: (sibling.id, siblingExecution.executionID, siblingIdentity))
    } catch {
      for process in processes { await process.close() }
      await consumerRuntime?.shutdown()
      await generations.shutdown()
      throw error
    }
    for process in processes { await process.close() }
    await consumerRuntime?.shutdown()
    await generations.shutdown()
    return receipts
  }

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
        takingOwnershipOf: channel.providerChannel.takeEndpoint())
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
