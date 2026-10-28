import ComputerMCPConfiguration
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatform
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
