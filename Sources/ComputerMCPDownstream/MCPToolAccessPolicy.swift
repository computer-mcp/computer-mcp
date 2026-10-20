import ComputerMCPConfiguration
import ComputerMCPCore
import Foundation

/// Resolves host grants against registration identity, before downstream discovery or execution.
package struct MCPToolAccessPolicy: Sendable {
  package let configuration: GatewayConfiguration
  package let grant: ProfileGrant
  package let derivesObserveGrant: Bool

  package init(configuration: GatewayConfiguration, grant: ProfileGrant, derivesObserveGrant: Bool)
  {
    self.configuration = configuration
    self.grant = grant
    self.derivesObserveGrant = derivesObserveGrant
  }

  package func allows(_ reference: MCPToolReference, riskFloor: CapabilityRisk? = nil) -> Bool {
    guard let server = configuration.mcp.servers.first(where: { $0.id == reference.serverID }),
      server.permitsTool(reference.toolName)
    else { return false }
    let risk = configuration.mcpRisk(for: reference).raised(to: riskFloor)
    guard grant.permitsRisk(risk) else { return false }
    guard risk != .fullShell || grant.fullShellEnabled else { return false }
    if derivesObserveGrant && risk == .readOnly { return true }
    return grant.grants(
      CapabilityDescriptor(
        id: "mcp.tools.call", risk: risk, mcpReference: reference,
        equivalentCapabilityIDs: configuration.mcpCapabilityIDs(for: reference)))
  }

  package func canDiscoverTools(on server: MCPServerConfig) -> Bool {
    guard server.enabled else { return false }
    if grant.capabilityIDs.contains("*") || grant.mcpServerIDs.contains(server.id)
      || grant.capabilityIDs.contains("mcp.tools.call")
    {
      return true
    }
    var names = Set(configuration.tools.filter { $0.source == server.id }.compactMap(\.tool))
    names.formUnion(server.toolRisks.keys)
    if let prefix = server.prefix, server.exposure.includesReexport {
      if prefix.isEmpty {
        names.formUnion(grant.capabilityIDs)
      } else {
        let marker = "\(prefix)."
        names.formUnion(
          grant.capabilityIDs.filter { $0.hasPrefix(marker) }.map {
            String($0.dropFirst(marker.count))
          })
      }
    }
    return names.contains { allows(.init(serverID: server.id, toolName: $0)) }
  }

  package func permitsServer(_ server: MCPServerConfig, capability: String) -> Bool {
    guard server.enabled else { return false }
    return grant.capabilityIDs.contains("*") || grant.mcpServerIDs.contains(server.id)
      || grant.capabilityIDs.contains(capability)
      || (derivesObserveGrant && Self.observeCapabilities.contains(capability))
  }

  package func isVisible(_ server: MCPServerConfig) -> Bool {
    canDiscoverTools(on: server)
      || Self.sessionCapabilities.contains { permitsServer(server, capability: $0) }
  }

  private static let sessionCapabilities: Set<String> = [
    "mcp.servers.list", "mcp.servers.status",
    "mcp.resources.list", "mcp.resources.templates.list", "mcp.resources.read",
    "mcp.prompts.list", "mcp.prompts.get", "mcp.events.read", "mcp.requests.list",
    "mcp.requests.read",
    "mcp.requests.cancel",
    "mcp.connections.close",
  ]

  private static let observeCapabilities = sessionCapabilities.subtracting([
    "mcp.requests.cancel", "mcp.connections.close",
  ])
}
