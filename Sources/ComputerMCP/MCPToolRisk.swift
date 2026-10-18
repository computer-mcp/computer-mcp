import Foundation

extension CapabilityRisk {
  func raised(to floor: CapabilityRisk?) -> CapabilityRisk {
    guard let floor, floor.order > order else { return self }
    return floor
  }

  private var order: Int {
    switch self {
    case .readOnly: 0
    case .workspaceWrite: 1
    case .externalWrite: 2
    case .destructive: 3
    case .fullShell: 4
    }
  }
}

extension MCPTool {
  /// Publisher metadata can raise host policy, but cannot grant authority or lower it.
  var declaredRiskFloor: CapabilityRisk? {
    get throws {
      let actionFloor = try hostServiceAction?.minimumRisk
      guard let meta else { return actionFloor }
      guard let object = meta.objectValue else {
        throw GatewayToolError.invalidArguments(
          "[mcp.invalid_risk_metadata] Tool metadata must be an object.")
      }
      guard let value = object["io.github.computer-mcp/risk"] else { return actionFloor }
      guard let raw = value.stringValue, let risk = CapabilityRisk(rawValue: raw) else {
        throw GatewayToolError.invalidArguments(
          "[mcp.invalid_risk_metadata] The tool declares an unsupported risk classification.")
      }
      return risk.raised(to: actionFloor)
    }
  }
}

extension GatewayConfiguration {
  func mcpRisk(for reference: MCPToolReference, declaredBy tool: MCPTool) throws -> CapabilityRisk {
    try mcpRisk(for: reference).raised(to: tool.declaredRiskFloor)
  }
}

/// Bound by the host after authorization and consent, never accepted from MCP arguments.
struct MCPInvocationAdmission: Sendable {
  @TaskLocal static var current: MCPInvocationAdmission?

  let reference: MCPToolReference
  let risk: CapabilityRisk
  let hostServiceAction: MCPHostServiceAction?
  let hostInvocationID: UUID?

  init?(descriptor: CapabilityDescriptor, hostInvocationID: UUID? = nil) {
    guard let reference = descriptor.mcpReference else { return nil }
    self.reference = reference
    risk = descriptor.risk
    hostServiceAction = descriptor.hostServiceAction
    self.hostInvocationID = hostInvocationID
  }

  func validate(
    reference: MCPToolReference, risk: CapabilityRisk,
    hostServiceAction: MCPHostServiceAction?
  ) throws {
    guard self.reference == reference, self.risk.raised(to: risk) == self.risk else {
      throw GatewayToolError.invalidArguments(
        "[mcp.risk_changed] The downstream tool risk changed after host authorization. Retry through the current host policy and approval flow."
      )
    }
    guard self.hostServiceAction == hostServiceAction else {
      throw GatewayToolError.invalidArguments(
        "[mcp.host_action_changed] The downstream host action changed after authorization. Retry through the current policy and approval flow."
      )
    }
  }

  func correlationID(for server: MCPServerConfig, tool: String) -> UUID? {
    guard server.hostServices, reference == MCPToolReference(serverID: server.id, toolName: tool)
    else { return nil }
    return hostInvocationID
  }
}
