import Foundation
import Testing

@testable import ComputerMCPWorktrees

func lifecycleRecoveryRecords(
  _ fixture: WorktreeFixture, identity: WorktreeRepositoryIdentity
) throws -> [WorktreeRecoveryRecord] {
  let snapshots = try WorktreeRecoveryStore(storage: fixture.storage).list()
  let snapshot = try #require(snapshots.first { $0.repository == identity })
  #expect(snapshots.count == 1)
  return snapshot.catalog.records
}

func expectNoSourceRecoveryRefs(_ fixture: WorktreeFixture) throws {
  #expect(
    try fixture.raw(["for-each-ref", "--format=%(refname)", "refs/computer-mcp/recovery/"]).isEmpty)
}

func expectRecoveryObject(
  _ fixture: WorktreeFixture, identity: WorktreeRepositoryIdentity, record: WorktreeRecoveryRecord
) throws {
  let key = try WorktreeRecoveryStore.key(for: identity)
  let git = fixture.storage.recovery.appendingPathComponent("stores/\(key)/repository.git")
  let prefix = ["--git-dir=" + git.path]
  #expect(
    try fixture.raw(prefix + ["cat-file", "-t", record.oid], root: fixture.directory)
      == record.objectType.rawValue)
  #expect(
    try fixture.raw(
      prefix + ["rev-parse", "refs/recovery/" + record.id.uuidString.lowercased()],
      root: fixture.directory) == record.oid)
}

struct WorktreeLifecycleRecoveryTests {
  @Test(arguments: ["head", "reference"])
  func acknowledgedReplacementSurvivingPrivateRootRemainsRetained(root: String) async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "surviving-root")
      let old = try f.privateCommit(service, projectID: created.projectID)
      _ = try service.publish(projectID: created.projectID) { _ in }
      let git = PrivateWorktreeGit(
        f: f, topology: try service.topology(projectID: created.projectID))
      try git.run(["commit", "--amend", "-m", "replacement"])
      let tip = try git.run(["rev-parse", "HEAD"])
      _ = try service.merge(projectID: created.projectID) { _, _ in }
      try service.acknowledgeReplacement(
        projectID: created.projectID, replacedOID: old, expectedPublishedOID: tip
      ) { _ in }
      if root == "head" {
        try git.run(["checkout", "--detach", old])
      } else {
        try git.run(["update-ref", "refs/heads/surviving", old])
      }
      try git.run(["reflog", "expire", "--expire=now", "--all"])
      _ = try await service.remove(
        projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      if root == "reference" {
        #expect(
          try service.deleteBranch(
            created.branch, authority: .sandbox, dryRun: false, confirm: true
          ) { _ in }.deleted)
      }
      let records = try lifecycleRecoveryRecords(f, identity: service.identity).filter {
        $0.oid == old
      }
      let reason: WorktreeRecoveryRecord.Claim.Reason =
        root == "head" ? .privateHead : .privateReference
      let record = try #require(
        records.first { $0.claims.contains { $0.reason == reason && $0.rootOID == old } })
      #expect(record.owner.source == f.source)
      #expect(record.owner.branch == "refs/heads/" + created.branch)
      #expect(record.objectType == .commit)
      try expectRecoveryObject(f, identity: service.identity, record: record)
      try expectNoSourceRecoveryRefs(f)
    }
  }

  @Test func noncommitRootSurvivesSourceAbsenceAndReadOnlyListing() async throws {
    try await removalFixture { f in
      let service = try f.service()
      let identity = service.identity
      let created = try service.create(name: "noncommit-root")
      let git = PrivateWorktreeGit(
        f: f, topology: try service.topology(projectID: created.projectID))
      let blob = try git.run(["hash-object", "-w", "--stdin"], input: Data("private blob".utf8))
      try git.run(["update-ref", "refs/tags/private-blob", blob])
      _ = try await service.remove(
        projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      let records = try lifecycleRecoveryRecords(f, identity: identity)
      let record = try #require(
        records.first {
          $0.oid == blob
            && $0.claims.contains { $0.reason == .privateReference && $0.rootOID == blob }
        })
      #expect(record.objectType == .blob)
      #expect(record.owner.source == f.source)
      #expect(record.owner.branch == "refs/heads/" + created.branch)
      try expectRecoveryObject(f, identity: identity, record: record)
      try expectNoSourceRecoveryRefs(f)
      try FileManager.default.removeItem(at: f.repository)

      let root = f.storage.recovery
      var directories = [root]
      for url in try lifecycleStoreEntries(root) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeDirectory {
          directories.append(url)
        } else {
          try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        }
      }
      for directory in directories.reversed() {
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o555], ofItemAtPath: directory.path)
      }
      defer {
        for directory in directories {
          try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
      }
      let before = try lifecycleStoreSnapshot(root)
      #expect(try lifecycleRecoveryRecords(f, identity: identity) == records)
      #expect(try lifecycleStoreSnapshot(root) == before)
      #expect(!FileManager.default.fileExists(atPath: f.repository.path))
    }
  }
}

private func lifecycleStoreEntries(_ root: URL) throws -> [URL] {
  let enumerator = try #require(
    FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
  return enumerator.compactMap { $0 as? URL }
}

private func lifecycleStoreSnapshot(_ root: URL) throws -> [String: Data] {
  var result: [String: Data] = [:]
  for url in try lifecycleStoreEntries(root) {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let type = attributes[.type] as? FileAttributeType
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
    var value = Data("\(String(describing: type)):\(mode):\(inode):\(modified):".utf8)
    if type == .typeRegular { value.append(try Data(contentsOf: url)) }
    result[String(url.path.dropFirst(root.path.count))] = value
  }
  return result
}
