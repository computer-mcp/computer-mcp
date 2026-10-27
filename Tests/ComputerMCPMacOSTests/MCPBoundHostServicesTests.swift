import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPTestSupport
import ComputerMCPTransport
import CryptoKit
import Darwin
import Foundation
import GRDB
import MCP
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)
struct MCPBoundHostServicesTests {
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

  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["register", "authorize", "unregister"],
    ["capability", "session", "completed", "work-only"])
  func mutationRechecksAfterVerification(operation: String, change: String) async throws {
    let barrier = HostVerificationBarrier()
    let evidence = InvocationCallbackEvidence()
    let fixture = try HostAuthorityFixture(worktrees: true, verificationBarrier: barrier)
    defer { fixture.remove() }
    let session = try fixture.session()
    let context = InvocationContext(session: session)
    let directory = try #require(fixture.peer.context(for: "scope")?.tools)
    let provisioning = try fixture.worktreeReceipt()
    let provisionArgs: [String: JSONValue] = [
      "plan_id": provisioning["id"]!,
      "expected_revision": .integer(1), "confirm_provision": .bool(true),
    ]
    if operation != "register" {
      _ = try await fixture.during("fixture.provision", provisionArgs, context: context) {
        service, _ in
        let result = try await service.call(
          name: "host.workspaces.register",
          arguments: ["worktree": .object(provisioning)])
        try #require(result.isError == false)
        return try .encoded(result)
      }
    }
    let body: @Sendable (MCPBoundHostServices, InvocationContext) async throws -> JSONValue = {
      service, invocationContext in
      evidence.entered()
      var receipt = provisioning
      let method: String
      if operation == "register" {
        method = "host.workspaces.register"
      } else {
        receipt["state"] = .string("removal_planned")
        receipt["revision"] = .integer(4)
        if operation == "unregister" {
          let authorized = try await service.call(
            name: "host.workspaces.authorize_removal",
            arguments: ["worktree": .object(receipt)])
          try #require(authorized.isError == false)
          try fixture.removeWorktree(at: receipt["path"]!.stringValue!)
          receipt["state"] = .string("removing")
          receipt["revision"] = .integer(5)
          method = "host.workspaces.unregister"
        } else {
          method = "host.workspaces.authorize_removal"
        }
      }
      let sent = receipt
      barrier.arm()
      let callback = Task {
        try await service.call(name: method, arguments: ["worktree": .object(sent)])
      }
      defer { barrier.resume() }
      try await barrier.waitUntilEntered()
      let id = try #require(invocationContext.admission?.hostInvocationID)
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
      if change == "capability" || change == "session" { evidence.revoked() }
      barrier.resume()
      let result = try await callback.value
      #expect(result.isError == true)
      evidence.checked()
      retained?.finish()
      return try .encoded(result)
    }
    let result = try await checkedInvocationResult(
      evidence: evidence, revoked: change == "capability" || change == "session"
    ) {
      if operation == "register" {
        return try await fixture.during("fixture.provision", provisionArgs, context: context, body)
      } else {
        return try await fixture.duringInvocation(
          "fixture.remove",
          [
            "managed_worktree_id": provisioning["id"]!, "expected_revision": .integer(4),
            "confirm_remove": .bool(true),
          ], context: context, body)
      }
    }
    if let result { #expect(result.objectValue?["isError"] == .bool(true)) }
    let remains =
      try fixture.database.derivedProjectRegistration(
        id: provisioning["workspace_id"]!.stringValue!) != nil
    #expect(remains == (operation != "register"))
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func idempotentRegistrationCannotAcquireEarlierRollbackOwnership(revoked: Bool) async throws {
    let evidence = InvocationCallbackEvidence()
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    let receipt = try fixture.worktreeReceipt()
    let args: [String: JSONValue] = [
      "plan_id": receipt["id"]!,
      "expected_revision": .integer(1), "confirm_provision": .bool(true),
    ]
    _ = try await fixture.during("fixture.provision", args) { service, _ in
      let result = try await service.call(
        name: "host.workspaces.register", arguments: ["worktree": .object(receipt)])
      try #require(result.isError == false)
      return try .encoded(result)
    }
    let before = try fixture.database.derivedProjectRegistration(
      id: receipt["workspace_id"]!.stringValue!)
    let result = try await checkedInvocationResult(evidence: evidence, revoked: revoked) {
      try await fixture.during("fixture.provision", args) { service, _ in
        evidence.entered()
        let repeated = try await service.call(
          name: "host.workspaces.register", arguments: ["worktree": .object(receipt)])
        try #require(repeated.isError == false)
        if revoked {
          var profile = try #require(fixture.database.profiles().first { $0.id == .chatGPTOperate })
          profile.permissions = .init()
          try fixture.database.saveProfile(profile)
          evidence.revoked()
        }
        let callback = try await service.call(
          name: "host.workspaces.unregister", arguments: ["worktree": .object(receipt)])
        #expect(callback.isError == true)
        evidence.checked()
        return try .encoded(callback)
      }
    }
    if let result {
      #expect(result.objectValue?["isError"] == .bool(true))
    }
    #expect(
      try fixture.database.derivedProjectRegistration(id: receipt["workspace_id"]!.stringValue!)
        == before)
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1))) func rollbackRequiresTheExactProvisioningRevision() async throws {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    let receipt = try fixture.worktreeReceipt()
    _ = try await fixture.during(
      "fixture.provision",
      [
        "plan_id": receipt["id"]!,
        "expected_revision": .integer(1), "confirm_provision": .bool(true),
      ]
    ) { service, _ in
      let result = try await service.call(
        name: "host.workspaces.register", arguments: ["worktree": .object(receipt)])
      try #require(result.isError == false)
      var changed = receipt
      changed["revision"] = .integer(999)
      let refused = try await service.call(
        name: "host.workspaces.unregister", arguments: ["worktree": .object(changed)])
      #expect(refused.isError == true)
      let valid = try await service.call(
        name: "host.workspaces.unregister", arguments: ["worktree": .object(receipt)])
      #expect(valid.isError == false)
      return try .encoded(valid)
    }
    #expect(
      try fixture.database.derivedProjectRegistration(id: receipt["workspace_id"]!.stringValue!)
        == nil)
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
      directory: try #require(captured.tools), context: foreign, origin: "probe",
      gitExecutable: "/usr/bin/git")
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

  @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
  func metadataOnlyRecoveryUsesANewExactLiveCall(pathExists: Bool, registered: Bool) async throws {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    var receipt = try fixture.worktreeReceipt()
    if registered {
      let provisioning = receipt
      _ = try await fixture.during(
        "fixture.provision",
        [
          "plan_id": receipt["id"]!,
          "expected_revision": .integer(1), "confirm_provision": .bool(true),
        ]
      ) { service, _ in
        let result = try await service.call(
          name: "host.workspaces.register",
          arguments: ["worktree": .object(provisioning)])
        try #require(result.isError == false)
        return try .encoded(result)
      }
    }
    let saved = try fixture.database.derivedProjectRegistration(
      id: receipt["workspace_id"]!.stringValue!)
    let savedProject = try fixture.database.project(id: receipt["workspace_id"]!.stringValue!)
    #expect((saved != nil) == registered)
    receipt["state"] = .string("removing")
    receipt["revision"] = .integer(5)
    if !pathExists { try fixture.removeWorktree(at: receipt["path"]!.stringValue!) }
    let recovering = receipt
    let result = try await fixture.duringInvocation(
      "fixture.remove",
      [
        "managed_worktree_id": receipt["id"]!, "expected_revision": .integer(5),
        "confirm_remove": .bool(true),
      ]
    ) { service, _ in
      let authorized = try await service.call(
        name: "host.workspaces.authorize_removal",
        arguments: ["worktree": .object(recovering)])
      if pathExists { return try .encoded(authorized) }
      try #require(authorized.isError == false)
      var finished = recovering
      finished["revision"] = .integer(6)
      return try await .encoded(
        service.call(
          name: "host.workspaces.unregister",
          arguments: ["worktree": .object(finished)]))
    }
    #expect(result.objectValue?["isError"] == .bool(pathExists))
    #expect(
      try fixture.database.derivedProjectRegistration(id: receipt["workspace_id"]!.stringValue!)
        == (pathExists ? saved : nil))
    #expect(
      try fixture.database.project(id: receipt["workspace_id"]!.stringValue!)
        == (pathExists ? savedProject : nil))
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1))) func unregisterRechecksAuthorityAfterRemovalWasAuthorized()
    async throws
  {
    let evidence = InvocationCallbackEvidence()
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    let provisioning = try fixture.worktreeReceipt()
    _ = try await fixture.during(
      "fixture.provision",
      [
        "plan_id": provisioning["id"]!,
        "expected_revision": .integer(1), "confirm_provision": .bool(true),
      ]
    ) { service, _ in
      let result = try await service.call(
        name: "host.workspaces.register", arguments: ["worktree": .object(provisioning)])
      try #require(result.isError == false)
      return try .encoded(result)
    }
    var receipt = provisioning
    receipt["state"] = .string("removal_planned")
    receipt["revision"] = .integer(4)
    let planned = receipt
    let result = try await checkedInvocationResult(evidence: evidence, revoked: true) {
      try await fixture.duringInvocation(
        "fixture.remove",
        [
          "managed_worktree_id": receipt["id"]!, "expected_revision": .integer(4),
          "confirm_remove": .bool(true),
        ]
      ) { service, _ in
        evidence.entered()
        let authorized = try await service.call(
          name: "host.workspaces.authorize_removal", arguments: ["worktree": .object(planned)])
        try #require(authorized.isError == false)
        try fixture.removeWorktree(at: planned["path"]!.stringValue!)
        var grant = try #require(fixture.database.profiles().first { $0.id == .chatGPTOperate })
        grant.permissions = .init()
        try fixture.database.saveProfile(grant)
        evidence.revoked()
        var removed = planned
        removed["state"] = .string("removing")
        removed["revision"] = .integer(5)
        let callback = try await service.call(
          name: "host.workspaces.unregister", arguments: ["worktree": .object(removed)])
        #expect(callback.isError == true)
        evidence.checked()
        return try .encoded(callback)
      }
    }
    if let result {
      #expect(result.objectValue?["isError"] == .bool(true))
    }
    #expect(
      try fixture.database.derivedProjectRegistration(id: receipt["workspace_id"]!.stringValue!)
        != nil)
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1))) func exactProvisionRollbackKeepsItsNarrowRevocationException()
    async throws
  {
    let evidence = InvocationCallbackEvidence()
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    let receipt = try fixture.worktreeReceipt()
    let result = try await checkedInvocationResult(evidence: evidence, revoked: true) {
      try await fixture.during(
        "fixture.provision",
        [
          "plan_id": receipt["id"]!,
          "expected_revision": .integer(1), "confirm_provision": .bool(true),
        ]
      ) { service, _ in
        evidence.entered()
        let registered = try await service.call(
          name: "host.workspaces.register", arguments: ["worktree": .object(receipt)])
        try #require(registered.isError == false)
        var grant = try #require(fixture.database.profiles().first { $0.id == .chatGPTOperate })
        grant.permissions = .init()
        try fixture.database.saveProfile(grant)
        evidence.revoked()
        let callback = try await service.call(
          name: "host.workspaces.unregister", arguments: ["worktree": .object(receipt)])
        #expect(callback.isError == false)
        evidence.checked()
        return try .encoded(callback)
      }
    }
    if let result {
      #expect(result.objectValue?["isError"] == .bool(false))
    }
    #expect(try fixture.database.project(id: receipt["workspace_id"]!.stringValue!) == nil)
    await fixture.close()
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

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func concurrentIdenticalActionsNeverSelectAnArbitraryInvocation(removal: Bool) async throws {
    let fixture = try HostAuthorityFixture(worktrees: true, multiplexed: true)
    defer { fixture.remove() }
    var receipt = try fixture.worktreeReceipt()
    receipt["state"] = .string("removal_planned")
    receipt["revision"] = .integer(4)
    let sent = receipt
    let entered = HostServicePairBarrier()
    let finished = HostServicePairBarrier()
    fixture.peer.setHandler { _ in
      await entered.arrive()
      let result = try await fixture.service.call(
        name: removal ? "host.workspaces.authorize_removal" : "host.diagnostics.snapshot",
        arguments: removal ? ["worktree": .object(sent)] : ["limit": .integer(1)])
      let encoded = try JSONValue.encoded(result)
      #expect(
        encoded.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue?
          .contains("one matching live gateway invocation") == true)
      await finished.arrive()
      return encoded
    }
    let args = JSONValue.object(
      removal
        ? [
          "project_id": .string("scope"),
          "managed_worktree_id": receipt["id"]!, "expected_revision": .integer(4),
          "confirm_remove": .bool(true),
        ] : ["project_id": .string("scope"), "limit": .integer(1)])
    let method = removal ? "adapter.fixture.remove" : "adapter.fixture.audit"
    async let first = fixture.runtime.callToolAsync(name: method, arguments: args, context: .empty)
    async let second = fixture.runtime.callToolAsync(name: method, arguments: args, context: .empty)
    let results = try await [first, second]
    #expect(results.allSatisfy { $0.objectValue?["isError"] == .bool(true) })
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1))) func leaseCapacityDoesNotLoseAnExistingLiveCall() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let directory = try #require(fixture.peer.context(for: "scope")?.tools)
    _ = try await fixture.during("fixture.audit") { _, context in
      let id = try #require(context.admission?.hostInvocationID)
      var leases: [MCPHostToolDirectory.InvocationLease] = []
      defer { for lease in leases { lease.finish() } }
      for _ in 1..<1024 {
        leases.append(try directory.retainWork(id: id, projectID: "scope", origin: "probe"))
      }
      #expect(throws: (any Error).self) {
        try directory.retain(id: id, projectID: "scope", origin: "probe")
      }
      let record = try #require(try fixture.database.hostCallRecordStore().record(id: id))
      #expect(record.requestLeaseIDs.count == 1 && record.workLeaseIDs.count == 1023)
      _ = try fixture.runtime.requireHostInvocation(projectID: "scope", origin: "probe", id: id)
      return .object([:])
    }
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func vendorNeutralProvisionRegistersItsExactReceipt() async throws {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    var receipt = try fixture.worktreeReceipt()
    receipt["workspace_id"] = .string("derived-workspace-" + receipt["id"]!.stringValue!)
    let wireReceipt = receipt
    let result = try await fixture.during(
      "fixture.provision",
      [
        "plan_id": receipt["id"]!, "expected_revision": .integer(1),
        "confirm_provision": .bool(true),
      ]
    ) { service, _ in
      try await .encoded(
        service.call(
          name: "host.workspaces.register", arguments: ["worktree": .object(wireReceipt)]))
    }
    #expect(result.objectValue?["isError"] == .bool(false))
    let registration = try #require(
      try fixture.database.derivedProjectRegistration(id: receipt["workspace_id"]!.stringValue!))
    let fieldNames = [
      "id": "id", "workspace_id": "workspaceID", "source_workspace_id": "sourceWorkspaceID",
      "source_repository_root": "sourceRoot", "git_common_directory": "gitCommonDirectory",
      "path": "path", "branch": "branch", "parent_lease_id": "parentLeaseID",
      "profile_id": "profileID", "principal_id": "principalID", "caller": "caller",
    ]
    let identity = JSONValue.object(
      Dictionary(uniqueKeysWithValues: fieldNames.map { ($0.value, receipt[$0.key]!) }))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }
      .joined()
    #expect(registration.receiptDigest == digest)
    let payload = try JSONValue.encoded(registration).objectValue!
    #expect(payload["workspace"]?.objectValue?["id"] == receipt["workspace_id"])
    #expect(payload["sourceWorkspaceID"] == receipt["source_workspace_id"])
    #expect(payload["project"] == nil && payload["sourceProjectID"] == nil)
    await fixture.close()
  }

  @Test(
    .timeLimit(.minutes(1)), arguments: ["codex-worktree-", "derived-workspace-"], [false, true])
  func consentedRemovalPreservesReceiptFormatsAndRoutes(prefix: String, generic: Bool) async throws
  {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    var receipt = try fixture.worktreeReceipt()
    receipt["workspace_id"] = .string(prefix + receipt["id"]!.stringValue!)
    let provisioning = receipt
    _ = try await fixture.during(
      "fixture.provision",
      [
        "plan_id": receipt["id"]!, "expected_revision": .integer(1),
        "confirm_provision": .bool(true),
      ]
    ) { service, _ in
      let result = try await service.call(
        name: "host.workspaces.register", arguments: ["worktree": .object(provisioning)])
      try #require(result.isError == false)
      return try .encoded(result)
    }
    receipt["state"] = .string("removal_planned")
    receipt["revision"] = .integer(4)
    let planned = receipt
    let result = try await fixture.duringInvocation(
      "fixture.remove",
      [
        "managed_worktree_id": receipt["id"]!, "expected_revision": .integer(4),
        "confirm_remove": .bool(true),
      ], generic: generic
    ) { service, invocationContext in
      let id = try #require(invocationContext.admission?.hostInvocationID)
      let call = try #require(try fixture.database.hostCallRecordStore().record(id: id))
      #expect(call.admission.action == .projectRemoval)
      #expect(
        call.admission.upstreamName == (generic ? "mcp.tools.call" : "adapter.fixture.remove"))
      #expect(call.admission.authorizationID != nil)
      #expect(!call.requestLeaseIDs.isEmpty)
      let authorized = try await service.call(
        name: "host.workspaces.authorize_removal", arguments: ["worktree": .object(planned)])
      try #require(authorized.isError == false)
      try fixture.removeWorktree(at: planned["path"]!.stringValue!)
      var removing = planned
      removing["state"] = .string("removing")
      removing["revision"] = .integer(5)
      return try await .encoded(
        service.call(name: "host.workspaces.unregister", arguments: ["worktree": .object(removing)])
      )
    }
    #expect(result.objectValue?["isError"] == .bool(false))
    #expect(
      try fixture.database.derivedProjectRegistration(id: receipt["workspace_id"]!.stringValue!)
        == nil)
    #expect(try fixture.database.project(id: receipt["workspace_id"]!.stringValue!) == nil)
    await fixture.close()
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: ["wrong-action", "wrong-id", "wrong-revision", "not-confirmed", "revoked"])
  func genericProvisionCannotBroadenAdmittedArgumentsOrCurrentAuthority(attack: String) async throws
  {
    let evidence = InvocationCallbackEvidence()
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    let receipt = try fixture.worktreeReceipt()
    var arguments: [String: JSONValue] = [
      "plan_id": receipt["id"]!, "expected_revision": .integer(1), "confirm_provision": .bool(true),
    ]
    if attack == "wrong-id" { arguments["plan_id"] = .string(UUID().uuidString.lowercased()) }
    if attack == "wrong-revision" { arguments["expected_revision"] = .integer(2) }
    if attack == "not-confirmed" { arguments["confirm_provision"] = .bool(false) }
    let result = try await checkedInvocationResult(evidence: evidence, revoked: attack == "revoked")
    {
      try await fixture.during(
        attack == "wrong-action" ? "fixture.audit" : "fixture.provision", arguments
      ) { service, _ in
        evidence.entered()
        if attack == "revoked" {
          var grant = try #require(fixture.database.profiles().first { $0.id == .chatGPTOperate })
          try grant.permissions.set(.denied, for: .project("scope"))
          try fixture.database.saveProfile(grant)
          evidence.revoked()
        }
        let callback = try await service.call(
          name: "host.workspaces.register", arguments: ["worktree": .object(receipt)])
        #expect(callback.isError == true)
        evidence.checked()
        return try .encoded(callback)
      }
    }
    if let result {
      #expect(result.objectValue?["isError"] == .bool(true))
    }
    #expect(try fixture.database.project(id: receipt["workspace_id"]!.stringValue!) == nil)
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
    #expect(fixture.payload(result)["owner"]?.objectValue?["workspace_id"] == .string("scope"))
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
        "host.workspaces.register", "host.workspaces.authorize_removal",
        "host.workspaces.unregister", "host.diagnostics.snapshot", "host.invocations.describe",
      ])
    let result = try await fixture.direct("host.unknown", [:])
    #expect(result.objectValue?["isError"] == .bool(true))
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
    #expect(value["workspace_id"] == .string("scope"))
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

  @Test(.timeLimit(.minutes(5)))
  func completedProvisionInvocationsDoNotExhaustTheConnection() async throws {
    let fixture = try HostAuthorityFixture(worktrees: true, worktreeStorage: .application)
    defer { fixture.remove() }
    let started = ContinuousClock.now
    var completed = 0
    defer { #expect(completed == 129) }
    var checkpoints: [String] = []
    do {
      for index in 0..<129 {
        let receipt = try fixture.worktreeReceipt()
        let result = try await fixture.during(
          "fixture.provision",
          [
            "plan_id": receipt["id"]!, "expected_revision": .number(1),
            "confirm_provision": .bool(true),
          ]
        ) { service, _ in
          try await .encoded(
            service.call(
              name: "host.workspaces.register", arguments: ["worktree": .object(receipt)]))
        }
        try #require(
          result.objectValue?["isError"] == .bool(false), "Provision \(index + 1): \(result)")
        let projectID = try #require(receipt["workspace_id"]?.stringValue)
        #expect(try fixture.database.derivedProjectRegistration(id: projectID) != nil)
        completed += 1
        if [1, 32, 64, 96, 128, 129].contains(completed) {
          checkpoints.append("\(completed): \(started.duration(to: .now))")
        }
      }
    } catch {
      Issue.record(
        "Provision capacity failed after \(completed)/129 registrations in \(started.duration(to: .now)); checkpoints: \(checkpoints.joined(separator: ", ")); \(error)"
      )
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func registrationRollbackRequiresItsOriginalLiveInvocation(laterInvocation: Bool) async throws {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    let receipt = try fixture.worktreeReceipt()
    let args: [String: JSONValue] = [
      "plan_id": receipt["id"]!, "expected_revision": .number(1),
      "confirm_provision": .bool(true),
    ]
    let registered = try await fixture.during("fixture.provision", args) { service, _ in
      let result = try await service.call(
        name: "host.workspaces.register", arguments: ["worktree": .object(receipt)])
      try #require(result.isError == false)
      if laterInvocation { return try .encoded(result) }
      return try await .encoded(
        service.call(name: "host.workspaces.unregister", arguments: ["worktree": .object(receipt)]))
    }
    #expect(registered.objectValue?["isError"] == .bool(false))
    if laterInvocation {
      let replay = try await fixture.during("fixture.provision", args) { service, _ in
        try await .encoded(
          service.call(
            name: "host.workspaces.unregister", arguments: ["worktree": .object(receipt)]))
      }
      #expect(replay.objectValue?["isError"] == .bool(true))
    }
    let projectID = try #require(receipt["workspace_id"]?.stringValue)
    #expect((try fixture.database.project(id: projectID) != nil) == laterInvocation)
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["missing", "other-principal"])
  func derivedReceiptMustBelongToTheVerifiedPrincipal(principal: String) async throws {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    var receipt = try fixture.worktreeReceipt()
    receipt["principal_id"] = principal == "missing" ? nil : .string(principal)
    let wireReceipt = receipt
    let result = try await fixture.during(
      "fixture.provision",
      [
        "plan_id": receipt["id"]!, "expected_revision": .number(1),
        "confirm_provision": .bool(true),
      ]
    ) { service, _ in
      try await .encoded(
        service.call(
          name: "host.workspaces.register", arguments: ["worktree": .object(wireReceipt)]))
    }
    #expect(result.objectValue?["isError"] == .bool(true))
    #expect(
      try fixture.database.derivedProjectRegistration(id: receipt["workspace_id"]!.stringValue!)
        == nil)
    await fixture.close()
  }

  @Test(.timeLimit(.minutes(1)))
  func receiptCallerIsProvenanceRatherThanResourceOwnership() async throws {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    var receipt = try fixture.worktreeReceipt()
    receipt["caller"] = .string("local-cli")
    let wireReceipt = receipt
    let result = try await fixture.during(
      "fixture.provision",
      [
        "plan_id": receipt["id"]!, "expected_revision": .number(1),
        "confirm_provision": .bool(true),
      ]
    ) { service, _ in
      try await .encoded(
        service.call(
          name: "host.workspaces.register", arguments: ["worktree": .object(wireReceipt)]))
    }
    #expect(result.objectValue?["isError"] == .bool(false))
    #expect(
      try fixture.database.derivedProjectRegistration(id: receipt["workspace_id"]!.stringValue!)?
        .principalID == "fixture-principal")
    await fixture.close()
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

private final class HostAuthorityFixture: @unchecked Sendable {
  enum WorktreeStorage { case project, application }

  let root: URL
  let connection: GatewayDatabaseConnection
  let database: GatewayDatabase
  let runtime: GatewayRuntime
  let service: MCPBoundHostServices
  let peer: HostServiceProbe
  private let storageRoot: URL
  private let managedProjectRoot: URL
  init(
    worktrees: Bool = false, additionalProject: Bool = false,
    requiresControlSession: Bool = false, multiplexed: Bool = false,
    verificationBarrier: HostVerificationBarrier? = nil,
    worktreeStorage: WorktreeStorage = .project
  ) throws {
    peer = HostServiceProbe(multiplexed: multiplexed)
    storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    root = storageRoot.appendingPathComponent("scope")
    managedProjectRoot =
      (worktreeStorage == .project ? root : storageRoot)
      .appendingPathComponent("managed").standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    connection = try GatewayDatabaseConnection(inMemory: ())
    database = GatewayDatabase(connection: connection)
    let project = RegisteredProject(id: "scope", displayName: "Fixture", rootPath: root.path)
    try database.saveProject(project)
    var projects = [project]
    if additionalProject {
      let otherRoot = storageRoot.appendingPathComponent("other")
      try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: false)
      let other = RegisteredProject(id: "other", displayName: "Other", rootPath: otherRoot.path)
      try database.saveProject(other)
      projects.append(other)
    }
    let profile = ProfileGrant(
      id: .chatGPTOperate,
      permissions: fixturePermissions([
        .project("scope"): .granted(.write),
        .plugin("*"): .granted(.use), .mcpServer("probe"): .granted(.all),
      ]),
      fullAccess: true, allowedCallers: [.secureTunnel])
    try database.saveProfile(profile)
    let trace = GatewayTransportTrace(transport: "gateway_socket", socketConnectionID: "connection")
    let context =
      !requiresControlSession
      ? try fixtureConsentedContext(
        database: database, grant: profile, caller: .secureTunnel,
        principalID: "fixture-principal", transportTrace: trace, platform: fixtureHostedPlatform())
      : ExecutionContext(
        caller: .secureTunnel, profileID: .chatGPTOperate, transportTrace: trace,
        trustedPrincipalID: "fixture-principal")
    runtime = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
        profiles: [.init(grant: profile)],
        mcp: .init(servers: [
          .init(
            id: "probe", transport: .stdio, command: "/bin/cat", exposure: .reexport,
            prefix: "adapter", allowedTools: HostServiceProbe.methods,
            toolRisks: Dictionary(
              uniqueKeysWithValues: HostServiceProbe.methods.map { ($0, .projectWrite) }),
            hostServices: true)
        ])),
      context: context,
      database: database, registeredProjects: projects,
      platform: fixtureHostedPlatform(),
      mcpClient: peer,
      requiresControlSession: requiresControlSession)
    let captured = try #require(peer.context(for: "scope"))
    if worktrees {
      try FileManager.default.createDirectory(
        at: managedProjectRoot, withIntermediateDirectories: false)
      let managed = try ProjectPathResolver.canonicalProject(managedProjectRoot)
      let scoped = MCPHostContext(
        runtimeID: captured.launchMetadata.runtimeID,
        context: .init(
          caller: captured.launchMetadata.caller, profileID: captured.launchMetadata.profileID,
          transportTrace: captured.launchMetadata.transportTrace,
          trustedPrincipalID: captured.launchMetadata.principalID),
        projectID: captured.launchMetadata.project.id,
        rootURL: URL(fileURLWithPath: captured.launchMetadata.project.rootPath),
        readOnly: captured.launchMetadata.readOnly, tools: captured.tools,
        managedProjectRoot: managed)
      service = MCPBoundHostServices(
        database: database, directory: try #require(captured.tools), context: scoped,
        origin: "probe", gitExecutable: "fixture-git",
        commandRunner: HostWorktreeGitStub(
          source: captured.launchMetadata.project.rootPath, barrier: verificationBarrier))
    } else {
      service = try #require(try runtime.makeHostServices(context: captured, origin: "probe"))
    }
  }
  func worktreeReceipt() throws -> [String: JSONValue] {
    let id = UUID().uuidString.lowercased()
    let source = root.resolvingSymlinksInPath()
    let component = SHA256.hash(data: Data("scope".utf8)).prefix(12).map {
      String(format: "%02x", $0)
    }.joined()
    let path = managedProjectRoot.appendingPathComponent(component)
      .appendingPathComponent(id)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    #expect(FileManager.default.fileExists(atPath: path.path))
    return [
      "id": .string(id), "workspace_id": .string("codex-worktree-" + id),
      "source_workspace_id": .string("scope"), "source_repository_root": .string(source.path),
      "git_common_directory": .string(source.appendingPathComponent(".git").path),
      "path": .string(path.path), "branch": .string("fixture-" + id),
      "parent_lease_id": .string("fixture-parent"), "profile_id": .string("chatgpt-operate"),
      "principal_id": .string("fixture-principal"),
      "caller": .string("secure-tunnel"), "state": .string("provisioning"), "revision": .number(2),
    ]
  }
  func removeWorktree(at path: String) throws {
    try FileManager.default.removeItem(atPath: path)
    #expect(!FileManager.default.fileExists(atPath: path))
  }
  func during(
    _ method: String, _ arguments: [String: JSONValue] = [:],
    context: InvocationContext = .empty,
    _ body: @escaping @Sendable (MCPBoundHostServices, InvocationContext) async throws -> JSONValue
  ) async throws -> JSONValue {
    let service = service
    peer.setHandler { context in try await body(service, context) }
    defer { peer.setHandler(nil) }
    var args = arguments
    args["project_id"] = .string("scope")
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
    await runtime.shutdown()
  }
  func remove() { try? FileManager.default.removeItem(at: storageRoot) }
}

