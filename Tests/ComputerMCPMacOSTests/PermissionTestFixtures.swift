import ComputerMCPConfiguration
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlugins
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPWorktrees
import Foundation
import Testing

@testable import ComputerMCPGateway

func fixturePermissions(_ entries: [Permission: PermissionState]) -> Permissions {
  var permissions = Permissions()
  for (permission, state) in entries { try! permissions.set(state, for: permission) }
  return permissions
}

@discardableResult
func fixtureApproveLocalProvider(
  _ server: MCPServerConfig, database: GatewayDatabase,
  runtime: GatewayPermissionRuntime, permissions: Permissions, fullAccess: Bool
) throws -> GatewayProviderReview {
  let owner = try GatewayPermissionOwner(
    context: .init(
      caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "provider-fixture-owner"),
    validate: {})
  let review = try GatewayProviderReview(
    server: server, configuration: database.configurationState())
  let view = try runtime.service.view(owner: owner)
  let previous = view.providers.first { $0.identity == review.identity }
  let consentIsCurrent = try runtime.store.readWithDatabase { _, ledger in
    previous?.fullAccessConsent.map { ledger.isConsentValid($0, for: .plugin(review.identity)) }
      ?? !fullAccess
  }
  if previous?.enabled != true || previous?.sourceDigest != review.sourceDigest || !consentIsCurrent
  {
    _ = try runtime.service.approveProvider(
      review, permissions: permissions, fullAccess: fullAccess, owner: owner,
      expectedProviderRevision: previous?.revision, expectedRevision: view.revision,
      expectedEpoch: #require(view.epoch))
  }
  _ = try database.prepareProviderContainer(review.identity)
  return try GatewayProviderReview(server: server, configuration: database.configurationState())
}

func fixtureApprovePlugin(
  _ package: PluginPackage, database: GatewayDatabase, runtime: GatewayPermissionRuntime,
  permissions: Permissions, fullAccess: Bool = false
) throws {
  let owner = try GatewayPermissionOwner(
    context: .init(
      caller: .localApp, profileID: .localAdmin,
      trustedPrincipalID: "plugin-fixture-owner"), validate: {})
  let view = try runtime.service.view(owner: owner)
  let review = try GatewayProviderReview(
    package: package, configuration: database.configurationState())
  _ = try runtime.service.approveProvider(
    review, permissions: permissions, fullAccess: fullAccess,
    owner: owner,
    expectedProviderRevision: view.providers.first { $0.identity == review.identity }?.revision,
    expectedRevision: view.revision, expectedEpoch: #require(view.epoch))
  _ = try database.prepareProviderContainer(review.identity)
}

func fixtureConsentedContext(
  database: GatewayDatabase, grant: ProfileGrant, caller: GatewayCallerKind,
  principalID: String = "verified-fixture", projectID: String? = nil,
  transportTrace: GatewayTransportTrace? = nil,
  platform: PlatformServices = MacOSPlatform.services(launcher: testExecutionLauncher())
) throws -> ExecutionContext {
  let session = GatewayControlSession(
    principalID: principalID, profileID: grant.id,
    caller: caller, database: database,
    profile: GatewayControlProfile(grant: grant, persisted: true),
    permissionService: try database.permissionRuntime(platform: platform).service)
  _ = try session.approveFullAccess(expectedRevision: session.revision)
  var context = ExecutionContext(
    caller: caller, profileID: grant.id, projectID: projectID,
    transportTrace: transportTrace, trustedPrincipalID: principalID)
  context.controlSession = session
  return context
}

func fixturePermissionDatabase(path: String) throws -> GatewayDatabase {
  let database = try GatewayDatabase(path: path)
  _ = database.permissionStore(counter: TestAuthorizationEpochCounter.shared(forDatabasePath: path))
  return database
}

func fixturePermissionControl(
  database: GatewayDatabase, configuration: GatewayConfiguration = .init(),
  platform: PlatformServices = MacOSPlatform.services(launcher: testExecutionLauncher())
) throws -> PermissionControlService {
  let ids = Set(GatewayProfileID.builtIns + configuration.profiles.map { $0.grant.id })
  try database.bootstrapPermissionProfiles(ids.map { configuration.profileGrant(for: $0) })
  let runtime = try database.permissionRuntime(platform: platform)
  let owner = try GatewayPermissionOwner(
    context: .init(
      caller: .localApp, profileID: .localAdmin,
      trustedPrincipalID: "fixture-owner"), validate: {})
  return PermissionControlService(service: runtime.service, owner: { owner })
}

/// Runs only the non-repository Git-layout probe; the host performs actual file writes.
func fixtureNonGitProject(root: URL) throws -> (platform: PlatformServices, git: CLICommandConfig) {
  let root = try ProjectPathResolver.canonicalProject(root)
  var platform = MacOSPlatform.services(launcher: testExecutionLauncher())
  platform.permissionPolicyReader = TestManagedPolicyReader()
  return (
    platform,
    CLICommandConfig(
      id: "git", executable: platform.gitExecutable, cwd: root.path, allowAnyArgs: false)
  )
}

func fixturePlatformWithGit(_ platform: PlatformServices, executable: String) -> PlatformServices {
  PlatformServices(
    launcher: platform.launcher, projectGrants: platform.projectGrants,
    pluginDirectories: platform.pluginDirectories, applications: platform.applications,
    toolProviders: platform.toolProviders, managementToolNames: platform.managementToolNames,
    executableSearchDirectories: platform.executableSearchDirectories, gitExecutable: executable,
    fileChanges: platform.fileChanges, permissionPolicyReader: platform.permissionPolicyReader,
    executionProxy: platform.executionProxy, hostDataPaths: platform.hostDataPaths)
}

func fixtureHostedPlatform() -> PlatformServices {
  MacOSPlatform.services(launcher: ExecutionLauncher(platform: HostedProviderExecutionPlatform()))
}

/// In-memory providers are already hosted. Any subprocess would leave this fixture's authority.
private struct HostedProviderExecutionPlatform: ExecutionPlatform {
  var supportsRecovery: Bool { true }
  var bootSessionID: String? { "hosted-provider-fixture" }
  func supportsDurableOwnership(sandboxed: Bool) -> Bool { true }
  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    Issue.record("An in-memory provider attempted to start \(command.executable).")
    throw ExecutionEnvironmentError.unavailable("Hosted provider fixtures cannot start programs")
  }
}

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

/// A host-derived child whose removal is in progress. It carries derived authority
/// without worktree content, so routing and publication tests need no Git fixture.
func fixtureRemovingDerivedProject(
  database: GatewayDatabase, id: String, sourceID: String, root: URL, displayName: String
) throws {
  let source = try #require(try database.project(id: sourceID))
  try database.connection.writer.write { sql in
    let project = ComputerMCPCore.RegisteredProject(
      id: id, displayName: displayName, rootPath: root.path)
    try ProjectRecord(project).insert(sql)
    try ProjectCanonicalRootRecord(
      canonicalRootPath: root.path, projectID: id, createdAt: project.createdAt
    ).insert(sql)
    try SQLiteDerivedProjectStore.commit(
      .init(
        projectID: id,
        source: .init(
          id: sourceID, root: GatewayDatabase.canonicalProjectRoot(source.rootPath),
          registeredAt: source.createdAt),
        // The record's root is the registered project's root, as the lifecycle writes both.
        root: project.rootPath, provenance: .host(worktreeID: UUID(), storageGeneration: UUID()),
        state: .removing),
      expecting: nil, in: sql)
  }
}
