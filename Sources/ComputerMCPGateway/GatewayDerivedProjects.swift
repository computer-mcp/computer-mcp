import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPWorktrees
import Foundation
import GRDB

extension GatewayDatabase {
  /// Lifecycle writes and the live permission projection share one transaction.
  package func derivedProjectStore(
    inspectNesting:
      @escaping @Sendable ([ComputerMCPCore.RegisteredProject]) throws -> [TrackedProjectNesting]
  ) -> any DerivedProjectStore {
    GatewayDerivedProjectStore(database: self, inspectNesting: inspectNesting)
  }

  package func derivedProjects() throws -> [DerivedProjectRecord] {
    try connection.writer.read(SQLiteDerivedProjectStore.records)
  }

  func derivedSourceID(for id: String) throws -> String? {
    try connection.writer.read { database in
      guard let record = try SQLiteDerivedProjectStore.record(id, in: database) else { return nil }
      guard try Self.availableDerivedProjects(in: database).contains(record) else {
        throw GatewayDatabaseError.invalidStoredValue("The derived source is unavailable.")
      }
      return record.source.id
    }
  }

  static func availableDerivedProjects(in database: Database) throws -> [DerivedProjectRecord] {
    let records = try SQLiteDerivedProjectStore.records(database)
    let projects = Dictionary(
      uniqueKeysWithValues: try ProjectRecord.fetchAll(database).map { ($0.id, $0) })
    var available = Set(projects.keys).subtracting(records.map(\.projectID))
    var result: [DerivedProjectRecord] = []
    // Each iteration consumes an edge. Cycles and unavailable sources never become authority.
    for _ in 0..<records.count {
      let next = records.filter { record in
        guard [.active, .removing].contains(record.state), !available.contains(record.projectID),
          available.contains(record.source.id), let source = projects[record.source.id],
          let child = projects[record.projectID]
        else { return false }
        return source.createdAt.databaseValue == record.source.registeredAt.databaseValue
          && canonicalProjectRoot(source.rootPath) == record.source.root
          && child.rootPath == record.root
      }
      if next.isEmpty { break }
      result += next
      available.formUnion(next.map(\.projectID))
    }
    return result
  }

  static func invalidateDerivedSources(_ sourceIDs: Set<String>, in database: Database) throws {
    var unavailable = sourceIDs
    let records = try SQLiteDerivedProjectStore.records(database)
    for _ in 0..<records.count {
      let next = records.filter {
        unavailable.contains($0.source.id) && !unavailable.contains($0.projectID)
      }
      if next.isEmpty { break }
      for var record in next {
        unavailable.insert(record.projectID)
        // Removing state retains its cleanup journal. Its live source check also fails closed.
        if record.state == .active || record.state == .creating || record.state == .recoveryRequired
        {
          let revision = record.revision
          record.state = .sourceUnavailable
          record.revision += 1
          try SQLiteDerivedProjectStore.commit(record, expecting: revision, in: database)
        }
      }
    }
  }

  static func reconcileDerivedSources(in database: Database) throws {
    let records = try SQLiteDerivedProjectStore.records(database)
    let projects = Dictionary(
      uniqueKeysWithValues: try ProjectRecord.fetchAll(database).map { ($0.id, $0) })
    var invalid: Set<String> = []
    for var record in records {
      let source = projects[record.source.id]
      let matches =
        source.map {
          $0.createdAt.databaseValue == record.source.registeredAt.databaseValue
            && canonicalProjectRoot($0.rootPath) == record.source.root
        } ?? false
      guard !matches || record.state == .sourceUnavailable else { continue }
      invalid.insert(record.projectID)
      if record.state == .active || record.state == .creating || record.state == .recoveryRequired {
        let revision = record.revision
        record.state = .sourceUnavailable
        record.revision += 1
        try SQLiteDerivedProjectStore.commit(record, expecting: revision, in: database)
      }
    }
    try invalidateDerivedSources(invalid, in: database)
  }

  static func hostContentIdentity(_ record: DerivedProjectRecord?) throws -> UUID? {
    guard let record, [.active, .removing].contains(record.state),
      case .host(_, let generation) = record.provenance, let worktree = record.worktree
    else { return nil }
    if record.state == .removing,
      !FileManager.default.fileExists(atPath: record.root)
    {
      return nil
    }
    try worktree.verifyContent()
    return generation
  }
}

