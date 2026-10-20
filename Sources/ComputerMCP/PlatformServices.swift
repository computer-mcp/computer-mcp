import ComputerMCPPlatform
import Foundation

/// Platform implementations selected by the host for gateway and control-plane composition.
package struct PlatformServices: Sendable {
  package let pluginDirectories: any PluginArchiveDirectoryFactory
  package let applications: any ApplicationBundleLocating
  package let workspaceGrants: any WorkspaceBookmarkServicing
  package let toolProviders: any GatewayToolProviderFactory
  package let executableSearchDirectories: [String]
  package let gitExecutable: String
  package let fileChanges: @Sendable (URL) throws -> any FileChangeMonitor

  package init(
    workspaceGrants: any WorkspaceBookmarkServicing,
    pluginDirectories: any PluginArchiveDirectoryFactory,
    applications: any ApplicationBundleLocating,
    toolProviders: any GatewayToolProviderFactory,
    executableSearchDirectories: [String],
    gitExecutable: String,
    fileChanges: @escaping @Sendable (URL) throws -> any FileChangeMonitor
  ) {
    self.workspaceGrants = workspaceGrants
    self.pluginDirectories = pluginDirectories
    self.applications = applications
    self.toolProviders = toolProviders
    self.executableSearchDirectories = executableSearchDirectories
    self.gitExecutable = gitExecutable
    self.fileChanges = fileChanges
  }
}
