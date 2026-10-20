import ComputerMCP
import ComputerMCPComputerUse
import ComputerMCPGateway
import ComputerMCPPersistence
import ComputerMCPPlatformDarwin
import ComputerMCPPlugins
import ComputerMCPTunnels
import Foundation

extension AppControlPlaneService {
  package static func live(
    directories: AppControlPlaneServiceDirectories? = nil,
    gatewayExecutablePath: String = "computer-mcp",
    keychainService: String,
    keychainAccessGroup: String
  ) throws -> AppControlPlaneService {
    let resolvedDirectories = try directories ?? .standard(environment: .production)
    try resolvedDirectories.prepare()
    let database = try GatewayDatabase(path: resolvedDirectories.database.path)
    try resolvedDirectories.secureDatabaseFiles()
    let bundledPlugins = BundledPlugins.current
    let platform = MacOSPlatform.services
    let manifestStore = try AtomicManifestStore(
      manifestURL: resolvedDirectories.manifest,
      database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database, bundledPlugins: bundledPlugins, applications: platform.applications)
    )
    let secretStore = try KeychainSecretStore(
      service: keychainService,
      accessGroup: keychainAccessGroup
    )
    let openAITunnelSupervisor = OpenAITunnelSupervisor(
      secretStore: secretStore, executableSearchDirectories: platform.executableSearchDirectories,
      proxyResolver: SystemNetworkProxyResolver())
    if !FileManager.default.fileExists(atPath: resolvedDirectories.manifest.path) {
      _ = try manifestStore.activate(manifest: defaultManifest)
    }
    return AppControlPlaneService(
      directories: resolvedDirectories,
      database: database,
      manifestStore: manifestStore,
      secretStore: secretStore,
      openAITunnelSupervisor: openAITunnelSupervisor,
      gatewayExecutablePath: gatewayExecutablePath,
      launchAtLoginController: SMAppServiceLaunchAtLoginController(),
      computerUsePermissionReader: ComputerUseService(),
      platform: platform,
      bundledPlugins: bundledPlugins
    )
  }
}
