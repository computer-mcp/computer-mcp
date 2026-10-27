import ComputerMCPEgress
import ComputerMCPPlatform
import ComputerMCPProcess
import Foundation

/// Platform implementations selected by the host for gateway and control-plane composition.
package struct PlatformServices: Sendable {
  package let launcher: ExecutionLauncher
  package let pluginDirectories: any PluginArchiveDirectoryFactory
  package let applications: any ApplicationBundleLocating
  package let projectGrants: any ProjectBookmarkServicing
  package let toolProviders: any GatewayToolProviderFactory
  /// Reserved even when a generation has no management provider.
  package let managementToolNames: Set<String>
  package let executableSearchDirectories: [String]
  package let gitExecutable: String
  package let fileChanges: @Sendable (URL) throws -> any FileChangeMonitor
  package var permissionPolicyReader: any ManagedPolicyReading
  package var hostDataPaths: Set<URL>
  package let executionProxy: ExecutionRevocationCoordinator.ProxyFactory?

  package init(
    launcher: ExecutionLauncher = ExecutionLauncher(),
    projectGrants: any ProjectBookmarkServicing,
    pluginDirectories: any PluginArchiveDirectoryFactory,
    applications: any ApplicationBundleLocating,
    toolProviders: any GatewayToolProviderFactory,
    managementToolNames: Set<String>,
    executableSearchDirectories: [String],
    gitExecutable: String,
    fileChanges: @escaping @Sendable (URL) throws -> any FileChangeMonitor,
    permissionPolicyReader: any ManagedPolicyReading = UnavailablePermissionPolicyReader(),
    executionProxy: ExecutionRevocationCoordinator.ProxyFactory? = nil,
    hostDataPaths: Set<URL> = []
  ) {
    self.launcher = launcher
    self.projectGrants = projectGrants
    self.pluginDirectories = pluginDirectories
    self.applications = applications
    self.toolProviders = toolProviders
    self.managementToolNames = managementToolNames
    self.executableSearchDirectories = executableSearchDirectories
    self.gitExecutable = gitExecutable
    self.fileChanges = fileChanges
    self.permissionPolicyReader = permissionPolicyReader
    self.executionProxy = executionProxy
    self.hostDataPaths = hostDataPaths
  }
}

package struct UnavailablePermissionPolicyReader: ManagedPolicyReading {
  package init() {}
  package func readSources() -> [ManagedPolicySourceSnapshot] {
    ManagedPolicySourceID.allCases.map {
      .init(source: $0, location: $0.rawValue, status: .unreadable("Policy adapter unavailable"))
    }
  }
  package func canonicalPolicyPath(_ path: String) throws -> String {
    throw GatewayPermissionError.invalidPolicySnapshot
  }
}
