import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)
final class CodexElevationGrantTests {
  @Test
  func testThreadStartPermanentlyBindsAnUnboundGrantToTheCreatedThread() throws {
    let fixture = try makeFixture()
    let requester = secureRequester(workspaceID: fixture.workspace.id)
    let approved = try approvedGrant(
      fixture: fixture,
      requester: requester,
      threadID: nil,
      mode: .boundedTime,
      maximumDurationSeconds: 300
    )
    let claim = try #require(
      try fixture.database.claimCodexElevationGrant(
        workspaceID: fixture.workspace.id,
        canonicalRoot: canonicalRoot(fixture.workspace.rootPath),
        profileID: requester.profileID ?? "",
        requestingCaller: requester.caller ?? "",
        requestingConnectionID: requester.socketConnectionID,
        threadID: nil,
        runtimeID: "runtime-startup",
        action: .threadStart,
        now: fixture.now
      )
    )

    let activated = try fixture.database.commitCodexElevationClaim(
      claim,
      runtimeID: "runtime-startup",
      threadID: "thread-created",
      turnID: nil,
      now: fixture.now
    )

    #expect(activated.id == approved.id)
    #expect(activated.threadID == "thread-created")
    #expect(activated.state == .active)
    #expect(
      try fixture.database.claimCodexElevationGrant(
        workspaceID: fixture.workspace.id,
        canonicalRoot: canonicalRoot(fixture.workspace.rootPath),
        profileID: requester.profileID ?? "",
        requestingCaller: requester.caller ?? "",
        requestingConnectionID: requester.socketConnectionID,
        threadID: "thread-other",
        runtimeID: "runtime-other",
        action: .turnStart,
        now: fixture.now.addingTimeInterval(1)
      ) == nil
    )
  }

  @Test
  func testSecureTunnelCannotSelfApproveButLocalAdministratorCan() throws {
    let fixture = try makeFixture()
    let requester = secureRequester(workspaceID: fixture.workspace.id)
    let pending = try CodexElevationGrantService.request(
      owner: requester,
      database: fixture.database,
      threadID: "thread-1",
      mode: .nextTurn,
      reason: "Run one reviewed operation.",
      maximumDurationSeconds: 300,
      maximumTurnCount: nil,
      now: fixture.now
    )

    expectThrows(
      try CodexElevationGrantService.approve(
        id: pending.id,
        owner: requester,
        database: fixture.database,
        now: fixture.now
      )
    ) { error in
      #expect(error as? CodexElevationGrantError == .localApprovalRequired)
    }
    let remoteLocalAdmin = CodexRuntimeOwner(
      workspaceID: fixture.workspace.id,
      profileID: GatewayProfileID.localAdmin.rawValue,
      caller: GatewayCallerKind.secureTunnel.rawValue,
      transport: "gateway_socket",
      socketConnectionID: "remote-admin",
      tunnelInstanceID: "tunnel-1",
      tunnelProfileID: "computer-mcp"
    )
    expectThrows(
      try CodexElevationGrantService.approve(
        id: pending.id,
        owner: remoteLocalAdmin,
        database: fixture.database,
        now: fixture.now
      )
    ) { error in
      #expect(error as? CodexElevationGrantError == .localApprovalRequired)
    }

    let approved = try CodexElevationGrantService.approve(
      id: pending.id,
      owner: localAdministrator(workspaceID: fixture.workspace.id),
      database: fixture.database,
      now: fixture.now
    )
    #expect(approved.state == .approved)
    #expect(approved.localApproverCaller == GatewayCallerKind.localCLI.rawValue)
  }

  @Test
  func testOverduePendingRequestsExpireBeforeDenialOrRevocation() throws {
    let fixture = try makeFixture()
    let requester = secureRequester(workspaceID: fixture.workspace.id)
    let administrator = localAdministrator(workspaceID: fixture.workspace.id)
    let overdue = fixture.now.addingTimeInterval(901)
    let pendingDenial = try CodexElevationGrantService.request(
      owner: requester,
      database: fixture.database,
      threadID: "thread-deny-expired",
      mode: .nextTurn,
      reason: "Verify the approval deadline remains authoritative.",
      maximumDurationSeconds: 300,
      maximumTurnCount: nil,
      now: fixture.now
    )

    expectThrows(
      try CodexElevationGrantService.deny(
        id: pendingDenial.id,
        owner: administrator,
        database: fixture.database,
        now: overdue
      )
    ) { error in
      #expect(error as? CodexElevationGrantError == .alreadyResolved("expired"))
    }
    let expiredDenial = try #require(
      try fixture.database.codexElevationGrant(id: pendingDenial.id)
    )
    #expect(expiredDenial.state == .expired)
    #expect(expiredDenial.resolutionReason == "Local approval deadline expired.")

    let pendingRevocation = try CodexElevationGrantService.request(
      owner: requester,
      database: fixture.database,
      threadID: "thread-revoke-expired",
      mode: .nextTurn,
      reason: "Verify requester revocation cannot replace expiration.",
      maximumDurationSeconds: 300,
      maximumTurnCount: nil,
      now: fixture.now
    )
    expectThrows(
      try CodexElevationGrantService.revoke(
        id: pendingRevocation.id,
        owner: requester,
        database: fixture.database,
        now: overdue
      )
    ) { error in
      #expect(error as? CodexElevationGrantError == .alreadyResolved("expired"))
    }
    let expiredRevocation = try #require(
      try fixture.database.codexElevationGrant(id: pendingRevocation.id)
    )
    #expect(expiredRevocation.state == .expired)
    #expect(expiredRevocation.resolutionReason == "Local approval deadline expired.")
  }

  @Test
  func testTunnelOnlyRequesterUsesTunnelInstanceAsConnectionBinding() throws {
    let fixture = try makeFixture()
    let requester = CodexRuntimeOwner(
      workspaceID: fixture.workspace.id,
      profileID: GatewayProfileID.cloudflareOperate.rawValue,
      caller: GatewayCallerKind.cloudflareTunnel.rawValue,
      transport: "cloudflare_tunnel",
      socketConnectionID: nil,
      tunnelInstanceID: "cloudflare-instance",
      tunnelProfileID: "computer-mcp"
    )
    let pending = try CodexElevationGrantService.request(
      owner: requester,
      database: fixture.database,
      threadID: "thread-1",
      mode: .nextTurn,
      reason: "Run one reviewed tunnel operation.",
      maximumDurationSeconds: 300,
      maximumTurnCount: nil,
      now: fixture.now
    )
    #expect(pending.requestingConnectionID == "tunnel:cloudflare-instance")
    _ = try CodexElevationGrantService.approve(
      id: pending.id,
      owner: localAdministrator(workspaceID: fixture.workspace.id),
      database: fixture.database,
      now: fixture.now
    )

    #expect(
      try fixture.database.claimCodexElevationGrant(
        workspaceID: fixture.workspace.id,
        canonicalRoot: canonicalRoot(fixture.workspace.rootPath),
        profileID: GatewayProfileID.cloudflareOperate.rawValue,
        requestingCaller: GatewayCallerKind.cloudflareTunnel.rawValue,
        requestingConnectionID: "tunnel:another-instance",
        threadID: "thread-1",
        runtimeID: "runtime-wrong-tunnel",
        action: .turnStart,
        now: fixture.now
      ) == nil
    )
    #expect(
      try fixture.database.claimCodexElevationGrant(
        workspaceID: fixture.workspace.id,
        canonicalRoot: canonicalRoot(fixture.workspace.rootPath),
        profileID: GatewayProfileID.cloudflareOperate.rawValue,
        requestingCaller: GatewayCallerKind.cloudflareTunnel.rawValue,
        requestingConnectionID: requester.elevationConnectionID,
        threadID: "thread-1",
        runtimeID: "runtime-bound-tunnel",
        action: .turnStart,
        now: fixture.now
      ) != nil
    )
  }

  @Test
  func testLocalAdministratorCannotResolveGrantFromAnotherWorkspace() throws {
    let fixture = try makeFixture()
    let requester = secureRequester(workspaceID: fixture.workspace.id)
    let pending = try CodexElevationGrantService.request(
      owner: requester,
      database: fixture.database,
      threadID: "thread-1",
      mode: .nextTurn,
      reason: "Remain inside the exact workspace boundary.",
      maximumDurationSeconds: 300,
      maximumTurnCount: nil,
      now: fixture.now
    )
    let otherWorkspaceAdministrator = localAdministrator(workspaceID: "workspace-other")

    expectThrows(
      try CodexElevationGrantService.approve(
        id: pending.id,
        owner: otherWorkspaceAdministrator,
        database: fixture.database,
        now: fixture.now
      )
    ) { error in
      #expect(error as? CodexElevationGrantError == .unknown(pending.id))
    }
    expectThrows(
      try CodexElevationGrantService.deny(
        id: pending.id,
        owner: otherWorkspaceAdministrator,
        database: fixture.database,
        now: fixture.now
      )
    ) { error in
      #expect(error as? CodexElevationGrantError == .unknown(pending.id))
    }
    expectThrows(
      try CodexElevationGrantService.revoke(
        id: pending.id,
        owner: otherWorkspaceAdministrator,
        database: fixture.database,
        now: fixture.now
      )
    ) { error in
      #expect(error as? CodexElevationGrantError == .unknown(pending.id))
    }
    #expect(try fixture.database.codexElevationGrant(id: pending.id)?.state == .pending)
  }

  @Test
  func testElevationClaimRequiresEveryExactBinding() throws {
    let fixture = try makeFixture()
    let requester = secureRequester(workspaceID: fixture.workspace.id)
    let approved = try approvedGrant(
      fixture: fixture,
      requester: requester,
      threadID: "thread-1",
      mode: .nextTurn
    )
    let root = canonicalRoot(fixture.workspace.rootPath)

    #expect(
      try claim(
        fixture: fixture,
        workspaceID: "wrong-workspace",
        canonicalRoot: root,
        profileID: requester.profileID ?? "",
        caller: requester.caller ?? "",
        connectionID: requester.socketConnectionID,
        threadID: "thread-1"
      ) == nil
    )
    #expect(
      try claim(
        fixture: fixture,
        workspaceID: fixture.workspace.id,
        canonicalRoot: "/tmp/wrong-root",
        profileID: requester.profileID ?? "",
        caller: requester.caller ?? "",
        connectionID: requester.socketConnectionID,
        threadID: "thread-1"
      ) == nil
    )
    #expect(
      try claim(
        fixture: fixture,
        workspaceID: fixture.workspace.id,
        canonicalRoot: root,
        profileID: "wrong-profile",
        caller: requester.caller ?? "",
        connectionID: requester.socketConnectionID,
        threadID: "thread-1"
      ) == nil
    )
    #expect(
      try claim(
        fixture: fixture,
        workspaceID: fixture.workspace.id,
        canonicalRoot: root,
        profileID: requester.profileID ?? "",
        caller: "wrong-caller",
        connectionID: requester.socketConnectionID,
        threadID: "thread-1"
      ) == nil
    )
    #expect(
      try claim(
        fixture: fixture,
        workspaceID: fixture.workspace.id,
        canonicalRoot: root,
        profileID: requester.profileID ?? "",
        caller: requester.caller ?? "",
        connectionID: "wrong-connection",
        threadID: "thread-1"
      ) == nil
    )
    #expect(
      try claim(
        fixture: fixture,
        workspaceID: fixture.workspace.id,
        canonicalRoot: root,
        profileID: requester.profileID ?? "",
        caller: requester.caller ?? "",
        connectionID: requester.socketConnectionID,
        threadID: "wrong-thread"
      ) == nil
    )

    let matching = try #require(
      try claim(
        fixture: fixture,
        workspaceID: fixture.workspace.id,
        canonicalRoot: root,
        profileID: requester.profileID ?? "",
        caller: requester.caller ?? "",
        connectionID: requester.socketConnectionID,
        threadID: "thread-1"
      )
    )
    #expect(matching.grant.id == approved.id)
    try fixture.database.abortCodexElevationClaim(matching, now: fixture.now)
  }

  @Test
  func testExpiredRevokedAndStaleClaimsCannotLeakElevation() throws {
    let fixture = try makeFixture()
    let requester = secureRequester(workspaceID: fixture.workspace.id)
    let expiring = try approvedGrant(
      fixture: fixture,
      requester: requester,
      threadID: "thread-expiring",
      mode: .threadScopedTTL,
      maximumDurationSeconds: 30
    )
    let root = canonicalRoot(fixture.workspace.rootPath)
    let expiredClaim = try fixture.database.claimCodexElevationGrant(
      workspaceID: fixture.workspace.id,
      canonicalRoot: root,
      profileID: requester.profileID ?? "",
      requestingCaller: requester.caller ?? "",
      requestingConnectionID: requester.socketConnectionID,
      threadID: "thread-expiring",
      runtimeID: "runtime-expired",
      action: .turnStart,
      now: fixture.now.addingTimeInterval(31)
    )
    #expect(expiredClaim == nil)
    #expect(try fixture.database.codexElevationGrant(id: expiring.id)?.state == .expired)

    let revoked = try approvedGrant(
      fixture: fixture,
      requester: requester,
      threadID: "thread-revoked",
      mode: .nextTurn
    )
    _ = try CodexElevationGrantService.revoke(
      id: revoked.id,
      owner: requester,
      database: fixture.database,
      now: fixture.now.addingTimeInterval(1)
    )
    #expect(
      try fixture.database.claimCodexElevationGrant(
        workspaceID: fixture.workspace.id,
        canonicalRoot: root,
        profileID: requester.profileID ?? "",
        requestingCaller: requester.caller ?? "",
        requestingConnectionID: requester.socketConnectionID,
        threadID: "thread-revoked",
        runtimeID: "runtime-revoked",
        action: .turnStart,
        now: fixture.now.addingTimeInterval(2)
      ) == nil
    )

    let restartGrant = try approvedGrant(
      fixture: fixture,
      requester: requester,
      threadID: "thread-restart",
      mode: .nextTurn,
      maximumDurationSeconds: 300
    )
    let firstClaim = try #require(
      try fixture.database.claimCodexElevationGrant(
        workspaceID: fixture.workspace.id,
        canonicalRoot: root,
        profileID: requester.profileID ?? "",
        requestingCaller: requester.caller ?? "",
        requestingConnectionID: requester.socketConnectionID,
        threadID: "thread-restart",
        runtimeID: "runtime-before-restart",
        action: .turnStart,
        now: fixture.now
      )
    )
    #expect(firstClaim.grant.id == restartGrant.id)
    try fixture.database.reconcileCodexElevationGrants(
      now: fixture.now.addingTimeInterval(331)
    )
    let reclaimed = try fixture.database.claimCodexElevationGrant(
      workspaceID: fixture.workspace.id,
      canonicalRoot: root,
      profileID: requester.profileID ?? "",
      requestingCaller: requester.caller ?? "",
      requestingConnectionID: requester.socketConnectionID,
      threadID: "thread-restart",
      runtimeID: "runtime-after-restart",
      action: .turnStart,
      now: fixture.now.addingTimeInterval(332)
    )
    #expect(reclaimed == nil)
    let reconciled = try fixture.database.codexElevationGrant(id: restartGrant.id)
    #expect(reconciled?.state == .invalidated)
    #expect(reconciled?.inFlightClaimID == nil)
    #expect(
      reconciled?.resolutionReason
        == "An elevated start ended without a durable consumption receipt."
    )
  }

  @Test
  func testDiagnosticsReportRequestedAndEffectivePermission() async throws {
    let fixture = try makeFixture()
    let requester = secureRequester(workspaceID: fixture.workspace.id)
    _ = try approvedGrant(
      fixture: fixture,
      requester: requester,
      threadID: nil,
      mode: .boundedTime,
      maximumDurationSeconds: 300
    )

    let snapshot = try await CodexOperationalDiagnostics.snapshot(
      database: fixture.database,
      owner: requester,
      configuredSandbox: .workspaceWrite,
      limit: 100,
      now: fixture.now
    )
    let elevation = snapshot.objectValue?["elevation"]?.objectValue
    #expect(elevation?["configured_default_sandbox"] == .string("workspace-write"))
    #expect(elevation?["requested_sandbox"] == .string("danger-full-access"))
    #expect(elevation?["effective_next_eligible_start"] == .string("danger-full-access"))
    #expect(elevation?["active_turn_unchanged"] == .bool(true))
  }

  @Test
  func testEffectivePermissionUsesConfiguredSafeSandboxAndRemainingGrants() throws {
    let fixture = try makeFixture()
    let requester = secureRequester(workspaceID: fixture.workspace.id)
    let safe = try CodexElevationGrantService.effective(
      owner: requester,
      database: fixture.database,
      threadID: "thread-1",
      configuredSandbox: .readOnly,
      now: fixture.now
    )
    #expect(safe.objectValue?["effective_sandbox"] == .string("read-only"))
    #expect(safe.objectValue?["effective_next_turn"] == .bool(false))

    let first = try approvedGrant(
      fixture: fixture,
      requester: requester,
      threadID: "thread-1",
      mode: .threadScopedTTL
    )
    _ = try approvedGrant(
      fixture: fixture,
      requester: requester,
      threadID: "thread-1",
      mode: .threadScopedTTL
    )
    _ = try CodexElevationGrantService.revoke(
      id: first.id,
      owner: requester,
      database: fixture.database,
      now: fixture.now.addingTimeInterval(1)
    )

    let stillElevated = try CodexElevationGrantService.effective(
      owner: requester,
      database: fixture.database,
      threadID: "thread-1",
      configuredSandbox: .readOnly,
      now: fixture.now.addingTimeInterval(1)
    )
    #expect(
      stillElevated.objectValue?["effective_sandbox"] == .string("danger-full-access")
    )
    #expect(stillElevated.objectValue?["effective_next_turn"] == .bool(true))
    #expect(stillElevated.objectValue?["matching_grants"]?.arrayValue?.count == 1)
  }

  @Test
  func testLocalAdministratorDoesNotMisreportAnotherConnectionGrantAsEffective() throws {
    let fixture = try makeFixture()
    let requester = secureRequester(workspaceID: fixture.workspace.id)
    let pending = try CodexElevationGrantService.request(
      owner: requester,
      database: fixture.database,
      threadID: "thread-1",
      mode: .nextTurn,
      reason: "Keep effective state bound to the requesting connection.",
      maximumDurationSeconds: 300,
      maximumTurnCount: nil,
      now: fixture.now
    )
    _ = try CodexElevationGrantService.approve(
      id: pending.id,
      owner: localAdministrator(workspaceID: fixture.workspace.id),
      database: fixture.database,
      now: fixture.now
    )

    let administratorView = try CodexElevationGrantService.effective(
      owner: localAdministrator(workspaceID: fixture.workspace.id),
      database: fixture.database,
      threadID: "thread-1",
      configuredSandbox: .readOnly,
      now: fixture.now
    )
    #expect(administratorView.objectValue?["effective_sandbox"] == .string("read-only"))
    #expect(administratorView.objectValue?["matching_grants"] == .array([]))

    let requesterView = try CodexElevationGrantService.effective(
      owner: requester,
      database: fixture.database,
      threadID: "thread-1",
      configuredSandbox: .readOnly,
      now: fixture.now
    )
    #expect(requesterView.objectValue?["effective_sandbox"] == .string("danger-full-access"))
    #expect(requesterView.objectValue?["matching_grants"]?.arrayValue?.count == 1)
  }

  @Test
  func testHandoffAndConnectionShutdownInvalidateBoundElevation() async throws {
    let fixture = try makeFixture()
    let requester = secureRequester(workspaceID: fixture.workspace.id)
    let handoffGrant = try approvedGrant(
      fixture: fixture,
      requester: requester,
      threadID: "thread-handoff",
      mode: .threadScopedTTL
    )
    try fixture.database.saveCodexThreadOwnership(
      CodexThreadOwnershipRecord(
        threadID: "thread-handoff",
        workspaceID: fixture.workspace.id,
        workspacePath: fixture.workspace.rootPath,
        runtimeID: "runtime-gone",
        state: .loaded,
        createdAt: fixture.now,
        updatedAt: fixture.now
      )
    )
    _ = try await CodexThreadHandoffService.release(
      threadID: "thread-handoff",
      workspaceID: fixture.workspace.id,
      mode: .graceful,
      interruptActiveTurn: false,
      database: fixture.database
    )
    #expect(
      try fixture.database.codexElevationGrant(id: handoffGrant.id)?.state == .invalidated
    )

    let disconnectGrant = try approvedGrant(
      fixture: fixture,
      requester: requester,
      threadID: nil,
      mode: .boundedTime
    )
    let provider = CodexGatewayProvider(
      configuration: CodexConfig(enabled: true, appServerEnabled: false),
      appServer: nil,
      exec: nil,
      mcp: nil,
      owner: requester,
      database: fixture.database
    )
    await provider.shutdown()
    #expect(
      try fixture.database.codexElevationGrant(id: disconnectGrant.id)?.state == .invalidated
    )
  }

  private func makeFixture() throws -> ElevationFixture {
    let database = try GatewayDatabase(inMemory: ())
    let workspace = RegisteredWorkspace(
      id: "elevation-workspace",
      displayName: "Elevation Fixture",
      rootPath: "/tmp/elevation-workspace"
    )
    try database.saveWorkspace(workspace)
    return ElevationFixture(
      database: database,
      workspace: workspace,
      now: Date(timeIntervalSince1970: 10_000)
    )
  }

  private func approvedGrant(
    fixture: ElevationFixture,
    requester: CodexRuntimeOwner,
    threadID: String?,
    mode: CodexElevationGrantMode,
    maximumDurationSeconds: Int = 300
  ) throws -> CodexElevationGrantRecord {
    let pending = try CodexElevationGrantService.request(
      owner: requester,
      database: fixture.database,
      threadID: threadID,
      mode: mode,
      reason: "Reviewed fixture elevation.",
      maximumDurationSeconds: maximumDurationSeconds,
      maximumTurnCount: mode == .nextTurn ? nil : 10,
      now: fixture.now
    )
    return try CodexElevationGrantService.approve(
      id: pending.id,
      owner: localAdministrator(workspaceID: fixture.workspace.id),
      database: fixture.database,
      now: fixture.now
    )
  }

  private func claim(
    fixture: ElevationFixture,
    workspaceID: String,
    canonicalRoot: String,
    profileID: String,
    caller: String,
    connectionID: String?,
    threadID: String
  ) throws -> CodexElevationClaim? {
    try fixture.database.claimCodexElevationGrant(
      workspaceID: workspaceID,
      canonicalRoot: canonicalRoot,
      profileID: profileID,
      requestingCaller: caller,
      requestingConnectionID: connectionID,
      threadID: threadID,
      runtimeID: "runtime-claim",
      action: .turnStart,
      now: fixture.now
    )
  }
}

private struct ElevationFixture {
  let database: GatewayDatabase
  let workspace: RegisteredWorkspace
  let now: Date
}

private func secureRequester(workspaceID: String) -> CodexRuntimeOwner {
  CodexRuntimeOwner(
    workspaceID: workspaceID,
    profileID: GatewayProfileID.chatGPTOperate.rawValue,
    caller: GatewayCallerKind.secureTunnel.rawValue,
    transport: "gateway_socket",
    socketConnectionID: "secure-connection",
    tunnelInstanceID: "tunnel-1",
    tunnelProfileID: "computer-mcp"
  )
}

private func localAdministrator(workspaceID: String) -> CodexRuntimeOwner {
  CodexRuntimeOwner(
    workspaceID: workspaceID,
    profileID: GatewayProfileID.localAdmin.rawValue,
    caller: GatewayCallerKind.localCLI.rawValue,
    transport: "control_socket",
    socketConnectionID: "local-control",
    tunnelInstanceID: nil,
    tunnelProfileID: nil
  )
}

private func canonicalRoot(_ path: String) -> String {
  URL(fileURLWithPath: path, isDirectory: true)
    .standardizedFileURL.resolvingSymlinksInPath().path
}