private final class HostServiceProbe: DownstreamMCPClient, @unchecked Sendable {
  static let methods = [
    "fixture.read", "fixture.audit", "fixture.provision", "fixture.remove",
    "codex.diagnostics.snapshot",
  ]
  private static let observedTools: [MCPTool] = methods.map { name in
    let action = [
      "fixture.audit": "diagnostics.snapshot", "fixture.provision": "workspaces.provision",
      "fixture.remove": "workspaces.remove",
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
    init(multiplexed: Bool) { self.multiplexed = multiplexed }
  }
  private let state: State
  private let hostContext: MCPHostContext?

  init(multiplexed: Bool = false) {
    state = State(multiplexed: multiplexed)
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
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  ) -> any DownstreamMCPClient {
    let scoped = hostContext as? MCPHostContext
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
    guard ready.wait(timeout: .now() + 10) == .success else {
      task.cancel()
      throw MCPHostServiceError.denied("Fixture callback timed out.")
    }
    return try box.get()
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

/// Fixed Git-layout metadata keeps these host contract tests inside the hosted fixture.
private struct HostWorktreeGitStub: CommandRunning {
  let source: String
  var barrier: HostVerificationBarrier? = nil
  func run(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    try barrier?.pauseIfArmed()
    #expect(executable == "fixture-git")
    let output: String
    switch arguments {
    case ["rev-parse", "--show-toplevel"]: output = try #require(workingDirectory).path
    case ["rev-parse", "--git-common-dir"]: output = source + "/.git"
    case ["worktree", "list", "--porcelain", "-z"]: output = ""
    default: throw MCPHostServiceError.denied("Unexpected fixture Git command.")
    }
    return .init(
      executable: executable, arguments: arguments, exitCode: 0, timedOut: false,
      stdout: output + "\n", stderr: "", stdoutTruncated: false, stderrTruncated: false)
  }
  func runData(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandDataResult {
    throw MCPHostServiceError.denied("Unexpected fixture binary command.")
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

private final class HostVerificationBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private var armed = false
  private let entered = DispatchSemaphore(value: 0)
  private let resumed = DispatchSemaphore(value: 0)
  func arm() { lock.withLock { armed = true } }
  func pauseIfArmed() throws {
    let pause = lock.withLock {
      let value = armed
      armed = false
      return value
    }
    guard pause else { return }
    entered.signal()
    guard resumed.wait(timeout: .now() + 10) == .success else {
      throw MCPHostServiceError.denied("Fixture verification barrier timed out.")
    }
  }
  private func waitForEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
  func waitUntilEntered() async throws {
    let success = await Task.detached { self.waitForEntry() }.value
    try #require(success)
  }
  func resume() { resumed.signal() }
}

@Suite(
  .nativeIntegration, .serialized, .timeLimit(.minutes(2)),
  .enabled(
    if: ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_PLUGIN_CONSUMER_WORKTREE"] != nil,
    "Build the companion fixture in an isolated plugin checkout to run consumer acceptance."))
struct PluginWorktreeConsumerTests {
  @Test(arguments: [false, true])
  func unchangedConsumerRemovesRealWorktreeThroughLiveHost(generic: Bool) async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let source = fixture.root.resolvingSymlinksInPath()
    let managed = source.deletingLastPathComponent().appendingPathComponent("managed")
    try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: false)
    let git = PluginWorktreeConsumerNativeGit(home: source)
    _ = try git.setup(["init", "-q"], at: source)
    _ = try git.setup(
      [
        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "test: baseline",
      ], at: source)
    let id = UUID().uuidString.lowercased()
    let component = SHA256.hash(data: Data("scope".utf8)).prefix(12).map {
      String(format: "%02x", $0)
    }.joined()
    let target = managed.appendingPathComponent(component).appendingPathComponent(id)
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try git.setup(["worktree", "add", "-q", "-b", "fixture-" + id, target.path], at: source)
    let head = try git.setup(["rev-parse", "HEAD"], at: target)
      .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let captured = try #require(fixture.peer.context(for: "scope"))
    let scoped = MCPHostContext(
      runtimeID: captured.launchMetadata.runtimeID,
      context: .init(
        caller: captured.launchMetadata.caller, profileID: captured.launchMetadata.profileID,
        transportTrace: captured.launchMetadata.transportTrace,
        trustedPrincipalID: captured.launchMetadata.principalID),
      projectID: "scope", rootURL: source, readOnly: false, tools: captured.tools,
      managedProjectRoot: managed)
    let service = MCPBoundHostServices(
      database: fixture.database, directory: try #require(captured.tools), context: scoped,
      origin: "probe", gitExecutable: "/usr/bin/git", commandRunner: git)
    let now = Date().timeIntervalSinceReferenceDate
    let record: [String: JSONValue] = [
      "id": .string(id), "source_workspace_id": .string("scope"),
      "workspace_id": .string("codex-worktree-" + id),
      "source_repository_root": .string(source.path),
      "git_common_directory": .string(source.appendingPathComponent(".git").path),
      "path": .string(target.path), "branch": .string("fixture-" + id),
      "start_point": .string("HEAD"), "head_oid": .string(head), "agent_id": .string("fixture"),
      "parent_lease_id": .string("fixture-parent"), "profile_id": .string("chatgpt-operate"),
      "principal_id": .string("fixture-principal"), "caller": .string("secure-tunnel"),
      "ttl_seconds": .integer(600), "state": .string("provisioning"), "revision": .integer(2),
      "created_at": .number(now), "updated_at": .number(now),
    ]
    let owner: JSONValue = .object([
      "workspace_id": .string("scope"), "profile_id": .string("chatgpt-operate"),
      "principal_id": .string("fixture-principal"), "caller": .string("secure-tunnel"),
      "transport": .string("gateway_socket"), "socket_connection_id": .string("connection"),
    ])
    let bridge = PluginWorktreeConsumerHostBridge(
      root: source, managed: managed, service: service, database: fixture.database, owner: owner)
    do {
      let registered = try await fixture.duringInvocation(
        "fixture.provision",
        [
          "plan_id": .string(id), "expected_revision": .integer(1),
          "confirm_provision": .bool(true),
        ],
        generic: generic
      ) { _, invocation in
        try await bridge.run(mode: "register", record: record, invocation: invocation)
        return .object(["isError": .bool(false)])
      }
      #expect(registered.objectValue?["isError"] != .bool(true))
      #expect(try fixture.database.derivedProjectRegistration(id: "codex-worktree-" + id) != nil)
      var removal = record
      removal["state"] = .string("removal_planned")
      removal["revision"] = .integer(4)
      removal["plan_expires_at"] = .number(now + 600)
      let planned = removal
      let removed = try await fixture.duringInvocation(
        "fixture.remove",
        [
          "managed_worktree_id": .string(id), "expected_revision": .integer(4),
          "confirm_remove": .bool(true),
        ], generic: generic
      ) { _, invocation in
        let callID = try #require(invocation.admission?.hostInvocationID)
        let call = try #require(try fixture.database.hostCallRecordStore().record(id: callID))
        #expect(call.admission.action == .projectRemoval)
        #expect(
          call.admission.upstreamName == (generic ? "mcp.tools.call" : "adapter.fixture.remove"))
        #expect(call.admission.authorizationID != nil && !call.requestLeaseIDs.isEmpty)
        try await bridge.run(mode: "remove", record: planned, invocation: invocation)
        return .object(["isError": .bool(false)])
      }
      #expect(removed.objectValue?["isError"] != .bool(true))
      #expect(!FileManager.default.fileExists(atPath: target.path))
      #expect(try fixture.database.derivedProjectRegistration(id: "codex-worktree-" + id) == nil)
      #expect(try fixture.database.project(id: "codex-worktree-" + id) == nil)
      let inventory = try git.setup(["worktree", "list", "--porcelain", "-z"], at: source).stdout
      #expect(!inventory.contains("worktree " + target.path))
      try await bridge.run(mode: "replay", record: planned, invocation: nil)
      await service.close()
      await fixture.close()
    } catch {
      await service.close()
      await fixture.close()
      throw error
    }
  }
}

private struct PluginWorktreeConsumerHostBridge: Sendable {
  let root: URL
  let managed: URL
  let service: MCPBoundHostServices
  let database: GatewayDatabase
  let owner: JSONValue

  func run(mode: String, record: [String: JSONValue], invocation: InvocationContext?) async throws {
    let consumer = try #require(
      ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_PLUGIN_CONSUMER_WORKTREE"])
    let socketPath = root.deletingLastPathComponent().appendingPathComponent("c.sock").path
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(listener >= 0)
    defer {
      Darwin.close(listener)
      unlink(socketPath)
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8)
    try #require(path.count < MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.initializeMemory(as: UInt8.self, repeating: 0)
      $0.copyBytes(from: path)
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try #require(bound == 0 && listen(listener, 1) == 0)
    let input = root.appendingPathComponent("consumer-" + mode + ".json")
    try JSONEncoder().encode(
      JSONValue.object([
        "socket_path": .string(socketPath), "mode": .string(mode), "owner": owner,
        "worktree": .object(record), "managed_root": .string(managed.path),
      ])
    ).write(to: input)
    let log = root.appendingPathComponent("consumer-" + mode + ".log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
    process.arguments = [
      "-n", "10", "/usr/bin/swift", "test", "--build-system", "native", "--skip-build",
      "--disable-automatic-resolution", "--no-parallel", "--filter",
      "HostWorktreeConsumerBridgeTests/existingTypedClientUsesCurrentHost",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: consumer)
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path, "TMPDIR": root.path + "/",
      "COMPUTER_MCP_TEST_PLUGIN_CONSUMER_INPUT": input.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
      }
    }
    let descriptor = try await BlockingOperationExecutor(label: "consumer-host-accept").perform {
      var item = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      guard poll(&item, 1, 8_000) > 0 else {
        throw CocoaError(
          .fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Consumer socket timeout"])
      }
      let accepted = accept(listener, nil, nil)
      guard accepted >= 0 else { throw CocoaError(.fileReadUnknown) }
      return accepted
    }
    let transport = try MCPInheritedSocketTransport(
      takingOwnershipOf: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    let server = MCP.Server(
      name: "current-host-consumer-test", version: "1", capabilities: .init(tools: .init()))
    let seen = PluginWorktreeConsumerCallbacks()
    await server.withMethodHandler(MCP.CallTool.self) { params in
      let args = (params.arguments ?? [:]).mapValues(JSONValue.init(sdkValue:))
      if let invocation {
        let id = try #require(invocation.admission?.hostInvocationID)
        let call = try #require(try database.hostCallRecordStore().record(id: id))
        try #require(call.lifecycle == .running)
        try #require(call.admission.authorizationID != nil && !call.requestLeaseIDs.isEmpty)
      }
      let result = try await service.call(name: params.name, arguments: args)
      await seen.append(params.name, arguments: args, isError: result.isError == true)
      return result
    }
    do {
      try await server.start(transport: transport)
      let deadline = ContinuousClock.now + .seconds(45)
      while process.isRunning && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      try #require(!process.isRunning, "Consumer process did not exit within 45 seconds")
      let text = try String(contentsOf: log, encoding: .utf8)
      print("Existing consumer \(mode):\n\(text)")
      try #require(process.terminationStatus == 0, "\(mode): \(text)")
      let calls = await seen.calls
      let expected =
        mode == "register"
        ? ["host.workspaces.register"]
        : mode == "remove"
          ? ["host.workspaces.authorize_removal", "host.workspaces.unregister"]
          : ["host.workspaces.authorize_removal"]
      #expect(calls.map(\.name) == expected)
      #expect(calls.allSatisfy { $0.isError == (mode == "replay") })
      if mode == "remove" {
        #expect(
          calls.map { $0.arguments["worktree"]?.objectValue?["revision"]?.intValue } == [4, 5])
        #expect(
          calls.map { $0.arguments["worktree"]?.objectValue?["state"]?.stringValue }
            == ["removal_planned", "removing"])
      }
      await transport.disconnect()
      await server.stop()
    } catch {
      await transport.disconnect()
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

private struct PluginWorktreeConsumerNativeGit: CommandRunning {
  let home: URL

  func run(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    try #require(executable == "/usr/bin/git")
    try #require(
      [
        ["rev-parse", "--show-toplevel"], ["rev-parse", "--git-common-dir"],
        ["worktree", "list", "--porcelain", "-z"],
      ].contains(arguments))
    return try setup(arguments, at: #require(workingDirectory))
  }

  func runData(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandDataResult {
    throw MCPHostServiceError.denied("Unexpected binary Git operation in consumer fixture.")
  }

  func setup(_ arguments: [String], at directory: URL) throws -> CommandResult {
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
    return .init(
      executable: "/usr/bin/git", arguments: arguments, exitCode: process.terminationStatus,
      timedOut: false, stdout: stdout, stderr: stderr, stdoutTruncated: false,
      stderrTruncated: false)
  }
}
