/// Semantic effects recognized by the host before policy, consent and dispatch.
/// A downstream declaration selects validation; it is never a grant.
package enum MCPHostServiceAction: String, Codable, Sendable {
  case diagnosticsSnapshot = "diagnostics.snapshot"
  case workspaceProvision = "workspaces.provision"
  case workspaceRemoval = "workspaces.remove"

  static let metadataKey = "io.github.computer-mcp/host-action"

  var minimumRisk: CapabilityRisk {
    switch self {
    case .diagnosticsSnapshot: .readOnly
    case .workspaceProvision: .workspaceWrite
    case .workspaceRemoval: .destructive
    }
  }

  /// Released adapters predate semantic declarations. Keep their wire identity
  /// compatible while all private-service authorization uses the admitted action.
  static func legacyAction(tool: String) -> Self? {
    switch tool {
    case "codex.diagnostics.snapshot": .diagnosticsSnapshot
    case "codex.worktree.provision.perform": .workspaceProvision
    case "codex.worktree.remove.perform": .workspaceRemoval
    default: nil
    }
  }
}

extension MCPTool {
  var hostServiceAction: MCPHostServiceAction? {
    get throws {
      if let meta, meta.objectValue == nil {
        throw GatewayToolError.invalidArguments(
          "[mcp.invalid_host_action] Tool metadata must be an object.")
      }
      guard let value = meta?.objectValue?[MCPHostServiceAction.metadataKey] else {
        return MCPHostServiceAction.legacyAction(tool: mcpReference?.toolName ?? name)
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
struct MCPToolAdmissionPolicy: Sendable {
  let risk: CapabilityRisk
  let hostServiceAction: MCPHostServiceAction?
}
