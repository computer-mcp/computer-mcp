import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPersistence
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPTransport
import ComputerMCPWorktrees
import CryptoKit
import Darwin
import Foundation
import GRDB
import MCP
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPermissions
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlugins
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)
struct MCPBoundHostServicesTests {
  @Test(.timeLimit(.minutes(1)))
  func ownerEnabledScopedPackageRunsBothRoutesOnASandboxedRegisteredSource() async throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = try ProjectPathResolver.canonicalProject(temporary.url)
    let project = root.appendingPathComponent("source")
    let packageRoot = root.appendingPathComponent("package")
    for directory in [project, packageRoot] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    try """
    id = 'scoped-fixture'
    name = 'Scoped fixture'
    version = '1.0.0'
    plugin_api = 1
    [[permissions]]
    id = 'project'
    access = 'write'
    purpose = 'Request host worktree operations.'
    [[mcp]]
    id = 'probe'
    transport = 'stdio'
    host_service_contract = 'projects-v1'
    executable = { path = 'provider' }
    capabilities = ['tools']
    """.write(
      to: packageRoot.appendingPathComponent(PluginManifest.filename), atomically: true,
      encoding: .utf8)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "/bin/cat"), to: packageRoot.appendingPathComponent("provider"))
    let database = try fixturePermissionDatabase(
      path: root.appendingPathComponent("host.sqlite").path)
    try database.saveProject(
      RegisteredProject(id: "source", displayName: "Source", rootPath: project.path))
    let providerPermissions = fixturePermissions([.project("source"): .granted(.write)])
    var callerPermissions = providerPermissions
    try callerPermissions.set(.granted(.use), for: .plugin("scoped-fixture"))
    let grant = ProfileGrant(
      id: .chatGPTOperate, permissions: callerPermissions, fullAccess: false,
      allowedCallers: [.secureTunnel])
    try database.saveProfile(grant)
    let platform = fixtureHostedPlatform()
    let store = PluginStore(database: database, platform: platform)
    let registered = try await store.registerDevelopment(at: packageRoot, expectedRevision: 0)
    _ = try await store.setSettings(
      .init(
        enabled: true,
        mcp: [
          "probe": .init(
            registrationID: "scoped-probe", exposure: .reexport, prefix: "adapter",
            allowedTools: ["fixture.read"], hostServices: true)
        ]), for: "scoped-fixture", expectedRevision: registered.revision)
    let peer = HostServiceProbe()
    let runtime = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: grant.id),
        profiles: [.init(grant: grant)]),
      context: .init(
        caller: .secureTunnel, profileID: grant.id, trustedPrincipalID: "scoped-source-client"),
      database: database, platform: platform, mcpClient: peer)
    do {
      try fixtureApprovePlugin(
        PluginPackage.load(at: packageRoot), database: database, runtime: runtime.permissionRuntime,
        permissions: providerPermissions)
      peer.setHandler { invocation in
        let execution = try #require(invocation.executionAuthority as? PreparedExecutionContext)
        let provider = try #require(execution.provider)
        #expect(provider.identity == .package("scoped-fixture"))
        #expect(provider.providerAuthorization.sandboxProjectID == "source")
        #expect(provider.delegatingAuthorization?.invocation.projectID == "source")
        #expect(execution.providerProject?.content == .source)
        #expect(invocation.admission?.hostInvocationID != nil)
        #expect(invocation.resolvedInvocation?.descriptor.risk == .externalWrite)
        guard case .sandbox(let sandbox) = execution.mode else {
          throw PermissionModelError.invalidAuthorization
        }
        #expect(sandbox.readOnly && sandbox.worktree.value == project.path && sandbox.git == nil)
        let container = try #require(sandbox.providerContainer)
        #expect(Set(sandbox.writableDirectories) == [sandbox.temporaryDirectory, container.root])
        return .object(["ok": .bool(true)])
      }
      _ = try await runtime.callToolAsync(
        name: "mcp.tools.call",
        arguments: .object([
          "server": .string("scoped-probe"), "tool": .string("fixture.read"),
          "arguments": .object(["project_id": .string("downstream-arguments-do-not-route")]),
        ]), context: .empty)
      _ = try await runtime.callToolAsync(
        name: "adapter.fixture.read", arguments: .object([:]), context: .empty)
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func consumerStartupBudgetPreservesLiveInvocation() async throws {
    let fixture = try HostAuthorityFixture(callbackTimeout: PluginConsumerTiming.invocationSeconds)
    defer { fixture.remove() }
    _ = try await fixture.during("fixture.audit", ["limit": .integer(1)]) { service, invocation in
      // Package startup can outlast the ordinary in-process fixture's budget.
      try await Task.sleep(for: .seconds(11))
      let id = try #require(invocation.admission?.hostInvocationID)
      let call = try #require(try fixture.database.hostCallRecordStore().record(id: id))
      #expect(call.lifecycle == .running)
      let response = try await service.call(
        name: "host.diagnostics.snapshot", arguments: ["limit": .integer(1)])
      #expect(response.isError != true)
      return try .encoded(response)
    }
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1))) func hostMutationCommitRejectsRevokedPersistentClientTrust()
    async throws
  {
    let evidence = InvocationCallbackEvidence()
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let published = try await fixture.runtime.callToolAsync(
      name: "project.list", arguments: nil, context: .empty)
    try #require(published.objectValue?["isError"] == .bool(false))
    let session = try fixture.session(consent: false)
    let snapshot = try session.approveFullAccess(
      lifetime: .alwaysAllowClient,
      expectedRevision: session.snapshot.revision)
    let consent = try #require(snapshot.fullAccessConsent)
    let directory = try #require(fixture.peer.context(for: "scope")?.tools)
    _ = try await checkedInvocationResult(evidence: evidence, revoked: true) {
      try await fixture.during("fixture.audit", context: .init(session: session)) { _, context in
        evidence.entered()
        let active = try #require(
          directory.active(projectID: "scope", origin: "probe").first {
            $0.id == context.admission?.hostInvocationID
          })
        var initiallyAuthorized = false
        var revoked = false
        var committedAfterRevocation = false
        #expect(throws: (any Error).self) {
          try fixture.runtime.withHostMutation(active) { authority in
            #expect(authority.consent?.trustID == consent.trustID)
            try fixture.database.withHostAuthority(authority) { initiallyAuthorized = true }
            try fixture.database.revokeClientTrust(
              id: #require(consent.trustID),
              expectedRevision: #require(consent.trustRevision))
            revoked = true
            evidence.revoked()
            try fixture.database.withHostAuthority(authority) { committedAfterRevocation = true }
          }
        }
        #expect(initiallyAuthorized)
        #expect(revoked)
        #expect(!committedAfterRevocation)
        evidence.checked()
        return .null
      }
    }
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true], ["increase", "revoked", "unchanged"])
  func profileEditsInvalidateHostMutationAuthority(explicitSession: Bool, change: String)
    async throws
  {
    let evidence = InvocationCallbackEvidence()
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let session = try fixture.session()
    let directory = try #require(fixture.peer.context(for: "scope")?.tools)
    _ = try await checkedInvocationResult(evidence: evidence, revoked: true) {
      try await fixture.during(
        "fixture.audit", context: explicitSession ? .init(session: session) : .empty
      ) { _, context in
        evidence.entered()
        let active = try #require(
          directory.active(projectID: "scope", origin: "probe").first {
            $0.id == context.admission?.hostInvocationID
          })
        var attempts = 0
        var committed = false
        #expect(throws: (any Error).self) {
          try fixture.runtime.withHostMutation(active) { authority in
            attempts += 1
            var profile = try #require(
              fixture.database.profiles().first { $0.id == .chatGPTOperate })
            if change == "revoked" {
              profile.permissions = .init()
            } else if change == "increase" {
              try profile.permissions.set(.granted(.access), for: .machineInformation)
            }
            try fixture.database.saveProfile(profile)
            evidence.revoked()
            try fixture.database.withHostAuthority(authority) { committed = true }
          }
        }
        #expect(attempts == 1)
        #expect(!committed)
        evidence.checked()
        return .null
      }
    }
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["principal", "profile", "caller"])
  func channelScopeCannotBorrowAnotherLiveRecord(field: String) async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let captured = try #require(fixture.peer.context(for: "scope"))
    let foreign = MCPHostContext(
      runtimeID: captured.launchMetadata.runtimeID,
      context: .init(
        caller: field == "caller" ? .localCLI : .secureTunnel,
        profileID: field == "profile" ? .localAdmin : .chatGPTOperate,
        trustedPrincipalID: field == "principal" ? "foreign" : "fixture-principal"),
      projectID: "scope", rootURL: fixture.root, readOnly: false, tools: captured.tools)
    let service = MCPBoundHostServices(
      database: fixture.database,
      directory: try #require(captured.tools), context: foreign, origin: "probe")
    _ = try await fixture.during("fixture.audit", ["limit": .integer(1)]) { _, _ in
      let result = try await service.call(
        name: "host.diagnostics.snapshot", arguments: ["limit": .integer(1)])
      #expect(result.isError == true)
      return try .encoded(result)
    }
    await service.close()
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1))) func shutdownCompletesRetainedCallRecords() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let directory = try #require(fixture.peer.context(for: "scope")?.tools)
    let retained = RetainedControlInvocation()
    _ = try await fixture.during("fixture.audit") { _, context in
      let id = try #require(context.admission?.hostInvocationID)
      await retained.hold(
        id: id, lease: try directory.retainWork(id: id, projectID: "scope", origin: "probe"))
      return .object([:])
    }
    let id = try #require(await retained.id)
    await fixture.close()
    #expect(try fixture.database.hostCallRecordStore().record(id: id)?.lifecycle == .completed)
    await retained.finish()
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["unchanged", "principal", "project", "origin", "digest", "completed", "lease"])
  func persistedCallTamperingCannotAuthorizeCallbacks(attack: String) async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let result = try await fixture.during("fixture.audit", ["limit": .integer(1)]) {
      service, context in
      let id = try #require(context.admission?.hostInvocationID)
      try await fixture.connection.writer.write { database in
        let row = try #require(
          try Row.fetchOne(
            database, sql: "SELECT payload FROM hostCallRecords WHERE id = ?",
            arguments: [id.uuidString]))
        let bytes: Data = row["payload"]
        var record = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var facts = try #require(record["admission"] as? [String: Any])
        switch attack {
        case "unchanged": break
        case "principal": facts["verifiedClientID"] = "foreign"
        case "project": facts["projectID"] = "foreign"
        case "origin":
          var route = try #require(facts["reference"] as? [String: Any])
          route["serverID"] = "foreign"
          facts["reference"] = route
        case "digest": facts["argumentsDigest"] = "foreign"
        case "completed": record["completedAt"] = Date().timeIntervalSinceReferenceDate
        default: record["requestLeaseIDs"] = [UUID().uuidString]
        }
        record["admission"] = facts
        try database.execute(
          sql: "UPDATE hostCallRecords SET payload = ? WHERE id = ?",
          arguments: [try JSONSerialization.data(withJSONObject: record), id.uuidString])
      }
      return try await .encoded(
        service.call(name: "host.diagnostics.snapshot", arguments: ["limit": .integer(1)]))
    }
    #expect(result.objectValue?["isError"] == .bool(attack != "unchanged"))
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1))) func durableBeginFailurePreventsProviderDispatch() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    try await fixture.connection.writer.write { database in
      try database.execute(
        sql:
          "CREATE TRIGGER reject_call BEFORE INSERT ON hostCallRecords BEGIN SELECT RAISE(ABORT, 'fixture'); END"
      )
    }
    await #expect(throws: (any Error).self) {
      try await fixture.during("fixture.audit") { _, _ in
        Issue.record("A provider cannot start before its call record commits.")
        return .object([:])
      }
    }
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1))) func failedCompletionCannotRecreateLostLiveAuthority() async throws
  {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let retained = RetainedControlInvocation()
    let directory = try #require(fixture.peer.context(for: "scope")?.tools)
    _ = try await fixture.during("fixture.audit") { _, context in
      let id = try #require(context.admission?.hostInvocationID)
      let lease = try directory.retainWork(id: id, projectID: "scope", origin: "probe")
      await retained.hold(id: id, lease: lease)
      return .object([:])
    }
    let id = try #require(await retained.id)
    #expect(try fixture.database.hostCallRecordStore().record(id: id)?.lifecycle == .retained)
    _ = try fixture.runtime.requireHostInvocation(projectID: "scope", origin: "probe", id: id)
    try await fixture.connection.writer.write { database in
      try database.execute(
        sql:
          "CREATE TRIGGER reject_finish BEFORE UPDATE ON hostCallRecords BEGIN SELECT RAISE(ABORT, 'fixture'); END"
      )
    }
    await retained.finish()
    #expect(try fixture.database.hostCallRecordStore().record(id: id)?.lifecycle == .retained)
    #expect(throws: (any Error).self) {
      try fixture.runtime.requireHostInvocation(projectID: "scope", origin: "probe", id: id)
    }
    let response = try await fixture.direct(
      "host.invocations.describe", ["invocation_id": .string(id.uuidString)])
    #expect(response.objectValue?["isError"] == .bool(true))
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func retainedInvocationRechecksItsControlSessionOutsideTheOriginalTask() async throws {
    let fixture = try HostAuthorityFixture(requiresControlSession: true)
    defer { fixture.remove() }
    let session = try fixture.session()
    let directory = try #require(fixture.peer.context(for: "scope")?.tools)
    let retained = RetainedControlInvocation()
    do {
      _ = try await fixture.during(
        "fixture.audit", ["limit": .integer(1)], context: .init(session: session)
      ) { _, _ in
        let invocation = try #require(
          directory.active(projectID: "scope", origin: "probe").first)
        let lease = try directory.retainWork(
          id: invocation.id, projectID: "scope", origin: "probe")
        await retained.hold(id: invocation.id, lease: lease)
        return .object([:])
      }
      let id = try #require(await retained.id)
      #expect(directory.active(projectID: "scope", origin: "probe").isEmpty)
      _ = try await Task.detached {
        try fixture.runtime.requireHostInvocation(projectID: "scope", origin: "probe", id: id)
      }.value
      try session.limitAccess(
        to: .init(
          permissionCeilings: fixturePermissions([
            .project("*"): .granted(.read), .mcpServer("*"): .granted(.read),
          ]), allowsFullAccess: false), expectedRevision: session.revision)
      await #expect(throws: (any Error).self) {
        try await Task.detached {
          try fixture.runtime.requireHostInvocation(projectID: "scope", origin: "probe", id: id)
        }.value
      }
      #expect(
        directory.active(projectID: "scope", origin: "probe", includingRetainedWork: true).count
          == 1)
      let read = try await fixture.runtime.callHostTool(
        name: "project.list", arguments: [:], projectID: "scope", origin: "probe",
        requestID: "callback-read")
      #expect(read.objectValue?["isError"] == .bool(false))
      session.end()
      let denied = try await fixture.runtime.callHostTool(
        name: "project.list", arguments: [:], projectID: "scope", origin: "probe",
        requestID: "callback-ended")
      #expect(denied.objectValue?["isError"] == .bool(true))
      #expect(throws: (any Error).self) {
        try fixture.runtime.requireHostInvocation(projectID: "scope", origin: "probe", id: id)
      }
      await retained.finish()
      #expect(
        directory.active(projectID: "scope", origin: "probe", includingRetainedWork: true).isEmpty
      )
      await fixture.close()
    } catch {
      await retained.finish()
      await fixture.close()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [true, false])
  func genericCallbacksResolveCommonConsentAndRefuseMixedSessions(sameSession: Bool) async throws {
    let fixture = try HostAuthorityFixture(requiresControlSession: true, multiplexed: true)
    defer { fixture.remove() }
    let firstSession = try fixture.session()
    let secondSession =
      sameSession
      ? firstSession
      : try fixture.session()
    let entered = HostServicePairBarrier()
    let finished = HostServicePairBarrier()
    fixture.peer.setHandler { _ in
      await entered.arrive()
      let result = try await fixture.runtime.callHostTool(
        name: "project.list", arguments: [:], projectID: "scope", origin: "probe",
        requestID: UUID().uuidString)
      await finished.arrive()
      return result
    }
    let args = JSONValue.object(["project_id": .string("scope"), "limit": .integer(1)])
    do {
      async let first = try await fixture.runtime.callToolAsync(
        name: "adapter.fixture.audit", arguments: args, context: .init(session: firstSession))
      async let second = try await fixture.runtime.callToolAsync(
        name: "adapter.fixture.audit", arguments: args, context: .init(session: secondSession))
      let results = try await [first, second]
      #expect(results.allSatisfy { $0.objectValue?["isError"] == .bool(!sameSession) })
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func vendorNeutralDiagnosticsUseTheAdmittedSemanticAction() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let result = try await fixture.during("fixture.audit", ["limit": .integer(1)]) {
      service, _ in
      try await .encoded(
        service.call(name: "host.diagnostics.snapshot", arguments: ["limit": .integer(1)]))
    }
    #expect(result.objectValue?["isError"] == .bool(false))
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["fixture.read", "codex.diagnostics.snapshot"])
  func privateActionsRequireExplicitMetadata(method: String) async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let result = try await fixture.during(method, ["limit": .integer(1)]) { service, _ in
      try await .encoded(
        service.call(name: "host.diagnostics.snapshot", arguments: ["limit": .integer(1)]))
    }
    #expect(result.objectValue?["isError"] == .bool(true))
    await fixture.close()
  }

  // The fixture commits each lease separately with the production disk durability settings.
  @Test(.timeLimit(.minutes(2))) func leaseCapacityDoesNotLoseAnExistingLiveCall() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let directory = try #require(fixture.peer.context(for: "scope")?.tools)
    let request = RetainedControlInvocation()
    _ = try await fixture.during("fixture.audit") { _, context in
      let id = try #require(context.admission?.hostInvocationID)
      await request.hold(
        id: id, lease: try directory.retain(id: id, projectID: "scope", origin: "probe"))
      return .object([:])
    }
    let id = try #require(await request.id)
    var leases: [MCPHostToolDirectory.InvocationLease] = []
    do {
      // The retained request owns the live call while the test measures capacity.
      // Each lease needs a durable commit, independently of the provider's reply.
      let path = try #require(fixture.connection.fileURL).path
      let store = HostCallRecordStore(connection: try GatewayDatabaseConnection(path: path))
      let initial = try #require(try store.record(id: id))
      try #require(initial.requestLeaseIDs.count == 1 && initial.workLeaseIDs.isEmpty)
      for _ in 1..<1024 {
        try Task.checkCancellation()
        leases.append(try directory.retainWork(id: id, projectID: "scope", origin: "probe"))
      }
      #expect(throws: (any Error).self) {
        try directory.retain(id: id, projectID: "scope", origin: "probe")
      }
      let record = try #require(try store.record(id: id))
      #expect(record.requestLeaseIDs == initial.requestLeaseIDs)
      #expect(record.workLeaseIDs.count == 1023)
      _ = try fixture.runtime.requireHostInvocation(projectID: "scope", origin: "probe", id: id)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
    for lease in leases { lease.finish() }
    await request.finish()
    let completed = try #require(try fixture.database.hostCallRecordStore().record(id: id))
    #expect(completed.lifecycle == .completed)
    #expect(completed.requestLeaseIDs.isEmpty && completed.workLeaseIDs.isEmpty)
  }

  @Test(.timeLimit(.minutes(5)), arguments: [false, true])
  func lifecycleOperationsUseTheHostLibraryWithReservedOperations(generic: Bool) async throws {
    let fixture = try HostAuthorityFixture(lifecycle: true, stoppableProvider: true)
    defer { fixture.remove() }
    let replies = HostReplies()
    _ = try await fixture.duringInvocation(
      "fixture.provision", ["name": .string("topic")], generic: generic
    ) { service, context in
      let invocationID = try #require(context.admission?.hostInvocationID)
      let operationID = try #require(context.admission?.hostOperationID)
      let call = try #require(try fixture.database.hostCallRecordStore().record(id: invocationID))
      #expect(call.admission.action == .projectProvision)
      #expect(
        call.admission.upstreamName == (generic ? "mcp.tools.call" : "adapter.fixture.provision"))
      let described = try await ProjectServiceCaller.describe(service, invocation: invocationID)
      #expect(described.result?["host_action"] == .string("projects.provision"))
      #expect(described.result?["risk"] == .string("project-write"))
      #expect(
        described.result?["operation"]?.objectValue?["state"] == .string("reserved"))
      #expect(
        described.result?["operation"]?.objectValue?["operation_id"]
          == .string(operationID.uuidString.lowercased()))
      replies.set("add", try await ProjectServiceCaller.add(service, context, name: "topic"))
      // A repeated callback returns the recorded outcome and starts nothing.
      replies.set("repeat", try await ProjectServiceCaller.add(service, context, name: "topic"))
      return .object([:])
    }
    let added = try #require(replies.get("add"))
    #expect(!added.isError)
    let envelope = try #require(added.result)
    #expect(replies.get("repeat")?.result == envelope)
    #expect(envelope["state"] == .string("completed"))
    #expect(envelope["action"] == .string("projects.provision"))
    #expect(envelope["source_project_id"] == .string("scope"))
    #expect(envelope["project_id"] == .string("scope"))
    #expect(envelope["error"] == .null)
    let operationID = try #require(envelope["operation_id"]?.stringValue)
    let created = try #require(envelope["result"]?.objectValue)
    #expect(created["worktree_id"] == .string(operationID))
    let projectID = try #require(created["project_id"]?.stringValue)
    #expect(projectID == "worktree-" + operationID)
    #expect(created["branch"] == .string("worktree/topic"))
    #expect(created["base"] == .string("main"))
    #expect(created["warnings"] == .array([]))
    let path = try #require(created["path"]?.stringValue)
    #expect(FileManager.default.fileExists(atPath: path))
    let records = try fixture.database.derivedProjects()
    #expect(records.map(\.projectID) == [projectID])
    #expect(records.first?.provenance.worktreeID.uuidString.lowercased() == operationID)

    try await fixture.refresh()
    // A linked checkout made outside the host lifecycle is foreign inventory.
    _ = try HostFixtureGit(home: fixture.root).run(
      [
        "worktree", "add", "-q", "-b", "foreign",
        fixture.root.deletingLastPathComponent().appendingPathComponent("foreign").path,
      ], at: fixture.root)
    _ = try await fixture.during("fixture.list") { service, context in
      replies.set("list", try await ProjectServiceCaller.list(service, context))
      return .object([:])
    }
    let worktrees = try #require(replies.get("list")?.result?["worktrees"]?.arrayValue)
    let host = try #require(
      worktrees.compactMap(\.objectValue).first { $0["owner"] == .string("host") })
    #expect(
      Set(host.keys) == [
        "path", "project_id", "branch", "base", "ahead", "behind", "dirty", "unavailable",
        "worktree_id", "owner",
      ])
    #expect(host["worktree_id"] == .string(operationID))
    #expect(host["project_id"] == .string(projectID))
    #expect(host["ahead"] == .integer(0) && host["behind"] == .integer(0))
    #expect(host["dirty"] == .bool(false) && host["unavailable"] == .null)
    let foreign = worktrees.compactMap(\.objectValue).filter { $0["owner"] == .string("foreign") }
    #expect(foreign.count == 2)
    #expect(foreign.allSatisfy { $0["worktree_id"] == .null && $0["project_id"] == .null })
    #expect(
      foreign.contains {
        $0["path"]?.stringValue.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
          == fixture.root.resolvingSymlinksInPath().path
      }, "\(foreign)")

    // A lost reply is recovered from the durable operation, without replaying Git.
    _ = try await fixture.during("fixture.read") { service, _ in
      replies.set(
        "inspect", try await ProjectServiceCaller.describe(service, operation: operationID))
      replies.set(
        "by-invocation",
        try await ProjectServiceCaller.describe(
          service, invocation: #require(UUID(uuidString: envelope["invocation_id"]!.stringValue!)))
      )
      replies.set(
        "unknown",
        try await ProjectServiceCaller.describe(
          service, operation: UUID().uuidString.lowercased()))
      return .object([:])
    }
    #expect(replies.get("inspect")?.result == envelope)
    #expect(replies.get("inspect")?.isError == false)
    #expect(replies.get("by-invocation")?.result == envelope)
    #expect(replies.get("unknown")?.code == "host.operation_not_found")
    #expect(try fixture.database.derivedProjects().count == 1)

    // The drain stops the initiating call's provider execution, so that call ends
    // before its callback settles; the host-owned removal completes regardless.
    let stopped = await #expect(throws: MCPHostServiceError.self) {
      try await fixture.during("fixture.remove", project: projectID) { service, context in
        replies.set("remove", try await ProjectServiceCaller.remove(service, context))
        return .object([:])
      }
    }
    #expect(stopped?.localizedDescription.hasSuffix("The fixture provider was stopped.") == true)
    let removed = try #require(try await replies.wait("remove").result)
    #expect(removed["state"] == .string("completed"), "\(removed)")
    #expect(removed["action"] == .string("projects.remove"))
    #expect(removed["source_project_id"] == .string("scope"))
    #expect(removed["project_id"] == .string(projectID))
    let removal = try #require(removed["result"]?.objectValue)
    #expect(removal["worktree_id"] == .string(operationID))
    #expect(removal["branch"] == .string("worktree/topic"))
    // The stopped writer ran with Full access, whose termination is best effort.
    #expect(removal["termination_warnings"]?.arrayValue?.count == 1)
    #expect(removal["oid"]?.stringValue?.count == 40)
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(try fixture.database.project(id: projectID) == nil)
    let removalID = try #require(removed["operation_id"]?.stringValue)
    // The captured source authorizes inspection after the selected project is gone.
    _ = try await fixture.during("fixture.read") { service, _ in
      replies.set(
        "after-removal", try await ProjectServiceCaller.describe(service, operation: removalID))
      return .object([:])
    }
    #expect(replies.get("after-removal")?.result == removed)
    await fixture.close()
  }

  /// A removal callback comes from the provider session that holds the selected worktree's
  /// use lease. The drain stops that provider with every other writer and its reply is
  /// lost with its channel; the host-owned removal still finishes under the call's own
  /// authorizations, and the source project reads the outcome by operation ID. Every
  /// boundary through the commit into teardown checks both authorities. The provider's
  /// authority ends with the worktree's teardown, which continues under the client's.
  @Test(
    .timeLimit(.minutes(5)),
    arguments: ["complete", "once", "client", "provider", "teardown-client", "unregister-client"])
  func providerInitiatedRemovalOutlivesTheDrainOfItsProvider(cause: String) async throws {
    let trigger = HostCommandTrigger()
    let journal = HostJournalTrigger()
    let fixture = try HostAuthorityFixture(
      lifecycle: true, stoppableProvider: true, beforeHostCommand: { try trigger.observe($0) },
      journalIO: .init(beforeDirectorySync: { try journal.observe() }))
    defer { fixture.remove() }
    let replies = HostReplies()
    // A sandboxed provider cannot write the source checkout, so the Full access provider
    // creates the worktree. Closing its callback channel after the claim abandons neither
    // the effect nor its settlement.
    _ = try await fixture.during("fixture.provision", ["name": .string("topic")]) { _, context in
      replies.setID("add", try #require(context.admission?.hostOperationID))
      let reply = try await fixture.providerCallback(
        context, project: "scope", "host.projects.worktree_add", ["name": .string("topic")],
        closeAfterClaim: true)
      #expect(reply == nil)
      return .object([:])
    }
    let creation = try await fixture.settled(try #require(replies.id("add")))
    #expect(creation.state == .completed, "\(creation)")
    let projectID = try #require(try fixture.database.derivedProjects().first?.projectID)
    let path = try #require(try fixture.database.project(id: projectID)?.rootPath)
    try await fixture.useSandboxedProvider()

    if cause == "once" { try fixture.setClientProjectAccess(.notGranted) }
    // The client's grant ends at the dirty check after the drain; the provider's approval
    // at the last check before the commit into teardown.
    trigger.arm(cause == "client" || cause == "provider", at: cause == "client" ? 1 : 2) {
      if cause == "client" { try fixture.setClientProjectAccess(.denied) }
      if cause == "provider" { try fixture.withdrawProviderApproval() }
    }
    if cause == "teardown-client" || cause == "unregister-client" {
      let storage = try #require(fixture.database.worktreeStorage)
      journal.arm(
        path: storage.journals.appendingPathComponent("removals/" + projectID + ".json"),
        phase: cause == "teardown-client" ? "content" : "unregistering"
      ) {
        #expect(try fixture.database.derivedProjects().first?.state == .removing)
        try fixture.setClientProjectAccess(.denied)
      }
    }
    let ended = await #expect(throws: (any Error).self) {
      try await fixture.duringAdmitted(
        "fixture.remove", project: projectID, onlyThisTime: cause == "once"
      ) { _, context in
        replies.setID("remove", try #require(context.admission?.hostOperationID))
        let provider = try #require(
          (context.executionAuthority as? PreparedExecutionContext)?.provider)
        replies.setID("provider", provider.providerAuthorization.id)
        // The drain stops this provider before capture; its reply is never delivered.
        let reply = try await fixture.providerCallback(
          context, project: projectID, "host.projects.worktree_remove",
          retainWriterThroughClose: cause == "complete")
        #expect(reply == nil)
        return .object([:])
      }
    }
    #expect(
      ended?.localizedDescription.hasSuffix("The fixture provider was stopped.") == true,
      "\(String(describing: ended))")
    let removalID = try #require(replies.id("remove"))
    let removal = try await fixture.settled(removalID)
    switch cause {
    case "complete", "once":
      #expect(removal.state == .completed, "\(removal)")
      #expect(!FileManager.default.fileExists(atPath: path))
      #expect(try fixture.database.project(id: projectID) == nil)
      // The commit into teardown ended the provider's authority over the worktree.
      #expect(throws: (any Error).self) {
        try fixture.runtime.permissionRuntime.service.validateAuthorization(
          #require(replies.id("provider")))
      }
      if cause == "once" { try fixture.setClientProjectAccess(.granted(.write)) }
      // A sandboxed provider reads, but cannot write, the source checkout.
      _ = try await fixture.during("fixture.list") { service, _ in
        replies.set(
          "inspect",
          try await ProjectServiceCaller.describe(service, operation: removalID.uuidString))
        return .object([:])
      }
      let inspected = try #require(replies.get("inspect")?.result)
      #expect(inspected == MCPHostOperations.envelope(removal).objectValue)
      #expect(inspected["state"] == .string("completed"))
    case "teardown-client", "unregister-client":
      #expect(journal.fired)
      #expect(removal.state == .recoveryRequired)
      #expect(removal.error != nil)
      #expect(try fixture.database.derivedProjects().first?.state == .removing)
      #expect(FileManager.default.fileExists(atPath: path) == (cause == "teardown-client"))
    default:
      // The invalidation fails the next boundary; the record settles from the journal.
      #expect(trigger.fired)
      #expect([.failed, .recoveryRequired].contains(removal.state), "\(removal)")
      #expect(removal.error != nil)
      #expect(FileManager.default.fileExists(atPath: path))
      #expect(try fixture.database.derivedProjects().first?.state == .active)
    }
    await fixture.close()
  }

  @Test(
    .timeLimit(.minutes(5)),
    arguments: [
      "complete", "once", "client-before", "provider-before", "client-teardown",
      "client-unregister", "provider-after", "provider-retired-after",
    ])
  func ordinaryBuiltinLifecycleCallbackOwnsCleanupWithoutParentLifecycleMetadata(cause: String)
    async throws
  {
    let command = HostCommandTrigger()
    let journal = HostJournalTrigger()
    let proofIDs = HostReplies()
    let fixture = try HostAuthorityFixture(
      lifecycle: true, builtinLifecycle: true, stoppableProvider: true,
      beforeHostCommand: { try command.observe($0) },
      journalIO: .init(beforeDirectorySync: { try journal.observe() }))
    defer { fixture.remove() }
    _ = try await fixture.during("fixture.read") { _, context in
      #expect(context.admission?.hostOperationID == nil)
      let invocation = try fixture.runtime.requireHostInvocation(
        projectID: "scope", origin: "probe", id: #require(context.admission?.hostInvocationID))
      #expect(invocation.admittedCapability.hostServiceAction == nil)
      let reply = try await fixture.providerCallback(
        context, project: "scope", "git.worktree_add", ["name": .string("builtin")],
        closeAfterClaim: true)
      #expect(reply == nil)
      return .object([:])
    }
    try await fixture.waitForBuiltin("git.worktree_add")
    let record = try #require(try fixture.database.derivedProjects().first)
    let projectID = record.projectID
    try await fixture.useSandboxedProvider()
    if cause == "once" { try fixture.setClientProjectAccess(.notGranted) }
    if cause == "client-before" || cause == "provider-before" {
      command.arm(true, at: 2) {
        if cause == "client-before" {
          try fixture.setClientProjectAccess(.denied)
        } else {
          try fixture.withdrawProviderApproval()
        }
      }
    }
    if ["client-teardown", "client-unregister", "provider-after", "provider-retired-after"]
      .contains(cause)
    {
      let storage = try #require(fixture.database.worktreeStorage)
      journal.arm(
        path: storage.journals.appendingPathComponent("removals/" + projectID + ".json"),
        phase: cause == "client-unregister" ? "unregistering" : "content"
      ) {
        #expect(try fixture.database.derivedProjects().first?.state == .removing)
        let clientID = try #require(proofIDs.id("client"))
        let providerID = try #require(proofIDs.id("provider"))
        let before = try fixture.builtinCallbackAuthorities(
          projectID: projectID, clientID: clientID, providerID: providerID)
        #expect(!before.originalClient.revoked && !before.client.revoked)
        #expect(before.clientCanWrite)
        if cause == "provider-retired-after" {
          try fixture.retireProviderSource()
        } else if cause == "provider-after" {
          try fixture.withdrawProviderApproval()
        } else {
          try fixture.setClientProjectAccess(.denied)
        }
        let after = try fixture.builtinCallbackAuthorities(
          projectID: projectID, clientID: clientID, providerID: providerID)
        #expect(after.client.id == before.client.id && after.provider.id == before.provider.id)
        #expect(!before.originalProvider.revoked || after.originalProvider.revoked)
        #expect(!before.provider.revoked || after.provider.revoked)
        let clientRevoked = cause != "provider-after"
        #expect(after.originalClient.revoked == clientRevoked)
        #expect(after.client.revoked == clientRevoked)
        #expect(after.clientCanWrite == !clientRevoked)
        if cause == "provider-after" || cause == "provider-retired-after" {
          #expect(after.originalProvider.revoked)
          #expect(after.provider.revoked)
        }
      }
    }
    let ended = await #expect(throws: (any Error).self) {
      try await fixture.duringAdmitted(
        "fixture.read", project: projectID, onlyThisTime: cause == "once"
      ) { _, context in
        #expect(context.admission?.hostOperationID == nil)
        let invocation = try fixture.runtime.requireHostInvocation(
          projectID: projectID, origin: "probe", id: #require(context.admission?.hostInvocationID))
        #expect(invocation.admittedCapability.hostServiceAction == nil)
        let execution = try #require(context.executionAuthority as? PreparedExecutionContext)
        let provider = try #require(execution.provider)
        proofIDs.setID("client", try #require(provider.delegatingAuthorization).id)
        proofIDs.setID("provider", provider.providerAuthorization.id)
        let reply = try await fixture.providerCallback(
          context, project: projectID, "git.worktree_remove")
        #expect(reply == nil)
        return .object([:])
      }
    }
    #expect(ended?.localizedDescription.hasSuffix("The fixture provider was stopped.") == true)
    try await fixture.waitForBuiltin("git.worktree_remove")
    try fixture.runtime.permissionRuntime.store.readWithDatabase { _, ledger in
      let callbacks = ledger.authorizations.values.filter {
        $0.invocation.tool == "git.worktree_remove" && $0.invocation.projectID == projectID
      }
      #expect(callbacks.count == 2)
      let allCallbacksFinished = callbacks.allSatisfy { $0.finished }
      #expect(allCallbacksFinished)
      #expect(
        callbacks.allSatisfy { proof in
          proof.basis.contains {
            if case .worktreeAuthority = $0 { return true }
            return false
          }
        })
    }
    let remaining = try fixture.database.derivedProjects().first
    if cause == "complete" || cause == "once" || cause == "provider-after" {
      #expect(remaining == nil)
      #expect(!FileManager.default.fileExists(atPath: record.root))
      #expect(try fixture.database.project(id: projectID) == nil)
      if cause == "provider-after" { #expect(journal.fired) }
    } else {
      #expect(remaining?.state == (cause.hasSuffix("before") ? .active : .removing))
      #expect(FileManager.default.fileExists(atPath: record.root) == (cause != "client-unregister"))
      #expect(cause.hasSuffix("before") ? command.fired : journal.fired)
      if cause == "provider-retired-after" {
        let storage = try #require(fixture.database.worktreeStorage)
        let data = try Data(
          contentsOf: storage.journals.appendingPathComponent("removals/" + projectID + ".json"))
        let removal = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(removal["phase"] as? String == "content")
        #expect(try fixture.database.project(id: projectID) != nil)
      }
    }
    let privateOperationCount = try await fixture.connection.writer.read {
      try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hostOperations")
    }
    #expect(privateOperationCount == 0)
    await fixture.close()
    #expect(!fixture.runtime.ownedWork.snapshot.contains { $0.kind == .invocation })
  }

  @Test(.timeLimit(.minutes(2)), arguments: [false, true])
  func creationCallbackUsesCapturedCustomBranchWhenOmitted(mismatch: Bool) async throws {
    let fixture = try HostAuthorityFixture(lifecycle: true)
    defer { fixture.remove() }
    let replies = HostReplies()
    _ = try await fixture.during(
      "fixture.provision", ["name": .string("topic"), "branch": .string("feature/topic")]
    ) { service, context in
      replies.set(
        "add",
        try await ProjectServiceCaller.add(
          service, context, name: "topic", branch: mismatch ? "feature/other" : nil))
      return .object([:])
    }
    let reply = try #require(replies.get("add"))
    if mismatch {
      #expect(reply.code == "host.operation_conflict")
      #expect(try fixture.database.derivedProjects().isEmpty)
    } else {
      #expect(!reply.isError)
      #expect(reply.result?["result"]?.objectValue?["branch"] == .string("feature/topic"))
      #expect(try fixture.database.derivedProjects().first?.worktree?.branchName == "feature/topic")
    }
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(2)))
  func explicitNullCreationFieldsUseReservedDefaults() async throws {
    let tool = try #require(
      MCPBoundHostServices.tools.first { $0.name == "host.projects.worktree_add" })
    let schema = try #require(try JSONValue.encoded(tool.inputSchema).objectValue)
    let properties = try #require(schema["properties"]?.objectValue)
    let nameSchema = try #require(properties["name"])
    for key in ["branch", "base"] {
      let alternatives = try #require(properties[key]?.objectValue?["anyOf"]?.arrayValue)
      #expect(alternatives.contains(.object(["type": .string("null")])))
      #expect(alternatives.contains(nameSchema))
    }

    let fixture = try HostAuthorityFixture(lifecycle: true)
    defer { fixture.remove() }
    let selection: [String: JSONValue] = ["name": .string("topic"), "branch": .null, "base": .null]
    _ = try await fixture.during("fixture.provision", selection) { service, context in
      let arguments = try ProjectServiceCaller.identifiers(context).merging(selection) { _, field in
        field
      }
      let reply = try await ProjectServiceCaller.reply(
        service.call(name: "host.projects.worktree_add", arguments: arguments))
      let created = try #require(reply.result?["result"]?.objectValue)
      #expect(created["branch"] == .string("worktree/topic"))
      #expect(created["base"] == .string("main"))
      return .object([:])
    }
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(2)), arguments: ["unchanged", "client", "provider"])
  func operationInspectionRequiresBothPrincipalsCurrentOriginalWriteEffect(downgrade: String)
    async throws
  {
    let fixture = try HostAuthorityFixture(lifecycle: true)
    defer { fixture.remove() }
    let replies = HostReplies()
    _ = try await fixture.during("fixture.provision", ["name": .string("topic")]) {
      service, context in
      replies.setID("operation", try #require(context.admission?.hostOperationID))
      replies.set("add", try await ProjectServiceCaller.add(service, context, name: "topic"))
      return .object([:])
    }
    #expect(replies.get("add")?.isError == false)
    try await fixture.useSandboxedProvider()
    if downgrade == "provider" { try fixture.setProviderProjectAccess(.granted(.read)) }
    if downgrade == "client" { try fixture.setClientProjectAccess(.granted(.read)) }
    let operation = try #require(replies.id("operation"))
    _ = try await fixture.during("fixture.list") { service, _ in
      let before = try fixture.runtime.permissionRuntime.store.readWithDatabase { _, ledger in
        (Set(ledger.authorizations.keys), Set(ledger.requests.keys))
      }
      replies.set(
        "inspect", try await ProjectServiceCaller.describe(service, operation: operation.uuidString)
      )
      let after = try fixture.runtime.permissionRuntime.store.readWithDatabase { _, ledger in
        (Set(ledger.authorizations.keys), Set(ledger.requests.keys))
      }
      #expect(before.0 == after.0 && before.1 == after.1)
      return .object([:])
    }
    #expect(replies.get("inspect")?.isError == (downgrade != "unchanged"))
    if downgrade != "unchanged" {
      #expect(replies.get("inspect")?.code == "host.operation_not_found")
    }
    #expect(try fixture.database.derivedProjects().count == 1)
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(2)), arguments: ["client", "provider"])
  func operationInspectionPreservesCurrentConsumedOnceEvidence(principal: String) async throws {
    let fixture = try HostAuthorityFixture(lifecycle: true)
    defer { fixture.remove() }
    _ = try await fixture.during("fixture.provision", ["name": .string("topic")]) {
      service, context in
      let added = try await ProjectServiceCaller.add(service, context, name: "topic")
      #expect(!added.isError)
      return .object([:])
    }
    let projectID = try #require(try fixture.database.derivedProjects().first?.projectID)
    try await fixture.useSandboxedProvider()
    if principal == "client" {
      try fixture.setClientProjectAccess(.notGranted)
    } else {
      try fixture.setProviderProjectAccess(.notGranted)
    }
    let replies = HostReplies()
    _ = try await fixture.duringAdmitted(
      "fixture.remove", project: projectID, onlyThisTime: true
    ) { service, context in
      let execution = try #require(context.executionAuthority as? PreparedExecutionContext)
      let binding = try #require(execution.provider)
      let selectedProofID: UUID? =
        principal == "client"
        ? binding.delegatingAuthorization?.id : binding.providerAuthorization.id
      let proofID = try #require(selectedProofID)
      let operationID = try #require(context.admission?.hostOperationID)
      replies.setID("operation", operationID)
      let invocationID = try #require(context.admission?.hostInvocationID)
      // Keep the reservation live: executing removal would drain this provider.
      let before = try fixture.runtime.permissionRuntime.store.readWithDatabase { _, ledger in
        let proof = try #require(ledger.authorizations[proofID])
        #expect(proof.executionID == execution.executionID)
        #expect(!proof.requestIDs.isEmpty)
        for id in proof.requestIDs {
          #expect(ledger.requests[id]?.status == .consumed(proofID))
        }
        return (ledger.requests, Set(ledger.authorizations.keys))
      }
      let byInvocation = try await ProjectServiceCaller.describe(service, invocation: invocationID)
      let byOperation = try await ProjectServiceCaller.describe(
        service, operation: operationID.uuidString)
      #expect(!byInvocation.isError && !byOperation.isError)
      #expect(byOperation.result == byInvocation.result?["operation"]?.objectValue)
      #expect(byOperation.result?["state"] == .string("reserved"))
      let after = try fixture.runtime.permissionRuntime.store.readWithDatabase { _, ledger in
        (ledger.requests, Set(ledger.authorizations.keys))
      }
      #expect(before.0 == after.0 && before.1 == after.1)
      return .object([:])
    }
    let operationID = try #require(replies.id("operation"))
    _ = try await fixture.duringAdmitted(
      "fixture.list", project: projectID, onlyThisTime: true
    ) { service, _ in
      let before = try fixture.runtime.permissionRuntime.store.readWithDatabase { _, ledger in
        (ledger.requests, Set(ledger.authorizations.keys))
      }
      let unrelated = try await ProjectServiceCaller.describe(
        service, operation: operationID.uuidString)
      #expect(unrelated.isError && unrelated.code == "host.operation_not_found")
      let after = try fixture.runtime.permissionRuntime.store.readWithDatabase { _, ledger in
        (ledger.requests, Set(ledger.authorizations.keys))
      }
      #expect(before.0 == after.0 && before.1 == after.1)
      return .object([:])
    }
    #expect(try fixture.database.derivedProjects().count == 1)
    await fixture.close()
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["name", "branch", "base", "unknown-operation", "wrong-action", "revoked"])
  func lifecycleCallbacksCannotChangeTheCapturedSelection(attack: String) async throws {
    let fixture = try HostAuthorityFixture(lifecycle: true)
    defer { fixture.remove() }
    let replies = HostReplies()
    let method = attack == "wrong-action" ? "fixture.audit" : "fixture.provision"
    let arguments: [String: JSONValue] =
      attack == "wrong-action" ? ["limit": .integer(1)] : ["name": .string("topic")]
    _ = try? await fixture.during(method, arguments) { service, context in
      if attack == "revoked" {
        var grant = try #require(fixture.database.profiles().first { $0.id == .chatGPTOperate })
        try grant.permissions.set(.denied, for: .project("scope"))
        try fixture.database.saveProfile(grant)
      }
      var invocation = context
      if attack == "unknown-operation" || attack == "wrong-action" {
        invocation = InvocationContext(
          admission: InvocationAdmission(
            descriptor: .init(
              id: "fixture", risk: .projectWrite, requirement: .none,
              mcpReference: .init(serverID: "probe", toolName: "fixture.provision"),
              hostServiceAction: .projectProvision),
            hostInvocationID: context.admission?.hostInvocationID, hostOperationID: UUID()))
      }
      replies.set(
        "add",
        try await ProjectServiceCaller.add(
          service, invocation, name: attack == "name" ? "other" : "topic",
          branch: attack == "branch" ? "worktree/other" : nil,
          base: attack == "base" ? "other" : nil))
      return .object([:])
    }
    let reply = try #require(replies.get("add"))
    #expect(reply.isError)
    switch attack {
    case "name", "branch", "base": #expect(reply.code == "host.operation_conflict")
    case "unknown-operation": #expect(reply.code == "host.operation_not_found")
    default:
      #expect(reply.code == "host.service_denied" || reply.result?["state"] == .string("failed"))
    }
    #expect(try fixture.database.derivedProjects().isEmpty)
    #expect(try fixture.unfinishedOperations().isEmpty)
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func unclaimedReservationsEndFailedAndCannotBeClaimedLater() async throws {
    let fixture = try HostAuthorityFixture(lifecycle: true)
    defer { fixture.remove() }
    let reserved = HostReplies()
    _ = try await fixture.during("fixture.provision", ["name": .string("topic")]) { _, context in
      reserved.setID("operation", try #require(context.admission?.hostOperationID))
      return .object([:])
    }
    let stale = try #require(reserved.id("operation"))
    let failed = try #require(
      try HostOperationStore(connection: fixture.connection).operation(id: stale))
    #expect(failed.state == .failed)
    #expect(failed.error?.code == "host.service_denied")
    let replies = HostReplies()
    _ = try await fixture.during("fixture.provision", ["name": .string("topic")]) {
      service, context in
      let replayed = InvocationContext(
        admission: InvocationAdmission(
          descriptor: .init(
            id: "fixture", risk: .projectWrite, requirement: .none,
            mcpReference: .init(serverID: "probe", toolName: "fixture.provision"),
            hostServiceAction: .projectProvision),
          hostInvocationID: context.admission?.hostInvocationID, hostOperationID: stale))
      replies.set("replay", try await ProjectServiceCaller.add(service, replayed, name: "topic"))
      replies.set(
        "inspect", try await ProjectServiceCaller.describe(service, operation: stale.uuidString))
      return .object([:])
    }
    #expect(replies.get("replay")?.code == "host.operation_conflict")
    #expect(replies.get("inspect")?.isError == false)
    #expect(replies.get("inspect")?.result?["state"] == .string("failed"))
    #expect(try fixture.database.derivedProjects().isEmpty)
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["capability", "session", "completed", "work-only"])
  func lifecycleClaimRechecksCurrentAuthority(change: String) async throws {
    let fixture = try HostAuthorityFixture(lifecycle: true)
    defer { fixture.remove() }
    let session = try fixture.session()
    let directory = try #require(fixture.peer.context(for: "scope")?.tools)
    let replies = HostReplies()
    _ = try? await fixture.during(
      "fixture.provision", ["name": .string("topic")], context: .init(session: session)
    ) { service, context in
      let id = try #require(context.admission?.hostInvocationID)
      let active = try #require(
        directory.active(projectID: "scope", origin: "probe").first { $0.id == id })
      var retained: MCPHostToolDirectory.InvocationLease?
      switch change {
      case "capability":
        var profile = try #require(fixture.database.profiles().first { $0.id == .chatGPTOperate })
        profile.permissions = .init()
        try fixture.database.saveProfile(profile)
      case "session": session.end()
      case "work-only":
        retained = try directory.retainWork(id: id, projectID: "scope", origin: "probe")
        directory.end(active)
      default: directory.end(active)
      }
      replies.set("add", try await ProjectServiceCaller.add(service, context, name: "topic"))
      retained?.finish()
      return .object([:])
    }
    #expect(replies.get("add")?.isError == true)
    #expect(try fixture.database.derivedProjects().isEmpty)
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func unknownAndRetiredMethodsAreOutsideTheContract() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    for name in [
      "host.workspaces.register", "host.workspaces.authorize_removal",
      "host.workspaces.unregister", "host.projects.worktree_rename",
    ] {
      let reply = try ProjectServiceCaller.reply(
        await fixture.service.call(name: name, arguments: [:]))
      #expect(reply.isError && reply.code == "host.unknown_method")
    }
    let invalid = try ProjectServiceCaller.reply(
      await fixture.service.call(
        name: "host.invocations.describe",
        arguments: ["invocation_id": .string(UUID().uuidString), "worktree": .object([:])]))
    #expect(invalid.isError && invalid.code == "host.service_denied")
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func privateServerAndLaunchContextAdvertiseTheProjectContract() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let captured = try #require(fixture.peer.context(for: "scope"))
    let launch = try JSONValue.encoded(captured.launchMetadata).objectValue
    #expect(launch?["hostServiceContract"] == .string("projects-v1"))
    #expect(launch?["project"]?.objectValue?["id"] == .string("scope"))
    // The private server initializes over the channel bound to the call's provider.
    _ = try await fixture.during("fixture.read") { _, context in
      let execution = try #require(context.executionAuthority as? PreparedExecutionContext)
      let session = try captured.makeHostSession(
        server: fixture.registration, execution: execution)
      let initialize = try await ProjectServiceCaller.initialize(
        session.providerChannel.takeEndpoint())
      try ProjectServiceCaller.requireContract(initialize)
      await session.close()
      return .object([:])
    }
    // The caller refuses an older or mismatched host before any lifecycle callback.
    for observed in [nil, "projects-v0"] as [String?] {
      var capabilities: [String: JSONValue] = ["tools": .object([:])]
      if let observed {
        capabilities["experimental"] = .object([
          MCPHostServiceContract.capabilityKey: .string(observed)
        ])
      }
      #expect(throws: MCPHostServiceContractError(observed: observed)) {
        try ProjectServiceCaller.requireContract(["capabilities": .object(capabilities)])
      }
    }
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func concurrentIdenticalActionsNeverSelectAnArbitraryInvocation() async throws {
    let fixture = try HostAuthorityFixture(multiplexed: true)
    defer { fixture.remove() }
    let entered = HostServicePairBarrier()
    let finished = HostServicePairBarrier()
    fixture.peer.setHandler { _ in
      await entered.arrive()
      let result = try await fixture.service.call(
        name: "host.diagnostics.snapshot", arguments: ["limit": .integer(1)])
      let encoded = try JSONValue.encoded(result)
      #expect(
        encoded.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue?
          .contains("one matching live gateway invocation") == true)
      await finished.arrive()
      return encoded
    }
    let args = JSONValue.object(["project_id": .string("scope"), "limit": .integer(1)])
    async let first = fixture.runtime.callToolAsync(
      name: "adapter.fixture.audit", arguments: args, context: .empty)
    async let second = fixture.runtime.callToolAsync(
      name: "adapter.fixture.audit", arguments: args, context: .empty)
    let results = try await [first, second]
    #expect(results.allSatisfy { $0.objectValue?["isError"] == .bool(true) })
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func genericHostCallbackRequiresProjectWhenSelectionIsAmbiguous() async throws {
    let fixture = try HostAuthorityFixture(additionalProject: true)
    defer { fixture.remove() }
    let tool = try #require(
      fixture.runtime.listTools(context: .empty).first { $0.name == "mcp.tools.call" })
    let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
    #expect(properties["project_id"]?.objectValue?["type"] == .string("string"))
    do {
      _ = try await fixture.genericDiagnostics(projectID: nil)
      Issue.record("An ambiguous project must be rejected before invoking the plugin.")
    } catch {
      #expect(String(describing: error).contains("project_required"))
    }
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func genericDiagnosticsBindTheHostProject(explicitProject: Bool) async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let result = try await fixture.genericDiagnostics(
      projectID: explicitProject ? "scope" : nil)
    #expect(result.objectValue?["isError"] == .bool(false))
    #expect(fixture.payload(result)["owner"]?.objectValue?["project_id"] == .string("scope"))
    await fixture.close()
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["no-invocation", "wrong-method", "extra-owner", "caller-time"])
  func diagnosticCallbacksRequireAnExactLiveInvocation(attack: String) async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    var arguments: [String: JSONValue] = ["limit": .number(1)]
    if attack == "extra-owner" { arguments["profile_id"] = .string("local-admin") }
    if attack == "caller-time" { arguments["now"] = .number(1) }
    let result: JSONValue
    if attack == "no-invocation" {
      result = try await fixture.direct("host.diagnostics.snapshot", arguments)
    } else {
      let args = arguments
      result = try await fixture.during(
        attack == "wrong-method" ? "fixture.read" : "fixture.audit",
        ["limit": .number(1)]
      ) { service, _ in
        try await .encoded(service.call(name: "host.diagnostics.snapshot", arguments: args))
      }
    }
    #expect(result.objectValue?["isError"] == .bool(true))
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func invocationEndsOnBothSuccessAndError() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    for fails in [false, true] {
      if fails {
        await #expect(throws: (any Error).self) {
          try await fixture.during("fixture.audit") { _, _ in
            throw MCPHostServiceError.denied("Fixture failure")
          }
        }
      } else {
        _ = try await fixture.during("fixture.audit") { _, _ in .object([:]) }
      }
      let result = try await fixture.direct("host.diagnostics.snapshot", ["limit": .number(1)])
      #expect(result.objectValue?["isError"] == .bool(true))
    }
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func privateServiceSurfaceIsNotExposedUpstream() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    #expect(try !fixture.runtime.listTools(context: .empty).contains { $0.name.hasPrefix("host.") })
    #expect(
      Set(MCPBoundHostServices.tools.map(\.name)) == [
        "host.invocations.describe", "host.projects.worktree_add", "host.projects.worktree_list",
        "host.projects.worktree_remove", "host.diagnostics.snapshot",
      ])
    let result = try await fixture.direct("host.unknown", [:])
    #expect(result.objectValue?["isError"] == .bool(true))
    #expect(
      result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]
        == .string("host.unknown_method"))
    await fixture.close()
    #expect(await fixture.service.cleanupConfirmed)
    await #expect(throws: (any Error).self) {
      try await fixture.service.call(
        name: "host.diagnostics.snapshot", arguments: ["limit": .number(1)])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func genericInvocationContextIsHostBoundAndExpiresWithTheCall() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let response = try await fixture.during("fixture.read", ["item": .string("sample")]) {
      service, context in
      let id = try #require(context.admission?.hostInvocationID)
      return try await .encoded(
        service.call(
          name: "host.invocations.describe", arguments: ["invocation_id": .string(id.uuidString)]))
    }
    let value = try #require(
      response.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
    #expect(value["format_version"] == .integer(1))
    #expect(value["principal_id"] == .string("fixture-principal"))
    #expect(value["project_id"] == .string("scope"))
    #expect(value["risk"] == .string("project-write"))
    #expect(value["operation"] == .null)
    #expect(value["registration_id"] == .string("probe"))
    #expect(value["profile_id"] == .string("chatgpt-operate"))
    #expect(value["tool"] == .string("fixture.read"))
    #expect(value["capability_id"] == .string("adapter.fixture.read"))
    #expect(value["authorization_revision"]?.intValue != nil)
    #expect(
      value["generation_id"]
        == fixture.peer.context(for: "scope").map {
          .string($0.launchMetadata.runtimeID.uuidString)
        })
    #expect(value["plugin_id"] == .null)
    #expect(value["contribution_id"] == .null)
    let id = try #require(value["invocation_id"])
    let callID = try #require(id.stringValue.flatMap(UUID.init(uuidString:)))
    #expect(try fixture.database.hostCallRecordStore().record(id: callID)?.lifecycle == .completed)
    let expired = try await fixture.direct("host.invocations.describe", ["invocation_id": id])
    #expect(expired.objectValue?["isError"] == .bool(true))
    await fixture.close()
  }

  @Test(
    .timeLimit(.minutes(1)), arguments: ["foreign-channel", "forged-id", "forged-owner", "revoked"])
  func genericInvocationContextRejectsForeignOrRevokedAuthority(attack: String) async throws {
    let evidence = InvocationCallbackEvidence()
    let fixture = try HostAuthorityFixture()
    let other = try HostAuthorityFixture()
    defer {
      fixture.remove()
      other.remove()
    }
    let response = try await checkedInvocationResult(
      evidence: evidence, revoked: attack == "revoked"
    ) {
      try await fixture.during("fixture.read") { service, context in
        evidence.entered()
        let id = try #require(context.admission?.hostInvocationID)
        var arguments: [String: JSONValue] = ["invocation_id": .string(id.uuidString)]
        if attack == "forged-id" { arguments["invocation_id"] = .string(UUID().uuidString) }
        if attack == "forged-owner" { arguments["principal_id"] = .string("other") }
        if attack == "revoked" {
          var profile = try #require(fixture.database.profiles().first { $0.id == .chatGPTOperate })
          profile.permissions = .init()
          try fixture.database.saveProfile(profile)
          evidence.revoked()
        }
        let callback = try await (attack == "foreign-channel" ? other.service : service).call(
          name: "host.invocations.describe", arguments: arguments)
        #expect(callback.isError == true)
        evidence.checked()
        return try .encoded(callback)
      }
    }
    if let response {
      #expect(response.objectValue?["isError"] == .bool(true))
    }
    await fixture.close()
    await other.close()
  }

}

