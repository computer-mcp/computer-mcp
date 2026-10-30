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
/// A project host-service callback carries its admitted action in place of a builtin tool.
struct GatewayWorktreeInvocation: InvocationExecutionAuthority {
  let authorization: InvocationAuthorization
  var additionalAuthorizationIDs: Set<UUID> = []
  var hostAction: MCPHostServiceAction? = nil
  var pathAccess: (any HostPathAccessChecking)? { nil }
}

/// Typed lifecycle results shared by the builtin tools and project host services.
enum GatewayWorktreeOutcome {
  case created(CreatedWorktree, worktreeID: UUID)
  case listed([WorktreeInventoryItem])
  case removed(WorktreeRemovalResult, worktreeID: UUID)
  case merged(JSONValue)
  case deletedBranch(JSONValue)
}

struct GatewayWorktreeService: GitWorktreeServing {
  let database: GatewayDatabase
  let runtime: GatewayPermissionRuntime
  let platform: PlatformServices
  let projectID: String?

  func call(_ operation: GitWorktreeOperation) throws -> JSONValue {
    switch try perform(operation) {
    case .created(let result, _):
      return .object([
        "project_id": .string(result.projectID), "path": .string(result.path.path),
        "branch": .string(result.branch), "base": .string(result.base),
        "warnings": .array(result.warnings.map(JSONValue.string)),
      ])
    case .listed(let items):
      return .object([
        "worktrees": .array(
          items.map { item in
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
    case .removed(let result, _):
      return .object([
        "project_id": .string(result.projectID), "branch": .string(result.branch),
        "oid": .string(result.oid),
        "terminationWarnings": .array(result.terminationWarnings.map(JSONValue.string)),
      ])
    case .merged(let value), .deletedBranch(let value): return value
    }
  }

  /// The source's main checkout branch, captured as a reservation's default base.
  func mainBranch(sourceID: String) throws -> String? {
    guard let storage = database.worktreeStorage, let project = try database.project(id: sourceID)
    else { throw WorktreeError.invalidRequest("A registered source repository is required.") }
    let git = GatewayWorktreeGit(launcher: platform.launcher, executable: platform.gitExecutable)
    return try WorktreeRepository(
      source: .init(
        id: project.id, root: GatewayDatabase.canonicalProjectRoot(project.rootPath),
        registeredAt: project.createdAt),
      store: database.derivedProjectStore(inspectNesting: { _ in [] }), storage: storage,
      executor: git,
      registeredProjectRoots: try database.projects().map { URL(fileURLWithPath: $0.rootPath) },
      timeoutMilliseconds: 30_000, maxOutputBytes: 1_048_576, lockTimeout: .seconds(30),
      owner: .init(bootSessionID: platform.launcher.bootSessionID)
    ).mainBranch()
  }

  /// A host-reserved `operationID` binds creation and removal journals to that operation.
  func perform(_ operation: GitWorktreeOperation, operationID: UUID? = nil) throws
    -> GatewayWorktreeOutcome
  {
    guard let invocation = InvocationExecution.current as? GatewayWorktreeInvocation,
      let projectID = invocation.authorization.invocation.projectID,
      self.projectID == nil || self.projectID == projectID,
      invocation.hostAction.map(operation.performs)
        ?? (invocation.authorization.invocation.tool == operation.toolName),
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
      guard selected != nil else {
        throw WorktreeError.invalidRequest("Call removal in the host worktree project.")
      }
    case .list: break
    }
    let access = GatewayWorktreeAccess(
      database: database, runtime: runtime, authorizationID: authorizationID, source: source,
      writing: operation.isWriting,
      additionalAuthorizationIDs: invocation.additionalAuthorizationIDs,
      teardownProjectID: operation.isRemoval ? projectID : nil)
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
      let result = try repository.create(
        name: name, branch: branch, base: base, operationID: operationID)
      guard
        let record = try database.derivedProjects().first(where: {
          $0.projectID == result.projectID
        })
      else { throw WorktreeError.recoveryRequired("The created registration is unavailable.") }
      return .created(result, worktreeID: record.provenance.worktreeID)
    case .list:
      return .listed(
        try repository.inventory { path in
          if let record = records.first(where: { $0.root == path.path }) {
            return (try? access.checkRecord(record, destinations: [], writing: false)) != nil
          }
          return (try? access.check(path, writing: false)) != nil
        })
    case .remove(let force):
      let worktreeID = selected!.provenance.worktreeID
      let result = try GatewaySynchronousOperation.run {
        try await repository.remove(
          projectID: projectID, force: force, operationID: operationID,
          terminate: { admission, journalOperationID in
            try await runtime.coordinator.terminateWorktreeWriters(
              admission, operationID: journalOperationID, until: .now.advanced(by: .seconds(30)))
          },
          authorize: { record, paths in
            try access.checkRecord(record, destinations: paths, writing: true)
          })
      }
      return .removed(result, worktreeID: worktreeID)
    case .merge(let branch):
      guard
        let record = records.first(where: {
          $0.source == source && $0.worktree?.branchName == branch
        })
      else {
        throw WorktreeError.invalidRequest("The branch must belong to a host worktree.")
      }
      let result = try repository.merge(projectID: record.projectID) { record, paths in
        try access.checkRecord(record, destinations: paths, writing: true)
      }
      return .merged(
        .object([
          "project_id": .string(result.projectID), "branch": .string(branch),
          "base": .string(String(result.base.dropFirst("refs/heads/".count))),
          "oid": .string(result.oid),
        ]))
    case .deleteBranch(let name, let force, let dryRun, let confirm):
      let result = try repository.deleteBranch(
        name, authority: invocation.authorization.mode == .sandbox ? .sandbox : .fullAccess,
        force: force, dryRun: dryRun, confirm: confirm,
        authorize: { _ in try access.checkSource() })
      return .deletedBranch(
        .object([
          "name": .string(name), "oid": .string(result.oid), "deleted": .bool(result.deleted),
          "dry_run": .bool(dryRun), "force": .bool(force),
        ]))
    }
  }
}

private struct GatewayWorktreeAccess: Sendable {
  let database: GatewayDatabase
  let runtime: GatewayPermissionRuntime
  let authorizationID: UUID
  let source: DerivedProjectSource
  let writing: Bool
  let additionalAuthorizationIDs: Set<UUID>
  /// The worktree a removal selects. The provider session's authority over it ends with
  /// that worktree's teardown: once its record is committed `.removing`, storage removal
  /// and unregistration are host-owned cleanup under the delegating client's authority
  /// alone. Every boundary up to and including that commit checks both authorities.
  let teardownProjectID: String?

  /// The delegating client's call authorization, plus the provider execution's
  /// authorizations until the selected worktree enters teardown.
  private func authorizationIDs() throws -> Set<UUID> {
    if let teardownProjectID,
      try database.derivedProjects().first(where: { $0.projectID == teardownProjectID })
        .map({ $0.state == .removing }) ?? true
    {
      return [authorizationID]
    }
    return additionalAuthorizationIDs.union([authorizationID])
  }

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
    let ids = try authorizationIDs()
    try runtime.store.transactionWithDatabase { _, ledger in
      for id in ids {
        try ledger.authorizeWorktreeHostPath(
          id, path: CanonicalPath(canonical.path), writing: writing)
      }
    }
  }

  func checkRecord(_ record: DerivedProjectRecord, destinations: [URL], writing: Bool) throws {
    try checkSource()
    guard record.source == source, let registration = record.worktree
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
  var isRemoval: Bool { if case .remove = self { true } else { false } }

  /// The lifecycle operation a project host-service action may perform.
  func performs(_ action: MCPHostServiceAction) -> Bool {
    switch (self, action) {
    case (.add, .projectProvision), (.list, .projectList), (.remove, .projectRemoval): true
    default: false
    }
  }
}
