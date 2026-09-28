import CryptoKit
import Foundation

enum ControlToolResponse {
  static func encodedPayload<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(
      JSONValue.self,
      from: CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys]).encode(value))
  }

  static func envelope(
    _ payload: JSONValue,
    requestID: String,
    capabilityID: String,
    identity: GatewaySocketConnectionIdentity,
    isError: Bool = false
  ) -> JSONValue {
    let execution = JSONValue.object([
      "request_id": .string(requestID),
      "caller": .string(GatewayCallerKind.localCLI.rawValue),
      "profile_id": .string(GatewayProfileID.localAdmin.rawValue),
      "workspace_id": .null,
      "capability_id": .string(capabilityID),
      "transport": .string("control_socket"),
      "socket_connection_id": .string(identity.connectionID),
    ])
    var structuredContent = payload.objectValue ?? ["result": payload]
    structuredContent["gateway_execution"] = execution
    return .object([
      "content": .array([
        .object(["type": .string("text"), "text": .string(payloadText(payload))])
      ]),
      "structuredContent": .object(structuredContent),
      "isError": .bool(isError),
      "_meta": .object(["computer_mcp": execution]),
    ])
  }

  static func payloadText(_ payload: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? String(decoding: encoder.encode(payload), as: UTF8.self)) ?? "{}"
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func digest(_ value: JSONValue) throws -> String {
    digest(try encodedJSON(value))
  }

  static func encodedJSON(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  static func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds * 1_000)
      + Int(duration.components.attoseconds / 1_000_000_000_000_000)
  }

  static func auditDisposition(
    for error: Error
  ) -> (decision: AuditDecision, code: String) {
    if error is MCPHTTPAuthenticationError { return (.failed, "mcp.authentication") }
    if let error = error as? PluginCatalogError {
      return (.failed, error.code)
    }
    if let error = error as? PluginArchiveError {
      return (.failed, "plugin.archive.\(error.rawValue)")
    }
    if let error = error as? PluginStoreError {
      let code =
        switch error {
        case .staleRevision: "stale_revision"
        case .unknownInstallation: "unknown_installation"
        case .invalidState: "invalid_state"
        case .manifestChanged: "manifest_changed"
        case .installationBusy: "installation_busy"
        case .artifactInUse: "artifact_in_use"
        }
      return (.failed, "plugin.\(code)")
    }
    if let error = error as? PluginHostError {
      let code =
        switch error {
        case .changeInProgress: "change_in_progress"
        case .invalidComposition: "invalid_composition"
        case .workerUnavailable: "worker_unavailable"
        }
      return (.failed, "plugin.\(code)")
    }
    if case .localAdminCannotBeSocketProfile = error as? AppControlPlaneServiceError {
      return (.denied, "policy.local_admin_remote")
    }
    if case .invalid(let message) = error as? ConfigurationError,
      message.contains("local-admin")
    {
      return (.denied, "policy.local_admin_remote")
    }
    if let gatewayError = error as? GatewayToolError {
      switch gatewayError {
      case .unknownTool:
        return (.failed, "control.tool_unknown")
      case .invalidArguments:
        return (.failed, "control.invalid_arguments")
      case .disabled:
        return (.denied, "control.operation_disabled")
      case .executionFailed, .unknownCLI, .unknownMCPServer:
        return (.failed, "control.operation_failed")
      }
    }
    if error is ConfigurationError {
      return (.failed, "configuration.invalid")
    }
    return (.failed, "control.operation_failed")
  }

  static func errorMessage(_ error: Error) -> String {
    String(
      ((error as? any LocalizedError)?.errorDescription ?? String(describing: error))
        .prefix(2_048)
    )
  }

}
