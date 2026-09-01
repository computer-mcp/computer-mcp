import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)
final class CodexManagedWorktreeTests {
  @Test
  func testManagedWorktreeProvisionAndRemovalRequireOwnedCleanLifecycle() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repository = directory.appendingPathComponent("repository", isDirectory: true)
    let managedRoot = directory.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try runGit(["init", "-q"], in: repository)
    try runGit(["config", "user.name", "Computer MCP Test"], in: repository)
    try runGit(["config", "user.email", "computer-mcp@example.invalid"], in: repository)
    try Data("baseline\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    try runGit(["add", "README.md"], in: repository)
    try runGit(["commit", "-q", "-m", "test: baseline"], in: repository)

    let database = try GatewayDatabase(inMemory: ())
    let sourceWorkspace = RegisteredWorkspace(
      id: "source-workspace",
      displayName: "Source",
      rootPath: repository.path
    )
    try database.saveWorkspace(sourceWorkspace)
    try database.saveProfile(
      ProfileGrant(
        id: .localAdmin,
        capabilityIDs: ["*"],
        workspaceIDs: [sourceWorkspace.id],
        allowedCallers: [.localMCP],
        fullShellEnabled: true
      )
    )
    let parent = try CodexWorktreeLeaseManager.acquire(
      database: database,
      workspaceID: sourceWorkspace.id,
      agentID: "parent-agent",
      threadID: "parent-thread",
      runID: nil,
      parentLeaseID: nil,
      branch: nil,
      mode: .exclusive,
      ttlSeconds: 900,
      liveRuntimeStatus: .object(["runtimes": .array([])])
    )

    let plan = try CodexManagedWorktreeManager.planProvision(
      database: database,
      sourceWorkspaceID: sourceWorkspace.id,
      profileID: GatewayProfileID.localAdmin.rawValue,
      caller: GatewayCallerKind.localMCP.rawValue,
      agentID: "child-agent",
      threadID: "child-thread",
      runID: nil,
      parentLeaseID: parent.id,
      branch: "codex/managed-child",
      startPoint: "HEAD",
      ttlSeconds: 900,
      managedRoot: managedRoot
    )
    #expect(plan.state == .planned)
    #expect(!FileManager.default.fileExists(atPath: plan.path))

    let active = try CodexManagedWorktreeManager.performProvision(
      database: database,
      sourceWorkspaceID: sourceWorkspace.id,
      planID: plan.id,
      expectedRevision: plan.revision,
      confirmProvision: true,
      managedRoot: managedRoot
    )
    #expect(active.state == .active)
    #expect(FileManager.default.fileExists(atPath: active.path))
    #expect(try database.workspace(id: active.workspaceID)?.rootPath == active.path)
    #expect(
      try database.profiles().first(where: { $0.id == .localAdmin })?
        .workspaceIDs.contains(active.workspaceID) == true
    )
    let childLeaseID = try #require(active.leaseID)
    var childLease = try #require(try database.codexWorktreeLease(id: childLeaseID))
    #expect(childLease.mode == .isolatedWorktree)
    #expect(childLease.parentLeaseID == parent.id)
    #expect(childLease.workspaceID == active.workspaceID)