private actor HostServicePairBarrier {
  private var waiter: CheckedContinuation<Void, Never>?
  func arrive() async {
    if let waiter {
      self.waiter = nil
      waiter.resume()
    } else {
      await withCheckedContinuation { waiter = $0 }
    }
  }
}

private final class InvocationCallbackEvidence: @unchecked Sendable {
  private let lock = NSLock()
  private var callbackRan = false
  private var authorityRevoked = false
  private var checkCompleted = false

  func entered() { lock.withLock { callbackRan = true } }
  func revoked() { lock.withLock { authorityRevoked = true } }
  func checked() { lock.withLock { checkCompleted = true } }

  func verify(revoked: Bool) {
    let state = lock.withLock { (callbackRan, authorityRevoked, checkCompleted) }
    #expect(state.0, "The invocation callback must run")
    #expect(state.1 == revoked, "The intended authority mutation must complete")
    #expect(state.2, "The callback authorization check must complete")
  }
}

private func checkedInvocationResult(
  evidence: InvocationCallbackEvidence, revoked: Bool, _ call: () async throws -> JSONValue
) async throws -> JSONValue? {
  defer { evidence.verify(revoked: revoked) }
  do {
    let result = try await call()
    #expect(!revoked, "Revoked execution returned a result")
    return result
  } catch PermissionModelError.invalidAuthorization {
    #expect(revoked, "A live execution lost authorization")
    return nil
  }
}

