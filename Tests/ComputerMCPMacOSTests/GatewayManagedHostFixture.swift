import ComputerMCPCore
import ComputerMCPDarwinTestSupport
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformDarwin
import ComputerMCPTestSupport
import ComputerMCPTunnels
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPGateway

struct GatewayManagedHostFixture {
  let control: AppControlPlaneService
  let service: AppGatewayService

  static func directories(root: URL) -> AppControlPlaneServiceDirectories {
    AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("app"),
      logs: root.appendingPathComponent("logs"))
  }

  init(_ fixture: FixedHostFixture, database reopenedDatabase: GatewayDatabase? = nil) async throws
  {
    try await self.init(
      root: fixture.root, configuration: fixture.configuration,
      database: reopenedDatabase ?? fixture.database, platform: fixture.platform)
  }

  init(
    root: URL, configuration: GatewayConfiguration, database: GatewayDatabase,
    platform: PlatformServices
  ) async throws {
    let directories = Self.directories(root: root)
    try directories.prepare()
    #expect(
      database.fileURL?.resolvingSymlinksInPath().path
        == directories.database.resolvingSymlinksInPath().path)
    var platform = platform
    platform.hostDataPaths.formUnion(directories.hostDataPaths)
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let permissions = try database.permissionRuntime(platform: platform)
    let owner = try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin,
        trustedPrincipalID: "worktree-acceptance-owner"), validate: {})
    let manifestStore = try AtomicManifestStore(
      manifestURL: directories.manifest, database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database, applications: platform.applications))
    if !FileManager.default.fileExists(atPath: directories.manifest.path) {
      _ = try manifestStore.activate(manifest: configuration.exportedTOML())
    }
    // AppControlPlaneService.live completes this bootstrap before accepting sessions.
    let loaded = try manifestStore.activeConfiguration()
    let ids = Set(GatewayProfileID.builtIns + loaded.profiles.map(\.id))
    try database.bootstrapPermissionProfiles(
      ids.sorted { $0.rawValue < $1.rawValue }.map { loaded.profileGrant(for: $0) },
      declarations: loaded.profiles.map(\.grant))
    control = AppControlPlaneService(
      directories: directories, database: database,
      permissionControl: PermissionControlService(service: permissions.service, owner: { owner }),
      manifestStore: manifestStore,
      defaultManifest: DefaultGatewayConfiguration.manifest, secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: platform.launcher, secretStore: secrets,
        executableSearchDirectories: platform.executableSearchDirectories,
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()),
      gatewayExecutablePath: try nativeGatewayTestExecutable().path,
      launchAtLoginController: SMAppServiceLaunchAtLoginController(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(),
      platform: platform, bundledPlugins: .init(packages: [], issues: []))
    service = AppGatewayService(
      controlPlane: control,
      socketConfiguration: .init(socketURL: root.appendingPathComponent("gateway.sock")))
  }
}
