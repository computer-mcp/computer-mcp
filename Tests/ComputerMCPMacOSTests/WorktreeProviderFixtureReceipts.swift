import ComputerMCPPermissions
import ComputerMCPSandbox
import Darwin
import Foundation
import GRDB
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPersistence
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPWorktrees

/// The exit child reports identities observed by the original scenario. Both
/// processes check committed state against them before the parent can delete it.
struct WorktreeProviderFixtureReceipts: Codable {
  struct Provider: Codable {
    let projectID: String
    let executionID: UUID
    let childID: UUID
    let member: ExecutionMember
  }

  struct Session: Codable {
    let id: String
    let principal: Principal
  }

  enum ReadbackError: LocalizedError, Equatable {
    case incomplete(String)
    case invalidHandoff

    var errorDescription: String? {
      switch self {
      case .incomplete(let receipt): "Incomplete worktree fixture receipt: \(receipt)"
      case .invalidHandoff:
        "The worktree fixture child did not return the expected root and receipts."
      }
    }
  }

  let root: WorktreeDirectoryIdentity
  let ownerID: UUID
  let sessions: [Session]
  let target: Provider
  let sibling: Provider

  private static let frame = "worktree-provider-fixture-receipts "
  private static let temporaryParent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)

  private static func rootName(for pid: pid_t) throws -> String {
    guard let process = DarwinProcessIdentity.current(pid: pid)?.identity else {
      throw ReadbackError.invalidHandoff
    }
    return "cm-worktree-provider-\(process.pid)-\(process.uniqueID)"
  }

  static func createRoot(for pid: pid_t) throws -> WorktreeDirectory {
    try WorktreeDirectory(physicalURL: temporaryParent)
      .child(rootName(for: pid), create: true, exclusive: true)
  }

  /// Swift 6.2 exit closures cannot capture the parent fixture. The direct
  /// parent's kernel identity locates its exclusively created directory.
  static func openParentRoot() throws -> WorktreeDirectory {
    try WorktreeDirectory(physicalURL: temporaryParent).child(rootName(for: getppid()))
  }

  static func capture(
    root: WorktreeDirectory, runtime: GatewayPermissionRuntime, sessions: [GatewayControlSession],
    target: (String, UUID, DarwinProcessIdentity), sibling: (String, UUID, DarwinProcessIdentity)
  ) throws -> Self {
    let connections = try sessions.map { session in
      let subject = try GatewayPermissionSubject(
        context: .init(
          caller: session.caller, profileID: session.profileID,
          trustedPrincipalID: session.principalID))
      return Session(id: session.id, principal: subject.principal)
    }
    return try runtime.store.readWithDatabase { database, _ in
      func provider(_ project: String, _ id: UUID, _ identity: DarwinProcessIdentity) throws
        -> Provider
      {
        let member = ExecutionMember(processID: identity.pid, identity: identity.uniqueID)
        guard let record = try ExecutionRuntimeRecord.load(id, database),
          record.children.count == 1,
          let child = record.children.first, child.value.recovery?.root == member
        else { throw ReadbackError.incomplete("native child for execution \(id)") }
        return Provider(projectID: project, executionID: id, childID: child.key, member: member)
      }
      return try Self(
        root: root.identity, ownerID: runtime.coordinator.ownerIdentity, sessions: connections,
        target: provider(target.0, target.1, target.2),
        sibling: provider(sibling.0, sibling.1, sibling.2))
    }
  }

  func report() throws {
    let payload = try JSONEncoder().encode(self).base64EncodedString()
    try FileHandle.standardOutput.write(contentsOf: Data("\(Self.frame)\(payload)\n".utf8))
  }

  static func decode(_ stdout: [UInt8]) throws -> Self {
    let frames = String(decoding: stdout, as: UTF8.self)
      .split(separator: "\n").filter { $0.hasPrefix(frame) }
    guard frames.count == 1, let frameLine = frames.first, frameLine.utf8.count <= 16_384,
      let bytes = Data(base64Encoded: String(frameLine.dropFirst(frame.count)))
    else { throw ReadbackError.invalidHandoff }
    return try JSONDecoder().decode(Self.self, from: bytes)
  }

  func waitForCommit(_ fixture: FixedHostFixture, root: WorktreeDirectory) async throws {
    let coordinator = fixture.runtime.permissionRuntime.coordinator
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while true {
      try await coordinator.reconcile(until: deadline)
      do {
        try verify(using: fixture.database.connection.writer, root: root)
        return
      } catch ReadbackError.incomplete(_) where ContinuousClock.now < deadline {
        // A pass can join a poll that started before the final child exited.
        try await Task.sleep(for: .milliseconds(10))
      }
    }
  }

  func verifyAndRemove(_ directory: WorktreeDirectory) throws {
    guard directory.identity == root else { throw ReadbackError.invalidHandoff }
    try directory.verify()
    let path = directory.url.appendingPathComponent("state.sqlite").path
    var metadata = stat()
    guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_nlink == 1
    else { throw ReadbackError.incomplete("existing state.sqlite") }

    // Opening through GatewayDatabase or SQLitePermissionStore would permit
    // migrations or authorization-epoch repair.
    var configuration = Configuration()
    configuration.readonly = true
    let reader = try DatabaseQueue(path: path, configuration: configuration)
    try verify(using: reader, root: directory)
    try reader.close()

    for provider in [target, sibling] {
      guard
        DarwinProcessIdentity.current(pid: provider.member.processID)?.identity.uniqueID
          != provider.member.identity
      else { throw ReadbackError.incomplete("joined provider \(provider.executionID)") }
    }
    try WorktreeDirectory(physicalURL: Self.temporaryParent).removeOwnedTree(root, io: .init())
  }

  private func verify(using reader: any DatabaseReader, root: WorktreeDirectory) throws {
    try reader.read { try verify(in: $0, root: root) }
  }

  private func verify(in database: Database, root: WorktreeDirectory) throws {
    let records = try ExecutionRuntimeRecord.all(database)
    for provider in [target, sibling] {
      guard let record = records.first(where: { $0.id == provider.executionID }),
        let child = record.children[provider.childID], child.recovery?.root == provider.member,
        child.completed, child.released
      else { throw ReadbackError.incomplete("provider child \(provider.childID)") }
    }
    guard
      records.allSatisfy({
        $0.ownerID == ownerID && $0.completed && $0.admissionFinished
          && $0.invocationInFlight != true && ($0.workIDs?.isEmpty ?? true)
          && $0.scratchDirectory == nil
          && $0.children.values.allSatisfy { $0.completed && $0.released }
      })
    else { throw ReadbackError.incomplete("execution drain") }

    guard let ledger = try PermissionLedgerRecord.load(database)?.decode(),
      ledger.pendingEpochRecovery == nil, ledger.pendingExecutionTerminations.isEmpty,
      ledger.executions.values.allSatisfy({ !$0.isRunning }),
      ledger.executions[target.executionID]?.revoked == true,
      ledger.executions[sibling.executionID]?.isRunning == false
    else { throw ReadbackError.incomplete("permission ledger") }
    for session in sessions {
      guard let connection = ledger.environment.connections[session.id],
        connection.principal == session.principal, connection.consent == nil,
        ledger.environment.endedConnections.contains(session.id)
      else { throw ReadbackError.incomplete("ended session \(session.id)") }
    }

    try verifyOwnership(records, in: root)
    try verifyWorktrees(records, in: root, database: database)
  }

  private func verifyOwnership(_ records: [ExecutionRuntimeRecord], in root: WorktreeDirectory)
    throws
  {
    let executions = try root.child("state.sqlite.executions")
    let ownership = try executions.child("ownership")
    var names = Set(try ownership.entries(limit: 4_096).filter { $0.hasSuffix(".json") })
    for record in records {
      for (childID, child) in record.children {
        guard let recovery = child.recovery else { continue }
        let name = childID.uuidString + ".json"
        guard names.remove(name) != nil,
          let bytes = try WorktreeJournalIO().read(name, in: ownership, limit: 131_072)
        else { throw ReadbackError.incomplete("ownership journal \(childID)") }
        let entry = try JSONDecoder().decode(ExecutionRecoveryJournal.Entry.self, from: bytes)
        guard entry.child == childID, entry.execution == record.id, entry.owner == ownerID,
          entry.boot == record.boot, entry.recovery.root == recovery.root,
          entry.worktreeUse == record.worktreeUse, entry.completed, entry.released
        else { throw ReadbackError.incomplete("ownership journal \(childID)") }
      }
    }
    guard names.isEmpty,
      try executions.entries(limit: 4_096).allSatisfy({ UUID(uuidString: $0) == nil })
    else { throw ReadbackError.incomplete("unsettled execution ownership or scratch") }
  }

  private func verifyWorktrees(
    _ records: [ExecutionRuntimeRecord], in root: WorktreeDirectory, database: Database
  ) throws {
    let journals = try root.child("worktree-journals")
    let removals = try journals.child("removals")
    let removal: WorktreeRemovalJournal = try readJournal(
      target.projectID, from: removals, limit: WorktreeRecoveryCatalog.byteLimit)
    let targetRegistration = try SQLiteDerivedProjectStore.record(target.projectID, in: database)
    let siblingRegistration = try SQLiteDerivedProjectStore.record(sibling.projectID, in: database)
    guard removal.record.projectID == target.projectID, removal.phase == .finished,
      removal.reconciliation?.finished == true, removal.terminal?.receipts != nil,
      targetRegistration == nil, siblingRegistration?.state == .active,
      try HostOperationStore.unfinished(in: database).isEmpty
    else { throw ReadbackError.incomplete("finished worktree removal and registrations") }

    let common = try root.child("project").child(".git")
    let repositoryIdentity = try WorktreeDirectory(common.url).identity
    let admission = try common.child("computer-mcp").child("admission")
    for provider in [target, sibling] {
      let removed = provider.projectID == target.projectID
      let creation: WorktreeCreationJournal = try readJournal(provider.projectID, from: journals)
      guard creation.id == provider.projectID,
        creation.repository.commonDirectory == repositoryIdentity,
        creation.phase == (removed ? .removed : .active),
        let use = records.first(where: { $0.id == provider.executionID })?.worktreeUse,
        use.ownerID == ownerID, use.executionID == provider.executionID,
        use.admission.projectID == provider.projectID,
        case .host(_, let generation) = creation.record.provenance,
        generation == use.admission.generation
      else {
        throw ReadbackError.incomplete(
          "worktree creation and writer identity \(provider.projectID)")
      }
      let gate = try admission.child(generation.uuidString.lowercased())
      let bytes = try WorktreeJournalIO().read("state.json", in: gate, limit: 4_194_304)
      guard let bytes else {
        throw ReadbackError.incomplete("worktree writer gate \(provider.projectID)")
      }
      let state = try JSONDecoder().decode(WriterGate.self, from: bytes)
      guard state.projectID == provider.projectID, state.generation == generation,
        state.writers.isEmpty, state.closedBy == (removed ? removal.operationID : nil)
      else { throw ReadbackError.incomplete("worktree writer gate \(provider.projectID)") }
    }
  }

  private func readJournal<Record: Decodable>(
    _ id: String, from directory: WorktreeDirectory, limit: Int = 131_072
  ) throws -> Record {
    guard let bytes = try WorktreeJournalIO().read(id + ".json", in: directory, limit: limit)
    else { throw ReadbackError.incomplete("worktree journal \(id)") }
    return try JSONDecoder().decode(Record.self, from: bytes)
  }

  private struct WriterGate: Decodable {
    let projectID: String
    let generation: UUID
    let closedBy: UUID?
    let writers: [UUID: UUID]
  }
}

