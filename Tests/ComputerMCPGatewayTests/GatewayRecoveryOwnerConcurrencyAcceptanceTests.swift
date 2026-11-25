import ComputerMCPCore
import ComputerMCPPersistence
import ComputerMCPWorktrees
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway
@testable import ComputerMCPWorktrees

@Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(2)))
struct GatewayRecoveryOwnerConcurrencyAcceptanceTests {
  @Test func reservedWriterBeforeSQLExecutionRowBlocksOwnerAdmission() throws {
    let f = try WorktreeServiceFixture()
    defer { f.remove() }
    let worktrees = try f.repository()
    let created = try worktrees.create(name: "sql-writer-admission")
    let publication = try worktrees.publish(projectID: created.projectID) { _ in }
    let owner = try GatewayRecoveryOwnerService(
      database: f.database, platform: f.platform,
      owner: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "local-app"))
    let view = try #require(try owner.list().first)
    let record = try #require(view.records.first { $0.oid == publication.oid })
    let review = try owner.reviewRelease(
      storeKey: view.key, generation: view.generation, selections: [record.selection])
    let gate = try worktrees.admission(projectID: created.projectID)
    let execution = UUID()
    let writer = try gate.reserve(ownerID: UUID(), executionID: execution)
    let sqlRows = try f.database.connection.writer.read { sql in
      try Int.fetchOne(
        sql, sql: "SELECT COUNT(*) FROM permissionRuntimeExecutions WHERE id = ?",
        arguments: [execution.uuidString]) ?? 0
    }
    #expect(sqlRows == 0)
    let refusal = try owner.confirm(review)
    guard case .busy = refusal.outcome else {
      Issue.record("Reserved writer was not admitted before owner release: \(refusal.outcome)")
      return
    }
    #expect(refusal.request.handle == review.handle)
    try gate.requireOpen(writer)
    #expect(try #require(owner.list().first).records.contains { $0.id == record.id })
    try gate.acknowledge(writer)
    let fresh = try owner.reviewRelease(
      storeKey: view.key, generation: view.generation, selections: [record.selection])
    let result = try owner.confirm(fresh)
    #expect(result.outcome == .released)
    #expect(try owner.resume(handle: fresh.handle) == result)
  }

  @Test func boundedAdapterLimitAfterWithdrawalRestoresOnRestart() throws {
    let f = try WorktreeServiceFixture()
    defer { f.remove() }
    let repository = try f.repository()
    let created = try repository.create(name: "bounded-restoration")
    try Data("private\n".utf8).write(to: created.path.appendingPathComponent("value"))
    _ = try f.git(["add", "value"], at: created.path)
    _ = try f.git(
      [
        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
        "commit", "-m", "private",
      ], at: created.path)
    _ = try repository.publish(projectID: created.projectID) { _ in }
    _ = try f.git(
      [
        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
        "commit", "--allow-empty", "-m", "shared",
      ], at: created.path)
    _ = try repository.publish(projectID: created.projectID) { _ in }
    let project = try #require(try f.database.project(id: "source"))
    let source = DerivedProjectSource(
      id: "source", root: GatewayDatabase.canonicalProjectRoot(f.source.path),
      registeredAt: project.createdAt)
    let storage = try #require(f.database.worktreeStorage)
    let derived = f.database.derivedProjectStore(inspectNesting: { _ in [] })
    let dependencies = GatewayAcceptanceDependencies(source: source, store: derived)
    let normal = try WorktreeRecoveryOwnerService(
      storage: storage, derived: derived, dependencies: dependencies, executor: f.executor)
    let view = try #require(try normal.list().first)
    guard
      case .reviewed(let review) = try normal.prepareMaintenance(
        key: view.key, generation: view.generation, principal: "local-app")
    else {
      Issue.record("Expected maintenance review")
      return
    }
    _ = try #require(review.packHash)
    let store = storage.recovery.appendingPathComponent("stores/" + view.key)
    let active = store.appendingPathComponent("owner-operation.json")
    let packs = store.appendingPathComponent("repository.git/objects/pack")
    let before = try gatewayPackFiles(packs)
    let limited = GatewayVerificationLimit(base: f.executor, active: active)
    let io = WorktreeJournalIO(beforeDirectorySync: {
      guard let bytes = try? Data(contentsOf: active),
        let journal = try? JSONDecoder().decode(RecoveryOwnerJournal.self, from: bytes),
        journal.handle == review.handle, journal.maintenance?.phase == .restoringDeferred
      else { return }
      throw GatewayAcceptanceInterruption.injected
    })
    let interrupted = try WorktreeRecoveryOwnerService(
      storage: storage, derived: derived, dependencies: dependencies, executor: limited,
      journalIO: io)
    #expect(throws: GatewayAcceptanceInterruption.self) {
      try interrupted.run(review, principal: "local-app")
    }
    #expect(limited.fired)
    let pending = try JSONDecoder().decode(
      RecoveryOwnerJournal.self, from: Data(contentsOf: active))
    #expect(pending.maintenance?.phase == .restoringDeferred)
    #expect(pending.maintenance?.reason == "Bounded command stdout exceeded its limit.")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: packs.path).contains {
        $0.hasSuffix(".quarantine")
      })
    let result = try normal.resume(review.handle, principal: "local-app")
    guard case .deferred(let reason) = result.outcome else {
      Issue.record("Expected a restored deferred result: \(result.outcome)")
      return
    }
    #expect(reason == "Bounded command stdout exceeded its limit.")
    #expect(result.request == .maintenance(review))
    #expect(try gatewayPackFiles(packs) == before)
    #expect(try #require(normal.list().first).records == view.records)
    #expect(!FileManager.default.fileExists(atPath: active.path))
    #expect(try normal.resume(review.handle, principal: "local-app") == result)
  }
}

