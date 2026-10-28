import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPToolKit
import ComputerMCPWorktrees
import Foundation

/// Lifecycle authority is distinct from program admission and cannot launch a program.
struct GatewayWorktreeInvocation: InvocationExecutionAuthority {
  let authorization: InvocationAuthorization
  var pathAccess: (any HostPathAccessChecking)? { nil }
}

struct GatewayWorktreeService: GitWorktreeServing {
  let database: GatewayDatabase
  let runtime: GatewayPermissionRuntime
  let platform: PlatformServices
  let projectID: String?

  func call(_ operation: GitWorktreeOperation) throws -> JSONValue {
    guard let invocation = InvocationExecution.current as? GatewayWorktreeInvocation,
      let projectID = invocation.authorization.invocation.projectID,
      self.projectID == nil || self.projectID == projectID,
      invocation.authorization.invocation.tool == operation.toolName,
      let storage = database.worktreeStorage
    else { throw PermissionModelError.invalidAuthorization }
    let authorizationID = invocation.authorization.id
    let records = try database.derivedProjects()
    let selected = records.first { $0.projectID == projectID }
    let sourceID = selected?.source.id ?? projectID
    guard let project = try database.project(id: sourceID),
      !records.contains(where: { $0.projectID == sourceID })
    else { throw WorktreeError.invalidRequest("A registered source repository is required.") }
    let source = DerivedProjectSource(
      id: project.id, root: GatewayDatabase.canonicalProjectRoot(project.rootPath),
      registeredAt: project.createdAt)
    if let selected, selected.source != source {
      throw WorktreeError.identityChanged("Source registration changed.")
    }
    switch operation {
    case .add, .merge, .deleteBranch:
      guard selected == nil else {
        throw WorktreeError.invalidRequest("Call this operation in the source project.")
      }
    case .remove:
      guard let selected, case .host = selected.provenance else {
        throw WorktreeError.invalidRequest("Call removal in the host worktree project.")
      }
    case .list: break
    }
    let access = GatewayWorktreeAccess(
      database: database, runtime: runtime, authorizationID: authorizationID, source: source,
      writing: operation.isWriting)
    try access.checkSource()
    let repository = try WorktreeRepository(
      source: source,
      store: database.derivedProjectStore(inspectNesting: { projects in
        try GatewayTrackedProjectNesting.inspect(
          projects,
          runner: GatewayWorktreeGit(
            launcher: platform.launcher, executable: platform.gitExecutable))
      }), storage: storage,
      executor: GatewayWorktreeGit(launcher: platform.launcher, executable: platform.gitExecutable),
      registeredProjectRoots: try database.projects().map { URL(fileURLWithPath: $0.rootPath) },
      timeoutMilliseconds: 30_000, maxOutputBytes: 16_777_216, lockTimeout: .seconds(30),
      owner: .init(bootSessionID: platform.launcher.bootSessionID),
      journalIO: .init(beforePublication: { try access.checkSource() }),
      checkAuthority: { try access.checkSource() },
      authorizeCreationPath: { try access.check($0, writing: false, followLeaf: false) })
    switch operation {
    case .add(let name, let branch, let base):
      let result = try repository.create(name: name, branch: branch, base: base)
      return .object([
        "project_id": .string(result.projectID), "path": .string(result.path.path),
        "branch": .string(result.branch), "base": .string(result.base),
        "warnings": .array(result.warnings.map(JSONValue.string)),
      ])
    case .list:
      let result = try repository.inventory { path in
        if let record = records.first(where: { $0.root == path.path }),
          case .host = record.provenance
        {
          return (try? access.checkRecord(record, destinations: [], writing: false)) != nil
        }
        return (try? access.check(path, writing: false)) != nil
      }
      return .object([
        "worktrees": .array(
          result.map { item in
            .object([
              "path": item.path.map(JSONValue.string) ?? .null,
              "project_id": item.projectID.map(JSONValue.string) ?? .null,
              "branch": item.branch.map(JSONValue.string) ?? .null,
              "base": item.base.map(JSONValue.string) ?? .null,
              "ahead": item.ahead.map { .number(Double($0)) } ?? .null,
              "behind": item.behind.map { .number(Double($0)) } ?? .null,
              "dirty": item.dirty.map(JSONValue.bool) ?? .null,
              "unavailable": item.unavailable.map(JSONValue.string) ?? .null,
            ])
          })
      ])
    case .remove(let force):
      let result = try GatewaySynchronousOperation.run {
        try await repository.remove(
          projectID: projectID, force: force,
          terminate: { admission, operationID in
            try await runtime.coordinator.terminateWorktreeWriters(
              admission, operationID: operationID, until: .now.advanced(by: .seconds(30)))
          },
          authorize: { record, paths in
            try access.checkRecord(record, destinations: paths, writing: true)
          })
      }
      return .object([
        "project_id": .string(result.projectID), "branch": .string(result.branch),
        "oid": .string(result.oid),
        "terminationWarnings": .array(result.terminationWarnings.map(JSONValue.string)),
      ])
    case .merge(let branch):
      guard
        let record = records.first(where: {
          $0.source == source && $0.worktree?.branchName == branch
        }), case .host = record.provenance
      else {
        throw WorktreeError.invalidRequest("The branch must belong to a host worktree.")
      }
      let result = try repository.merge(projectID: record.projectID) { record, paths in
        try access.checkRecord(record, destinations: paths, writing: true)
      }
      return .object([
        "project_id": .string(result.projectID), "branch": .string(branch),
        "base": .string(String(result.base.dropFirst("refs/heads/".count))),
        "oid": .string(result.oid),
      ])
    case .deleteBranch(let name, let force, let dryRun, let confirm):
      let result = try repository.deleteBranch(
        name, authority: invocation.authorization.mode == .sandbox ? .sandbox : .fullAccess,
        force: force, dryRun: dryRun, confirm: confirm,
        authorize: { _ in try access.checkSource() })
      return .object([
        "name": .string(name), "oid": .string(result.oid), "deleted": .bool(result.deleted),
        "dry_run": .bool(dryRun), "force": .bool(force),
      ])
    }
  }
}