extension GatewayWorktreeLifecycleTests {
  @Test func worktreeFixtureReadbackRejectsUnreleasedProviderChild() throws {
    let parent = try WorktreeDirectory(
      physicalURL: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
    let root = try parent.child("cm-worktree-receipt-\(UUID())", create: true, exclusive: true)
    defer {
      do { try parent.removeOwnedTree(root.identity, io: .init()) } catch {
        Issue.record(error)
      }
    }

    let provider = WorktreeProviderFixtureReceipts.Provider(
      projectID: "test", executionID: UUID(), childID: UUID(),
      member: .init(processID: 1, identity: 1))
    let receipts = WorktreeProviderFixtureReceipts(
      root: root.identity, ownerID: UUID(), sessions: [], target: provider, sibling: provider)
    let connection = try GatewayDatabaseConnection(
      path: root.url.appendingPathComponent("state.sqlite").path)
    var record = ExecutionRuntimeRecord(
      id: provider.executionID, ownerID: receipts.ownerID, boot: "test")
    record.admissionFinished = true
    record.completed = true
    record.children[provider.childID] = .init(
      recovery: .init(root: provider.member, sandboxed: true, backend: "test"),
      completed: true, released: false)
    try connection.writer.write { try record.save($0) }
    try connection.writer.close()

    #expect(
      throws: WorktreeProviderFixtureReceipts.ReadbackError.incomplete(
        "provider child \(provider.childID)")
    ) {
      try receipts.verifyAndRemove(root)
    }
    try root.verify()
  }
}
