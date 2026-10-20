import ComputerMCP
import ComputerMCPPlatformDarwin
import ComputerMCPProcess

package enum MacOSPlatform {
  package static var services: PlatformServices {
    PlatformServices(
      workspaceGrants: WorkspaceBookmarkService(),
      toolProviders: MacOSToolProviders(),
      executableSearchDirectories: ExternalProviderDiscovery.macOSSearchDirectories,
      fileChanges: { try DirectoryEventFileChangeMonitor(fileURL: $0) }
    )
  }
}