/// The native registry receives the same concrete worktree service as the provider
/// peer, with journal observation installed before either captures that service.
private struct HostWorktreeJournalProviders: GatewayToolProviderFactory {
  let base: any GatewayToolProviderFactory
  let journalIO: WorktreeJournalIO

  func makeProviders(
    configuration: GatewayConfiguration, commandRunner: any CommandRunning,
    processManager: any ProcessManaging, shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient, hostContext: MCPHostContext
  ) -> GatewayToolRegistry {
    var hostContext = hostContext
    if var worktrees = hostContext.worktrees as? GatewayWorktreeService {
      worktrees.journalIO = journalIO
      hostContext.worktrees = worktrees
    }
    return base.makeProviders(
      configuration: configuration, commandRunner: commandRunner,
      processManager: processManager, shellManager: shellManager, mcpClient: mcpClient,
      hostContext: hostContext)
  }
}

private struct HostBuiltinCallbackAuthorities: Sendable {
  let client: InvocationAuthorization
  let provider: InvocationAuthorization
  let originalClient: InvocationAuthorization
  let originalProvider: InvocationAuthorization
  let clientCanWrite: Bool
}

private final class HostAuthorityFixture: @unchecked Sendable {
  let root: URL
  let connection: GatewayDatabaseConnection
  let database: GatewayDatabase
  private(set) var runtime: GatewayRuntime
  private(set) var service: MCPBoundHostServices
  let peer: HostServiceProbe
  let context: ExecutionContext
  let registration: MCPServerConfig
  private(set) var review: GatewayProviderReview
  private let storageRoot: URL
  private let make: () throws -> GatewayRuntime
  private var retired: [GatewayRuntime] = []
  private var services: [MCPBoundHostServices] = []