private struct GatewayDerivedProjectStore: DerivedProjectStore {
  let database: GatewayDatabase
  let inspectNesting:
    @Sendable ([ComputerMCPCore.RegisteredProject]) throws -> [TrackedProjectNesting]
  private var storage: SQLiteDerivedProjectStore { .init(connection: database.connection) }

  func records() throws -> [DerivedProjectRecord] { try storage.records() }
  func protectedBranches() throws -> [ProtectedWorktreeBranch] { try storage.protectedBranches() }
  func releaseProtection(_ branch: ProtectedWorktreeBranch) throws {
    try storage.releaseProtection(branch)
  }

  func commit(
    _ record: DerivedProjectRecord, expecting revision: Int64?,
    protecting branch: ProtectedWorktreeBranch?
  ) throws {
    // Filesystem validation precedes the short write transaction. It grants no writable launch.
    if record.state == .active { try record.worktree?.verifyContent() }
    let expected = try database.configurationState()
    let nesting = record.state == .active ? try inspectNesting(expected.projects) : []
    try database.permissionTransaction { sql in
      guard try GatewayDatabase.configurationState(in: sql) == expected else {
        throw GatewayDatabaseError.configurationChanged
      }
      if record.state == .active || record.state == .creating {
        guard
          let source = try GatewayDatabase.projects(in: sql).first(where: {
            $0.id == record.source.id
          }),
          source.createdAt.databaseValue == record.source.registeredAt.databaseValue,
          GatewayDatabase.canonicalProjectRoot(source.rootPath) == record.source.root
        else {
          throw DerivedProjectStoreError.invalidRecord
        }
      }
      if revision == nil {
        guard try ProjectRecord.fetchOne(sql, key: record.projectID) == nil,
          try ProjectAliasRecord.fetchOne(sql, key: record.projectID) == nil,
          try ProjectCanonicalRootRecord.fetchOne(sql, key: record.root) == nil,
          try !ProfileRecord.fetchAll(sql).contains(where: {
            try $0.value().permissions.entries[.project(record.projectID)] != nil
          })
        else { throw DerivedProjectStoreError.invalidRecord }
      }
      if record.state == .active, try ProjectRecord.fetchOne(sql, key: record.projectID) == nil {
        let project = ComputerMCPCore.RegisteredProject(
          id: record.projectID, displayName: URL(fileURLWithPath: record.root).lastPathComponent,
          rootPath: record.root)
        try ProjectRecord(project).insert(sql)
        try ProjectCanonicalRootRecord(
          canonicalRootPath: record.root, projectID: project.id, createdAt: project.createdAt
        ).insert(sql)
      }
      try SQLiteDerivedProjectStore.commit(record, expecting: revision, protecting: branch, in: sql)
      if record.state == .active {
        let derived = try GatewayDatabase.availableDerivedProjects(in: sql)
        let catalog = try ProjectCatalog(
          GatewayDatabase.projects(in: sql).map { project in
            try ComputerMCPPermissions.RegisteredProject(
              id: project.id,
              root: CanonicalPath(GatewayDatabase.canonicalProjectRoot(project.rootPath)),
              sourceID: derived.first { $0.projectID == project.id }?.source.id)
          })
        let permissions = try Dictionary(
          uniqueKeysWithValues: ProfileRecord.fetchAll(sql).map { row in
            (Principal.client("profile:" + row.id), try row.value().permissions)
          })
        try catalog.validate(nesting: nesting, permissions: permissions)
      }
    }
  }

  func remove(_ id: String, expecting revision: Int64) throws {
    try database.permissionTransaction { sql in
      guard let record = try SQLiteDerivedProjectStore.record(id, in: sql),
        record.revision == revision
      else {
        throw DerivedProjectStoreError.revisionConflict
      }
      try GatewayDatabase.invalidateDerivedSources([id], in: sql)
      try ProjectCanonicalRootRecord.filter(Column("projectID") == id).deleteAll(sql)
      _ = try ProjectRecord.deleteOne(sql, key: id)
      try SQLiteDerivedProjectStore.remove(id, expecting: revision, in: sql)
    }
  }
}
