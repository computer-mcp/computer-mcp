import ComputerMCPConfiguration
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

@Suite struct GatewayEnvironmentPublicationTests {
  @Test(arguments: [true, false])
  func stalePluginPublicationPreservesLiveProviderAuthority(revokeSourceGrant: Bool) throws {
    let root = try environmentFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let store = try database.configuredPermissionStore()
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    let project = ComputerMCPCore.RegisteredProject(
      id: "source", displayName: "Source", rootPath: source.path)
    try database.saveProject(project)
    let projectRoot = try CanonicalPath(ProjectPathResolver.canonicalProject(source).path)
    let service = GatewayPermissionService(store: store, policyReader: TestManagedPolicyReader())
    let registered = try database.projects()
    let projects = [ComputerMCPPermissions.RegisteredProject(id: project.id, root: projectRoot)]
    let platform: Set<PathRule> = [
      .init(root: try .init(root.appendingPathComponent("user").path), kind: .userData),
      .init(root: try .init(root.appendingPathComponent("host").path), kind: .hostData),
    ]
    let skill = PathRule(
      root: try .init(root.appendingPathComponent("plugin/skills").path), kind: .skillLibrary)
    var plugins = try database.pluginStoreSnapshot()
    plugins.revision += 1
    _ = try database.savePluginStoreSnapshot(plugins, expectedRevision: 0)
    try service.configureEnvironment(
      .init(projects: projects, rules: platform.union([skill])), trustedHosts: [],
      expectedProjects: registered, expectedConfigurationRevision: nil,
      expectedPluginRevision: plugins.revision, platformRules: platform, configurationRules: [skill]
    )
    let principal = Principal.plugin(.package("provider"))
    let execution = try store.transactionWithDatabase { _, ledger in
      try ledger.setPermission(
        .granted(.read), for: .project(project.id), principal: principal,
        expectedRevision: ledger.revision)
      let decision = try ledger.authorize(
        invocation: .init(
          principal: principal, tool: "read", projectID: project.id, argumentsDigest: "source"),
        requirements: .init(
          paths: [.init(path: projectRoot, operation: .read)], sandboxProjectID: project.id),
        now: Date())
      guard case .allowed(let proof) = decision else {
        Issue.record("Provider admission failed: \(decision)")
        throw PermissionModelError.invalidAuthorization
      }
      let projection = try ledger.prepareExecutionPermissions(proof.id)
      #expect(
        projection.readablePaths.contains { $0.excludedSubtrees?.contains(skill.root) == true })
      return try ledger.startExecution(owner: principal, authorizationIDs: [proof.id])
    }
    #expect(throws: GatewayDatabaseError.configurationChanged) {
      try service.configureEnvironment(
        .init(projects: projects, rules: platform), trustedHosts: [],
        expectedProjects: registered, expectedConfigurationRevision: nil,
        expectedPluginRevision: 0, platformRules: platform, configurationRules: [])
    }
    try store.transactionWithDatabase { sql, ledger in
      #expect(
        try GatewayConfigurationPaths.read(
          GatewayConfigurationPaths.configurationKey, database: sql) == [skill])
      #expect(
        ledger.executionAccess(
          execution.id, principal: principal, operation: .writeInput, now: Date())
          == .allowed)
      let result: RevocationResult
      if revokeSourceGrant {
        result = try ledger.revoke(
          principal: principal, permission: .project(project.id), expectedRevision: ledger.revision)
      } else {
        var environment = ledger.environment
        environment.limits[principal] = .init(sources: [
          .owner: .available(ManagedPolicy(deniedReadLocations: [projectRoot]))
        ])
        result = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      }
      #expect(result.executionsToTerminate == [execution.id])
      #expect(ledger.executions[execution.id]?.revoked == true)
    }
  }

  @Test func currentProjectSetExcludesRetainedAliasRowsAfterOwnerDeduplication() throws {
    let root = try environmentFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let store = try database.configuredPermissionStore()
    try database.bootstrapPermissionProfiles([])
    let project = ComputerMCPCore.RegisteredProject(
      id: "canonical", displayName: "Project", rootPath: root.path,
      createdAt: Date(timeIntervalSince1970: 1000))
    try database.saveProject(project)
    let service = GatewayPermissionService(store: store, policyReader: TestManagedPolicyReader())
    let paths = try PathEnvironmentSnapshot(projects: [
      .init(id: project.id, root: .init(root.path))
    ])
    try service.configureEnvironment(
      paths, trustedHosts: [], expectedProjects: database.projects(),
      expectedConfigurationRevision: nil)
    var duplicate = project
    duplicate.id = "historical-alias"
    duplicate.createdAt.addTimeInterval(1)
    #expect(throws: PermissionModelError.invalidProjectGraph) {
      try database.saveProject(duplicate)
    }
    // Owner recovery can receive historical rows without first publishing them as authority.
    try database.connection.writer.write { try ProjectRecord(duplicate).insert($0) }
    _ = try database.applyProjectDeduplication(
      expectedPlanDigest: database.projectDeduplicationPlan().planDigest,
      allowMetadataConflicts: false)
    #expect(try database.connection.writer.read { try ProjectRecord.fetchCount($0) } == 2)
    #expect(try database.projects().map(\.id) == [project.id])
    #expect(try database.project(id: duplicate.id)?.id == project.id)
    try service.configureEnvironment(
      paths, trustedHosts: [], expectedProjects: database.projects(),
      expectedConfigurationRevision: nil)
    try store.readWithDatabase { _, ledger in
      #expect(ledger.environment.paths?.registeredProjects.map(\.id) == [project.id])
    }
  }

  @Test func currentDerivedSourcesAndMissingSavedLeavesRemainRecoverable() throws {
    let root = try environmentFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let child = root.appendingPathComponent("child")
    for directory in [source, child] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    let database = try GatewayDatabase(inMemory: ())
    let store = try database.configuredPermissionStore()
    try database.bootstrapPermissionProfiles([])
    try database.saveProject(.init(id: "source", displayName: "Source", rootPath: source.path))
    var permissions = Permissions()
    try permissions.set(.granted(.write), for: .project("source"))
    try database.saveProfile(
      .init(id: .chatGPTOperate, permissions: permissions, allowedCallers: [.secureTunnel]))
    let service = GatewayPermissionService(store: store, policyReader: TestManagedPolicyReader())
    let sourcePaths = try PathEnvironmentSnapshot(projects: [
      .init(id: "source", root: .init(source.path))
    ])
    try service.configureEnvironment(
      sourcePaths, trustedHosts: [], expectedProjects: database.projects(),
      expectedConfigurationRevision: nil)
    let sourceProject = try #require(try database.project(id: "source"))
    try database.connection.writer.write { sql in
      let project = ComputerMCPCore.RegisteredProject(
        id: "child", displayName: "Child", rootPath: child.path)
      try ProjectRecord(project).insert(sql)
      try ProjectCanonicalRootRecord(
        canonicalRootPath: child.path, projectID: "child", createdAt: project.createdAt
      ).insert(sql)
      // A removal in progress keeps derived authority without worktree content. The
      // record's root is the registered project's root, as the lifecycle writes both.
      try SQLiteDerivedProjectStore.commit(
        .init(
          projectID: "child",
          source: .init(
            id: "source", root: GatewayDatabase.canonicalProjectRoot(sourceProject.rootPath),
            registeredAt: sourceProject.createdAt),
          root: project.rootPath,
          provenance: .host(worktreeID: UUID(), storageGeneration: UUID()), state: .removing),
        expecting: nil, in: sql)
    }
    let paths = try PathEnvironmentSnapshot(
      projects: sourcePaths.registeredProjects + [
        .init(id: "child", root: .init(child.path), sourceID: "source")
      ])
    try service.configureEnvironment(
      paths, trustedHosts: [], expectedProjects: database.projects(),
      expectedConfigurationRevision: nil)
    let before = try store.readWithDatabase { _, ledger in ledger }
    let wrongSource = try PathEnvironmentSnapshot(
      projects: sourcePaths.registeredProjects + [
        .init(id: "child", root: .init(child.path))
      ])
    #expect(throws: GatewayDatabaseError.configurationChanged) {
      try service.configureEnvironment(
        wrongSource, trustedHosts: [], expectedProjects: database.projects(),
        expectedConfigurationRevision: nil)
    }
    #expect(try store.readWithDatabase { _, ledger in ledger } == before)
    try FileManager.default.removeItem(at: child)
    try service.configureEnvironment(
      paths, trustedHosts: [], expectedProjects: database.projects(),
      expectedConfigurationRevision: nil)
    let missing = try store.readWithDatabase { _, ledger in ledger }
    let replacement = root.appendingPathComponent("replacement")
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: child, withDestinationURL: replacement)
    #expect(throws: GatewayDatabaseError.configurationChanged) {
      try service.configureEnvironment(
        paths, trustedHosts: [], expectedProjects: database.projects(),
        expectedConfigurationRevision: nil)
    }
    #expect(try store.readWithDatabase { _, ledger in ledger } == missing)
    try FileManager.default.removeItem(at: child)
    try database.derivedProjectStore(inspectNesting: { _ in [] }).remove("child", expecting: 1)
    #expect(try database.project(id: "child") == nil)
    #expect(try database.profiles().first?.permissions.entries[.project("child")] == nil)
  }

  @Test func unchangedCapturedPathsDoNotAdvanceTheAuthorityCounter() throws {
    var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    root = try ProjectPathResolver.canonicalProject(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try GatewayDatabase(inMemory: ())
    let counter = TestAuthorizationEpochCounter()
    let store = database.permissionStore(counter: counter)
    try database.bootstrapPermissionProfiles([.localAdmin])
    let service = GatewayPermissionService(store: store, policyReader: TestManagedPolicyReader())
    var configuration = GatewayConfiguration()
    configuration.hostDataPaths = [root.appendingPathComponent("manifest.toml")]
    let platform: Set<PathRule> = [.init(root: try .init(root.path), kind: .userData)]
    func configure() throws {
      let source = try GatewayConfigurationPaths.capture(configuration)
      try service.configureEnvironment(
        .init(rules: platform.union(source)), trustedHosts: [],
        expectedProjects: [], expectedConfigurationRevision: nil,
        platformRules: platform, configurationRules: source)
    }
    try configure()
    let before = try counter.withExclusiveAccess { try $0.read() }
    for _ in 0..<3 { try configure() }
    #expect(try counter.withExclusiveAccess { try $0.read() } == before)
    var profile = ProfileGrant.localAdmin
    try profile.permissions.set(.denied, for: .screen)
    try database.saveProfile(profile)
    #expect(try counter.withExclusiveAccess { try $0.read() } != before)
  }

  @Test(arguments: ["removed", "root", "extra"])
  func capturedPathsCannotRestoreAChangedProject(change: String) throws {
    var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    root = try ProjectPathResolver.canonicalProject(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let originalRoot = root.appendingPathComponent("project")
    let repairedRoot = root.appendingPathComponent("repaired")
    try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: repairedRoot, withIntermediateDirectories: false)
    let database = try GatewayDatabase(inMemory: ())
    let store = try database.configuredPermissionStore()
    let service = GatewayPermissionService(store: store, policyReader: TestManagedPolicyReader())
    let project = ComputerMCPCore.RegisteredProject(
      id: "P", displayName: "Project", rootPath: originalRoot.path)
    try database.saveProject(project)
    let paths = try PathEnvironmentSnapshot(projects: [
      .init(id: "P", root: .init(originalRoot.path))
    ])
    try service.configureEnvironment(
      paths, trustedHosts: [], expectedProjects: try database.projects(),
      expectedConfigurationRevision: nil)
    if change == "root" {
      var repaired = project
      repaired.rootPath = repairedRoot.path
      try database.saveProject(repaired)
    } else {
      try database.removeProject(id: "P", expectedConfiguration: database.configurationState())
    }
    let current = try database.projects()
    let proposed =
      change == "extra"
      ? try PathEnvironmentSnapshot(
        projects: paths.registeredProjects + [.init(id: "extra", root: .init("/private/tmp/extra"))]
      ) : paths
    #expect(throws: GatewayDatabaseError.configurationChanged) {
      try service.configureEnvironment(
        proposed, trustedHosts: [], expectedProjects: current, expectedConfigurationRevision: nil)
    }
    try store.readWithDatabase { _, ledger in
      let live = ledger.environment.paths?.registeredProjects ?? []
      #expect(live.count == current.count)
      #expect(!live.contains { $0.id == "P" && $0.root.string == originalRoot.path })
    }
  }
}

private func environmentFixtureDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return try ProjectPathResolver.canonicalProject(directory)
}
