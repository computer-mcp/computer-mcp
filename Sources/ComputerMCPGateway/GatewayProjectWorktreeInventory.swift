import ComputerMCPCore
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPWorktrees
import Foundation
import GRDB

package struct ProjectWorktreeInventory: Sendable {
  /// The registration generation continues to identify children after source removal or ID reuse.
  package let source: DerivedProjectSource
  package let projectName: String?
  package let worktrees: [ProjectWorktreeView]
  package let isInventoryAvailable: Bool
}

package struct ProjectWorktreeView: Sendable {
  package let projectID: String?
  package let worktreeID: UUID?
  package let storageGeneration: UUID?
  package let lifecycleRevision: Int64?
  package let lifecycleState: DerivedProjectRecord.State?
  package let path: String?
  package let branch: String?
  package let base: String?
  package let ahead: Int?
  package let behind: Int?
  package let dirty: Bool?
  package let isInspectable: Bool
}

extension GatewayDatabase {
  /// Owner-facing inventory uses host lifecycle records for identity and Git only for live state.
  package func projectWorktreeInventory(platform: PlatformServices) throws
    -> [ProjectWorktreeInventory]
  {
    let (projects, records, registeredRoots) = try connection.writer.read { sql in
      (
        try Self.projects(in: sql), try SQLiteDerivedProjectStore.records(sql),
        Dictionary(grouping: try ProjectCanonicalRootRecord.fetchAll(sql), by: \.projectID)
      )
    }
    let childIDs = Set(records.map(\.projectID))
    let sources = Dictionary(
      uniqueKeysWithValues: projects.filter { !childIDs.contains($0.id) }.map { project in
        let root =
          registeredRoots[project.id]?.first {
            $0.createdAt.databaseValue == project.createdAt.databaseValue
          }?.canonicalRootPath ?? project.rootPath
        return (
          DerivedProjectSource(id: project.id, root: root, registeredAt: project.createdAt), project
        )
      })
    let executor = GatewayWorktreeGit(
      launcher: platform.launcher, executable: platform.gitExecutable)
    return try Set(sources.keys).union(records.map(\.source)).sorted {
      ($0.id, $0.registeredAt, $0.root) < ($1.id, $1.registeredAt, $1.root)
    }.map { source in
      try Task.checkCancellation()
      let children = records.filter { $0.source == source }
      let inventory: [WorktreeInventoryItem]?
      if let project = sources[source], let storage = worktreeStorage,
        let access = try? platform.projectGrants.resolve(project)
      {
        defer { access.close() }
        let root = URL(fileURLWithPath: source.root)
        @Sendable func checkSource() throws {
          guard access.isActive, try ProjectRootIdentity(root) == access.rootIdentity else {
            throw WorktreeError.identityChanged("The registered project moved.")
          }
        }
        do {
          let items = try WorktreeRepository(
            source: source, store: derivedProjectStore(inspectNesting: { _ in [] }),
            storage: storage, executor: executor,
            registeredProjectRoots: projects.map { URL(fileURLWithPath: $0.rootPath) },
            timeoutMilliseconds: 30_000, maxOutputBytes: 16_777_216, lockTimeout: .seconds(30),
            owner: .init(bootSessionID: platform.launcher.bootSessionID),
            checkAuthority: checkSource
          ).inventory { _ in true }
          try checkSource()
          inventory = items
        } catch {
          try Task.checkCancellation()
          inventory = nil
        }
      } else {
        inventory = nil
      }
      let managed = children.map { record in
        let (worktreeID, storageGeneration) =
          switch record.provenance {
          case .host(let id, let generation): (id, generation)
          }
        let live = inventory?.first { $0.worktreeID == worktreeID }
        return ProjectWorktreeView(
          projectID: record.projectID, worktreeID: worktreeID, storageGeneration: storageGeneration,
          lifecycleRevision: record.revision, lifecycleState: record.state,
          path: record.root, branch: record.worktree?.branchName, base: record.worktree?.baseName,
          ahead: live?.ahead, behind: live?.behind, dirty: live?.dirty,
          isInspectable: live.map { $0.unavailable == nil } ?? false)
      }
      let foreign = (inventory ?? []).filter {
        $0.owner == .foreign && $0.path != source.root
      }.map {
        ProjectWorktreeView(
          projectID: nil, worktreeID: nil, storageGeneration: nil, lifecycleRevision: nil,
          lifecycleState: nil,
          path: $0.path, branch: $0.branch, base: nil, ahead: nil, behind: nil, dirty: $0.dirty,
          isInspectable: $0.dirty != nil)
      }
      return ProjectWorktreeInventory(
        source: source, projectName: sources[source]?.displayName, worktrees: managed + foreign,
        isInventoryAvailable: inventory != nil)
    }
  }
}
