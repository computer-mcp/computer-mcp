import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPWorktrees
import Foundation
import Testing

@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)
struct GatewayWorktreeServiceTests {
  @Test func sandboxLifecyclePreservesPrivateCommitAndProtectsBranches() throws {
    let fixture = try WorktreeServiceFixture()
    defer { fixture.remove() }
    let created = try fixture.call(.add(name: "topic", branch: nil, base: nil))
    let id = try #require(created.objectValue?["project_id"]?.stringValue)
    let root = URL(fileURLWithPath: try #require(created.objectValue?["path"]?.stringValue))
    #expect(created.objectValue?["base"] == .string("main"))
    let record = try #require(try fixture.database.derivedProjects().first { $0.projectID == id })
    let repository = try fixture.repository()
    _ = try repository.topology(projectID: id)
    try Data("private change".utf8).write(to: root.appendingPathComponent("value"))
    let view: [String: String] = [:]
    _ = try fixture.git(["add", "value"], at: root, environment: view)
    _ = try fixture.git(
      [
        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m",
        "Private",
      ], at: root, environment: view)
    let head = try fixture.git(["rev-parse", "HEAD"], at: root, environment: view)
      .trimmingCharacters(in: .newlines)
    #expect(try fixture.git(["rev-parse", "refs/heads/worktree/topic"]) != head + "\n")
    #expect(throws: (any Error).self) {
      try fixture.call(
        .deleteBranch(name: "worktree/topic", force: true, dryRun: false, confirm: true))
    }
    #expect(throws: (any Error).self) {
      try fixture.call(
        .deleteBranch(name: "worktree/topic", force: false, dryRun: false, confirm: true))
    }
    let merged = try fixture.call(.merge(branch: "worktree/topic"))
    #expect(merged.objectValue?["oid"] == .string(head))
    #expect(
      try String(contentsOf: fixture.source.appendingPathComponent("value"), encoding: .utf8)
        == "private change")
    let removed = try fixture.call(.remove(force: false), projectID: id)
    #expect(removed.objectValue?["oid"] == .string(head))
    #expect(removed.objectValue?["terminationWarnings"] == .array([]))
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(try fixture.database.project(id: id) == nil)
    let deleted = try fixture.call(
      .deleteBranch(name: record.worktree!.branchName, force: false, dryRun: false, confirm: true))
    #expect(deleted.objectValue?["deleted"] == .bool(true))
  }

  @Test func hostServiceActionsPerformOnlyTheirLifecycleOperation() throws {
    let fixture = try WorktreeServiceFixture()
    defer { fixture.remove() }
    let operation = GitWorktreeOperation.add(name: "topic", branch: nil, base: nil)
    let proof = try fixture.admit(operation, projectID: "source")
    for action in [MCPHostServiceAction.projectList, .projectRemoval, .diagnosticsSnapshot] {
      #expect(throws: (any Error).self) {
        try InvocationExecution.$current.withValue(
          GatewayWorktreeInvocation(authorization: proof, hostAction: action)
        ) { try fixture.service("source").perform(operation) }
      }
    }
    #expect(try fixture.database.derivedProjects().isEmpty)
    let operationID = UUID()
    let outcome = try InvocationExecution.$current.withValue(
      GatewayWorktreeInvocation(authorization: proof, hostAction: .projectProvision)
    ) { try fixture.service("source").perform(operation, operationID: operationID) }
    guard case .created(let created, let worktreeID) = outcome else {
      Issue.record("Provisioning returned another outcome.")
      return
    }
    // The reserved operation is the creation journal's operation and the worktree's ID.
    #expect(worktreeID == operationID)
    #expect(created.projectID == "worktree-" + operationID.uuidString.lowercased())
    let storage = try #require(fixture.database.worktreeStorage)
    #expect(try storage.creationOutcome(operationID: operationID) == .created(created))
    #expect(try storage.creationOutcome(operationID: UUID()) == .notStarted)
  }

  @Test func restartReconcilesLifecycleOperationsFromTheirJournals() throws {
    let fixture = try WorktreeServiceFixture()
    defer { fixture.remove() }
    let repository = try fixture.repository()
    let storage = try #require(fixture.database.worktreeStorage)
    let completedID = UUID()
    let created = try repository.create(name: "completed", operationID: completedID)
    let interruptedID = UUID()
    _ = try repository.create(name: "interrupted", operationID: interruptedID)
    // An in-progress creation journal leaves the outcome to journal recovery.
    let name = "worktree-" + interruptedID.uuidString.lowercased() + ".json"
    let journals = try WorktreeDirectory(storage.journals)
    let original = try #require(try WorktreeJournalIO().read(name, in: journals, limit: 131_072))
    var fields = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
    fields["phase"] = "checkout"
    let interrupted = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    let removedID = UUID()
    let removable = try repository.create(name: "removable")
    let removal = try GatewaySynchronousOperation.run {
      try await repository.remove(
        projectID: removable.projectID, operationID: removedID, terminate: { _, _ in },
        authorize: { _, _ in })
    }
    try WorktreeJournalIO().write(interrupted, name: name, in: journals, replacing: original)
    let store = HostOperationStore(connection: fixture.database.connection)
    let source = try #require(try fixture.database.project(id: "source"))
    func record(
      _ id: UUID, _ action: MCPHostServiceAction, project: String = "source", running: Bool
    ) throws {
      let admission = HostCallAdmission(
        id: UUID(), generationID: UUID(), verifiedClientID: "client",
        actingPrincipal: .plugin(.localServer("probe")), profileID: .chatGPTOperate,
        caller: .secureTunnel, projectID: project, sourceProjectID: "source",
        upstreamName: "adapter.lifecycle",
        reference: .init(serverID: "probe", toolName: "lifecycle"),
        action: action, argumentsDigest: "digest", authorizationID: UUID(),
        authorizationRevision: 1, controlSessionID: nil, controlSessionRevision: nil,
        requestID: "request")
      try store.reserve(
        .init(
          id: id,
          binding: .init(
            admission: admission, action: action, pluginID: nil, contributionID: nil,
            sourceRegisteredAt: source.createdAt, projectRegisteredAt: source.createdAt,
            worktreeID: nil, arguments: [:])))
      if running {
        _ = try fixture.database.connection.writer.write {
          try HostOperationStore.claim(id, in: $0)
        }
      }
    }
    let reservedID = UUID()
    let absentID = UUID()
    try record(reservedID, .projectProvision, running: false)
    try record(completedID, .projectProvision, running: true)
    try record(interruptedID, .projectProvision, running: true)
    try record(absentID, .projectProvision, running: true)
    try record(removedID, .projectRemoval, project: removable.projectID, running: true)
    try fixture.database.reconcileHostOperations(owner: UUID())
    #expect(try store.operation(id: reservedID)?.state == .failed)
    #expect(try store.operation(id: absentID)?.state == .failed)
    #expect(try store.operation(id: interruptedID)?.state == .recoveryRequired)
    let completed = try #require(try store.operation(id: completedID))
    #expect(completed.state == .completed)
    #expect(completed.result?.objectValue?["path"] == .string(created.path.path))
    #expect(
      completed.result?.objectValue?["worktree_id"]
        == .string(completedID.uuidString.lowercased()))
    let removed = try #require(try store.operation(id: removedID))
    #expect(removed.state == .completed)
    #expect(removed.result?.objectValue?["oid"] == .string(removal.oid))
    try fixture.database.reconcileHostOperations(owner: UUID())
    #expect(try store.operation(id: completedID) == completed)
    #expect(try store.unfinished().map(\.id) == [interruptedID])
  }

  @Test func preparedGitTransactionAbortsAndBoundsTheWholeSession() throws {
    let fixture = try WorktreeServiceFixture()
    defer { fixture.remove() }
    let oid = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
    let command = WorktreeGitCommand(
      arguments: ["update-ref", "--stdin"], directory: fixture.source,
      environment: HostGitConfiguration.environment(home: fixture.root),
      input: Data("start\ncreate refs/heads/prepared \(oid)\nprepare\n".utf8),
      timeoutMilliseconds: 30_000, maxOutputBytes: 4096)
    #expect(throws: WorktreeServiceTestFailure.self) {
      try fixture.executor.withPreparedTransaction(command) {
        #expect(
          FileManager.default.fileExists(
            atPath: fixture.source.appendingPathComponent(".git/refs/heads/prepared.lock").path))
        throw WorktreeServiceTestFailure.unexpected
      }
    }
    #expect(try fixture.git(["for-each-ref", "refs/heads/prepared"]).isEmpty)
    var bounded = command
    bounded.timeoutMilliseconds = 1000
    var entered = false
    #expect(throws: (any Error).self) {
      try fixture.executor.withPreparedTransaction(bounded) {
        entered = true
        Thread.sleep(forTimeInterval: 1.2)
      }
    }
    #expect(entered)
    #expect(try fixture.git(["for-each-ref", "refs/heads/prepared"]).isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.source.appendingPathComponent(".git/refs/heads/prepared.lock").path))
  }

  @Test func removalResumesAfterContentDisappearsBeforeRegistrationCleanup() throws {
    let fixture = try WorktreeServiceFixture()
    defer { fixture.remove() }
    let result = try fixture.call(.add(name: "interrupted", branch: nil, base: nil))
    let id = try #require(result.objectValue?["project_id"]?.stringValue)
    let path = try #require(result.objectValue?["path"]?.stringValue)
    let repository = try fixture.repository(
      journalIO: .init(beforePublication: {
        if !FileManager.default.fileExists(atPath: path) {
          throw WorktreeServiceTestFailure.unexpected
        }
      }))
    #expect(throws: WorktreeServiceTestFailure.self) {
      try GatewaySynchronousOperation.run {
        try await repository.remove(projectID: id, terminate: { _, _ in }, authorize: { _, _ in })
      }
    }
    #expect(!FileManager.default.fileExists(atPath: path))
    let record = try #require(try fixture.database.derivedProjects().first { $0.projectID == id })
    #expect(record.state == .removing)
    #expect(try GatewayDatabase.hostContentIdentity(record) == nil)
    #expect(try fixture.database.project(id: id) != nil)
    let removed = try fixture.call(.remove(force: false), projectID: id)
    #expect(removed.objectValue?["project_id"] == .string(id))
    #expect(try fixture.database.project(id: id) == nil)
  }

  @Test func sourceLocationAndCurrentAuthorityAreRequired() throws {
    let fixture = try WorktreeServiceFixture()
    defer { fixture.remove() }
    let result = try fixture.call(.add(name: "guards", branch: nil, base: nil))
    let id = try #require(result.objectValue?["project_id"]?.stringValue)
    #expect(throws: (any Error).self) {
      try fixture.call(.add(name: "nested", branch: nil, base: nil), projectID: id)
    }
    #expect(throws: (any Error).self) { try fixture.call(.remove(force: true)) }
    #expect(throws: (any Error).self) {
      try fixture.call(.add(name: "other", branch: "worktree/guards", base: nil))
    }
    let inventory = try fixture.call(.list)
    #expect(inventory.objectValue?["worktrees"]?.arrayValue?.count == 2)
    let proof = try fixture.admit(.remove(force: true), projectID: id)
    var profile = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
    try profile.permissions.set(.granted(.read), for: .project("source"))
    try fixture.database.saveProfile(profile)
    #expect(throws: (any Error).self) {
      try InvocationExecution.$current.withValue(GatewayWorktreeInvocation(authorization: proof)) {
        try fixture.service(id).call(.remove(force: true))
      }
    }
    #expect(try fixture.database.project(id: id) != nil)
  }
}

