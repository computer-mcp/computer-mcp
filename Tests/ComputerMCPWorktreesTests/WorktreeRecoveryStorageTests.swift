import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeRecoveryStorageTests {
  @Test func appAndStandaloneRecoveryRootsFollowTheirStorageOwner() throws {
    try fixture { directory in
      let database = directory.appendingPathComponent("database/host.sqlite")
      let appRoot = directory.appendingPathComponent("application-support")
      let standalone = try #require(WorktreeStorage(databaseURL: database))
      let app = try #require(
        WorktreeStorage(databaseURL: database, applicationSupportRoot: appRoot))
      #expect(
        standalone.recovery
          == database.deletingLastPathComponent().appendingPathComponent("worktree-recovery"))
      #expect(app.recovery == appRoot.appendingPathComponent("WorktreeRecovery"))
      #expect(WorktreeStorage(databaseURL: nil, applicationSupportRoot: appRoot) == nil)
    }
  }

  @Test func recoveryOverlapIsDeniedEvenForOwnedRoots() throws {
    try fixture { directory in
      let database = directory.appendingPathComponent("host.sqlite")
      for storage in [
        try #require(WorktreeStorage(databaseURL: database)),
        try #require(WorktreeStorage(databaseURL: database, applicationSupportRoot: directory)),
      ] {
        let nested = storage.recovery.appendingPathComponent("nested")
        for root in [directory, storage.recovery, nested] {
          #expect(throws: WorktreeError.self) {
            try storage.validate(projectRoots: [root], ownedRoots: [root.path])
          }
        }
        let sibling = directory.appendingPathComponent(
          storage.recovery.lastPathComponent + "-other")
        try storage.validate(projectRoots: [sibling], ownedRoots: [])
      }
    }
  }
}