    let dirtyFile = URL(fileURLWithPath: active.path).appendingPathComponent("dirty.txt")
    try Data("not accepted\n".utf8).write(to: dirtyFile)
    #expect(throws: CodexManagedWorktreeError.self) {
      try CodexManagedWorktreeManager.planRemoval(
        database: database,
        sourceWorkspaceID: sourceWorkspace.id,
        managedWorktreeID: active.id,
        liveRuntimeStatus: .object(["runtimes": .array([])]),
        managedRoot: managedRoot
      )
    }
    try FileManager.default.removeItem(at: dirtyFile)
    childLease = try CodexWorktreeLeaseManager.release(
      database: database,
      workspaceID: childLease.workspaceID,
      leaseID: childLease.id,
      expectedRevision: childLease.revision,
      reason: "Child evidence reconciled."
    )
    #expect(childLease.state == .released)

    let removalPlan = try CodexManagedWorktreeManager.planRemoval(
      database: database,
      sourceWorkspaceID: sourceWorkspace.id,
      managedWorktreeID: active.id,
      liveRuntimeStatus: .object(["runtimes": .array([])]),
      managedRoot: managedRoot
    )
    let removed = try CodexManagedWorktreeManager.performRemoval(
      database: database,
      sourceWorkspaceID: sourceWorkspace.id,
      managedWorktreeID: active.id,
      expectedRevision: removalPlan.revision,
      confirmRemoval: true,
      liveRuntimeStatus: .object(["runtimes": .array([])]),
      managedRoot: managedRoot
    )
    #expect(removed.state == .removed)
    #expect(!FileManager.default.fileExists(atPath: active.path))
    #expect(try database.workspace(id: active.workspaceID) == nil)
    #expect(
      try database.profiles().first(where: { $0.id == .localAdmin })?
        .workspaceIDs.contains(active.workspaceID) == false
    )
    let preservedBranch = try gitResult(
      ["show-ref", "--verify", "--quiet", "refs/heads/codex/managed-child"],
      in: repository
    )
    #expect(preservedBranch.exitCode == 0)
  }

  @Test
  func testRemovalNeverTargetsAnUnownedUserWorktree() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try GatewayDatabase(inMemory: ())
    try database.saveWorkspace(
      RegisteredWorkspace(
        id: "source-workspace",
        displayName: "Source",
        rootPath: directory.path
      )
    )

    #expect(throws: CodexManagedWorktreeError.self) {
      try CodexManagedWorktreeManager.planRemoval(
        database: database,
        sourceWorkspaceID: "source-workspace",
        managedWorktreeID: "user-owned-worktree",
        liveRuntimeStatus: .object(["runtimes": .array([])]),
        managedRoot: directory.appendingPathComponent("managed", isDirectory: true)
      )
    }
    #expect(FileManager.default.fileExists(atPath: directory.path))
  }

  @Test
  func testRemovalRejectsAReceiptedPathReplacedBySymbolicLink() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repository = directory.appendingPathComponent("repository", isDirectory: true)
    let managedRoot = directory.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try runGit(["init", "-q"], in: repository)
    try runGit(["config", "user.name", "Computer MCP Test"], in: repository)
    try runGit(["config", "user.email", "computer-mcp@example.invalid"], in: repository)
    try Data("baseline\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    try runGit(["add", "README.md"], in: repository)
    try runGit(["commit", "-q", "-m", "test: baseline"], in: repository)

    let database = try GatewayDatabase(inMemory: ())
    let source = RegisteredWorkspace(
      id: "source-workspace",
      displayName: "Source",
      rootPath: repository.path
    )
    try database.saveWorkspace(source)
    try database.saveProfile(
      ProfileGrant(
        id: .localAdmin,
        capabilityIDs: ["*"],
        workspaceIDs: [source.id],
        allowedCallers: [.localMCP],
        fullShellEnabled: true
      )
    )
    let parent = try CodexWorktreeLeaseManager.acquire(
      database: database,
      workspaceID: source.id,
      agentID: "parent-agent",
      threadID: "parent-thread",
      runID: nil,
      parentLeaseID: nil,
      branch: nil,
      mode: .exclusive,
      ttlSeconds: 900,
      liveRuntimeStatus: .object(["runtimes": .array([])])
    )
    let plan = try CodexManagedWorktreeManager.planProvision(
      database: database,
      sourceWorkspaceID: source.id,
      profileID: GatewayProfileID.localAdmin.rawValue,
      caller: GatewayCallerKind.localMCP.rawValue,
      agentID: "child-agent",
      threadID: "child-thread",
      runID: nil,
      parentLeaseID: parent.id,
      branch: "codex/symlink-boundary",
      startPoint: "HEAD",
      ttlSeconds: 900,
      managedRoot: managedRoot
    )
    let active = try CodexManagedWorktreeManager.performProvision(
      database: database,
      sourceWorkspaceID: source.id,
      planID: plan.id,
      expectedRevision: plan.revision,
      confirmProvision: true,
      managedRoot: managedRoot
    )
    let childLeaseID = try #require(active.leaseID)
    var childLease = try #require(try database.codexWorktreeLease(id: childLeaseID))
    childLease = try CodexWorktreeLeaseManager.release(
      database: database,
      workspaceID: childLease.workspaceID,
      leaseID: childLease.id,
      expectedRevision: childLease.revision,
      reason: "Ready for removal validation."
    )
    #expect(childLease.state == .released)

    let original = URL(fileURLWithPath: active.path, isDirectory: true)
    let moved = directory.appendingPathComponent("moved-worktree", isDirectory: true)
    try FileManager.default.moveItem(at: original, to: moved)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)

    #expect(throws: CodexManagedWorktreeError.self) {
      try CodexManagedWorktreeManager.planRemoval(
        database: database,
        sourceWorkspaceID: source.id,
        managedWorktreeID: active.id,
        liveRuntimeStatus: .object(["runtimes": .array([])]),
        managedRoot: managedRoot
      )
    }
    #expect(FileManager.default.fileExists(atPath: moved.path))
  }

  @Test
  func testProvisionRollbackDoesNotDeleteBranchCreatedByAnotherWriter() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let repository = directory.appendingPathComponent("repository", isDirectory: true)
    let managedRoot = directory.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try runGit(["init", "-q"], in: repository)
    try runGit(["config", "user.name", "Computer MCP Test"], in: repository)
    try runGit(["config", "user.email", "computer-mcp@example.invalid"], in: repository)
    try Data("baseline\n".utf8).write(to: repository.appendingPathComponent("README.md"))
    try runGit(["add", "README.md"], in: repository)
    try runGit(["commit", "-q", "-m", "test: baseline"], in: repository)

    let database = try GatewayDatabase(inMemory: ())
    let source = RegisteredWorkspace(
      id: "source-workspace",
      displayName: "Source",
      rootPath: repository.path
    )
    try database.saveWorkspace(source)
    try database.saveProfile(
      ProfileGrant(
        id: .localAdmin,
        capabilityIDs: ["*"],
        workspaceIDs: [source.id],
        allowedCallers: [.localMCP],
        fullShellEnabled: true
      )
    )
    let parent = try CodexWorktreeLeaseManager.acquire(
      database: database,
      workspaceID: source.id,
      agentID: "parent-agent",
      threadID: "parent-thread",
      runID: nil,
      parentLeaseID: nil,
      branch: nil,
      mode: .exclusive,
      ttlSeconds: 900,
      liveRuntimeStatus: .object(["runtimes": .array([])])
    )
    let branch = "codex/concurrent-owner"
    let plan = try CodexManagedWorktreeManager.planProvision(
      database: database,
      sourceWorkspaceID: source.id,
      profileID: GatewayProfileID.localAdmin.rawValue,
      caller: GatewayCallerKind.localMCP.rawValue,
      agentID: "child-agent",
      threadID: "child-thread",
      runID: nil,
      parentLeaseID: parent.id,
      branch: branch,
      startPoint: "HEAD",
      ttlSeconds: 900,
      commandRunner: BranchRaceCommandRunner(branch: branch),
      managedRoot: managedRoot
    )

    #expect(throws: CodexManagedWorktreeError.self) {
      try CodexManagedWorktreeManager.performProvision(
        database: database,
        sourceWorkspaceID: source.id,
        planID: plan.id,
        expectedRevision: plan.revision,
        confirmProvision: true,
        commandRunner: BranchRaceCommandRunner(branch: branch),
        managedRoot: managedRoot
      )
    }
    let branchResult = try gitResult(
      ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
      in: repository
    )
    #expect(branchResult.exitCode == 0)
  }

  private func runGit(_ arguments: [String], in directory: URL) throws {
    let result = try gitResult(arguments, in: directory)
    guard result.exitCode == 0 else {
      throw CodexManagedWorktreeError.command(result.stderr)
    }
  }

  private func gitResult(_ arguments: [String], in directory: URL) throws -> CommandResult {
    try ProcessCommandRunner().run(
      executable: "/usr/bin/git",
      arguments: arguments,
      workingDirectory: directory,
      environment: ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"],
      timeoutMilliseconds: 10_000,
      maxOutputBytes: 1_048_576
    )
  }
}

private final class BranchRaceCommandRunner: CommandRunning, @unchecked Sendable {
  private let branch: String
  private let runner = ProcessCommandRunner()
  private let lock = NSLock()
  private var injected = false

  init(branch: String) {
    self.branch = branch
  }

  func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult {
    lock.lock()
    let shouldInject =
      !injected && executable == "/usr/bin/git" && arguments.starts(with: ["worktree", "add"])
    if shouldInject {
      injected = true
    }
    lock.unlock()

    if shouldInject, let workingDirectory {
      let create = try runner.run(
        executable: executable,
        arguments: ["branch", branch, "HEAD"],
        workingDirectory: workingDirectory,
        environment: environment,
        timeoutMilliseconds: timeoutMilliseconds,
        maxOutputBytes: maxOutputBytes
      )
      guard create.exitCode == 0 else { return create }
      return CommandResult(
        executable: executable,
        arguments: arguments,
        exitCode: 128,
        timedOut: false,
        stdout: "",
        stderr: "fatal: a concurrent writer created the branch",
        stdoutTruncated: false,
        stderrTruncated: false
      )
    }
    return try runner.run(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes
    )
  }

  func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult {
    try runner.runData(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes
    )
  }
}