private enum WorktreeServiceTestFailure: Error { case unexpected }

struct WorktreeServiceFixture {
  let root: URL
  let source: URL
  let database: GatewayDatabase
  let runtime: GatewayPermissionRuntime
  let platform: PlatformServices
  let executor: GatewayWorktreeGit
  init(policyReader: any ManagedPolicyReading = TestManagedPolicyReader()) throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    root = try ProjectPathResolver.canonicalProject(temporary)
    source = root.appendingPathComponent("source")
    let host = root.appendingPathComponent("host")
    for directory in [source, host] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    database = try fixturePermissionDatabase(path: host.appendingPathComponent("state.sqlite").path)
    try database.bootstrapPermissionProfiles([])
    try database.saveProject(.init(id: "source", displayName: "Source", rootPath: source.path))
    var permissions = Permissions()
    try permissions.set(.granted(.write), for: .project("source"))
    try database.saveProfile(
      .init(id: .chatGPTOperate, permissions: permissions, allowedCallers: [.secureTunnel]))
    let unused = WorktreeServicePlatform()
    platform = PlatformServices(
      launcher: testExecutionLauncher(), projectGrants: unused,
      pluginDirectories: unused, applications: TestApplicationBundleLocator(),
      toolProviders: unused,
      managementToolNames: [], executableSearchDirectories: [],
      gitExecutable: try testExecutable("git"),
      fileChanges: { _ in throw WorktreeServiceTestFailure.unexpected },
      permissionPolicyReader: policyReader)
    runtime = try database.permissionRuntime(platform: platform)
    try runtime.service.configureEnvironment(
      .init(
        projects: [.init(id: "source", root: .init(source.path))],
        rules: [
          .init(root: .init(root.path), kind: .userData),
          .init(root: .init(host.path), kind: .hostData),
        ]),
      trustedHosts: [], expectedProjects: database.projects(), expectedConfigurationRevision: nil)
    executor = GatewayWorktreeGit(launcher: platform.launcher, executable: platform.gitExecutable)
    _ = try git(["init", "--initial-branch=main"])
    try Data("initial".utf8).write(to: source.appendingPathComponent("value"))
    _ = try git(["add", "value"])
    _ = try git([
      "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m",
      "Initial",
    ])
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
  func git(_ arguments: [String], at directory: URL? = nil, environment: [String: String] = [:])
    throws -> String
  {
    let result = try executor.execute(
      .init(
        arguments: HostGitConfiguration.arguments + arguments,
        directory: directory ?? source,
        environment: HostGitConfiguration.environment(home: root).merging(environment) { _, value in
          value
        },
        timeoutMilliseconds: 30_000, maxOutputBytes: 1_048_576))
    try #require(result.exitCode == 0, "\(String(decoding: result.error, as: UTF8.self))")
    return String(decoding: result.output, as: UTF8.self)
  }
  func service(_ projectID: String) -> GatewayWorktreeService {
    .init(database: database, runtime: runtime, platform: platform, projectID: projectID)
  }
  func admit(_ operation: GitWorktreeOperation, projectID: String) throws -> InvocationAuthorization
  {
    let decision = try runtime.service.admit(
      subject: .init(
        context: .init(
          caller: .secureTunnel,
          profileID: .chatGPTOperate, trustedPrincipalID: "fixture")), tool: operation.toolName,
      projectID: projectID, argumentsDigest: UUID().uuidString,
      requirements: .init(
        actions: [
          .init(
            requirement: .init(.project("source"), operation.isWriting ? .write : .read),
            scope: .project("source"))
        ],
        paths: [.init(path: .init(source.path), operation: .read)], sandboxProjectID: "source"))
    guard case .allowed(let proof) = decision else { throw WorktreeServiceTestFailure.unexpected }
    return proof
  }
  func call(_ operation: GitWorktreeOperation, projectID: String = "source") throws -> JSONValue {
    let proof = try admit(operation, projectID: projectID)
    let invocation = try GatewaySynchronousOperation.run {
      try await runtime.prepare(
        authorization: proof,
        descriptor: .init(
          id: operation.toolName,
          risk: .projectWrite, requirement: .init(access: .sourceProjectWrite),
          projectRequirement: .required,
          localOnly: false, usesNetwork: false, hostOperation: .worktreeLifecycle),
        directory: source, connectionID: nil)
    }
    return try InvocationExecution.$current.withValue(invocation) {
      try service(projectID).call(operation)
    }
  }
  func repository(journalIO: WorktreeJournalIO = .init()) throws -> WorktreeRepository {
    let project = try #require(try database.project(id: "source"))
    return try WorktreeRepository(
      source: .init(
        id: "source", root: GatewayDatabase.canonicalProjectRoot(source.path),
        registeredAt: project.createdAt),
      store: database.derivedProjectStore(inspectNesting: { _ in [] }),
      storage: database.worktreeStorage!, executor: executor,
      registeredProjectRoots: database.projects().map { URL(fileURLWithPath: $0.rootPath) },
      timeoutMilliseconds: 30_000, maxOutputBytes: 1_048_576, lockTimeout: .seconds(1),
      journalIO: journalIO)
  }
}

