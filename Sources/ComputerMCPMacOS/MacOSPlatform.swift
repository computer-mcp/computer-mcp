import ComputerMCPControlPlane
import ComputerMCPGateway
import ComputerMCPPlatformDarwin
import ComputerMCPProcess

package enum MacOSPlatform {
  package static var services: PlatformServices {
    services(launcher: ExecutionLauncher(platform: DarwinExecutionPlatform()))
  }

  package static func services(launcher: ExecutionLauncher) -> PlatformServices {
    PlatformServices(
      launcher: launcher,
      projectGrants: ProjectBookmarkService(),
      pluginDirectories: DarwinPluginArchiveDirectoryFactory(),
      applications: ApplicationBundleLookup(),
      toolProviders: MacOSToolProviders(launcher: launcher),
      managementToolNames: GatewayRemoteManagement.toolNames,
      executableSearchDirectories: ExternalProviderDiscovery.macOSSearchDirectories,
      gitExecutable: "/usr/bin/git",
      fileChanges: { try DirectoryEventFileChangeMonitor(fileURL: $0) }
    )
  }
}
