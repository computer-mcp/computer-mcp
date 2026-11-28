import ComputerMCPPersistence
import Foundation

@testable import ComputerMCPWorktrees

struct LifecycleFailureStore: DerivedProjectStore {
  let base: SQLiteDerivedProjectStore
  let operation: String
  let after: Bool

  func records() throws -> [DerivedProjectRecord] { try base.records() }
  func protectedBranches() throws -> [ProtectedWorktreeBranch] { try base.protectedBranches() }
  func commit(
    _ record: DerivedProjectRecord, expecting revision: Int64?,
    protecting branch: ProtectedWorktreeBranch?
  ) throws {
    try fail("mark", when: !after && record.state == .removing)
    try base.commit(record, expecting: revision, protecting: branch)
    try fail("mark", when: after && record.state == .removing)
  }
  func remove(_ id: String, expecting revision: Int64) throws {
    try fail("remove", when: !after)
    try base.remove(id, expecting: revision)
    try fail("remove", when: after)
  }
  func releaseProtection(_ branch: ProtectedWorktreeBranch) throws {
    try fail("release", when: !after)
    try base.releaseProtection(branch)
    try fail("release", when: after)
  }
  private func fail(_ name: String, when enabled: Bool) throws {
    if operation == name && enabled { throw CancellationError() }
  }
}
