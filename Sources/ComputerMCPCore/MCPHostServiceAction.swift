/// Semantic effects recognized by the host before policy, consent and dispatch.
/// A downstream declaration selects validation; it is never a grant.
package enum MCPHostServiceAction: String, Codable, Sendable {
  case diagnosticsSnapshot = "diagnostics.snapshot"
  // Action values are advertised by independently installed plugins.
  case projectProvision = "workspaces.provision"
  case projectRemoval = "workspaces.remove"

  static let metadataKey = "io.github.computer-mcp/host-action"

  var minimumRisk: CapabilityRisk {
    switch self {
    case .diagnosticsSnapshot: .readOnly
    case .projectProvision: .projectWrite
    case .projectRemoval: .destructive
    }
  }
}

extension MCPTool {
  package var hostServiceAction: MCPHostServiceAction? {
    get throws {
      if let meta, meta.objectValue == nil {
        throw GatewayToolError.invalidArguments(
          "[mcp.invalid_host_action] Tool metadata must be an object.")
      }
      guard let value = meta?.objectValue?[MCPHostServiceAction.metadataKey] else {
        return nil
      }
      guard let raw = value.stringValue, let action = MCPHostServiceAction(rawValue: raw) else {
        throw GatewayToolError.invalidArguments(
          "[mcp.invalid_host_action] The tool declares an unsupported host action.")
      }
      return action
    }
  }
}

/// One discovery observation supplies both risk and semantic effect.
package struct MCPToolAdmissionPolicy: Sendable {
  package let risk: CapabilityRisk
  package let hostServiceAction: MCPHostServiceAction?

  package init(risk: CapabilityRisk, hostServiceAction: MCPHostServiceAction?) {
    self.risk = risk
    self.hostServiceAction = hostServiceAction
  }
}
