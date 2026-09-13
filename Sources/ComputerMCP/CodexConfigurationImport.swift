import Foundation

/// Decodes and preserves the embedded provider's configuration for offline export.
package struct CodexConfigurationImport: Codable, Equatable, Sendable {
  package var enabled: Bool
  package var executable: String
  package var appServerEnabled: Bool
  package var execEnabled: Bool
  package var mcpEnabled: Bool
  package var experimentalAPI: Bool
  package var appServerRequestTimeoutSeconds: Int
  package var appServerAppListTimeoutSeconds: Int
  package var appServerTerminationGraceMilliseconds: Int
  package var appServerKillGraceMilliseconds: Int
  package var appServerApprovalTimeoutSeconds: Int
  package var appServerAutoApproveWorkspaceWrites: Bool
  package var sandbox: CodexSandboxMode
  package var approvalPolicy: CodexApprovalPolicy
  package var maxSessions: Int
  package var maxEventsPerSession: Int

  package init(
    enabled: Bool = false,
    executable: String = "codex",
    appServerEnabled: Bool = true,
    execEnabled: Bool = true,
    mcpEnabled: Bool = true,
    experimentalAPI: Bool = true,
    appServerRequestTimeoutSeconds: Int = 30,
    appServerAppListTimeoutSeconds: Int = 120,
    appServerTerminationGraceMilliseconds: Int = 1_000,
    appServerKillGraceMilliseconds: Int = 2_000,
    appServerApprovalTimeoutSeconds: Int = 300,
    appServerAutoApproveWorkspaceWrites: Bool = false,
    sandbox: CodexSandboxMode = .workspaceWrite,
    approvalPolicy: CodexApprovalPolicy = .never,
    maxSessions: Int = 8,
    maxEventsPerSession: Int = 1_024
  ) {
    self.enabled = enabled
    self.executable = executable
    self.appServerEnabled = appServerEnabled
    self.execEnabled = execEnabled
    self.mcpEnabled = mcpEnabled
    self.experimentalAPI = experimentalAPI
    self.appServerRequestTimeoutSeconds = appServerRequestTimeoutSeconds
    self.appServerAppListTimeoutSeconds = appServerAppListTimeoutSeconds
    self.appServerTerminationGraceMilliseconds = appServerTerminationGraceMilliseconds
    self.appServerKillGraceMilliseconds = appServerKillGraceMilliseconds
    self.appServerApprovalTimeoutSeconds = appServerApprovalTimeoutSeconds
    self.appServerAutoApproveWorkspaceWrites = appServerAutoApproveWorkspaceWrites
    self.sandbox = sandbox
    self.approvalPolicy = approvalPolicy
    self.maxSessions = maxSessions
    self.maxEventsPerSession = maxEventsPerSession
  }

  private enum CodingKeys: String, CodingKey {
    case enabled
    case executable
    case appServerEnabled = "app_server_enabled"
    case execEnabled = "exec_enabled"
    case mcpEnabled = "mcp_enabled"
    case experimentalAPI = "experimental_api"
    case appServerRequestTimeoutSeconds = "app_server_request_timeout_seconds"
    case appServerAppListTimeoutSeconds = "app_server_app_list_timeout_seconds"
    case appServerTerminationGraceMilliseconds = "app_server_termination_grace_milliseconds"
    case appServerKillGraceMilliseconds = "app_server_kill_grace_milliseconds"
    case appServerApprovalTimeoutSeconds = "app_server_approval_timeout_seconds"
    case appServerAutoApproveWorkspaceWrites = "app_server_auto_approve_workspace_writes"
    case sandbox
    case approvalPolicy = "approval_policy"
    case maxSessions = "max_sessions"
    case maxEventsPerSession = "max_events_per_session"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    executable = try container.decodeIfPresent(String.self, forKey: .executable) ?? "codex"
    appServerEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .appServerEnabled) ?? true
    execEnabled = try container.decodeIfPresent(Bool.self, forKey: .execEnabled) ?? true
    mcpEnabled = try container.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? true
    experimentalAPI =
      try container.decodeIfPresent(Bool.self, forKey: .experimentalAPI) ?? true
    appServerRequestTimeoutSeconds =
      try container.decodeIfPresent(Int.self, forKey: .appServerRequestTimeoutSeconds) ?? 30
    appServerAppListTimeoutSeconds =
      try container.decodeIfPresent(Int.self, forKey: .appServerAppListTimeoutSeconds) ?? 120
    appServerTerminationGraceMilliseconds =
      try container.decodeIfPresent(Int.self, forKey: .appServerTerminationGraceMilliseconds)
      ?? 1_000
    appServerKillGraceMilliseconds =
      try container.decodeIfPresent(Int.self, forKey: .appServerKillGraceMilliseconds) ?? 2_000
    appServerApprovalTimeoutSeconds =
      try container.decodeIfPresent(Int.self, forKey: .appServerApprovalTimeoutSeconds) ?? 300
    appServerAutoApproveWorkspaceWrites =
      try container.decodeIfPresent(Bool.self, forKey: .appServerAutoApproveWorkspaceWrites)
      ?? false
    sandbox =
      try container.decodeIfPresent(CodexSandboxMode.self, forKey: .sandbox)
      ?? .workspaceWrite
    approvalPolicy =
      try container.decodeIfPresent(CodexApprovalPolicy.self, forKey: .approvalPolicy)
      ?? .never
    maxSessions = try container.decodeIfPresent(Int.self, forKey: .maxSessions) ?? 8
    maxEventsPerSession =
      try container.decodeIfPresent(Int.self, forKey: .maxEventsPerSession) ?? 1_024
  }

  package func validate() throws {
    guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ConfigurationError.invalid("codex.executable must not be empty.")
    }
    guard maxSessions > 0 && maxSessions <= 64 else {
      throw ConfigurationError.invalid("codex.max_sessions must be between 1 and 64.")
    }
    guard appServerRequestTimeoutSeconds >= 1 && appServerRequestTimeoutSeconds <= 300 else {
      throw ConfigurationError.invalid(
        "codex.app_server_request_timeout_seconds must be between 1 and 300."
      )
    }
    guard appServerAppListTimeoutSeconds >= 1 && appServerAppListTimeoutSeconds <= 300 else {
      throw ConfigurationError.invalid(
        "codex.app_server_app_list_timeout_seconds must be between 1 and 300."
      )
    }
    guard
      appServerTerminationGraceMilliseconds >= 0
        && appServerTerminationGraceMilliseconds <= 30_000
    else {
      throw ConfigurationError.invalid(
        "codex.app_server_termination_grace_milliseconds must be between 0 and 30000."
      )
    }
    guard appServerKillGraceMilliseconds >= 100 && appServerKillGraceMilliseconds <= 30_000 else {
      throw ConfigurationError.invalid(
        "codex.app_server_kill_grace_milliseconds must be between 100 and 30000."
      )
    }
    guard appServerApprovalTimeoutSeconds >= 1 && appServerApprovalTimeoutSeconds <= 3_600 else {
      throw ConfigurationError.invalid(
        "codex.app_server_approval_timeout_seconds must be between 1 and 3600."
      )
    }
    guard maxEventsPerSession >= 64 && maxEventsPerSession <= 16_384 else {
      throw ConfigurationError.invalid(
        "codex.max_events_per_session must be between 64 and 16384."
      )
    }
    if enabled && !appServerEnabled && !execEnabled && !mcpEnabled {
      throw ConfigurationError.invalid(
        "At least one Codex path must be enabled when [codex].enabled is true."
      )
    }
    guard sandbox != .dangerFullAccess else {
      throw ConfigurationError.invalid(
        "codex.sandbox cannot be danger-full-access."
      )
    }
  }

}

package enum CodexSandboxMode: String, Codable, Equatable, Sendable {
  case readOnly = "read-only"
  case workspaceWrite = "workspace-write"
  case dangerFullAccess = "danger-full-access"
}

package enum CodexApprovalPolicy: String, Codable, Equatable, Sendable {
  case untrusted
  case onFailure = "on-failure"
  case onRequest = "on-request"
  case never
}
