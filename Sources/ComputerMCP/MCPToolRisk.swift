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
      guard let meta else { return nil }
      guard let object = meta.objectValue else {
        throw GatewayToolError.invalidArguments(
          "[mcp.invalid_risk_metadata] Tool metadata must be an object.")
      }
      guard let value = object["io.github.computer-mcp/risk"] else { return nil }
      guard let raw = value.stringValue, let risk = CapabilityRisk(rawValue: raw) else {
        throw GatewayToolError.invalidArguments(
          "[mcp.invalid_risk_metadata] The tool declares an unsupported risk classification.")
      }
      return risk
    }
  }
}

extension GatewayConfiguration {
  func mcpRisk(for reference: MCPToolReference, declaredBy tool: MCPTool) throws -> CapabilityRisk {
    try mcpRisk(for: reference).raised(to: tool.declaredRiskFloor)
  }
}

/// Bound by the host after authorization and consent, never accepted from MCP arguments.
struct MCPInvocationRisk: Sendable {
  @TaskLocal static var current: MCPInvocationRisk?

  let reference: MCPToolReference
  let risk: CapabilityRisk

  init?(descriptor: CapabilityDescriptor) {
    guard let reference = descriptor.mcpReference else { return nil }
    self.reference = reference
    risk = descriptor.risk
  }

  func validate(reference: MCPToolReference, risk: CapabilityRisk) throws {
    guard self.reference == reference, self.risk.raised(to: risk) == self.risk else {
      throw GatewayToolError.invalidArguments(
        "[mcp.risk_changed] The downstream tool risk changed after host authorization. Retry through the current host policy and approval flow."
      )
    }
  }
}
