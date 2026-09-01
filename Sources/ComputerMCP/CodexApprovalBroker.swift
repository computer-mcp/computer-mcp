import Foundation

enum CodexApprovalKind: String, Codable, Equatable, Sendable {
  case commandExecution = "command_execution"
  case fileChange = "file_change"
  case permissions
  case applyPatch = "apply_patch"
  case execCommand = "exec_command"
  case registeredTool = "registered_tool"
}

enum CodexApprovalState: String, Codable, Equatable, Sendable {
  case pending
  case approved
  case denied
  case timedOut = "timed_out"
  case interrupted
  case failed

  var isTerminal: Bool {
    self != .pending
  }
}

enum CodexApprovalDecision: String, Codable, Equatable, Sendable {
  case approveOnce = "approve_once"
  case approveSession = "approve_session"
  case deny
}

struct CodexApprovalRecord: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let upstreamRequestID: String
  let kind: CodexApprovalKind
  let risk: CapabilityRisk
  var state: CodexApprovalState
  let workspaceID: String?
  let workspacePath: String
  let runtimeID: String
  let threadID: String?
  let turnID: String?
  let itemID: String?
  let correlationID: String
  let socketConnectionID: String?
  let tunnelInstanceID: String?
  let details: JSONValue
  let proposedAction: JSONValue
  let createdAt: Date
  let expiresAt: Date
  var resolvedAt: Date?
  var decision: CodexApprovalDecision?
  var scope: String?
  var resolutionReason: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case upstreamRequestID = "upstream_request_id"
    case kind
    case risk
    case state
    case workspaceID = "workspace_id"
    case workspacePath = "workspace_path"
    case runtimeID = "runtime_id"
    case threadID = "thread_id"
    case turnID = "turn_id"
    case itemID = "item_id"
    case correlationID = "correlation_id"
    case socketConnectionID = "socket_connection_id"
    case tunnelInstanceID = "tunnel_instance_id"
    case details
    case proposedAction = "proposed_action"
    case createdAt = "created_at"
    case expiresAt = "expires_at"
    case resolvedAt = "resolved_at"
    case decision
    case scope
    case resolutionReason = "resolution_reason"
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

enum CodexApprovalBrokerError: Error, LocalizedError, Sendable {
  case unknown(String)
  case alreadyResolved(String)
  case invalidDecision(String)
  case outsideWorkspace(String)
  case unsupportedScope(String)
  case unavailableAfterRestart(String)

  var errorDescription: String? {
    switch self {
    case .unknown(let id):
      return "Unknown Codex approval '\(id)'."
    case .alreadyResolved(let id):
      return "Codex approval '\(id)' is already resolved."
    case .invalidDecision(let decision):
      return "Unsupported Codex approval decision '\(decision)'."
    case .outsideWorkspace(let detail):
      return "Codex approval exceeds the registered workspace: \(detail)"
    case .unsupportedScope(let detail):
      return "Codex approval scope is not supported: \(detail)"
    case .unavailableAfterRestart(let id):
      return
        "Codex approval '\(id)' survived for audit, but its App Server request is no longer live."
    }
  }
}

enum CodexApprovalRedactor {
  static func redact(_ value: JSONValue) -> JSONValue {
    var remainingEntries = 10_000
    return redact(value, depth: 0, remainingEntries: &remainingEntries)
  }

  private static func redact(
    _ value: JSONValue,
    depth: Int,
    remainingEntries: inout Int
  ) -> JSONValue {
    guard depth <= 16, remainingEntries > 0 else {
      return .string("[TRUNCATED]")
    }
    remainingEntries -= 1
    switch value {
    case .object(let object):
      var result: [String: JSONValue] = [:]
      for key in object.keys.sorted() {
        guard remainingEntries > 0 else {
          result["_truncated"] = .bool(true)
          break
        }
        let safeKey = redactString(key, maximumCharacters: 256)
        result[safeKey] =
          isSensitiveKey(key)
          ? .string("[REDACTED]")
          : redact(object[key] ?? .null, depth: depth + 1, remainingEntries: &remainingEntries)
      }
      return .object(result)
    case .array(let values):
      var result: [JSONValue] = []
      for value in values {
        guard remainingEntries > 0 else {
          result.append(.string("[TRUNCATED]"))
          break
        }
        result.append(redact(value, depth: depth + 1, remainingEntries: &remainingEntries))
      }
      return .array(result)
    case .string(let value):
      return .string(redactString(value))
    case .number, .bool, .null:
      return value
    }
  }

  static func redactString(
    _ value: String,
    maximumCharacters: Int = 8_192
  ) -> String {
    precondition(maximumCharacters > 0)
    return String(redactedString(value).prefix(maximumCharacters))
  }

  private static func isSensitiveKey(_ key: String) -> Bool {
    let normalized = key.lowercased()
    return ["authorization", "credential", "password", "secret", "token"]
      .contains { normalized.contains($0) }
  }

  private static func redactedString(_ value: String) -> String {
    let patterns = [
      #"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#,
      #"(?i)((?:api[_-]?key|token|credential|password|secret)\s*[=:]\s*)[^\s,;]+"#,
    ]
    let redacted = patterns.reduce(value) { current, pattern in
      guard let expression = try? NSRegularExpression(pattern: pattern) else {
        return current
      }
      let range = NSRange(current.startIndex..<current.endIndex, in: current)
      return expression.stringByReplacingMatches(
        in: current,
        range: range,
        withTemplate: "$1[REDACTED]"
      )
    }
    return redacted
  }
}