  /// `lifecycle` uses a real source repository, host Git and worktree storage;
  /// `stoppableProvider` ends a call whose provider execution the host stops, and
  /// `beforeHostCommand` observes every host-launched command before it starts.
  init(
    lifecycle: Bool = false, builtinLifecycle: Bool = false, additionalProject: Bool = false,
    requiresControlSession: Bool = false, multiplexed: Bool = false,
    callbackTimeout: TimeInterval = 10, storageDirectory: URL? = nil,
    stoppableProvider: Bool = false,
    beforeHostCommand: (@Sendable (ExecutionCommand) throws -> Void)? = nil,
    journalIO: WorktreeJournalIO = .init()
  ) throws {
    // Host Git lifecycle work runs inside the probe's callback window.
    peer = HostServiceProbe(
      multiplexed: multiplexed,
      callbackTimeout: lifecycle ? max(callbackTimeout, 120) : callbackTimeout, journalIO: journalIO
    )
    let requested =
      storageDirectory
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
    storageRoot = lifecycle ? try ProjectPathResolver.canonicalProject(requested) : requested
    root = storageRoot.appendingPathComponent("scope")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Host storage stays outside the source repository.
    let host = lifecycle ? storageRoot.appendingPathComponent("host") : storageRoot
    try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
    if storageDirectory != nil {
      database = try GatewayDatabase(path: host.appendingPathComponent("host.sqlite").path)
      _ = database.permissionStore(counter: WorktreeAcceptanceCounter(directory: storageRoot))
    } else {
      database = try fixturePermissionDatabase(
        path: host.appendingPathComponent("host.sqlite").path)
    }
    connection = database.connection
    if lifecycle, !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
    {
      let git = HostFixtureGit(home: storageRoot)
      _ = try git.run(["init", "-q", "--initial-branch=main"], at: root)
      try Data("initial".utf8).write(to: root.appendingPathComponent("value"))
      _ = try git.run(["add", "value"], at: root)
      _ = try git.run(
        [
          "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c",
          "commit.gpgsign=false", "commit", "-qm", "Initial",
        ], at: root)
    }
    let project =
      try database.project(id: "scope")
      ?? RegisteredProject(id: "scope", displayName: "Fixture", rootPath: root.path)
    if try database.project(id: "scope") == nil { try database.saveProject(project) }
    if additionalProject {
      let otherRoot = storageRoot.appendingPathComponent("other")
      try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: false)
      try database.saveProject(
        RegisteredProject(id: "other", displayName: "Other", rootPath: otherRoot.path))
    }
    let profile =
      try database.profiles().first { $0.id == .chatGPTOperate }
      ?? ProfileGrant(
        id: .chatGPTOperate,
        permissions: fixturePermissions([
          .project("scope"): .granted(.write),
          .plugin("*"): .granted(.use), .mcpServer("probe"): .granted(.all),
        ]),
        fullAccess: true, allowedCallers: [.secureTunnel])
    if try database.profiles().allSatisfy({ $0.id != profile.id }) {
      try database.saveProfile(profile)
    }
    let basePlatform =
      lifecycle
      ? MacOSPlatform.services(
        launcher: testExecutionLauncher(
          observations: beforeHostCommand.map { ExecutionObservations(beforeStart: $0) }))
      : fixtureHostedPlatform()
    let platform =
      builtinLifecycle
      ? PlatformServices(
        launcher: basePlatform.launcher, projectGrants: basePlatform.projectGrants,
        pluginDirectories: basePlatform.pluginDirectories, applications: basePlatform.applications,
        toolProviders: HostWorktreeJournalProviders(
          base: basePlatform.toolProviders, journalIO: journalIO),
        managementToolNames: basePlatform.managementToolNames,
        executableSearchDirectories: basePlatform.executableSearchDirectories,
        gitExecutable: basePlatform.gitExecutable, fileChanges: basePlatform.fileChanges,
        permissionPolicyReader: basePlatform.permissionPolicyReader,
        executionProxy: basePlatform.executionProxy, hostDataPaths: basePlatform.hostDataPaths)
      : basePlatform
    let trace = GatewayTransportTrace(transport: "gateway_socket", socketConnectionID: "connection")
    let context =
      !requiresControlSession
      ? try fixtureConsentedContext(
        database: database, grant: profile, caller: .secureTunnel,
        principalID: "fixture-principal", transportTrace: trace, platform: platform)
      : ExecutionContext(
        caller: .secureTunnel, profileID: .chatGPTOperate, transportTrace: trace,
        trustedPrincipalID: "fixture-principal")
    let registration = MCPServerConfig(
      id: "probe", transport: .stdio, command: "/bin/cat", exposure: .reexport,
      prefix: "adapter", allowedTools: HostServiceProbe.methods,
      toolRisks: Dictionary(
        uniqueKeysWithValues: HostServiceProbe.methods.map { method -> (String, CapabilityRisk) in
          (method, method == "fixture.list" ? .readOnly : .projectWrite)
        }),
      hostServices: true)
    self.context = context
    self.registration = registration
    let database = database
    let peer = peer
    make = {
      let runtime = try GatewayRuntime(
        configuration: .init(
          runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
          profiles: [.init(grant: profile)],
          mcp: .init(servers: [registration]),
          builtin: .init(
            enabled: builtinLifecycle ? ["git.worktree_add", "git.worktree_remove"] : [])),
        context: context,
        database: database, registeredProjects: try database.projects(),
        platform: platform,
        mcpClient: peer,
        requiresControlSession: requiresControlSession)
      _ = try runtime.makeControlSession()
      return runtime
    }
    runtime = try make()
    review = try fixtureApproveLocalProvider(
      registration, database: database,
      runtime: database.permissionRuntime(platform: platform),
      permissions: profile.permissions, fullAccess: true)
    if let session = context.controlSession as? GatewayControlSession {
      _ = try session.approveFullAccess(expectedRevision: session.revision)
    }
    let scope = try #require(peer.context(for: "scope"))
    service = try #require(try runtime.makeHostServices(context: scope, origin: "probe"))
    if stoppableProvider {
      peer.endCalls { [weak self] id in self?.providerStopped(id) ?? false }
    }
  }

  /// Whether the host has stopped this provider execution.
  func providerStopped(_ id: UUID) -> Bool {
    (try? runtime.permissionRuntime.store.readWithDatabase { _, ledger in
      ledger.executions[id].map { !$0.isRunning }
    }) == true
  }

  /// A new generation publishes host worktrees registered after the previous one.
  func refresh() async throws {
    services.append(service)
    retired.append(runtime)
    runtime = try make()
    let scope = try #require(peer.context(for: "scope"))
    service = try #require(try runtime.makeHostServices(context: scope, origin: "probe"))
  }

  func service(for projectID: String) throws -> MCPBoundHostServices {
    if projectID == "scope" { return service }
    let context = try #require(peer.context(for: projectID))
    let bound = try #require(try runtime.makeHostServices(context: context, origin: "probe"))
    services.append(bound)
    return bound
  }

  func unfinishedOperations() throws -> [HostOperationRecord] {
    try HostOperationStore(connection: connection).unfinished()
  }

  /// The record once its host-owned work has settled.
  func settled(_ id: UUID) async throws -> HostOperationRecord {
    let store = HostOperationStore(connection: connection)
    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
    while ContinuousClock.now < deadline {
      if let record = try store.operation(id: id),
        [.completed, .failed, .recoveryRequired].contains(record.state)
      {
        return record
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    return try #require(try store.operation(id: id))
  }

  func waitForBuiltin(_ name: String) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
    while runtime.ownedWork.snapshot.contains(where: {
      $0.kind == .invocation && $0.resourceID == name
    }),
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      !runtime.ownedWork.snapshot.contains { $0.kind == .invocation && $0.resourceID == name })
  }

  func setClientProjectAccess(_ state: PermissionState) throws {
    var grant = try #require(database.profiles().first { $0.id == .chatGPTOperate })
    try grant.permissions.set(state, for: .project("scope"))
    try database.saveProfile(grant)
  }

  /// From the next generation on, neither the client nor the provider has Full access.
  func useSandboxedProvider() async throws {
    var grant = try #require(database.profiles().first { $0.id == .chatGPTOperate })
    grant.fullAccess = false
    try database.saveProfile(grant)
    try approveProvider(grant.permissions)
    try await refresh()
  }

  func withdrawProviderApproval() throws { try approveProvider(fixturePermissions([:])) }

  /// A source retirement uses the ledger operation that ends all original proofs
  /// carried by that provider execution, including its delegating client's proof.
  func retireProviderSource() throws {
    try runtime.permissionRuntime.store.transactionWithDatabase { _, ledger in
      _ = try ledger.retireProviderExecutions(
        .localServer(registration.id), expectedRevision: ledger.revision)
    }
  }

  func builtinCallbackAuthorities(projectID: String, clientID: UUID, providerID: UUID) throws
    -> HostBuiltinCallbackAuthorities
  {
    try runtime.permissionRuntime.store.readWithDatabase { _, ledger in
      let originalClient = try #require(ledger.authorizations[clientID])
      let originalProvider = try #require(ledger.authorizations[providerID])
      #expect(originalClient.executionID != nil)
      #expect(originalClient.executionID == originalProvider.executionID)
      let callbacks = ledger.authorizations.values.filter {
        $0.invocation.tool == "git.worktree_remove" && $0.invocation.projectID == projectID
      }
      try #require(callbacks.count == 2)
      let client = try #require(
        callbacks.first { $0.invocation.principal == originalClient.invocation.principal })
      let provider = try #require(
        callbacks.first { $0.invocation.principal == originalProvider.invocation.principal })
      #expect(client.basis.contains(.worktreeAuthority(clientID)))
      #expect(provider.basis.contains(.worktreeAuthority(providerID)))
      var validation = ledger
      let clientCanWrite: Bool
      do {
        try validation.authorizeWorktreeHostPath(
          client.id, path: CanonicalPath(root.appendingPathComponent("value").path), writing: true)
        clientCanWrite = true
      } catch { clientCanWrite = false }
      return HostBuiltinCallbackAuthorities(
        client: client, provider: provider, originalClient: originalClient,
        originalProvider: originalProvider, clientCanWrite: clientCanWrite)
    }
  }

  func setProviderProjectAccess(_ state: PermissionState) throws {
    var permissions = try #require(database.profiles().first { $0.id == .chatGPTOperate })
      .permissions
    try permissions.set(state, for: .project("scope"))
    try approveProvider(permissions)
  }

  private func approveProvider(_ permissions: Permissions) throws {
    let service = runtime.permissionRuntime.service
    let owner = try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "fixture-owner"),
      validate: {})
    // The review binds the configuration state it was made from.
    let current = try GatewayProviderReview(
      server: registration, configuration: database.configurationState())
    let view = try service.view(owner: owner)
    let approval = try #require(view.providers.first { $0.identity == current.identity })
    _ = try service.approveProvider(
      current, permissions: permissions, fullAccess: false, owner: owner,
      expectedProviderRevision: approval.revision, expectedRevision: view.revision,
      expectedEpoch: #require(view.epoch))
    review = current
  }

  /// A call admitted under current grants, or through Only This Time answers to the
  /// requests it raises, followed by its explicit retry.
  func duringAdmitted(
    _ method: String, project: String, onlyThisTime: Bool,
    arguments: [String: JSONValue] = [:],
    _ body: @escaping @Sendable (MCPBoundHostServices, InvocationContext) async throws -> JSONValue
  ) async throws -> JSONValue {
    guard onlyThisTime else { return try await during(method, arguments, project: project, body) }
    let requests: [PermissionRequest]
    do {
      _ = try await during(method, arguments, project: project, body)
      Issue.record("The call did not require a permission answer.")
      return .null
    } catch GatewayPermissionCallError.required(let raised, _, _) {
      requests = raised
    }
    let service = runtime.permissionRuntime.service
    let owner = try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "fixture-owner"),
      validate: {})
    for request in requests {
      _ = try service.answerRequest(
        request.id, answer: .onlyThisTime, owner: owner,
        expectedRevision: service.view(owner: owner).revision)
    }
    return try await during(
      method,
      arguments.merging([
        GatewayPermissionRetryInput.field: .array(requests.map { .string($0.id.uuidString) })
      ]) { _, retry in retry },
      project: project, body)
  }

  /// The provider peer's side of a callback: a host session bound to the call's prepared
  /// provider execution, reached over the inherited socket. The peer ends with its
  /// execution, as a provider process does, or after the claim when `closeAfterClaim`;
  /// either way its reply is lost and nil is returned.
  func providerCallback(
    _ context: InvocationContext, project: String, _ name: String,
    _ arguments: [String: JSONValue] = [:], closeAfterClaim: Bool = false,
    retainWriterThroughClose: Bool = false
  ) async throws -> HostReply? {
    let execution = try #require(context.executionAuthority as? PreparedExecutionContext)
    let host = try #require(peer.context(for: project))
    let session = try host.makeHostSession(server: registration, execution: execution)
    let operationID = context.admission?.hostOperationID
    var values = arguments
    if name.hasPrefix("host.") {
      values["invocation_id"] = .string(
        try #require(context.admission?.hostInvocationID).uuidString)
      values["operation_id"] = .string(try #require(operationID).uuidString.lowercased())
    }
    let client = MCP.Client(name: "fixture-provider", version: "1")
    let outcome = HostCallbackOutcome()
    var invocationWork: ExecutionWorkLease?
    defer {
      if let invocationWork {
        #expect(throws: Never.self) { try invocationWork.finish() }
      }
    }
    do {
      if retainWriterThroughClose {
        // The peer's retirement loop below observes the stop. Like a local MCP proxy,
        // it keeps the execution receipt until closing the host callback channel.
        invocationWork = try execution.retainWork(cancellation: {})
      }
      let transport = try MCPInheritedSocketTransport(
        takingOwnershipOf: try session.providerChannel.takeEndpoint())
      _ = try await client.connect(transport: transport)
      let request: RequestContext<MCP.CallTool.Result> = try await client.callTool(
        name: name, arguments: values.mapValues(\.sdkValue))
      let pending = Task {
        do {
          outcome.set(.success(try ProjectServiceCaller.reply(try await request.value)))
        } catch { outcome.set(.failure(error)) }
      }
      let store = HostOperationStore(connection: connection)
      let deadline = ContinuousClock.now.advanced(by: .seconds(120))
      while outcome.value == nil, ContinuousClock.now < deadline {
        let claimed: Bool
        if let operationID {
          claimed = try store.operation(id: operationID).map { $0.state != .reserved } ?? false
        } else {
          claimed = try runtime.permissionRuntime.store.readWithDatabase { _, ledger in
            ledger.authorizations.values.contains { proof in
              proof.invocation.tool == name && proof.invocation.projectID == project
                && proof.basis.contains {
                  guard case .worktreeAuthority(let parentID) = $0 else { return false }
                  return execution.provider?.authorizationIDs.contains(parentID) == true
                }
            }
          }
        }
        if providerStopped(execution.executionID) || (closeAfterClaim && claimed) {
          await client.disconnect()
          await session.close()
          pending.cancel()
          await pending.value
          return nil
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      await client.disconnect()
      await session.close()
      return try #require(outcome.value).get()
    } catch {
      await client.disconnect()
      await session.close()
      throw error
    }
  }

  func during(
    _ method: String, _ arguments: [String: JSONValue] = [:], project: String = "scope",
    context: InvocationContext = .empty,
    _ body: @escaping @Sendable (MCPBoundHostServices, InvocationContext) async throws -> JSONValue
  ) async throws -> JSONValue {
    let service = try service(for: project)
    peer.setHandler { context in try await body(service, context) }
    defer { peer.setHandler(nil) }
    var args = arguments
    args["project_id"] = .string(project)
    return try await runtime.callToolAsync(
      name: "adapter." + method, arguments: .object(args), context: context)
  }
  func direct(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
    try await .encoded(service.call(name: name, arguments: arguments))
  }
  func duringInvocation(
    _ method: String, _ arguments: [String: JSONValue], generic: Bool = false,
    context: InvocationContext = .empty,
    _ body: @escaping @Sendable (MCPBoundHostServices, InvocationContext) async throws -> JSONValue
  ) async throws -> JSONValue {
    let service = service
    peer.setHandler { context in try await body(service, context) }
    defer { peer.setHandler(nil) }
    var args = arguments
    args["project_id"] = .string("scope")
    let tool = generic ? "mcp.tools.call" : "adapter." + method
    if generic {
      args = [
        "project_id": .string("scope"), "server": .string("probe"),
        "tool": .string(method), "arguments": .object(arguments),
      ]
    }
    return try await runtime.callToolAsync(name: tool, arguments: .object(args), context: context)
  }
  func session(consent: Bool = true) throws -> GatewayControlSession {
    let profile = try #require(database.profiles().first { $0.id == .chatGPTOperate })
    let session = GatewayControlSession(
      principalID: "fixture-principal", profileID: profile.id,
      caller: .secureTunnel, database: database, profile: .init(grant: profile, persisted: true),
      permissionService: try database.permissionRuntime(
        platform: fixtureHostedPlatform()
      ).service)
    if consent { _ = try session.approveFullAccess(expectedRevision: session.revision) }
    return session
  }
  func genericDiagnostics(projectID: String?) async throws -> JSONValue {
    let service = service
    peer.setHandler { _ in
      try await .encoded(
        service.call(
          name: "host.diagnostics.snapshot",
          arguments: ["limit": .number(1)]))
    }
    defer { peer.setHandler(nil) }
    var arguments: [String: JSONValue] = [
      "server": .string("probe"), "tool": .string("fixture.audit"),
      "arguments": .object(["limit": .number(1)]),
    ]
    if let projectID { arguments["project_id"] = .string(projectID) }
    return try await runtime.callToolAsync(
      name: "mcp.tools.call", arguments: .object(arguments), context: .empty)
  }
  func payload(_ value: JSONValue) -> [String: JSONValue] {
    let downstream = value.objectValue?["structuredContent"]?.objectValue?["result"]
    return downstream?.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue ?? [:]
  }
  func close() async {
    await service.close()
    for bound in services { await bound.close() }
    for old in retired { await old.shutdown() }
    await runtime.shutdown()
  }
  func remove() { try? FileManager.default.removeItem(at: storageRoot) }
}

/// One private-service reply, decoded as a `projects-v1` caller sees it.
private struct HostReply: Equatable, Sendable {
  let result: [String: JSONValue]?
  let error: [String: JSONValue]?
  let isError: Bool
  /// The refusal code, or the recorded error code of an operation envelope.
  var code: String? {
    error?["code"]?.stringValue ?? result?["error"]?.objectValue?["code"]?.stringValue
  }
}

private final class HostReplies: @unchecked Sendable {
  private let lock = NSLock()
  private var replies: [String: HostReply] = [:]
  private var ids: [String: UUID] = [:]
  func set(_ key: String, _ reply: HostReply) { lock.withLock { replies[key] = reply } }
  func get(_ key: String) -> HostReply? { lock.withLock { replies[key] } }
  /// A reply recorded by a callback that outlives its originating call.
  func wait(_ key: String, timeout: Duration = .seconds(120)) async throws -> HostReply {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let reply = get(key) { return reply }
      try await Task.sleep(for: .milliseconds(10))
    }
    return try #require(get(key), "No \(key) reply")
  }
  func setID(_ key: String, _ id: UUID) { lock.withLock { ids[key] = id } }
  func id(_ key: String) -> UUID? { lock.withLock { ids[key] } }
}

/// The deterministic `projects-v1` caller. It checks the host marker before any
/// lifecycle callback, passes the host-supplied invocation and operation IDs with the
/// exact dispatched arguments, and recovers a lost reply only by inspection.
private enum ProjectServiceCaller {
  static func requireContract(_ initialize: [String: JSONValue]) throws {
    let observed = initialize["capabilities"]?.objectValue?["experimental"]?.objectValue?[
      MCPHostServiceContract.capabilityKey]?.stringValue
    guard observed == MCPHostServiceContract.identifier else {
      throw MCPHostServiceContractError(observed: observed)
    }
  }

  /// Raw MCP initialization over the inherited endpoint; the SDK does not surface
  /// experimental capabilities.
  static func initialize(_ handle: FileHandle) async throws -> [String: JSONValue] {
    let request =
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fixture","version":"1"}}}"#
    try handle.write(contentsOf: Data((request + "\n").utf8))
    let line = try await Task.detached {
      var buffer = Data()
      while !buffer.contains(0x0A) {
        let chunk = handle.availableData
        guard !chunk.isEmpty else { break }
        buffer.append(chunk)
      }
      return buffer.split(separator: 0x0A).first.map(Data.init) ?? Data()
    }.value
    let message = try JSONDecoder().decode(JSONValue.self, from: line)
    return try #require(message.objectValue?["result"]?.objectValue)
  }

  static func reply(_ result: MCP.CallTool.Result) throws -> HostReply {
    let encoded = try JSONValue.encoded(result).objectValue ?? [:]
    let structured = encoded["structuredContent"]?.objectValue ?? [:]
    return .init(
      result: structured["result"]?.objectValue, error: structured["error"]?.objectValue,
      isError: encoded["isError"] == .bool(true))
  }

  static func describe(_ service: MCPBoundHostServices, invocation: UUID) async throws
    -> HostReply
  {
    try reply(
      await service.call(
        name: "host.invocations.describe",
        arguments: ["invocation_id": .string(invocation.uuidString)]))
  }

  static func describe(_ service: MCPBoundHostServices, operation: String) async throws
    -> HostReply
  {
    try reply(
      await service.call(
        name: "host.invocations.describe", arguments: ["operation_id": .string(operation)]))
  }

  static func add(
    _ service: MCPBoundHostServices, _ context: InvocationContext, name: String,
    branch: String? = nil, base: String? = nil
  ) async throws -> HostReply {
    var arguments = try identifiers(context)
    arguments["name"] = .string(name)
    if let branch { arguments["branch"] = .string(branch) }
    if let base { arguments["base"] = .string(base) }
    return try reply(await service.call(name: "host.projects.worktree_add", arguments: arguments))
  }

  static func remove(
    _ service: MCPBoundHostServices, _ context: InvocationContext, force: Bool? = nil
  ) async throws -> HostReply {
    var arguments = try identifiers(context)
    if let force { arguments["force"] = .bool(force) }
    return try reply(
      await service.call(name: "host.projects.worktree_remove", arguments: arguments))
  }

  static func list(_ service: MCPBoundHostServices, _ context: InvocationContext) async throws
    -> HostReply
  {
    let invocation = try #require(context.admission?.hostInvocationID)
    return try reply(
      await service.call(
        name: "host.projects.worktree_list",
        arguments: ["invocation_id": .string(invocation.uuidString)]))
  }

  static func identifiers(_ context: InvocationContext) throws -> [String: JSONValue] {
    [
      "invocation_id": .string(try #require(context.admission?.hostInvocationID).uuidString),
      "operation_id": .string(
        try #require(context.admission?.hostOperationID).uuidString.lowercased()),
    ]
  }
}

private final class HostServiceProbe: DownstreamMCPClient, @unchecked Sendable {
  static let methods = [
    "fixture.read", "fixture.audit", "fixture.provision", "fixture.remove", "fixture.list",
    "codex.diagnostics.snapshot",
  ]
  private static let observedTools: [MCPTool] = methods.map { name in
    let action = [
      "fixture.audit": "diagnostics.snapshot", "fixture.provision": "projects.provision",
      "fixture.remove": "projects.remove", "fixture.list": "projects.list",
    ][name]
    return .init(
      name: name, description: "Fixture", inputSchema: .object([:]),
      meta: action.map { .object(["io.github.computer-mcp/host-action": .string($0)]) })
  }
  private final class State: @unchecked Sendable {
    let lock = NSLock()
    var contexts: [String: MCPHostContext] = [:]
    var handler: (@Sendable (InvocationContext) async throws -> JSONValue)?
    var activeCalls = 0
    let multiplexed: Bool
    let callbackTimeout: TimeInterval
    var journalIO = WorktreeJournalIO()
    var providerStopped: (@Sendable (UUID) -> Bool)?
    init(multiplexed: Bool, callbackTimeout: TimeInterval) {
      self.multiplexed = multiplexed
      self.callbackTimeout = callbackTimeout
    }
  }
  private let state: State
  private let hostContext: MCPHostContext?

  init(
    multiplexed: Bool = false, callbackTimeout: TimeInterval = 10,
    journalIO: WorktreeJournalIO = .init()
  ) {
    state = State(multiplexed: multiplexed, callbackTimeout: callbackTimeout)
    state.journalIO = journalIO
    hostContext = nil
  }
  private init(state: State, hostContext: MCPHostContext?) {
    self.state = state
    self.hostContext = hostContext
  }
  func context(for projectID: String) -> MCPHostContext? {
    state.lock.withLock { state.contexts[projectID] }
  }
  func setHandler(_ value: (@Sendable (InvocationContext) async throws -> JSONValue)?) {
    state.lock.withLock { state.handler = value }
  }
  /// The probe then stands in for a provider process: when the host stops a call's provider
  /// execution, as a worktree removal drain does, the call ends like a terminated process
  /// would, and its pending callback stays with the host.
  func endCalls(whenStopped stopped: @escaping @Sendable (UUID) -> Bool) {
    state.lock.withLock { state.providerStopped = stopped }
  }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  ) -> any DownstreamMCPClient {
    var scoped = hostContext as? MCPHostContext
    if var worktrees = scoped?.worktrees as? GatewayWorktreeService {
      worktrees.journalIO = state.journalIO
      scoped?.worktrees = worktrees
    }
    if let scoped {
      state.lock.withLock { state.contexts[scoped.launchMetadata.project.id] = scoped }
    }
    return HostServiceProbe(state: state, hostContext: scoped)
  }
  func cachedTools(server: MCPServerConfig, context: InvocationContext) -> [MCPTool]? {
    Self.observedTools
  }
  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    // Multiplexed peers can answer metadata while another request awaits its callback.
    guard state.lock.withLock({ state.activeCalls == 0 || state.multiplexed }) else {
      throw MCPHostServiceError.denied("Catalog queried while the parent call is suspended.")
    }
    return Self.observedTools
  }
  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    guard let hostContext,
      hostContext.launchMetadata.project.id == context.resolvedInvocation?.identity.projectID
    else {
      throw MCPHostServiceError.denied("The fixture call reached another project channel.")
    }
    guard let handler = state.lock.withLock({ state.handler }) else {
      throw MCPHostServiceError.denied("Fixture handler absent.")
    }
    state.lock.withLock { state.activeCalls += 1 }
    defer { state.lock.withLock { state.activeCalls -= 1 } }
    let box = HostProbeResult()
    let ready = DispatchSemaphore(value: 0)
    let task = Task.detached {
      do { box.set(.success(try await handler(context))) } catch { box.set(.failure(error)) }
      ready.signal()
    }
    let provider = (context.executionAuthority as? PreparedExecutionContext)?.executionID
    let stopped = state.lock.withLock { state.providerStopped }
    let deadline = DispatchTime.now() + state.callbackTimeout
    while true {
      let replied = ready.wait(timeout: .now() + .milliseconds(10)) == .success
      if let provider, let stopped, stopped(provider) {
        throw MCPHostServiceError.denied("The fixture provider was stopped.")
      }
      if replied { return try box.get() }
      guard DispatchTime.now() < deadline else {
        task.cancel()
        throw MCPHostServiceError.denied("Fixture callback timed out.")
      }
    }
  }
  func listResources(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?, context: InvocationContext)
    throws -> JSONValue
  { .null }
  func readResource(server: MCPServerConfig, uri: String, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func getPrompt(
    server: MCPServerConfig, name: String, arguments: [String: String]?, context: InvocationContext
  ) throws
    -> JSONValue
  { .null }
}

private final class HostCallbackOutcome: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Result<HostReply, any Error>?
  var value: Result<HostReply, any Error>? { lock.withLock { stored } }
  func set(_ value: Result<HostReply, any Error>) { lock.withLock { stored = value } }
}

/// Runs one action before the `occurrence`th host `git status` after it is armed. A
/// removal's first status is its dirty check after the writer drain; its second is the
/// last check before the commit into teardown.
private final class HostCommandTrigger: @unchecked Sendable {
  private let lock = NSLock()
  private var action: (@Sendable () throws -> Void)?
  private var remaining = 0
  private var didFire = false
  var fired: Bool { lock.withLock { didFire } }
  func arm(_ enabled: Bool, at occurrence: Int, _ action: @escaping @Sendable () throws -> Void) {
    guard enabled else { return }
    lock.withLock {
      self.action = action
      remaining = occurrence
    }
  }
  func observe(_ command: ExecutionCommand) throws {
    guard command.arguments.contains("status") else { return }
    let action = lock.withLock { () -> (@Sendable () throws -> Void)? in
      guard self.action != nil else { return nil }
      remaining -= 1
      guard remaining == 0 else { return nil }
      defer { self.action = nil }
      didFire = true
      return self.action
    }
    try action?()
  }
}

private final class HostJournalTrigger: @unchecked Sendable {
  private let lock = NSLock()
  private var target: (URL, String, @Sendable () throws -> Void)?
  private var didFire = false
  var fired: Bool { lock.withLock { didFire } }

  func arm(path: URL, phase: String, action: @escaping @Sendable () throws -> Void) {
    lock.withLock { target = (path, phase, action) }
  }

  func observe() throws {
    let action = try lock.withLock { () -> (@Sendable () throws -> Void)? in
      guard let target, let data = try? Data(contentsOf: target.0),
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["phase"] as? String == target.1
      else { return nil }
      self.target = nil
      didFire = true
      return target.2
    }
    try action?()
  }
}

private final class HostProbeResult: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<JSONValue, any Error>?
  func set(_ value: Result<JSONValue, any Error>) { lock.withLock { self.value = value } }
  func get() throws -> JSONValue { try lock.withLock { try value!.get() } }
}

