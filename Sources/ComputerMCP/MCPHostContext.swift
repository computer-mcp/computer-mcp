import Foundation

/// Immutable launch provenance for a workspace's downstream stdio processes.
/// This is not a credential or a grant. The gateway still authorizes and audits every call.
package struct MCPHostContext: Encodable, Sendable {
  package static let environmentKey = "COMPUTER_MCP_HOST_CONTEXT"
  static let descriptorEnvironmentKey = "COMPUTER_MCP_HOST_FD"

  package struct Workspace: Encodable, Sendable {
    let id: String
    let rootPath: String
  }

  let formatVersion = 1
  let runtimeID: UUID
  let caller: GatewayCallerKind
  let profileID: GatewayProfileID
  let workspace: Workspace
  let readOnly: Bool
  let transportTrace: GatewayTransportTrace?
  let tools: MCPHostToolDirectory?
  let managedWorkspaceRoot: String?
  /// Host-local recovery storage; never serialized into downstream launch metadata.
  var processOwnershipRoot: URL?

  private enum CodingKeys: String, CodingKey {
    case formatVersion, runtimeID, caller, profileID, workspace, readOnly, transportTrace,
      managedWorkspaceRoot
  }

  package init(
    runtimeID: UUID, context: ExecutionContext, workspaceID: String, rootURL: URL,
    readOnly: Bool, tools: MCPHostToolDirectory? = nil, managedWorkspaceRoot: URL? = nil,
    processOwnershipRoot: URL? = nil
  ) {
    self.runtimeID = runtimeID
    caller = context.caller
    profileID = context.profileID
    workspace = Workspace(id: workspaceID, rootPath: rootURL.path)
    self.readOnly = readOnly
    transportTrace = context.transportTrace
    self.tools = tools
    self.managedWorkspaceRoot = managedWorkspaceRoot?.standardizedFileURL.path
    self.processOwnershipRoot = processOwnershipRoot
  }

  /// Registration overrides and inherited environments cannot assert host provenance.
  static func launchEnvironment(
    inherited: [String: String], overrides: [String: String], context: Self?
  ) throws -> [String: String] {
    var result = inherited.merging(overrides) { _, value in value }
    result.removeValue(forKey: environmentKey)
    result.removeValue(forKey: descriptorEnvironmentKey)
    if let context {
      let data = try JSONEncoder().encode(context)
      guard data.count <= 16_384 else {
        throw GatewayToolError.executionFailed("Downstream MCP host context exceeds 16 KiB.")
      }
      result[environmentKey] = String(decoding: data, as: UTF8.self)
    }
    return result
  }
}
