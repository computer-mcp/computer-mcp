import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import Foundation

/// Immutable launch provenance, not a credential or grant. The host authorizes every call.
package struct MCPHostLaunchMetadata: Encodable, Sendable {
  package static let environmentKey = "COMPUTER_MCP_HOST_CONTEXT"
  package static let descriptorEnvironmentKey = "COMPUTER_MCP_HOST_FD"
  package static let readHandleEnvironmentKey = "COMPUTER_MCP_HOST_READ_HANDLE"
  package static let writeHandleEnvironmentKey = "COMPUTER_MCP_HOST_WRITE_HANDLE"

  package struct Project: Encodable, Sendable {
    package let id: String
    package let rootPath: String
  }

  package let formatVersion = 1
  package let runtimeID: UUID
  package let caller: GatewayCallerKind
  package let profileID: GatewayProfileID
  package let project: Project
  package let readOnly: Bool
  package let transportTrace: GatewayTransportTrace?
  package let managedProjectRoot: String?
  package let principalID: String

  private enum CodingKeys: String, CodingKey {
    // Launch metadata is consumed by independently installed plugins.
    case formatVersion, runtimeID, caller, profileID, readOnly, transportTrace, principalID
    case project = "workspace"
    case managedProjectRoot = "managedWorkspaceRoot"
  }

  package init(
    runtimeID: UUID, context: ExecutionContext, projectID: String, rootURL: URL,
    readOnly: Bool, managedProjectRoot: URL? = nil
  ) {
    self.runtimeID = runtimeID
    caller = context.caller
    profileID = context.profileID
    project = Project(id: projectID, rootPath: rootURL.path)
    self.readOnly = readOnly
    transportTrace = context.transportTrace
    self.managedProjectRoot = managedProjectRoot?.standardizedFileURL.path
    principalID = context.principalID
  }

  /// Inherited and registration-supplied values cannot assert host provenance or descriptors.
  package static func launchEnvironment(
    inherited: [String: String], overrides: [String: String], context: Self?
  ) throws -> [String: String] {
    var result = inherited.merging(overrides) { _, value in value }
    for key in [
      environmentKey, descriptorEnvironmentKey, readHandleEnvironmentKey, writeHandleEnvironmentKey,
    ] {
      result.removeValue(forKey: key)
    }
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

/// Host-owned launch state and session construction supplied to downstream clients.
package protocol MCPHostEnvironment: Sendable {
  var launchMetadata: MCPHostLaunchMetadata { get }
  var projectRoot: URL { get }
  var processOwnershipRoot: URL? { get }
  var pluginArtifacts: [String: PluginDirectoryIdentity] { get }
  var providesHostServices: Bool { get }
  func makeHostSession(server: MCPServerConfig) throws -> any MCPHostSessionHandle
}

/// The downstream process inherits the child handle; cleanup must precede ownership confirmation.
package protocol MCPHostSessionHandle: Sendable {
  var childHandle: FileHandle { get }
  func close() async
  func shutdownConfirmed() async -> Bool
}
