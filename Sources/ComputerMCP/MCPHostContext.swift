import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPlatform
import Foundation

/// Workspace launch provenance and gateway-owned authority and lifecycle state.
package struct MCPHostContext: MCPHostEnvironment {
  package let launchMetadata: MCPHostLaunchMetadata
  let tools: MCPHostToolDirectory?
  /// Host-local recovery storage; never serialized into downstream launch metadata.
  package var processOwnershipRoot: URL?
  /// Host-owned file identities by registration; never supplied in plugin arguments.
  package var pluginArtifacts: [String: PluginDirectoryIdentity] = [:]
  /// In-process work ownership is never serialized or asserted by a plugin.
  var ownedWork: GatewayOwnedWork?
  /// Host-local execution receipts and identity are never environment credentials.
  let executionDatabase: GatewayDatabase?
  /// Verified admission evidence for host ownership writes, never inferred from caller provenance.
  let verifiedPrincipalID: String?

  package var workspaceRoot: URL { URL(fileURLWithPath: launchMetadata.workspace.rootPath) }
  package var providesHostServices: Bool { tools != nil }

  package init(
    runtimeID: UUID, context: ExecutionContext, workspaceID: String, rootURL: URL,
    readOnly: Bool, tools: MCPHostToolDirectory? = nil, managedWorkspaceRoot: URL? = nil,
    processOwnershipRoot: URL? = nil, executionDatabase: GatewayDatabase? = nil
  ) {
    launchMetadata = MCPHostLaunchMetadata(
      runtimeID: runtimeID, context: context, workspaceID: workspaceID, rootURL: rootURL,
      readOnly: readOnly, managedWorkspaceRoot: managedWorkspaceRoot)
    self.tools = tools
    self.processOwnershipRoot = processOwnershipRoot
    self.executionDatabase = executionDatabase
    verifiedPrincipalID = context.trustedPrincipalID
  }

  package func makeHostSession(server: MCPServerConfig) throws -> any MCPHostSessionHandle {
    try MCPHostSession(context: self, server: server)
  }
}
