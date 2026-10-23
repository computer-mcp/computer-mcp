import ComputerMCPPlatform
import Foundation

/// Platform implementations selected by the host for gateway and control-plane composition.
package struct PlatformServices: Sendable {
  package let pluginDirectories: any PluginArchiveDirectoryFactory
  package let applications: any ApplicationBundleLocating
  package let projectGrants: any ProjectBookmarkServicing
  package let toolProviders: any GatewayToolProviderFactory
  /// Reserved even when a generation has no management provider.
  package let managementToolNames: Set<String>
  package let executableSearchDirectories: [String]
  package let gitExecutable: String
  package let fileChanges: @Sendable (URL) throws -> any FileChangeMonitor

  package init(
    projectGrants: any ProjectBookmarkServicing,
    pluginDirectories: any PluginArchiveDirectoryFactory,
    applications: any ApplicationBundleLocating,
    toolProviders: any GatewayToolProviderFactory,
    managementToolNames: Set<String>,
    executableSearchDirectories: [String],
    gitExecutable: String,
    fileChanges: @escaping @Sendable (URL) throws -> any FileChangeMonitor
  ) {
    self.projectGrants = projectGrants
    self.pluginDirectories = pluginDirectories
    self.applications = applications
    self.toolProviders = toolProviders
    self.managementToolNames = managementToolNames
    self.executableSearchDirectories = executableSearchDirectories
    self.gitExecutable = gitExecutable
    self.fileChanges = fileChanges
  }
}
