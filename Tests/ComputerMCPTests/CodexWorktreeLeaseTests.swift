import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)
final class CodexWorktreeLeaseTests {
  @Test
  func testExclusiveLeasePreventsConcurrentMutationAndIsIdempotentForOwner() throws {
    let database = try makeDatabase()
    let first = try acquire(database: database, agentID: "agent-a", threadID: "thread-a")
    let retry = try acquire(database: database, agentID: "agent-a", threadID: "thread-a")

    #expect(retry.id == first.id)
    #expect(throws: CodexWorktreeLeaseError.self) {
      try self.acquire(database: database, agentID: "agent-b", threadID: "thread-b")
    }
    #expect(throws: CodexWorktreeLeaseError.self) {
      try CodexWorktreeLeaseManager.validate(
        database: database,
        workspaceID: "workspace-1",
        leaseID: nil,
        threadID: "thread-b"
      )
    }
    try CodexWorktreeLeaseManager.validate(
      database: database,
      workspaceID: "workspace-1",
      leaseID: first.id,
      threadID: "thread-a"
    )
  }

  @Test
  func testLeaseHeartbeatReleaseAndRevisionAreDurable() throws {
    let database = try makeDatabase()
    var lease = try acquire(database: database, agentID: "agent-a", threadID: "thread-a")
    let previousExpiry = lease.expiresAt
    lease = try CodexWorktreeLeaseManager.heartbeat(
      database: database,
      workspaceID: "workspace-1",
      leaseID: lease.id,
      expectedRevision: lease.revision,
      ttlSeconds: 1_800,
      now: lease.heartbeatAt.addingTimeInterval(1)
    )
    #expect(lease.expiresAt > previousExpiry)

    let staleRevision = lease.revision
    lease = try CodexWorktreeLeaseManager.release(
      database: database,
      workspaceID: "workspace-1",
      leaseID: lease.id,
      expectedRevision: lease.revision,
      reason: "Child results reconciled."
    )
    #expect(lease.state == .released)
    #expect(lease.releaseReason == "Child results reconciled.")
    #expect(try database.codexWorktreeLease(id: lease.id) == lease)
    #expect(throws: CodexWorktreeLeaseError.self) {
      try CodexWorktreeLeaseManager.release(
        database: database,
        workspaceID: "workspace-1",
        leaseID: lease.id,
        expectedRevision: staleRevision,
        reason: "stale writer"
      )
    }
  }

  @Test
  func testExpiredCleanupChangesReceiptsOnly() throws {
    let database = try makeDatabase()
    let startedAt = Date()
    let lease = try acquire(
      database: database,
      agentID: "agent-a",
      threadID: "thread-a",
      now: startedAt
    )
    let preview = try CodexWorktreeLeaseManager.cleanupExpired(
      database: database,
      workspaceID: "workspace-1",
      perform: false,
      now: startedAt.addingTimeInterval(901)
    )
    #expect(preview.objectValue?["candidates"]?.arrayValue?.count == 1)
    #expect(preview.objectValue?["filesystem_changes"] == .bool(false))

    let cleanup = try CodexWorktreeLeaseManager.cleanupExpired(
      database: database,
      workspaceID: "workspace-1",
      perform: true,
      now: startedAt.addingTimeInterval(901)
    )
    #expect(cleanup.objectValue?["expired"]?.arrayValue?.count == 1)
    #expect(cleanup.objectValue?["process_signals_sent"] == .bool(false))
    #expect(try database.codexWorktreeLease(id: lease.id)?.state == .expired)
  }

  @Test
  func testIsolatedChildRequiresRegisteredWorkspaceAndParentLineage() throws {
    let database = try makeDatabase()
    try database.saveWorkspace(
      RegisteredWorkspace(
        id: "workspace-2",
        displayName: "Isolated worktree",
        rootPath: "/tmp/workspace-2"
      )
    )
    let parent = try acquire(database: database, agentID: "parent", threadID: "thread-parent")
    let child = try CodexWorktreeLeaseManager.acquire(
      database: database,
      workspaceID: "workspace-2",
      agentID: "child",
      threadID: "thread-child",
      runID: nil,
      parentLeaseID: parent.id,
      branch: "codex/child",
      mode: .isolatedWorktree,
      ttlSeconds: 900,
      liveRuntimeStatus: .object(["runtimes": .array([])])
    )

    #expect(child.mode == .isolatedWorktree)
    #expect(child.parentLeaseID == parent.id)
    #expect(child.workspacePath == "/tmp/workspace-2")
    #expect(child.branch == "codex/child")
  }

  @Test
  func testPersistedLeaseInputsAreBoundedAndCredentialTextIsNotStored() throws {
    let database = try makeDatabase()
    #expect(throws: CodexWorktreeLeaseError.self) {
      try self.acquire(
        database: database,
        agentID: "token=lease-secret",
        threadID: "thread-a"
      )
    }
    var lease = try acquire(database: database, agentID: "agent-a", threadID: "thread-a")
    lease = try CodexWorktreeLeaseManager.release(
      database: database,
      workspaceID: "workspace-1",
      leaseID: lease.id,
      expectedRevision: lease.revision,
      reason: "completed; Authorization: Bearer lease-secret"
    )
    #expect(lease.releaseReason?.contains("[REDACTED]") == true)
    #expect(lease.releaseReason?.contains("lease-secret") == false)
  }

  private func makeDatabase() throws -> GatewayDatabase {
    let database = try GatewayDatabase(inMemory: ())
    try database.saveWorkspace(
      RegisteredWorkspace(
        id: "workspace-1",
        displayName: "Primary",
        rootPath: "/tmp/workspace-1"
      )
    )
    return database
  }

  private func acquire(
    database: GatewayDatabase,
    agentID: String,
    threadID: String,
    now: Date = Date()
  ) throws -> CodexWorktreeLease {
    try CodexWorktreeLeaseManager.acquire(
      database: database,
      workspaceID: "workspace-1",
      agentID: agentID,
      threadID: threadID,
      runID: nil,
      parentLeaseID: nil,
      branch: "codex/primary",
      mode: .exclusive,
      ttlSeconds: 900,
      liveRuntimeStatus: .object(["runtimes": .array([])]),
      now: now
    )
  }
}