private struct GatewayWorktreeAccess: Sendable {
  let database: GatewayDatabase
  let runtime: GatewayPermissionRuntime
  let authorizationID: UUID
  let source: DerivedProjectSource
  let writing: Bool

  func checkSource() throws {
    guard let current = try database.project(id: source.id),
      current.createdAt == source.registeredAt,
      GatewayDatabase.canonicalProjectRoot(current.rootPath) == source.root
    else { throw WorktreeError.identityChanged("Source registration changed.") }
    try check(URL(fileURLWithPath: source.root), writing: writing)
  }

  func check(_ path: URL, writing: Bool, followLeaf: Bool = true) throws {
    let canonical =
      try followLeaf
      ? ProjectPathResolver.resolve(path.path, relativeTo: URL(fileURLWithPath: "/"))
      : ProjectPathResolver.resolve(
        path.deletingLastPathComponent().path, relativeTo: URL(fileURLWithPath: "/")
      )
      .appendingPathComponent(path.lastPathComponent)
    try runtime.store.transactionWithDatabase { _, ledger in
      try ledger.authorizeWorktreeHostPath(
        authorizationID, path: CanonicalPath(canonical.path), writing: writing)
    }
  }

  func checkRecord(_ record: DerivedProjectRecord, destinations: [URL], writing: Bool) throws {
    try checkSource()
    guard record.source == source, case .host = record.provenance,
      let registration = record.worktree
    else { throw PermissionModelError.invalidAuthorization }
    // The source path carries inherited permissions even during journaled cleanup,
    // after the content directory itself has already been removed.
    let root = URL(fileURLWithPath: record.root)
    if FileManager.default.fileExists(atPath: root.path) {
      try registration.verifyContent()
      try check(root, writing: writing)
    }
    for path in destinations {
      if path.path == root.path || path.path.hasPrefix(root.path + "/") {
        let relative = String(path.path.dropFirst(root.path.count))
        try check(URL(fileURLWithPath: source.root + relative), writing: writing, followLeaf: false)
        // Unlinking a symlink affects the link, not its target. The descriptor
        // traversal in the service checks the entry's identity before unlink.
        try check(path, writing: writing, followLeaf: false)
      } else {
        try check(path, writing: writing)
      }
    }
  }
}

extension GitWorktreeOperation {
  var toolName: String {
    switch self {
    case .add: "git.worktree_add"
    case .list: "git.worktree_list"
    case .remove: "git.worktree_remove"
    case .merge: "git.merge"
    case .deleteBranch: "git.branch_delete"
    }
  }
  var isWriting: Bool { if case .list = self { false } else { true } }
}
