import ComputerMCPCore
import ComputerMCPPermissions
import Foundation

package enum GatewayPermissionCallError: Error, LocalizedError, AuditErrorClassifying {
  case required(
    [PermissionRequest], evidence: GatewayPermissionAuditEvidence? = nil,
    afterDispatch: Bool = false
  )
  case denied(DenialReason, evidence: GatewayPermissionAuditEvidence? = nil)

  package var auditClassification: (decision: AuditDecision, code: String)? { (.denied, code) }

  var evidence: GatewayPermissionAuditEvidence? {
    switch self {
    case .required(_, let evidence, _), .denied(_, let evidence): return evidence
    }
  }

  var auditFields: [String: JSONValue] {
    switch self {
    case .required(let requests, _, _):
      return ["permission_request_ids": .array(requests.map { .string($0.id.uuidString) })]
    case .denied(let reason, _): return ["denial_reason": .string(String(describing: reason))]
    }
  }

  package var code: String {
    switch self {
    case .required: return "permission.required"
    case .denied(let reason, _):
      switch reason {
      case .managedLimit: return "permission.managed_limit"
      case .authoritySuspended: return "permission.authority_suspended"
      case .fullAccessRequiresConsent: return "permission.full_access_consent_required"
      case .fullAccessRequired: return "permission.full_access_required"
      default: return "permission.denied"
      }
    }
  }

  package var errorDescription: String? {
    switch self {
    case .required(_, _, let afterDispatch):
      return afterDispatch
        ? "A required operation failed with a permission error. The local owner can allow it for an explicit retry. Earlier operations may have had effects."
        : "The local owner must answer the permission requests before this call can run."
    case .denied(let reason, _):
      return "The permission service refused this call: \(String(describing: reason))."
    }
  }

  var fields: [String: JSONValue] {
    switch self {
    case .denied(let reason, _):
      var value: [String: JSONValue] = ["reason": .string(String(describing: reason))]
      if case .managedLimit(let sources) = reason {
        value["sources"] = .array(
          sources.map { .string($0.rawValue) }.sorted { $0.stringValue! < $1.stringValue! })
      }
      return value
    case .required(let requests, _, let afterDispatch):
      let ids = requests.map { JSONValue.string($0.id.uuidString) }
      var fields: [String: JSONValue] = [
        "request_ids": .array(ids),
        "call_dispatched": .bool(afterDispatch),
        "request_group_id": .string(
          requests.first.map { MCPExecutionRecord.digest((try? .encoded($0.invocation)) ?? .null) }
            ?? ""),
        "requests": .array(requests.map(Self.request)),
        "retry": .object([
          "field": .string(GatewayPermissionRetryInput.field),
          "instructions": .string(
            afterDispatch
              ? "The operation failed with a permission error. Earlier operations may have had effects. After reviewing them and the owner's answers, explicitly retry the same tool with unchanged arguments and all request IDs."
              : "After the local owner answers, retry the same tool with unchanged arguments and all request IDs. No call was executed."
          ),
        ]),
      ]
      if afterDispatch, let invocation = requests.first?.invocation {
        fields["original_call"] = .object([
          "tool": .string(invocation.tool),
          "project_id": invocation.projectID.map(JSONValue.string) ?? .null,
        ])
      }
      return fields
    }
  }

  private static func request(_ request: PermissionRequest) -> JSONValue {
    var row: [String: JSONValue] = [
      "request_id": .string(request.id.uuidString),
      "expires_at": .string(ISO8601DateFormatter().string(from: request.expiresAt)),
      "owner": .string("local-owner"),
    ]
    switch request.content {
    case .permission(let content):
      let name: String
      let object: String?
      switch content.requirement.permission {
      case .project(let id):
        name = "project"
        object = id
      case .plugin(let id):
        name = "plugin"
        object = id
      case .mcpServer(let id):
        name = "mcp_server"
        object = id
      case .filesAndFolders(let folder):
        name = "files_and_folders"
        object = folder.rawValue
      case .screen:
        name = "screen"
        object = nil
      case .desktopControl:
        name = "desktop_control"
        object = nil
      case .localNetwork:
        name = "local_network"
        object = nil
      case .machineInformation:
        name = "machine_information"
        object = nil
      case .unifiedLogs:
        name = "unified_logs"
        object = nil
      case .skills:
        name = "skills"
        object = nil
      }
      row["principal"] = try? .encoded(content.principal)
      row["permission"] = .string(name)
      row["object"] = object.map(JSONValue.string) ?? .null
      row["value"] = .string(content.requirement.value.rawValue)
      row["scope"] = try? .encoded(content.scope)
      row["plugin_purpose"] = content.pluginPurpose.map(JSONValue.string) ?? .null
    case .network(let content):
      row["principal"] = try? .encoded(content.principal)
      row["permission"] = .string("network")
      row["object"] = .string(content.host)
      row["value"] = .string("allow")
      row["scope"] = try? .encoded(RequestScope.host(content.host, project: content.projectID))
      row["plugin_purpose"] = content.pluginPurpose.map(JSONValue.string) ?? .null
    case .projectRegistration(let content):
      row["principal"] = try? .encoded(content.principal)
      row["permission"] = .string("project_registration")
      row["object"] = .string(content.projectID)
      row["value"] = .string(content.access.rawValue)
      row["scope"] = try? .encoded(RequestScope.path(content.path))
    }
    return .object(row)
  }
}

struct GatewayAuditCompletionError: Error, LocalizedError, AuditErrorClassifying {
  var errorDescription: String? {
    "The tool may have completed, but its final audit record could not be saved. Inspect the resulting state before deciding what to do; this response does not authorize replay."
  }
  var auditClassification: (decision: AuditDecision, code: String)? {
    (.failed, "audit.outcome_unknown")
  }
}