private actor RetainedControlInvocation {
  private(set) var id: UUID?
  private var lease: MCPHostToolDirectory.InvocationLease?
  func hold(id: UUID, lease: MCPHostToolDirectory.InvocationLease) {
    self.id = id
    self.lease = lease
  }
  func finish() {
    lease?.finish()
    lease = nil
  }
}

@Suite(
  .nativeIntegration, .serialized, .timeLimit(.minutes(5)),
  .enabled(
    if: ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_PLUGIN_CONSUMER_WORKTREE"] != nil,
    "Build the companion fixture in an isolated plugin checkout to run consumer acceptance."))
struct PluginWorktreeConsumerTests {
  private struct HostPhase: Codable {
    let mode: String
    let storage: URL
  }

  /// Creation and its lost reply run in one host process; inspection after restart and
  /// removal run in another, against the same durable store.
  @Test func separatelyBuiltConsumerRecoversALostReplyAcrossRestart() async throws {
    let storage = URL(fileURLWithPath: "/private/tmp/cm-consumer-\(UUID())")
    defer { try? FileManager.default.removeItem(at: storage) }
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
    try await runHostPhase("provision", storage: storage)
    try await runHostPhase("recover", storage: storage)
  }

  @Test func consumerRefusesAHostWithoutTheProjectContract() async throws {
    let storage = URL(fileURLWithPath: "/private/tmp/cm-consumer-\(UUID())")
    defer { try? FileManager.default.removeItem(at: storage) }
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
    let bridge = PluginWorktreeConsumerHostBridge(directory: storage, service: nil)
    let output = try #require(try await bridge.run(mode: "obsolete"))
    #expect(output["refused"] == .string("host.unsupported_contract"))
    #expect(output["observed_contract"] == .null)
    print("PLUGIN_CONSUMER obsolete_host_refused=true lifecycle_calls=0")
  }

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_CONSUMER_HOST_PHASE"] != nil))
  func consumerHostPhase() async throws {
    let input = try #require(
      ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_CONSUMER_HOST_PHASE"])
    let phase = try JSONDecoder().decode(
      HostPhase.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    let fixture = try HostAuthorityFixture(
      lifecycle: true, callbackTimeout: PluginConsumerTiming.invocationSeconds,
      storageDirectory: phase.storage, stoppableProvider: true)
    do {
      if phase.mode == "provision" {
        try await provision(fixture, storage: phase.storage)
      } else {
        try #require(phase.mode == "recover")
        try await recover(fixture, storage: phase.storage)
      }
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }

  private func provision(_ fixture: HostAuthorityFixture, storage: URL) async throws {
    _ = try await fixture.during("fixture.provision", ["name": .string("consumer")]) {
      service, context in
      let bridge = PluginWorktreeConsumerHostBridge(
        directory: storage, service: service, dropping: "host.projects.worktree_add")
      let output = try #require(
        try await bridge.run(mode: "provision", context: context, name: "consumer"))
      #expect(output["reply"] == .string("lost"))
      return .object([:])
    }
    let operations = try HostOperationStore(connection: fixture.connection)
    let created = try #require(try fixture.database.derivedProjects().first)
    let operation = try #require(
      try operations.operation(id: created.provenance.worktreeID))
    #expect(operation.state == .completed)
  }

