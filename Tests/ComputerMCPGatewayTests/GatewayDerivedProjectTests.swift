import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import ComputerMCPWorktrees
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway

@Suite struct GatewayDerivedProjectTests {
  @Test(arguments: [false, true])
  func sourceRemovalRetainsDataAndCannotReattachToAReusedID(host: Bool) throws {
    let f = try DerivedAuthorityFixture()
    defer { f.remove() }
    let id: String
    if host { id = try f.create("retained").projectID } else { id = try f.plugin().project.id }
    let record = try #require(f.database.derivedProjects().first { $0.projectID == id })
    let original = try #require(try f.database.project(id: "source"))
    let originalProfiles = try f.database.profiles()
    let before = try f.database.configurationState()
    try f.database.deleteProject(id: "source")
    #expect(try f.database.project(id: id) == nil)
    #expect(try f.database.projects().isEmpty)
    let orphan = try #require(f.database.derivedProjects().first { $0.projectID == id })
    #expect(orphan.state == .sourceUnavailable)
    #expect(orphan.provenance == record.provenance)
    #expect(orphan.worktree == record.worktree)
    #expect(FileManager.default.fileExists(atPath: record.root))
    #expect(try f.database.profiles() == originalProfiles)
    #expect(try f.database.configurationState() != before)
    var replacement = original
    replacement.createdAt.addTimeInterval(1)
    try f.database.saveProject(replacement)
    #expect(try f.database.project(id: id) == nil)
    #expect(throws: (any Error).self) { _ = try f.database.derivedSourceID(for: id) }
    // A new child may use the new source registration; retained siblings stay unavailable.
    let fresh = try f.plugin(id: "fresh")
    #expect(try f.database.project(id: fresh.project.id) != nil)
    if host {
      #expect(throws: (any Error).self) { _ = try f.create("fresh-host") }
    }
    #expect(try f.database.project(id: id) == nil)
    #expect(
      try f.store.readWithDatabase { _, ledger in ledger.environment.paths?.registeredProjects.count
      } == 2)
  }

  @Test(arguments: ["content", "parent", "source"])
  func hostContentIsIdentityBoundAndSiblingAndHostDataRemainDenied(replaced: String) throws {
    let f = try DerivedAuthorityFixture()
    defer { f.remove() }
    let first = try f.create("first")
    let second = try f.create("second")
    let record = try #require(
      f.database.derivedProjects().first { $0.projectID == first.projectID })
    #expect(try f.database.derivedSourceID(for: first.projectID) == "source")
    let beforeProfiles = try f.database.profiles()
    let reader = try f.admit(
      project: first.projectID, path: first.path, profile: .chatGPTOperate, principal: "reader")
    let access = GatewayPathAccess(store: f.store, authorizationID: reader.id)
    try access.check(first.path.appendingPathComponent("value"), operation: .read)
    #expect(throws: (any Error).self) { try access.check(second.path, operation: .read) }
    #expect(throws: (any Error).self) {
      try access.check(f.host.appendingPathComponent("host.sqlite"), operation: .read)
    }
    #expect(try f.database.profiles() == beforeProfiles)
    let denied = try f.service.admit(
      subject: .init(
        context: .init(
          caller: .secureTunnel, profileID: .chatGPTObserve, trustedPrincipalID: "denied")),
      tool: "file.read", projectID: first.projectID, argumentsDigest: "read",
      requirements: try .init(
        paths: [
          .init(
            path: .init(ProjectPathResolver.canonicalProject(first.path).path), operation: .read)
        ], sandboxProjectID: "source"))
    if case .allowed = denied { Issue.record("A denied source principal acquired the worktree.") }
    let paths = try #require(f.store.readWithDatabase { _, ledger in ledger.environment.paths })
    #expect(paths.registeredProjects.first { $0.id == first.projectID }?.hostContentIdentity != nil)
    let forged = try PathEnvironmentSnapshot(
      projects: paths.registeredProjects.map { project in
        var project = project
        if project.id == "source" { project.hostContentIdentity = UUID() }
        return project
      }, rules: paths.pathRules)
    #expect(throws: GatewayDatabaseError.configurationChanged) {
      try f.service.configureEnvironment(
        forged, trustedHosts: [], expectedProjects: f.database.projects(),
        expectedConfigurationRevision: nil)
    }
    let target =
      replaced == "source"
      ? f.source : replaced == "parent" ? first.path.deletingLastPathComponent() : first.path
    let replacement = target.deletingLastPathComponent().appendingPathComponent("old")
    try FileManager.default.moveItem(at: target, to: replacement)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try access.check(first.path, operation: .read) }
    #expect(throws: (any Error).self) { try record.worktree?.verifyContent() }
  }

  @Test func currentSourceSettingsAndGrantChangesReachExistingWorktreeCalls() throws {
    let f = try DerivedAuthorityFixture()
    defer { f.remove() }
    let child = try f.create("settings")
    let admitted = try f.admit(
      project: child.projectID, path: child.path, profile: .chatGPTOperate, principal: "reader")
    var profile = try #require(f.database.profiles().first { $0.id == .chatGPTOperate })
    profile.projectNetworks["source"] = .custom(hosts: ["example.invalid"], includesTrusted: false)
    try f.database.saveProfile(profile)
    let next = try f.admit(
      project: child.projectID, path: child.path, profile: .chatGPTOperate, principal: "reader")
    try f.store.transactionWithDatabase { _, ledger in
      let projection = try ledger.prepareExecutionPermissions(next.id)
      #expect(projection.network == .custom(hosts: ["example.invalid"], includesTrusted: false))
    }
    try f.store.transactionWithDatabase { _, ledger in
      let key = SandboxSettingsKey(principal: next.invocation.principal, projectID: "source")
      try ledger.setSandboxSettings(
        .init(deniedReadLocations: [.init(ProjectPathResolver.canonicalProject(child.path).path)]),
        for: key, expectedRevision: ledger.revision)
    }
    #expect(throws: (any Error).self) {
      _ = try f.admit(
        project: child.projectID, path: child.path, profile: .chatGPTOperate, principal: "reader")
    }
    try profile.permissions.set(.denied, for: .project("source"))
    try f.database.saveProfile(profile)
    #expect(throws: (any Error).self) {
      try GatewayPathAccess(store: f.store, authorizationID: admitted.id).check(
        child.path, operation: .read)
    }
    #expect(throws: (any Error).self) {
      _ = try f.admit(
        project: child.projectID, path: child.path, profile: .chatGPTOperate, principal: "reader")
    }
  }

  @Test func activationRejectsNarrowerTrackedProjectsAndProjectsNestedLocations() throws {
    let f = try DerivedAuthorityFixture()
    defer { f.remove() }
    let inner = f.source.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
    try f.database.saveProject(.init(id: "nested", displayName: "Nested", rootPath: inner.path))
    let deniedStore = f.database.derivedProjectStore { _ in
      [.init(innerID: "nested", outerID: "source")]
    }
    #expect(throws: (any Error).self) {
      _ = try f.repository(store: deniedStore).create(name: "nested-denied")
    }
    #expect(try f.database.projects().count == 2)
    var profile = try #require(f.database.profiles().first { $0.id == .chatGPTOperate })
    try profile.permissions.set(.granted(.write), for: .project("nested"))
    try f.database.saveProfile(profile)
    let child = try f.repository(store: deniedStore).create(name: "nested-allowed")
    let location = try f.store.readWithDatabase { _, ledger in
      ledger.environment.paths?.projects.location(
        at: try .init(
          ProjectPathResolver.resolve(
            child.path.appendingPathComponent("nested/file").path,
            relativeTo: URL(fileURLWithPath: "/")
          ).path))
    }
    #expect(location?.projectID == "nested")
  }
}

