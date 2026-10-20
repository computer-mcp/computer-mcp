import ComputerMCPControlPlane
import ComputerMCPGateway
import ComputerMCPPlatformDarwin
import ComputerMCPProcess

package enum MacOSPlatform {
  package static var services: PlatformServices {
    PlatformServices(
      workspaceGrants: WorkspaceBookmarkService(),
      pluginDirectories: DarwinPluginArchiveDirectoryFactory(),
      applications: ApplicationBundleLookup(),
      toolProviders: MacOSToolProviders(),
      managementToolNames: GatewayRemoteManagement.toolNames,
      executableSearchDirectories: ExternalProviderDiscovery.macOSSearchDirectories,
      gitExecutable: "/usr/bin/git",
      fileChanges: { try DirectoryEventFileChangeMonitor(fileURL: $0) }
    )
  }
}
