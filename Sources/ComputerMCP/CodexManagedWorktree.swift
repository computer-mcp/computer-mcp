import CryptoKit
import Darwin
import Foundation

enum CodexManagedWorktreeState: String, Codable, Equatable, Sendable {
  case planned
  case provisioning
  case active
  case removalPlanned = "removal_planned"
  case removing
  case removed
  case failed
}

struct CodexManagedWorktree: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let sourceWorkspaceID: String
  let workspaceID: String
  let sourceRepositoryRoot: String
  let gitCommonDirectory: String
  let path: String
  let branch: String
  let startPoint: String
  var headOID: String
  let agentID: String
  let threadID: String?
  let runID: String?
  let parentLeaseID: String
  let profileID: String
  let caller: String
  let ttlSeconds: Int
  var leaseID: String?
  var state: CodexManagedWorktreeState
  let createdAt: Date
  var updatedAt: Date
  var planExpiresAt: Date?
  var removedAt: Date?
  var lastError: String?
  var revision: Int

  private enum CodingKeys: String, CodingKey {
    case id
    case sourceWorkspaceID = "source_workspace_id"
    case workspaceID = "workspace_id"
    case sourceRepositoryRoot = "source_repository_root"
    case gitCommonDirectory = "git_common_directory"
    case path
    case branch
    case startPoint = "start_point"
    case headOID = "head_oid"
    case agentID = "agent_id"
    case threadID = "thread_id"
    case runID = "run_id"
    case parentLeaseID = "parent_lease_id"
    case profileID = "profile_id"
    case caller
    case ttlSeconds = "ttl_seconds"
    case leaseID = "lease_id"
    case state
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case planExpiresAt = "plan_expires_at"
    case removedAt = "removed_at"
    case lastError = "last_error"
    case revision
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

enum CodexManagedWorktreeError: Error, LocalizedError, Sendable {
  case unavailable
  case invalid(String)
  case unknown(String)
  case revisionConflict(expected: Int, actual: Int)
  case state(String)
  case command(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "Managed Codex worktrees require the Gateway Database."
    case .invalid(let detail):
      return "Invalid managed worktree request: \(detail)"
    case .unknown(let id):
      return "Unknown Computer MCP-managed worktree '\(id)'."
    case .revisionConflict(let expected, let actual):
      return "Managed worktree revision conflict: expected \(expected), current \(actual)."
    case .state(let detail):
      return "Managed worktree state does not allow this operation: \(detail)"
    case .command(let detail):
      return "Managed worktree Git operation failed: \(detail)"
    }
  }
}

