import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class GatewayDatabaseTests {
  @Test
  func testPersistsWorkspacesProfilesProvidersAndAuditWithoutPayloadContent() throws {
    let database = try GatewayDatabase(inMemory: ())
    let timestamp = Date(timeIntervalSince1970: 1_000)
    let workspace = RegisteredWorkspace(
      id: "workspace-1",
      displayName: "Example",
      rootPath: "/tmp/example",
      bookmarkData: Data([1, 2, 3]),
      createdAt: timestamp,
      updatedAt: timestamp
    )
    try database.saveWorkspace(workspace)

    let profile = ProfileGrant(
      id: .localAdmin,
      capabilityIDs: ["file.write", "shell.run"],
      workspaceIDs: [workspace.id],
      allowedCallers: [],
      fullShellEnabled: true
    )
    try database.saveProfile(profile)

    let provider = ProviderState(
      id: "codex-app-server",
      kind: "codex-app-server",
      executablePath: "/usr/local/bin/codex",
      observedVersion: "1.0",
      health: "ready",
      checkedAt: timestamp
    )
    try database.saveProviderState(provider)

    let audit = AuditEvent(
      occurredAt: timestamp,
      requestID: "request-1",
      mcpRequestID: "mcp-request-1",
      caller: .secureTunnel,
      transport: "gateway_socket",
      socketConnectionID: "socket-1",
      tunnelInstanceID: "tunnel-instance-1",
      tunnelProfileID: "computer-mcp",
      profileID: .chatGPTOperate,
      workspaceID: workspace.id,
      capabilityID: "file.write",
      decision: .allowed,
      inputDigest: "sha256:input",
      outputDigest: "sha256:output",
      outputByteCount: 12
    )
    try database.recordAudit(audit)

    #expect((try database.workspaces()) == ([workspace]))
    #expect((try database.profiles()) == ([profile]))
    #expect((try database.providerStates()) == ([provider]))
    #expect((try database.auditEvents()) == ([audit]))
  }

  @Test
  func testOperationTicketLifecycleIsSingleUseAndRecordsSuccess() throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 1_000)
    let ticket = OperationTicket(
      id: "ticket-1",
      capabilityID: "file.trash",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      workspaceID: "workspace-1",
      inputDigest: "sha256:input",
      expiresAt: now.addingTimeInterval(30)
    )
    try database.saveOperationTicket(ticket)

    let executing = try database.beginOperationTicket(
      id: ticket.id,
      principalID: ticket.principalID,
      invocationID: "invocation-1",
      parentRequestID: "commit-request-1",
      at: now
    )
    #expect((executing.state) == (.executing))
    #expect((executing.invocationID) == ("invocation-1"))
    #expect((executing.parentRequestID) == ("commit-request-1"))
    #expect((executing.executingAt) == (now))

    let succeeded = try database.finishOperationTicket(
      id: ticket.id,
      invocationID: "invocation-1",
      state: .succeeded,
      at: now.addingTimeInterval(1)
    )
    #expect((succeeded.state) == (.succeeded))
    #expect((succeeded.completedAt) == (now.addingTimeInterval(1)))
    #expect((succeeded.failureCode) == nil)

    expectThrows(
      try database.beginOperationTicket(
        id: ticket.id,
        principalID: ticket.principalID,
        invocationID: "invocation-2",
        parentRequestID: "commit-request-2",
        at: now
      )
    ) { error in
      guard case GatewayDatabaseError.operationTicketUnavailable = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
  }

  @Test
  func testOperationTicketExpiryFailsPreparedTicket() throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 1_000)
    let expired = OperationTicket(
      id: "ticket-2",
      capabilityID: "file.trash",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      inputDigest: "sha256:expired",
      expiresAt: now.addingTimeInterval(-1)
    )
    try database.saveOperationTicket(expired)
    expectThrows(
      try database.beginOperationTicket(
        id: expired.id,
        principalID: expired.principalID,
        invocationID: "expired-invocation",
        parentRequestID: "expired-request",
        at: now
      )
    ) { error in
      #expect((error as? GatewayDatabaseError) == (.operationTicketExpired(expired.id)))
    }
    let stored = try #require(try database.operationTicket(id: expired.id))
    #expect((stored.state) == (.failed))
    #expect((stored.completedAt) == (now))
    #expect((stored.failureCode) == ("operations.ticket_expired"))
  }

  @Test
  func testConcurrentOperationTicketClaimAllowsExactlyOneInvocation() throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 1_000)
    let ticket = OperationTicket(
      id: "ticket-concurrent",
      capabilityID: "file.trash",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      inputDigest: "sha256:concurrent",
      expiresAt: now.addingTimeInterval(30)
    )
    try database.saveOperationTicket(ticket)
    let claims = ConcurrentTicketClaims()

    DispatchQueue.concurrentPerform(iterations: 2) { index in
      let invocationID = "invocation-\(index)"
      do {
        _ = try database.beginOperationTicket(
          id: ticket.id,
          principalID: ticket.principalID,
          invocationID: invocationID,
          parentRequestID: "request-\(index)",
          at: now
        )
        claims.recordSuccess(invocationID)
      } catch {
        claims.recordFailure(error)
      }
    }

    #expect((claims.successes.count) == (1))
    #expect((claims.failures.count) == (1))
    guard let failure = claims.failures.first as? GatewayDatabaseError,
      case .operationTicketUnavailable = failure
    else {
      Issue.record("Expected the losing claim to observe an unavailable ticket.")
      return
    }
    #expect((try database.operationTicket(id: ticket.id)?.invocationID) == (claims.successes.first))
  }

  @Test
  func testRuntimeSettingsPersistAndReplaceValues() throws {
    let database = try GatewayDatabase(inMemory: ())

    #expect((try database.runtimeSetting(key: "active-gateway-profile")) == nil)
    try database.saveRuntimeSetting(
      key: "active-gateway-profile",
      value: GatewayProfileID.chatGPTObserve.rawValue
    )
    #expect(
      (try database.runtimeSetting(key: "active-gateway-profile"))
        == (GatewayProfileID.chatGPTObserve.rawValue))

    try database.saveRuntimeSetting(
      key: "active-gateway-profile",
      value: GatewayProfileID.chatGPTOperate.rawValue
    )
    #expect(
      (try database.runtimeSetting(key: "active-gateway-profile"))
        == (GatewayProfileID.chatGPTOperate.rawValue))
  }

  @Test
  func testFindsAuditEventByExactRequestIDBeyondBoundedRecentPage() throws {
    let database = try GatewayDatabase(inMemory: ())
    let target = AuditEvent(
      id: "audit-target",
      occurredAt: Date(timeIntervalSince1970: 1),
      requestID: "gateway-request-target",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      capabilityID: "codex.app.status",
      decision: .allowed
    )
    try database.recordAudit(target)
    for index in 0..<250 {
      try database.recordAudit(
        AuditEvent(
          id: "audit-\(index)",
          occurredAt: Date(timeIntervalSince1970: TimeInterval(index + 2)),
          requestID: "gateway-request-\(index)",
          caller: .secureTunnel,
          profileID: .chatGPTOperate,
          capabilityID: "codex.app.events.read",
          decision: .allowed
        )
      )
    }

    #expect((try database.auditEvent(requestID: target.requestID)) == (target))
    #expect((try database.auditEvent(requestID: "missing-request")) == nil)
  }
}

private final class ConcurrentTicketClaims: @unchecked Sendable {
  private let lock = NSLock()
  private var storedSuccesses: [String] = []
  private var storedFailures: [Error] = []

  var successes: [String] {
    lock.withLock { storedSuccesses }
  }

  var failures: [Error] {
    lock.withLock { storedFailures }
  }

  func recordSuccess(_ invocationID: String) {
    lock.withLock {
      storedSuccesses.append(invocationID)
    }
  }

  func recordFailure(_ error: Error) {
    lock.withLock {
      storedFailures.append(error)
    }
  }
}
