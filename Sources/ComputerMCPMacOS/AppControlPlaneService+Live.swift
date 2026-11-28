import ComputerMCPComputerUse
import ComputerMCPConfiguration
import ComputerMCPControlPlane
import ComputerMCPCore
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
    let database = try GatewayDatabase(
      path: resolvedDirectories.database.path,
      applicationSupportRoot: resolvedDirectories.applicationSupport)
    try resolvedDirectories.secureDatabaseFiles()
    let bundledPlugins = BundledPlugins.current
    var platform = MacOSPlatform.services
    platform.hostDataPaths.formUnion(resolvedDirectories.hostDataPaths)
    let counter = try KeychainAuthorizationEpochCounter(
      keychain: SecurityKeychainAdapter(accessGroup: keychainAccessGroup),
      lockDirectory: resolvedDirectories.runtime,
      service: keychainService + ".permissions", account: "authorization-epoch")
    try database.claimPermissionComposition(.app)
    _ = database.permissionStore(counter: counter)
    try activatePermissionMigration(
      directories: resolvedDirectories, database: database,
      platform: platform, bundledPlugins: bundledPlugins)
    let permissions = try MacOSPermissionServices(
      database: database, counter: counter, platform: platform,
      owner: {
        try GatewayPermissionOwner(
          context: ExecutionContext(
            caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "local-app"),
          validate: {})
      })
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
      launcher: platform.launcher,
      secretStore: secretStore, executableSearchDirectories: platform.executableSearchDirectories,
      proxyResolver: SystemNetworkProxyResolver())
    let defaultManifest = DefaultGatewayConfiguration.manifest
    if !FileManager.default.fileExists(atPath: resolvedDirectories.manifest.path) {
      _ = try manifestStore.activate(manifest: defaultManifest)
    }
    let configuration = try manifestStore.activeConfiguration()
    let profileIDs = Set(GatewayProfileID.builtIns + configuration.profiles.map(\.id))
    let initialProfiles = profileIDs.sorted { $0.rawValue < $1.rawValue }
      .map { configuration.profileGrant(for: $0) }
    try database.bootstrapPermissionProfiles(
      initialProfiles,
      declarations: configuration.profiles.map(\.grant))
    let recoveryOwner = try GatewayRecoveryOwnerService(
      database: database, platform: platform,
      owner: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "local-app"))
    return AppControlPlaneService(
      directories: resolvedDirectories,
      database: database,
      permissionControl: permissions.control,
      recoveryOwner: recoveryOwner,
      manifestStore: manifestStore,
      defaultManifest: defaultManifest,
      secretStore: secretStore,
      openAITunnelSupervisor: openAITunnelSupervisor,
      gatewayExecutablePath: gatewayExecutablePath,
      launchAtLoginController: SMAppServiceLaunchAtLoginController(),
      computerUsePermissionReader: ComputerUseService(),
      platform: platform,
      bundledPlugins: bundledPlugins
    )
  }

  package static func activatePermissionMigration(
    directories: AppControlPlaneServiceDirectories, database: GatewayDatabase,
    platform: PlatformServices, bundledPlugins: BundledPlugins
  ) throws {
    let report = try AtomicManifestStore.activatePermissionMigration(
      manifestURL: directories.manifest, database: database,
      applications: platform.applications, bundledPlugins: bundledPlugins)
    let logger = try AppFileLogger(directory: directories.logs)
    if let message = report?.startupDiagnostic {
      logger.append(.warning, event: "permissions.upgrade", fields: ["summary": message])
    }
    // Every retired checkout is reported before any provider starts.
    try database.drainPluginWorktreeRetirements { notice in
      try logger.recordPluginWorktreeRetirement(notice)
    }
  }

}
