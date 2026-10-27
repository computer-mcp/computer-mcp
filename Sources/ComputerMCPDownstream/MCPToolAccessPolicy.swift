import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import Foundation

/// Resolves object permissions against host registration identity before discovery or execution.
package struct MCPToolAccessPolicy: Sendable {
  package let configuration: GatewayConfiguration
  package let grant: ProfileGrant
  package let fullAccessConsented: Bool
  package let pluginIDs: [String: String]

  package init(
    configuration: GatewayConfiguration, grant: ProfileGrant,
    fullAccessConsented: Bool = false, pluginIDs: [String: String] = [:]
  ) {
    self.configuration = configuration
    self.grant = grant
    self.fullAccessConsented = fullAccessConsented
    self.pluginIDs = pluginIDs
  }

  package func allows(_ reference: MCPToolReference, riskFloor: CapabilityRisk? = nil) -> Bool {
    guard let server = configuration.mcp.servers.first(where: { $0.id == reference.serverID }),
      server.permitsTool(reference.toolName)
    else { return false }
    let risk = configuration.mcpRisk(for: reference).raised(to: riskFloor)
    guard permitsObject(server, access: risk == .readOnly ? .read : .all) else { return false }
    return server.transport == .stdio || risk != .fullShell
      || (grant.fullAccess && fullAccessConsented)
  }

  package func canDiscoverTools(on server: MCPServerConfig) -> Bool {
    server.enabled && permitsObject(server, access: .read)
  }

  /// Once an object is visible, its selected catalog describes tools the owner
  /// can grant. A write tool may therefore be listed with only server read access.
  package func isToolVisible(_ reference: MCPToolReference) -> Bool {
    guard let server = configuration.mcp.servers.first(where: { $0.id == reference.serverID })
    else { return false }
    return canDiscoverTools(on: server) && server.permitsTool(reference.toolName)
  }

  package func permitsServer(_ server: MCPServerConfig, capability: String) -> Bool {
    server.enabled && permitsObject(server, access: Self.serverAccess(for: capability))
  }

  package func isVisible(_ server: MCPServerConfig) -> Bool { canDiscoverTools(on: server) }

  package func hasAdmittedTool(_ reference: MCPToolReference, context: InvocationContext) -> Bool {
    guard context.executionAuthority != nil, let resolved = context.resolvedInvocation,
      let admission = context.admission, admission.reference == reference,
      resolved.descriptor.mcpReference == reference
    else { return false }
    return hasAdmittedObject(
      reference.serverID, access: admission.risk == .readOnly ? .read : .all,
      context: context)
  }

  package func hasAdmittedServer(
    _ server: MCPServerConfig, capability: String, context: InvocationContext
  ) -> Bool {
    guard context.executionAuthority != nil, let resolved = context.resolvedInvocation,
      resolved.identity.tool == capability, server.enabled,
      configuration.mcp.servers.contains(where: { $0.id == server.id && $0.enabled })
    else { return false }
    switch (capability, resolved.descriptor.requirement.execution) {
    case ("mcp.requests.read", .read), ("mcp.requests.cancel", .cancel),
      ("mcp.requests.list", .list):
      // The provider checks the retained execution's authority before exposing
      // output or accepting control of its exact request.
      return true
    default: break
    }
    return hasAdmittedObject(
      server.id, access: Self.serverAccess(for: capability), context: context)
  }

  private func hasAdmittedObject(
    _ serverID: String, access: PermissionValue, context: InvocationContext
  ) -> Bool {
    guard context.executionAuthority != nil, let resolved = context.resolvedInvocation,
      configuration.mcp.servers.contains(where: { $0.id == serverID && $0.enabled })
    else { return false }
    let permission = objectPermission(serverID)
    let value: PermissionValue = pluginIDs[serverID] == nil ? access : .use
    return resolved.requirements.actions.contains {
      $0.requirement.permission == permission
        && Self.includes($0.requirement.value, value)
    }
  }

  private func permitsObject(_ server: MCPServerConfig, access: PermissionValue) -> Bool {
    guard server.enabled else { return false }
    let value: PermissionValue = pluginIDs[server.id] == nil ? access : .use
    guard case .granted(let granted) = grant.permissions.state(for: objectPermission(server.id))
    else { return false }
    return Self.includes(granted, value)
  }

  private func objectPermission(_ serverID: String) -> Permission {
    pluginIDs[serverID].map(Permission.plugin) ?? .mcpServer(serverID)
  }

  private static func includes(_ granted: PermissionValue, _ required: PermissionValue) -> Bool {
    granted == required || (required == .read && (granted == .write || granted == .all))
  }

  private static func serverAccess(for capability: String) -> PermissionValue {
    ["mcp.requests.cancel", "mcp.connections.close"].contains(capability) ? .all : .read
  }
}
