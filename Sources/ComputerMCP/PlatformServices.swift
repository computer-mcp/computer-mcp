import ComputerMCPPlatform
import Foundation

/// Platform implementations selected by the host for gateway and control-plane composition.
package struct PlatformServices: Sendable {
  package let workspaceGrants: any WorkspaceBookmarkServicing
  package let toolProviders: any GatewayToolProviderFactory
  package let executableSearchDirectories: [String]
  package let fileChanges: @Sendable (URL) throws -> any FileChangeMonitor

  package init(
    workspaceGrants: any WorkspaceBookmarkServicing,
    toolProviders: any GatewayToolProviderFactory,
    executableSearchDirectories: [String],
    fileChanges: @escaping @Sendable (URL) throws -> any FileChangeMonitor
  ) {
    self.workspaceGrants = workspaceGrants
    self.toolProviders = toolProviders
    self.executableSearchDirectories = executableSearchDirectories
    self.fileChanges = fileChanges
  }
}