private enum GatewayAcceptanceInterruption: Error { case injected }

private struct GatewayAcceptanceDependencies: WorktreeRecoveryDependencyReading {
  let source: DerivedProjectSource
  let store: any DerivedProjectStore

  func recoveryEvidence(
    for repository: WorktreeRepositoryIdentity, sources: Set<DerivedProjectSource>
  ) throws -> WorktreeRecoveryDependencyEvidence {
    .init(
      registrations: sources.contains(source) ? [source] : [], derived: try store.records(),
      protections: try store.protectedBranches(), unfinishedOperations: [], executions: [])
  }

  func validateRecoveryEvidence(
    _ expected: WorktreeRecoveryDependencyEvidence, for repository: WorktreeRepositoryIdentity,
    sources: Set<DerivedProjectSource>, commit: () throws -> Void
  ) throws -> Bool {
    guard try recoveryEvidence(for: repository, sources: sources) == expected else { return false }
    try commit()
    return true
  }
}

private final class GatewayVerificationLimit: WorktreeGitExecuting, @unchecked Sendable {
  let base: GatewayWorktreeGit
  let active: URL
  private let lock = NSLock()
  private var didFire = false

  init(base: GatewayWorktreeGit, active: URL) {
    self.base = base
    self.active = active
  }
  var fired: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didFire
  }

  private func bounded(_ command: WorktreeGitCommand) -> WorktreeGitCommand {
    lock.lock()
    defer { lock.unlock() }
    guard !didFire, command.arguments.contains("verify-pack"),
      let bytes = try? Data(contentsOf: active),
      let journal = try? JSONDecoder().decode(RecoveryOwnerJournal.self, from: bytes),
      journal.maintenance?.phase == .verifying
    else { return command }
    didFire = true
    var limited = command
    limited.maxOutputBytes = 1
    return limited
  }

  func execute(_ command: WorktreeGitCommand) throws -> WorktreeGitResult {
    try base.execute(bounded(command))
  }
  func executeBounded(
    _ command: WorktreeGitCommand, fileOutput: WorktreeGitFileOutput?, fileSizeLimit: Int?
  ) throws -> WorktreeGitResult {
    try base.executeBounded(bounded(command), fileOutput: fileOutput, fileSizeLimit: fileSizeLimit)
  }
  func withPreparedTransaction(_ command: WorktreeGitCommand, _ body: () throws -> Void) throws {
    try base.withPreparedTransaction(command, body)
  }
}

private func gatewayPackFiles(_ directory: URL) throws -> [String: Data] {
  var result: [String: Data] = [:]
  for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
    result[name] = try Data(contentsOf: directory.appendingPathComponent(name))
  }
  return result
}

extension GatewayRecoveryOwnerConcurrencyAcceptanceTests {
  @Test func boundedAdapterReportsActualWaitDeadline() throws {
    let f = try WorktreeServiceFixture()
    defer { f.remove() }
    let marker = f.root.appendingPathComponent("slow-worker-started")
    let executable = f.root.appendingPathComponent("slow-git")
    let quotedGit = "'" + f.executor.executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let quotedMarker = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let script =
      "#!/bin/sh\nprintf started > \(quotedMarker)\n/bin/sleep 2\nexec \(quotedGit) \"$@\"\n"
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let adapter = GatewayWorktreeGit(launcher: f.platform.launcher, executable: executable.path)
    let command = WorktreeGitCommand(
      arguments: ["--version"], directory: f.source,
      environment: HostGitConfiguration.environment(home: f.root), timeoutMilliseconds: 500,
      maxOutputBytes: 4096)
    do {
      _ = try adapter.execute(command)
      Issue.record("The slow worker exceeded its deadline without a bounded error")
    } catch WorktreeError.busy(let reason) {
      #expect(reason == "Bounded command exceeded its deadline.")
    }
    #expect(try String(contentsOf: marker, encoding: .utf8) == "started")
    #expect(
      try f.executor.execute(
        .init(
          arguments: ["--version"], directory: f.source,
          environment: HostGitConfiguration.environment(home: f.root),
          timeoutMilliseconds: 30_000, maxOutputBytes: 4096)
      ).exitCode == 0)
  }
}
