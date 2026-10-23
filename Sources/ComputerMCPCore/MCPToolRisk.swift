import Foundation

extension CapabilityRisk {
  package func raised(to floor: CapabilityRisk?) -> CapabilityRisk {
    guard let floor, floor.order > order else { return self }
    return floor
  }

  private var order: Int {
    switch self {
    case .readOnly: 0
    case .projectWrite: 1
    case .externalWrite: 2
    case .destructive: 3
    case .fullShell: 4
    }
  }
}

extension MCPTool {
  /// Publisher metadata can raise host policy, but cannot grant authority or lower it.
  package var declaredRiskFloor: CapabilityRisk? {
    get throws {
      let actionFloor = try hostServiceAction?.minimumRisk
      guard let meta else { return actionFloor }
      guard let object = meta.objectValue else {
        throw GatewayToolError.invalidArguments(
          "[mcp.invalid_risk_metadata] Tool metadata must be an object.")
      }
      guard let value = object["io.github.computer-mcp/risk"] else { return actionFloor }
      // Independently installed publishers retain the version-1 risk spelling on the wire.
      guard let raw = value.stringValue,
        let risk = raw == "workspace-write"
          ? CapabilityRisk.projectWrite : CapabilityRisk(rawValue: raw)
      else {
        throw GatewayToolError.invalidArguments(
          "[mcp.invalid_risk_metadata] The tool declares an unsupported risk classification.")
      }
      return risk.raised(to: actionFloor)
    }
  }
}
