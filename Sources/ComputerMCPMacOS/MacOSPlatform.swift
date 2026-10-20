import ComputerMCP
import ComputerMCPPlatformDarwin
import ComputerMCPProcess

package enum MacOSPlatform {
  package static var services: PlatformServices {
    PlatformServices(
      workspaceGrants: WorkspaceBookmarkService(),
      pluginDirectories: DarwinPluginArchiveDirectoryFactory(),
      applications: ApplicationBundleLookup(),
      toolProviders: MacOSToolProviders(),
      executableSearchDirectories: ExternalProviderDiscovery.macOSSearchDirectories,
      fileChanges: { try DirectoryEventFileChangeMonitor(fileURL: $0) }
    )
  }
}