  private func recover(_ fixture: HostAuthorityFixture, storage: URL) async throws {
    let record = try #require(try fixture.database.derivedProjects().first)
    let operationID = record.provenance.worktreeID.uuidString.lowercased()
    let outputs = ConsumerOutputs()
    _ = try await fixture.during("fixture.read") { service, context in
      let bridge = PluginWorktreeConsumerHostBridge(directory: storage, service: service)
      outputs.set(
        try await bridge.run(mode: "inspect", context: context, operationID: operationID))
      return .object([:])
    }
    let inspected = try #require(outputs.value?["envelope"]?.objectValue)
    #expect(inspected["state"] == .string("completed"))
    #expect(inspected["operation_id"] == .string(operationID))
    let path = try #require(inspected["result"]?.objectValue?["path"]?.stringValue)
    #expect(FileManager.default.fileExists(atPath: path))
    // The drain stops the initiating call's provider; the host-owned removal completes.
    let removal = HostReplies()
    _ = await #expect(throws: MCPHostServiceError.self) {
      try await fixture.during("fixture.remove", project: record.projectID) {
        service, context in
        removal.setID("operation", try #require(context.admission?.hostOperationID))
        let bridge = PluginWorktreeConsumerHostBridge(directory: storage, service: service)
        outputs.set(try await bridge.run(mode: "remove", context: context))
        return .object([:])
      }
    }
    let settled = try await fixture.settled(try #require(removal.id("operation")))
    let removed = try #require(MCPHostOperations.envelope(settled).objectValue)
    #expect(removed["state"] == .string("completed"))
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(try fixture.database.project(id: record.projectID) == nil)
    print(
      "PLUGIN_CONSUMER contract_checked=true creation=true lost_reply_recovered=true restart=true removal=true"
    )
  }

  private func runHostPhase(_ mode: String, storage: URL) async throws {
    let spec = storage.appendingPathComponent(mode + "-host.json")
    try JSONEncoder().encode(HostPhase(mode: mode, storage: storage)).write(to: spec)
    let log = storage.appendingPathComponent(mode + "-host.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = try #require(Bundle.main.executableURL)
    let bundle = try #require(Bundle(for: ConsumerHostBundleMarker.self).executableURL)
    process.arguments = [
      "--test-bundle-path", bundle.path, bundle.path, "--testing-library", "swift-testing",
      "--filter", "PluginWorktreeConsumerTests/consumerHostPhase",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["COMPUTER_MCP_TEST_CONSUMER_HOST_PHASE"] = spec.path
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    try process.run()
    defer {
      if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }
    let deadline = ContinuousClock.now + .seconds(180)
    while process.isRunning && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(!process.isRunning, "Consumer host phase exceeded its deadline")
    let text = try String(contentsOf: log, encoding: .utf8)
    print("CONSUMER_HOST \(mode):\n\(text)")
    try #require(process.terminationStatus == 0, "\(text)")
  }
}

private final class ConsumerHostBundleMarker: NSObject {}

private final class ConsumerOutputs: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String: JSONValue]?
  var value: [String: JSONValue]? { lock.withLock { stored } }
  func set(_ value: [String: JSONValue]?) { lock.withLock { stored = value } }
}

/// Serves one consumer process over a private socket. With `service`, it is the host's
/// private `projects-v1` server; without one, a server that omits the contract marker.
private struct PluginWorktreeConsumerHostBridge: Sendable {
  let directory: URL
  let service: MCPBoundHostServices?
  var dropping: String? = nil

