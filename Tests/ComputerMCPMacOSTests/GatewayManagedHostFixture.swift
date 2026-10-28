import ComputerMCPDarwinTestSupport
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatformDarwin
import ComputerMCPTestSupport
import ComputerMCPTunnels
import Foundation

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPGateway

struct GatewayManagedHostFixture {
  let control: AppControlPlaneService
  let service: AppGatewayService

  init(_ fixture: FixedHostFixture, database reopenedDatabase: GatewayDatabase? = nil) async throws
  {
    let database = reopenedDatabase ?? fixture.database
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: fixture.root.appendingPathComponent("app"),
      logs: fixture.root.appendingPathComponent("logs"))
    try directories.prepare()
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let permissions = try database.permissionRuntime(platform: fixture.platform)
    let owner = try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin,
        trustedPrincipalID: "worktree-acceptance-owner"), validate: {})
    control = AppControlPlaneService(
      directories: directories, database: database,
      permissionControl: PermissionControlService(service: permissions.service, owner: { owner }),
      manifestStore: try AtomicManifestStore(
        manifestURL: directories.manifest, database: database,
        loader: GatewayManifestConfigurationLoader(
          database: database, applications: fixture.platform.applications)),
      defaultManifest: DefaultGatewayConfiguration.manifest, secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: fixture.platform.launcher, secretStore: secrets,
        executableSearchDirectories: fixture.platform.executableSearchDirectories,
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()),
      gatewayExecutablePath: try nativeGatewayTestExecutable().path,
      launchAtLoginController: SMAppServiceLaunchAtLoginController(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(),
      platform: fixture.platform, bundledPlugins: .init(packages: [], issues: []))
    service = AppGatewayService(
      controlPlane: control,
      socketConfiguration: .init(socketURL: fixture.root.appendingPathComponent("gateway.sock")))
    if !FileManager.default.fileExists(atPath: directories.manifest.path) {
      _ = try await control.activateManifest(
        fixture.configuration.exportedTOML(), expectedDigest: nil)
    }
  }
}