private struct WorktreeServicePlatform: ProjectBookmarkServicing, PluginArchiveDirectoryFactory,
  GatewayToolProviderFactory
{
  func registerFolder(at url: URL, displayName: String?) throws -> ComputerMCPCore.RegisteredProject
  {
    throw WorktreeServiceTestFailure.unexpected
  }
  func resolve(_ project: ComputerMCPCore.RegisteredProject) throws -> ResolvedProjectAccess {
    throw WorktreeServiceTestFailure.unexpected
  }
  func create(at url: URL) throws -> any PluginArchiveStagingDirectory {
    throw WorktreeServiceTestFailure.unexpected
  }
  func recover(_ identity: PluginDirectoryIdentity) throws -> any PluginArchiveStagingDirectory {
    throw WorktreeServiceTestFailure.unexpected
  }
  func identity(url: URL, status: stat, descriptor: Int32) throws -> PluginDirectoryIdentity {
    throw WorktreeServiceTestFailure.unexpected
  }
  func matches(_ identity: PluginDirectoryIdentity, status: stat, descriptor: Int32) throws -> Bool
  {
    throw WorktreeServiceTestFailure.unexpected
  }
  func renameExclusively(
    from source: String, in sourceDirectory: Int32, to destination: String,
    in destinationDirectory: Int32
  ) throws { throw WorktreeServiceTestFailure.unexpected }
  func makeProviders(
    configuration: GatewayConfiguration, commandRunner: any CommandRunning,
    processManager: any ProcessManaging, shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient, hostContext: MCPHostContext
  ) -> GatewayToolRegistry {
    .init(
      providers: { [] }, downstreamPolicy: { _, _ in throw WorktreeServiceTestFailure.unexpected })
  }
}