  func run(
    mode: String, context: InvocationContext? = nil, name: String? = nil,
    operationID: String? = nil
  ) async throws -> [String: JSONValue]? {
    let consumer = try #require(
      ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_PLUGIN_CONSUMER_WORKTREE"])
    let socketPath = directory.appendingPathComponent("c.sock").path
    let listener = try pluginConsumerListener(at: socketPath)
    defer {
      Darwin.close(listener)
      unlink(socketPath)
    }
    let outputURL = directory.appendingPathComponent("consumer-" + mode + "-output.json")
    var input: [String: JSONValue] = [
      "socket_path": .string(socketPath), "mode": .string(mode),
      "output_path": .string(outputURL.path),
    ]
    if let id = context?.admission?.hostInvocationID {
      input["invocation_id"] = .string(id.uuidString)
    }
    if let id = context?.admission?.hostOperationID {
      input["operation_id"] = .string(id.uuidString.lowercased())
    }
    if let operationID { input["operation_id"] = .string(operationID) }
    if let name { input["name"] = .string(name) }
    let inputURL = directory.appendingPathComponent("consumer-" + mode + ".json")
    try JSONEncoder().encode(JSONValue.object(input)).write(to: inputURL)
    let log = directory.appendingPathComponent("consumer-" + mode + ".log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [
      "test", "--build-system", "native", "--skip-build",
      "--disable-automatic-resolution", "--no-parallel", "--filter",
      "HostWorktreeConsumerBridgeTests/projectServiceConsumerUsesTheHostContract",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: consumer)
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": directory.path,
      "TMPDIR": directory.path + "/", "COMPUTER_MCP_TEST_PLUGIN_CONSUMER_INPUT": inputURL.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    let descriptor = try await BlockingOperationExecutor(label: "consumer-host-accept").perform {
      try acceptPluginConsumer(listener: listener, process: process, log: log)
    }
    let socket = try MCPInheritedSocketTransport(
      takingOwnershipOf: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    let server = MCP.Server(
      name: "consumer-host-bridge", version: "1", capabilities: .init(tools: .init()))
    let seen = PluginWorktreeConsumerCallbacks()
    await server.withMethodHandler(MCP.CallTool.self) { [service, dropping] params in
      let args = (params.arguments ?? [:]).mapValues(JSONValue.init(sdkValue:))
      guard let service else {
        await seen.append(params.name, arguments: args, isError: true)
        throw MCPError.invalidRequest("This host offers no project services.")
      }
      let result = try await service.call(name: params.name, arguments: args)
      await seen.append(params.name, arguments: args, isError: result.isError == true)
      // The effect completed; the consumer never receives its reply.
      if params.name == dropping { throw MCPError.internalError("Fixture dropped the reply.") }
      return result
    }
    do {
      if service == nil {
        try await server.start(transport: socket)
      } else {
        try await server.start(transport: await MCPHostContractTransport(base: socket))
      }
      let deadline = ContinuousClock.now + .seconds(PluginConsumerTiming.protocolSeconds)
      while process.isRunning && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      try #require(
        !process.isRunning,
        "Consumer process did not exit within \(PluginConsumerTiming.protocolSeconds) seconds")
      let text = try String(contentsOf: log, encoding: .utf8)
      print("Consumer \(mode):\n\(text)")
      try #require(process.terminationStatus == 0, "\(mode): \(text)")
      let calls = await seen.calls.map(\.name)
      let expected: [String] =
        switch mode {
        case "provision": ["host.invocations.describe", "host.projects.worktree_add"]
        case "inspect": ["host.invocations.describe"]
        case "remove": ["host.projects.worktree_remove"]
        default: []
        }
      #expect(calls == expected)
      await socket.disconnect()
      await server.stop()
      guard FileManager.default.fileExists(atPath: outputURL.path) else { return nil }
      return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: outputURL))
        .objectValue
    } catch {
      await socket.disconnect()
      await server.stop()
      throw error
    }
  }
}

private actor PluginWorktreeConsumerCallbacks {
  struct Call: Sendable {
    let name: String
    let arguments: [String: JSONValue]
    let isError: Bool
  }
  private(set) var calls: [Call] = []
  func append(_ name: String, arguments: [String: JSONValue], isError: Bool) {
    calls.append(.init(name: name, arguments: arguments, isError: isError))
  }
}

/// Fixture Git with an isolated home and no user or system configuration.
private struct HostFixtureGit {
  let home: URL

  func run(_ arguments: [String], at directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = [
      "PATH": "/usr/bin:/bin", "HOME": home.path, "TMPDIR": home.path + "/",
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C",
    ]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    try #require(process.terminationStatus == 0, "\(stderr)")
    return stdout
  }
}