private struct DerivedAuthorityFixture {
  let root: URL
  let source: URL
  let host: URL
  let database: GatewayDatabase
  let store: SQLitePermissionStore
  let service: GatewayPermissionService
  let git: DerivedFixtureGit

  init() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    root = temporary.standardizedFileURL.resolvingSymlinksInPath()
    source = root.appendingPathComponent("source")
    host = root.appendingPathComponent("host")
    for directory in [source, host] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    database = try fixturePermissionDatabase(path: host.appendingPathComponent("host.sqlite").path)
    store = try database.configuredPermissionStore()
    try database.bootstrapPermissionProfiles([])
    try database.saveProject(.init(id: "source", displayName: "Source", rootPath: source.path))
    var allow = Permissions()
    try allow.set(.granted(.write), for: .project("source"))
    var deny = Permissions()
    try deny.set(.denied, for: .project("source"))
    for (id, permissions) in [(GatewayProfileID.chatGPTOperate, allow), (.chatGPTObserve, deny)] {
      try database.saveProfile(
        .init(id: id, permissions: permissions, allowedCallers: [.secureTunnel]))
    }
    service = GatewayPermissionService(store: store, policyReader: TestManagedPolicyReader())
    try service.configureEnvironment(
      .init(
        projects: [
          .init(id: "source", root: .init(ProjectPathResolver.canonicalProject(source).path))
        ],
        rules: [
          .init(root: .init(ProjectPathResolver.canonicalProject(root).path), kind: .userData),
          .init(root: .init(ProjectPathResolver.canonicalProject(host).path), kind: .hostData),
        ]),
      trustedHosts: [], expectedProjects: database.projects(), expectedConfigurationRevision: nil)
    git = try DerivedFixtureGit()
    _ = try git.raw(["init", "--initial-branch=main"], at: source)
    _ = try git.raw(["config", "user.name", "Fixture"], at: source)
    _ = try git.raw(["config", "user.email", "fixture@example.invalid"], at: source)
    try Data("initial".utf8).write(to: source.appendingPathComponent("value"))
    _ = try git.raw(["add", "value"], at: source)
    _ = try git.raw(["commit", "-m", "Initial"], at: source)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
  func repository(store custom: (any DerivedProjectStore)? = nil) throws -> WorktreeRepository {
    let project = try #require(try database.project(id: "source"))
    return try WorktreeRepository(
      source: .init(id: project.id, root: source.path, registeredAt: project.createdAt),
      store: custom ?? database.derivedProjectStore(inspectNesting: { _ in [] }),
      storage: WorktreeStorage(databaseURL: database.fileURL)!, executor: git,
      registeredProjectRoots: database.projects().map { URL(fileURLWithPath: $0.rootPath) },
      timeoutMilliseconds: 20_000, maxOutputBytes: 1_048_576, lockTimeout: .seconds(1))
  }
  func create(_ name: String) throws -> CreatedWorktree { try repository().create(name: name) }
  func plugin(id: String = "plugin") throws -> MCPDerivedProjectRegistration {
    let child = root.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    let registration = MCPDerivedProjectRegistration(
      origin: "fixture", receiptID: "receipt", sourceProjectID: "source", sourceRoot: source.path,
      receiptDigest: "digest", profileID: .chatGPTOperate, principalID: "owner",
      caller: .secureTunnel,
      project: .init(id: id, displayName: "Plugin", rootPath: child.path))
    try database.registerDerivedProject(
      registration, verifiedPrincipalID: "owner", caller: .secureTunnel)
    return registration
  }
  func admit(project: String, path: URL, profile: GatewayProfileID, principal: String) throws
    -> InvocationAuthorization
  {
    let decision = try service.admit(
      subject: .init(
        context: .init(caller: .secureTunnel, profileID: profile, trustedPrincipalID: principal)),
      tool: "file.read", projectID: project, argumentsDigest: UUID().uuidString,
      requirements: try .init(
        paths: [
          .init(path: .init(ProjectPathResolver.canonicalProject(path).path), operation: .read)
        ], sandboxProjectID: "source"))
    guard case .allowed(let proof) = decision else {
      throw PermissionModelError.invalidAuthorization
    }
    return proof
  }
}

