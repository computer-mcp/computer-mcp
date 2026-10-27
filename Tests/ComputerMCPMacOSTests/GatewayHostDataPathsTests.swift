import ComputerMCPConfiguration
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import Foundation
import Testing

@Suite(.serialized)
struct GatewayHostDataPathsTests {
  @Test func appStorageProtectsAllOwnedRootsIncludingCustomizedLocations() {
    var directories = AppControlPlaneServiceDirectories(
      applicationSupport: URL(fileURLWithPath: "/owned/support"),
      logs: URL(fileURLWithPath: "/owned/logs"))
    directories.configuration = URL(fileURLWithPath: "/custom/configuration")
    directories.tunnelClientProfiles = URL(fileURLWithPath: "/custom/tunnel-profiles")
    directories.runtime = URL(fileURLWithPath: "/custom/runtime")
    #expect(
      directories.hostDataPaths.isSuperset(of: [
        directories.applicationSupport, directories.configuration, directories.logs,
        directories.plugins, directories.tunnelClientProfiles, directories.runtime,
        directories.database, directories.manifest,
      ]))
    #expect(!directories.hostDataPaths.contains(URL(fileURLWithPath: "/owned")))
    #expect(!directories.hostDataPaths.contains(FileManager.default.homeDirectoryForCurrentUser))
  }

  @Test func manifestActivationImmediatelyRevokesPathsAndPreservesIndependentPlatformProtection()
    throws
  {
    var root = FileManager.default.temporaryDirectory
      .appendingPathComponent("host-path-publication-" + UUID().uuidString, isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    root = try ProjectPathResolver.canonicalProject(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let protected = root.appendingPathComponent("new-tunnel-state", isDirectory: true)
    let platformOwned = root.appendingPathComponent("platform-state", isDirectory: true)
    for directory in [protected, platformOwned] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let file = protected.appendingPathComponent("credential")
    let platformFile = platformOwned.appendingPathComponent("credential")
    for target in [file, platformFile] { try Data("fixture".utf8).write(to: target) }
    let database = try GatewayDatabase(inMemory: ())
    let store = database.permissionStore(counter: TestAuthorizationEpochCounter())
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: root.path)
    try database.saveProject(project)
    let profile = ProfileGrant(
      id: .chatGPTOperate,
      permissions: fixturePermissions([.project("fixture"): .granted(.read)]),
      allowedCallers: [.localMCP])
    try database.bootstrapPermissionProfiles([profile], declarations: [])
    let authority = GatewayPermissionService(store: store, policyReader: TestManagedPolicyReader())
    let platformRule = PathRule(root: try CanonicalPath(platformOwned.path), kind: .hostData)
    let paths = try PathEnvironmentSnapshot(
      projects: [.init(id: project.id, root: CanonicalPath(root.path))], rules: [platformRule])
    try authority.configureEnvironment(
      paths, trustedHosts: [], expectedProjects: try database.projects(),
      expectedConfigurationRevision: nil,
      platformRules: [platformRule], configurationRules: [])
    let manifest = root.appendingPathComponent("Configuration/computer-mcp.toml")
    let manifests = try AtomicManifestStore(
      manifestURL: manifest, database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database, applications: fixtureHostedPlatform().applications))
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: profile.id),
      builtin: .init(enabled: []), projectDirectory: root)
    let initial = try manifests.activate(manifest: configuration.exportedTOML())
    let subject = try GatewayPermissionSubject(
      context: .init(
        caller: .localMCP, profileID: profile.id, trustedPrincipalID: "fixture-client"))
    let requirements = InvocationRequirements(
      paths: [.init(path: try CanonicalPath(file.path), operation: .read)],
      sandboxProjectID: project.id, execution: .background)
    guard
      case .allowed(let authorization) = try authority.admit(
        subject: subject, tool: "file.read", projectID: project.id, argumentsDigest: "fixture",
        requirements: requirements)
    else {
      Issue.record("The ordinary project file was not initially readable")
      return
    }
    let execution = try store.transactionWithDatabase { _, ledger in
      try ledger.startExecution(owner: subject.principal, authorizationIDs: [authorization.id])
    }
    let checker = GatewayPathAccess(store: store, authorizationID: authorization.id)
    try checker.check(file, operation: .read)
    configuration.transports.openAI = [
      .init(
        id: "new-state", tunnelClientProfile: "fixture", tunnelID: "one",
        profileDirectory: protected.path),
      .init(
        id: "overlap", tunnelClientProfile: "fixture", tunnelID: "two",
        profileDirectory: platformOwned.path),
    ]
    let changed = try manifests.activate(
      manifest: configuration.exportedTOML(), expectedDigest: initial.digest)
    #expect(throws: (any Error).self) { try checker.check(file, operation: .read) }
    #expect(
      try store.readWithDatabase { _, ledger in
        ledger.pendingRevocations.executionsToTerminate.contains(execution.id)
      })
    configuration.transports.openAI = []
    _ = try manifests.activate(
      manifest: configuration.exportedTOML(), expectedDigest: changed.digest)
    #expect(throws: (any Error).self) { try checker.check(file, operation: .read) }
    guard
      case .allowed = try authority.admit(
        subject: subject, tool: "file.read", projectID: project.id, argumentsDigest: "new-call",
        requirements: requirements)
    else {
      Issue.record("Removing the configuration source did not restore ordinary project access")
      return
    }
    #expect(
      try authority.admit(
        subject: subject, tool: "file.read", projectID: project.id,
        argumentsDigest: "platform-call",
        requirements: .init(
          paths: [.init(path: CanonicalPath(platformFile.path), operation: .read)],
          sandboxProjectID: project.id)) == .denied(.hostData))
  }

  @Test func configuredTunnelDirectoriesAreCanonicalHostDataAndRevokeRetainedReads() async throws {
    var root = FileManager.default.temporaryDirectory
      .appendingPathComponent("host-data-paths-" + UUID().uuidString, isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    root = try ProjectPathResolver.canonicalProject(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let protected = root.appendingPathComponent("tunnel-state", isDirectory: true)
    let unrelated = root.appendingPathComponent("user-project", isDirectory: true)
    for directory in [protected, unrelated] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let alias = root.appendingPathComponent("profile-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protected)
    let file = protected.appendingPathComponent("credentials.json")
    try Data("fixture secret".utf8).write(to: file)
    let database = try GatewayDatabase(inMemory: ())
    let store = database.permissionStore(counter: TestAuthorizationEpochCounter())
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: root.path)
    try database.saveProject(project)
    let profile = ProfileGrant(
      id: .chatGPTOperate,
      permissions: fixturePermissions([.project("fixture"): .granted(.write)]),
      allowedCallers: [.localMCP])
    try database.saveProfile(profile)
    var platform = fixtureHostedPlatform()
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let authority = try database.permissionRuntime(platform: platform)
    try await authority.ready()
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .chatGPTOperate),
      profiles: [.init(grant: profile)], builtin: .init(enabled: []), projectDirectory: root)
    let context = ExecutionContext(
      caller: .localMCP, profileID: .chatGPTOperate, trustedPrincipalID: "fixture-client")
    let first = try GatewayRuntime(
      configuration: configuration, context: context, database: database,
      registeredProjects: [project], platform: platform)
    _ = try await first.callToolForMCPAsync(name: "project.list", arguments: nil, context: .empty)
    let subject = try GatewayPermissionSubject(context: context)
    let requirements = InvocationRequirements(
      paths: [.init(path: try CanonicalPath(file.path), operation: .read)],
      sandboxProjectID: "fixture")
    guard
      case .allowed(let authorization) = try authority.service.admit(
        subject: subject, tool: "file.read", projectID: "fixture", argumentsDigest: "fixture",
        requirements: requirements)
    else {
      await first.shutdown()
      Issue.record("The ordinary project file was not initially readable")
      return
    }
    let checker = GatewayPathAccess(store: store, authorizationID: authorization.id)
    try checker.check(file, operation: .read)
    configuration.transports.openAI = [
      .init(
        id: "configured", tunnelClientProfile: "fixture", tunnelID: "fixture",
        profileDirectory: alias.path)
    ]
    let second = try GatewayRuntime(
      configuration: configuration, context: context, database: database,
      registeredProjects: [project], platform: platform)
    do {
      _ = try await second.callToolAsync(name: "project.list", arguments: nil, context: .empty)
      let paths = try #require(try store.readWithDatabase { _, ledger in ledger.environment.paths })
      #expect(paths.pathRules.contains { $0.kind == .hostData && $0.root.string == protected.path })
      let executionRoot = try CanonicalPath(
        ProjectPathResolver.resolve(
          database.permissionExecutionRoot.path, relativeTo: URL(fileURLWithPath: "/")
        ).path)
      #expect(
        paths.pathRules.contains { $0.kind == .hostData && $0.root == executionRoot })
      #expect(database.permissionExecutionRoot != database.mcpProcessOwnershipRoot)
      #expect(
        try authority.service.admit(
          subject: subject, tool: "file.read", projectID: "fixture",
          argumentsDigest: "execution-storage",
          requirements: .init(
            paths: [
              .init(path: CanonicalPath(executionRoot.string + "/private-state"), operation: .read)
            ],
            sandboxProjectID: "fixture")) == .denied(.hostData))
      #expect(
        !paths.pathRules.contains { $0.kind == .hostData && $0.root.string == unrelated.path })
      #expect(throws: (any Error).self) { try checker.check(file, operation: .read) }
      #expect(
        try authority.service.admit(
          subject: subject, tool: "file.read", projectID: "fixture", argumentsDigest: "fixture",
          requirements: requirements) == .denied(.hostData))
      await first.shutdown()
      await second.shutdown()
    } catch {
      await first.shutdown()
      await second.shutdown()
      throw error
    }
  }
}