enum CodexManagedWorktreeManager {
  static func planProvision(
    database: GatewayDatabase?,
    sourceWorkspaceID: String?,
    profileID: String?,
    caller: String?,
    agentID: String,
    threadID: String?,
    runID: String?,
    parentLeaseID: String,
    branch: String,
    startPoint: String,
    ttlSeconds: Int,
    commandRunner: any CommandRunning = ProcessCommandRunner(),
    managedRoot: URL? = nil,
    now: Date = Date()
  ) throws -> CodexManagedWorktree {
    guard let database else { throw CodexManagedWorktreeError.unavailable }
    guard let sourceWorkspaceID,
      let source = try database.workspace(id: sourceWorkspaceID)
    else {
      throw CodexManagedWorktreeError.invalid("the source workspace is not registered")
    }
    guard let profileID, GatewayProfileID(rawValue: profileID) != nil else {
      throw CodexManagedWorktreeError.invalid("the gateway profile is unavailable")
    }
    guard let caller, GatewayCallerKind(rawValue: caller) != nil else {
      throw CodexManagedWorktreeError.invalid("the gateway caller is unavailable")
    }
    try validateText(agentID, name: "agent_id", maximum: 256)
    try validateText(branch, name: "branch", maximum: 256)
    try validateText(startPoint, name: "start_point", maximum: 256)
    if let threadID {
      try validateOpaqueIdentifier(threadID, name: "thread_id", maximum: 1_024)
    }
    guard (30...86_400).contains(ttlSeconds) else {
      throw CodexManagedWorktreeError.invalid("ttl_seconds must be between 30 and 86400")
    }
    guard let parent = try database.codexWorktreeLease(id: parentLeaseID),
      parent.workspaceID == sourceWorkspaceID,
      parent.state == .active,
      parent.expiresAt > now
    else {
      throw CodexManagedWorktreeError.invalid(
        "parent_lease_id must identify an active lease for the source workspace"
      )
    }
    if let runID {
      guard let run = try database.codexOrchestrationRun(id: runID),
        run.workspaceID == sourceWorkspaceID
      else {
        throw CodexManagedWorktreeError.invalid(
          "run_id must identify a run in the source workspace"
        )
      }
    }
    let sourceRoot = URL(fileURLWithPath: source.rootPath, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    let repositoryRoot = try gitPath(
      ["rev-parse", "--show-toplevel"],
      workingDirectory: sourceRoot,
      runner: commandRunner
    )
    guard canonicalURL(repositoryRoot, relativeTo: sourceRoot).path == sourceRoot.path else {
      throw CodexManagedWorktreeError.invalid(
        "the registered source workspace must be the Git repository root"
      )
    }
    _ = try git(
      ["check-ref-format", "--branch", branch],
      workingDirectory: sourceRoot,
      runner: commandRunner
    )
    let branchLookup = try gitResult(
      ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
      workingDirectory: sourceRoot,
      runner: commandRunner
    )
    guard branchLookup.exitCode == 1 else {
      if branchLookup.exitCode == 0 {
        throw CodexManagedWorktreeError.invalid("branch already exists")
      }
      throw commandError(branchLookup)
    }
    let headOID = try gitText(
      ["rev-parse", "--verify", "\(startPoint)^{commit}"],
      workingDirectory: sourceRoot,
      runner: commandRunner
    )
    guard isObjectID(headOID) else {
      throw CodexManagedWorktreeError.command("Git returned an invalid start commit.")
    }
    let commonDirectory = canonicalURL(
      try gitPath(
        ["rev-parse", "--git-common-dir"],
        workingDirectory: sourceRoot,
        runner: commandRunner
      ),
      relativeTo: sourceRoot
    )
    let id = UUID().uuidString.lowercased()
    let workspaceID = "codex-worktree-\(id)"
    let root = managedRootURL(database: database, override: managedRoot)
    let sourceComponent = SHA256.hash(data: Data(sourceWorkspaceID.utf8))
      .prefix(12).map { String(format: "%02x", $0) }.joined()
    let target =
      root
      .appendingPathComponent(sourceComponent, isDirectory: true)
      .appendingPathComponent(id, isDirectory: true)
      .standardizedFileURL
    guard target.path.hasPrefix(root.standardizedFileURL.path + "/") else {
      throw CodexManagedWorktreeError.invalid("derived worktree path escaped the managed root")
    }
    guard !FileManager.default.fileExists(atPath: target.path) else {
      throw CodexManagedWorktreeError.invalid("derived worktree path already exists")
    }
    guard
      !(try database.codexManagedWorktrees(sourceWorkspaceID: sourceWorkspaceID, limit: 5_000))
        .contains(where: {
          $0.branch == branch
            && [.planned, .provisioning, .active, .removalPlanned, .removing].contains($0.state)
        })
    else {
      throw CodexManagedWorktreeError.invalid(
        "branch is already reserved by a Computer MCP-managed worktree"
      )
    }
    let record = CodexManagedWorktree(
      id: id,
      sourceWorkspaceID: sourceWorkspaceID,
      workspaceID: workspaceID,
      sourceRepositoryRoot: sourceRoot.path,
      gitCommonDirectory: commonDirectory.path,
      path: target.path,
      branch: branch,
      startPoint: startPoint,
      headOID: headOID,
      agentID: agentID,
      threadID: threadID,
      runID: runID,
      parentLeaseID: parentLeaseID,
      profileID: profileID,
      caller: caller,
      ttlSeconds: ttlSeconds,
      leaseID: nil,
      state: .planned,
      createdAt: now,
      updatedAt: now,
      planExpiresAt: now.addingTimeInterval(300),
      removedAt: nil,
      lastError: nil,
      revision: 1
    )
    try database.saveCodexManagedWorktree(record)
    return record
  }

  static func performProvision(
    database: GatewayDatabase?,
    sourceWorkspaceID: String?,
    planID: String,
    expectedRevision: Int,
    confirmProvision: Bool,
    commandRunner: any CommandRunning = ProcessCommandRunner(),
    managedRoot: URL? = nil,
    now: Date = Date()
  ) throws -> CodexManagedWorktree {
    guard let database else { throw CodexManagedWorktreeError.unavailable }
    guard confirmProvision else {
      throw CodexManagedWorktreeError.invalid(
        "confirm_provision must be true after reviewing the persisted plan"
      )
    }
    guard var record = try database.codexManagedWorktree(id: planID),
      record.sourceWorkspaceID == sourceWorkspaceID
    else {
      throw CodexManagedWorktreeError.unknown(planID)
    }
    guard record.revision == expectedRevision else {
      throw CodexManagedWorktreeError.revisionConflict(
        expected: expectedRevision,
        actual: record.revision
      )
    }
    guard record.state == .planned, record.planExpiresAt.map({ $0 > now }) == true else {
      throw CodexManagedWorktreeError.state("the provision plan is not current")
    }
    guard let parent = try database.codexWorktreeLease(id: record.parentLeaseID),
      parent.workspaceID == record.sourceWorkspaceID,
      parent.state == .active,
      parent.expiresAt > now
    else {
      throw CodexManagedWorktreeError.state("the parent lease is no longer active")
    }
    let sourceRoot = URL(fileURLWithPath: record.sourceRepositoryRoot, isDirectory: true)
    let expectedRoot = managedRootURL(database: database, override: managedRoot)
    let target = URL(fileURLWithPath: record.path, isDirectory: true).standardizedFileURL
    guard target.path.hasPrefix(expectedRoot.standardizedFileURL.path + "/") else {
      throw CodexManagedWorktreeError.invalid("persisted path is outside the managed root")
    }
    guard !FileManager.default.fileExists(atPath: target.path) else {
      throw CodexManagedWorktreeError.state("the planned worktree path already exists")
    }
    let resolvedOID = try gitText(
      ["rev-parse", "--verify", "\(record.startPoint)^{commit}"],
      workingDirectory: sourceRoot,
      runner: commandRunner
    )
    guard resolvedOID == record.headOID else {
      throw CodexManagedWorktreeError.state("the planned start point changed")
    }
    let branchLookup = try gitResult(
      ["show-ref", "--verify", "--quiet", "refs/heads/\(record.branch)"],
      workingDirectory: sourceRoot,
      runner: commandRunner
    )
    guard branchLookup.exitCode == 1 else {
      throw CodexManagedWorktreeError.state("the planned branch is no longer available")
    }
    record = try database.updateCodexManagedWorktree(
      id: record.id,
      sourceWorkspaceID: sourceWorkspaceID,
      expectedRevision: record.revision
    ) { value in
      value.state = .provisioning
      value.updatedAt = now
      value.lastError = nil
    }
    var createdLease: CodexWorktreeLease?
    var createdGitWorktree = false
    do {
      try prepareManagedRoot(expectedRoot)
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
      try validateManagedDirectory(
        target.deletingLastPathComponent(),
        containedIn: expectedRoot
      )
      _ = try git(
        ["worktree", "add", "-b", record.branch, target.path, record.headOID],
        workingDirectory: sourceRoot,
        runner: commandRunner
      )
      createdGitWorktree = true
      let actualRoot = canonicalURL(
        try gitPath(
          ["rev-parse", "--show-toplevel"],
          workingDirectory: target,
          runner: commandRunner
        ),
        relativeTo: target
      )
      let actualCommon = canonicalURL(
        try gitPath(
          ["rev-parse", "--git-common-dir"],
          workingDirectory: target,
          runner: commandRunner
        ),
        relativeTo: target
      )
      try validateManagedDirectory(target, containedIn: expectedRoot)
      guard actualRoot.path == target.resolvingSymlinksInPath().path,
        actualCommon.path == record.gitCommonDirectory
      else {
        throw CodexManagedWorktreeError.state(
          "Git did not create the exact planned worktree in the source repository"
        )
      }
      let workspace = RegisteredWorkspace(
        id: record.workspaceID,
        displayName:
          "\(URL(fileURLWithPath: record.sourceRepositoryRoot).lastPathComponent) — \(record.branch)",
        rootPath: target.path,
        createdAt: now,
        updatedAt: now
      )
      try database.saveWorkspace(workspace)
      try grantWorkspace(
        database: database,
        profileID: record.profileID,
        caller: record.caller,
        sourceWorkspaceID: record.sourceWorkspaceID,
        workspaceID: record.workspaceID
      )
      let lease = try database.acquireCodexWorktreeLease(
        workspaceID: record.workspaceID,
        workspacePath: target.path,
        mode: .isolatedWorktree,
        agentID: record.agentID,
        threadID: record.threadID,
        runID: record.runID,
        parentLeaseID: record.parentLeaseID,
        branch: record.branch,
        ttlSeconds: record.ttlSeconds,
        now: now
      )
      createdLease = lease
      let actualHead = try gitText(
        ["rev-parse", "HEAD"],
        workingDirectory: target,
        runner: commandRunner
      )
      return try database.updateCodexManagedWorktree(
        id: record.id,
        sourceWorkspaceID: sourceWorkspaceID,
        expectedRevision: record.revision
      ) { value in
        value.state = .active
        value.headOID = actualHead
        value.leaseID = lease.id
        value.updatedAt = now
        value.planExpiresAt = nil
      }
    } catch {
      if let createdLease {
        _ = try? CodexWorktreeLeaseManager.release(
          database: database,
          workspaceID: createdLease.workspaceID,
          leaseID: createdLease.id,
          expectedRevision: createdLease.revision,
          reason: "managed_worktree_provision_rolled_back",
          now: now
        )
      }
      try? database.deleteWorkspace(id: record.workspaceID)
      if createdGitWorktree {
        _ = try? gitResult(
          ["worktree", "remove", target.path],
          workingDirectory: sourceRoot,
          runner: commandRunner
        )
        _ = try? gitResult(
          ["branch", "-D", record.branch],
          workingDirectory: sourceRoot,
          runner: commandRunner
        )
      }
      let message = safeError(error)
      _ = try? database.updateCodexManagedWorktree(
        id: record.id,
        sourceWorkspaceID: sourceWorkspaceID,
        expectedRevision: record.revision
      ) { value in
        value.state = .failed
        value.updatedAt = now
        value.planExpiresAt = nil
        value.lastError = message
      }
      throw error
    }
  }

  static func planRemoval(
    database: GatewayDatabase?,
    sourceWorkspaceID: String?,
    managedWorktreeID: String,
    liveRuntimeStatus: JSONValue,
    commandRunner: any CommandRunning = ProcessCommandRunner(),
    managedRoot: URL? = nil,
    now: Date = Date()
  ) throws -> CodexManagedWorktree {
    guard let database else { throw CodexManagedWorktreeError.unavailable }
    guard let record = try database.codexManagedWorktree(id: managedWorktreeID),
      record.sourceWorkspaceID == sourceWorkspaceID
    else {
      throw CodexManagedWorktreeError.unknown(managedWorktreeID)
    }
    guard record.state == .active else {
      throw CodexManagedWorktreeError.state("only an active managed worktree can be removed")
    }
    try validateRemoval(
      record,
      database: database,
      liveRuntimeStatus: liveRuntimeStatus,
      commandRunner: commandRunner,
      managedRoot: managedRoot,
      expectedHeadOID: nil,
      now: now
    )
    let target = URL(fileURLWithPath: record.path, isDirectory: true)
    let headOID = try gitText(
      ["rev-parse", "HEAD"],
      workingDirectory: target,
      runner: commandRunner
    )
    return try database.updateCodexManagedWorktree(
      id: record.id,
      sourceWorkspaceID: sourceWorkspaceID,
      expectedRevision: record.revision
    ) { value in
      value.state = .removalPlanned
      value.headOID = headOID
      value.updatedAt = now
      value.planExpiresAt = now.addingTimeInterval(300)
      value.lastError = nil
    }
  }

  static func performRemoval(
    database: GatewayDatabase?,
    sourceWorkspaceID: String?,
    managedWorktreeID: String,
    expectedRevision: Int,
    confirmRemoval: Bool,
    liveRuntimeStatus: JSONValue,
    commandRunner: any CommandRunning = ProcessCommandRunner(),
    managedRoot: URL? = nil,
    now: Date = Date()
  ) throws -> CodexManagedWorktree {
    guard let database else { throw CodexManagedWorktreeError.unavailable }
    guard confirmRemoval else {
      throw CodexManagedWorktreeError.invalid(
        "confirm_remove must be true after reviewing the removal plan"
      )
    }
    guard var record = try database.codexManagedWorktree(id: managedWorktreeID),
      record.sourceWorkspaceID == sourceWorkspaceID
    else {
      throw CodexManagedWorktreeError.unknown(managedWorktreeID)
    }
    guard record.revision == expectedRevision else {
      throw CodexManagedWorktreeError.revisionConflict(
        expected: expectedRevision,
        actual: record.revision
      )
    }
    guard record.state == .removalPlanned,
      record.planExpiresAt.map({ $0 > now }) == true
    else {
      throw CodexManagedWorktreeError.state("the removal plan is not current")
    }
    try validateRemoval(
      record,
      database: database,
      liveRuntimeStatus: liveRuntimeStatus,
      commandRunner: commandRunner,
      managedRoot: managedRoot,
      expectedHeadOID: record.headOID,
      now: now
    )
    record = try database.updateCodexManagedWorktree(
      id: record.id,
      sourceWorkspaceID: sourceWorkspaceID,
      expectedRevision: record.revision
    ) { value in
      value.state = .removing
      value.updatedAt = now
      value.lastError = nil
    }
    let sourceRoot = URL(fileURLWithPath: record.sourceRepositoryRoot, isDirectory: true)
    do {
      _ = try git(
        ["worktree", "remove", record.path],
        workingDirectory: sourceRoot,
        runner: commandRunner
      )
      guard !FileManager.default.fileExists(atPath: record.path) else {
        throw CodexManagedWorktreeError.state("Git returned success but the worktree remains")
      }
      try database.deleteWorkspace(id: record.workspaceID)
      try revokeWorkspace(database: database, workspaceID: record.workspaceID)
      return try database.updateCodexManagedWorktree(
        id: record.id,
        sourceWorkspaceID: sourceWorkspaceID,
        expectedRevision: record.revision
      ) { value in
        value.state = .removed
        value.updatedAt = now
        value.removedAt = now
        value.planExpiresAt = nil
      }
    } catch {
      let message = safeError(error)
      _ = try? database.updateCodexManagedWorktree(
        id: record.id,
        sourceWorkspaceID: sourceWorkspaceID,
        expectedRevision: record.revision
      ) { value in
        value.state = .active
        value.updatedAt = now
        value.planExpiresAt = nil
        value.lastError = message
      }
      throw error
    }
  }

  static func managedRootURL(database: GatewayDatabase, override: URL?) -> URL {
    if let override {
      return override.standardizedFileURL
    }
    if let databaseURL = database.fileURL {
      return databaseURL.deletingLastPathComponent()
        .appendingPathComponent("Managed Worktrees", isDirectory: true)
        .standardizedFileURL
    }
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("Computer MCP Managed Worktrees", isDirectory: true)
      .standardizedFileURL
  }

  private static func validateRemoval(
    _ record: CodexManagedWorktree,
    database: GatewayDatabase,
    liveRuntimeStatus: JSONValue,
    commandRunner: any CommandRunning,
    managedRoot: URL?,
    expectedHeadOID: String?,
    now: Date
  ) throws {
    guard let leaseID = record.leaseID,
      let lease = try database.codexWorktreeLease(id: leaseID),
      lease.workspaceID == record.workspaceID
    else {
      throw CodexManagedWorktreeError.state("the managed writer lease receipt is missing")
    }
    guard lease.state != .active else {
      let suffix = lease.expiresAt <= now ? "run lease cleanup first" : "release it first"
      throw CodexManagedWorktreeError.state("the managed writer lease is active; \(suffix)")
    }
    guard (liveRuntimeStatus.objectValue?["runtimes"]?.arrayValue ?? []).isEmpty else {
      throw CodexManagedWorktreeError.state(
        "a live Computer MCP runtime still owns the managed workspace"
      )
    }
    let root = managedRootURL(database: database, override: managedRoot).standardizedFileURL
    let target = URL(fileURLWithPath: record.path, isDirectory: true).standardizedFileURL
    try validateManagedDirectory(root, containedIn: root)
    guard target.path.hasPrefix(root.path + "/"),
      FileManager.default.fileExists(atPath: target.path)
    else {
      throw CodexManagedWorktreeError.state(
        "the ownership receipt does not identify an existing path under the managed root"
      )
    }
    try validateManagedDirectory(target, containedIn: root)
    let actualRoot = canonicalURL(
      try gitPath(
        ["rev-parse", "--show-toplevel"],
        workingDirectory: target,
        runner: commandRunner
      ),
      relativeTo: target
    )
    let actualCommon = canonicalURL(
      try gitPath(
        ["rev-parse", "--git-common-dir"],
        workingDirectory: target,
        runner: commandRunner
      ),
      relativeTo: target
    )
    guard actualRoot.path == target.resolvingSymlinksInPath().path,
      actualCommon.path == record.gitCommonDirectory
    else {
      throw CodexManagedWorktreeError.state(
        "the path is not the exact worktree recorded by Computer MCP"
      )
    }
    let status = try gitResult(
      ["status", "--porcelain=v1", "-z"],
      workingDirectory: target,
      runner: commandRunner
    )
    guard status.exitCode == 0, status.stdout.isEmpty else {
      throw CodexManagedWorktreeError.state("the managed worktree is not clean")
    }
    if let expectedHeadOID {
      let head = try gitText(
        ["rev-parse", "HEAD"],
        workingDirectory: target,
        runner: commandRunner
      )
      guard head == expectedHeadOID else {
        throw CodexManagedWorktreeError.state("the managed worktree HEAD changed after review")
      }
    }
  }

  private static func grantWorkspace(
    database: GatewayDatabase,
    profileID: String,
    caller: String,
    sourceWorkspaceID: String,
    workspaceID: String
  ) throws {
    guard let parsedProfile = GatewayProfileID(rawValue: profileID),
      let parsedCaller = GatewayCallerKind(rawValue: caller)
    else {
      throw CodexManagedWorktreeError.invalid("stored profile ownership is invalid")
    }
    let existing = try database.profiles().first { $0.id == parsedProfile }
    var grant =
      existing
      ?? ProfileGrant(
        id: parsedProfile,
        capabilityIDs: [],
        workspaceIDs: [sourceWorkspaceID],
        allowedCallers: [parsedCaller],
        fullShellEnabled: parsedProfile == .localAdmin
      )
    guard grant.workspaceIDs.contains(sourceWorkspaceID) else {
      throw CodexManagedWorktreeError.state(
        "the persisted profile no longer grants the source workspace"
      )
    }
    grant.workspaceIDs.insert(workspaceID)
    try database.saveProfile(grant)
  }

  private static func revokeWorkspace(database: GatewayDatabase, workspaceID: String) throws {
    for var grant in try database.profiles() where grant.workspaceIDs.contains(workspaceID) {
      grant.workspaceIDs.remove(workspaceID)
      try database.saveProfile(grant)
    }
  }

  private static func prepareManagedRoot(_ root: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: root.path) {
      let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw CodexManagedWorktreeError.invalid(
          "the managed worktree root must be a real directory"
        )
      }
      let attributes = try fileManager.attributesOfItem(atPath: root.path)
      if let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value != getuid() {
        throw CodexManagedWorktreeError.invalid(
          "the managed worktree root is owned by another user"
        )
      }
    } else {
      try fileManager.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
    }
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: root.path
    )
  }

  private static func validateManagedDirectory(_ directory: URL, containedIn root: URL) throws {
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw CodexManagedWorktreeError.invalid(
        "managed worktree paths must be real directories, not symbolic links"
      )
    }
    let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
    let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    guard
      resolvedDirectory == resolvedRoot
        || resolvedDirectory.path.hasPrefix(resolvedRoot.path + "/")
    else {
      throw CodexManagedWorktreeError.invalid(
        "managed worktree path escaped the canonical managed root"
      )
    }
  }

  private static func validateText(_ value: String, name: String, maximum: Int) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= maximum, trimmed == value else {
      throw CodexManagedWorktreeError.invalid(
        "\(name) must contain 1...\(maximum) bytes without surrounding whitespace"
      )
    }
    guard CodexApprovalRedactor.redactString(value, maximumCharacters: maximum) == value else {
      throw CodexManagedWorktreeError.invalid(
        "\(name) must not contain credential-like text"
      )
    }
  }

  private static func validateOpaqueIdentifier(
    _ value: String,
    name: String,
    maximum: Int
  ) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed == value, value.utf8.count <= maximum else {
      throw CodexManagedWorktreeError.invalid(
        "\(name) must contain 1...\(maximum) bytes without surrounding whitespace"
      )
    }
  }

  private static func git(
    _ arguments: [String],
    workingDirectory: URL,
    runner: any CommandRunning
  ) throws -> CommandResult {
    let result = try gitResult(arguments, workingDirectory: workingDirectory, runner: runner)
    guard result.exitCode == 0, !result.timedOut else { throw commandError(result) }
    return result
  }

  private static func gitText(
    _ arguments: [String],
    workingDirectory: URL,
    runner: any CommandRunning
  ) throws -> String {
    try git(arguments, workingDirectory: workingDirectory, runner: runner)
      .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func gitPath(
    _ arguments: [String],
    workingDirectory: URL,
    runner: any CommandRunning
  ) throws -> String {
    let value = try gitText(arguments, workingDirectory: workingDirectory, runner: runner)
    guard !value.isEmpty, value.utf8.count <= 16_384 else {
      throw CodexManagedWorktreeError.command("Git returned an invalid path.")
    }
    return value
  }

  private static func gitResult(
    _ arguments: [String],
    workingDirectory: URL,
    runner: any CommandRunning
  ) throws -> CommandResult {
    try runner.run(
      executable: "/usr/bin/git",
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"],
      timeoutMilliseconds: 30_000,
      maxOutputBytes: 1_048_576
    )
  }

  private static func commandError(_ result: CommandResult) -> CodexManagedWorktreeError {
    let detail =
      result.timedOut
      ? "command timed out"
      : (result.stderr.isEmpty ? "exit \(result.exitCode ?? -1)" : result.stderr)
    return .command(CodexApprovalRedactor.redactString(detail, maximumCharacters: 4_096))
  }

  private static func canonicalURL(_ path: String, relativeTo base: URL) -> URL {
    let url =
      path.hasPrefix("/")
      ? URL(fileURLWithPath: path, isDirectory: true)
      : base.appendingPathComponent(path, isDirectory: true)
    return url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func isObjectID(_ value: String) -> Bool {
    value.utf8.count == 40
      && value.utf8.allSatisfy {
        ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
      }
  }

  private static func safeError(_ error: Error) -> String {
    CodexApprovalRedactor.redactString(error.localizedDescription, maximumCharacters: 4_096)
  }
}
