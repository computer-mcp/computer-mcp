import Foundation

/// Semantic effects recognized by the host before policy, consent and dispatch.
/// A downstream declaration selects validation; it is never a grant.
package enum MCPHostServiceAction: String, Codable, Sendable {
  case diagnosticsSnapshot = "diagnostics.snapshot"
  case projectProvision = "projects.provision"
  case projectRemoval = "projects.remove"
  case projectList = "projects.list"

  static let metadataKey = "io.github.computer-mcp/host-action"

  var minimumRisk: CapabilityRisk {
    switch self {
    case .diagnosticsSnapshot, .projectList: .readOnly
    case .projectProvision: .projectWrite
    case .projectRemoval: .destructive
    }
  }

  /// Both peers must agree on the project lifecycle contract before these dispatch.
  package var isProjectLifecycle: Bool { self != .diagnosticsSnapshot }

  /// Mutations receive a durable host-reserved operation before they are forwarded.
  package var reservesOperation: Bool { self == .projectProvision || self == .projectRemoval }
}

/// The project lifecycle protocol identity, independent of a manifest's `plugin_api`.
package enum MCPHostServiceContract {
  package static let identifier = "projects-v1"
  /// Key in an MCP initialization result's `capabilities.experimental`.
  package static let capabilityKey = "io.github.computer-mcp/host-service-contract"
  /// `tools/call` metadata carrying the host-reserved lifecycle operation UUID.
  package static let operationMetadataKey = "io.github.computer-mcp/host-operation"
}

/// A missing, unknown or mismatched contract marker refuses lifecycle dispatch before
/// any mutation. Retrying under another method spelling cannot satisfy it.
package struct MCPHostServiceContractError: Error, Equatable, LocalizedError, AuditErrorClassifying
{
  package static let code = "host.unsupported_contract"
  package let observed: String?

  package init(observed: String?) { self.observed = observed }

  package var errorDescription: String? {
    "The plugin and host do not agree on the \(MCPHostServiceContract.identifier) project "
      + "service contract. Update Computer MCP and the affected plugin together, then restart "
      + "the provider."
  }

  package var auditClassification: (decision: AuditDecision, code: String)? {
    (.denied, Self.code)
  }

  /// Structured fields reported beside `code` and `message`.
  package var fields: [String: JSONValue] {
    [
      "required_contract": .string(MCPHostServiceContract.identifier),
      "observed_contract": observed.map(JSONValue.string) ?? .null,
    ]
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