private struct DerivedFixtureGit: WorktreeGitExecuting {
  let executable: URL
  init() throws { executable = URL(fileURLWithPath: try testExecutable("git")) }
  func raw(_ args: [String], at directory: URL) throws -> WorktreeGitResult {
    try execute(
      .init(
        arguments: args, directory: directory,
        environment: [
          "PATH": executable.deletingLastPathComponent().path + ":/usr/bin:/bin",
          "HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        ],
        input: Data(), timeoutMilliseconds: 20_000, maxOutputBytes: 1_048_576))
  }
  func execute(_ command: WorktreeGitCommand) throws -> WorktreeGitResult {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    let input = Pipe()
    process.executableURL = executable
    process.arguments = command.arguments
    process.currentDirectoryURL = command.directory
    process.environment = command.environment
    process.standardOutput = output
    process.standardError = error
    process.standardInput = input
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: command.input)
    try input.fileHandleForWriting.close()
    let end = ContinuousClock.now.advanced(by: .milliseconds(command.timeoutMilliseconds))
    while process.isRunning, ContinuousClock.now < end { Thread.sleep(forTimeInterval: 0.002) }
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    return .init(
      output: output.fileHandleForReading.readDataToEndOfFile(),
      error: error.fileHandleForReading.readDataToEndOfFile(), exitCode: process.terminationStatus)
  }
}
