import Foundation

enum CodexElevationGrantMode: String, Codable, CaseIterable, Sendable {
  case nextTurn = "next-turn"
  case threadScopedTTL = "thread-scoped-ttl"
  case boundedTime = "bounded-time"
}

enum CodexElevationGrantState: String, Codable, Sendable {
  case pending
  case approved
  case active
  case denied
  case revoked
  case expired
  case consumed
  case invalidated

  var isEffective: Bool {
    self == .approved || self == .active
  }
}

enum CodexElevationAction: String, Codable, Sendable {
  case threadStart = "thread-start"
  case turnStart = "turn-start"
}

struct CodexElevationGrantRecord: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let workspaceID: String
  let canonicalRoot: String
  let profileID: String
  let requestingCaller: String
  let requestingConnectionID: String?
  var threadID: String?
  let requestedSandbox: String
  let reason: String
  let mode: CodexElevationGrantMode
  let createdAt: Date
  let requestExpiresAt: Date
  let maximumDurationSeconds: Int
  let maximumTurnCount: Int?
  let requestCorrelationID: String
  var state: CodexElevationGrantState
  var localApprovedAt: Date?
  var activationAt: Date?
  var expiresAt: Date?
  var revokedAt: Date?
  var resolvedAt: Date?
  var resolutionReason: String?
  var approvalCorrelationID: String?
  var localApproverCaller: String?
  var consumedTurnCount: Int
  var consumedRuntimeIDs: [String]
  var consumedTurnIDs: [String]
  var inFlightClaimID: String?
  var inFlightAction: CodexElevationAction?
  var updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case id
    case workspaceID = "workspace_id"
    case canonicalRoot = "canonical_root"
    case profileID = "profile_id"
    case requestingCaller = "requesting_caller"
    case requestingConnectionID = "requesting_connection_id"
    case threadID = "thread_id"
    case requestedSandbox = "requested_sandbox"
    case reason
    case mode
    case createdAt = "created_at"
    case requestExpiresAt = "request_expires_at"
    case maximumDurationSeconds = "maximum_duration_seconds"
    case maximumTurnCount = "maximum_turn_count"
    case requestCorrelationID = "request_correlation_id"
    case state
    case localApprovedAt = "local_approved_at"
    case activationAt = "activation_at"
    case expiresAt = "expires_at"
    case revokedAt = "revoked_at"
    case resolvedAt = "resolved_at"
    case resolutionReason = "resolution_reason"
    case approvalCorrelationID = "approval_correlation_id"
    case localApproverCaller = "local_approver_caller"
    case consumedTurnCount = "consumed_turn_count"
    case consumedRuntimeIDs = "consumed_runtime_ids"
    case consumedTurnIDs = "consumed_turn_ids"
    case inFlightClaimID = "in_flight_claim_id"
    case inFlightAction = "in_flight_action"
    case updatedAt = "updated_at"
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

struct CodexElevationClaim: Sendable {
  let id: String
  let action: CodexElevationAction
  let grant: CodexElevationGrantRecord
}

enum CodexElevationGrantError: Error, LocalizedError, Sendable, Equatable {
  case persistenceUnavailable
  case missingRuntimeBinding
  case unknown(String)
  case invalidMode(String)
  case invalidDuration
  case invalidTurnCount
  case threadRequired
  case requestExpired
  case alreadyResolved(String)
  case localApprovalRequired
  case requesterMismatch
  case claimMismatch

  var errorDescription: String? {
    switch self {
    case .persistenceUnavailable:
      return "Scoped Codex elevation requires the Gateway Database."
    case .missingRuntimeBinding:
      return "Scoped Codex elevation requires workspace, profile, caller, and connection bindings."
    case .unknown(let id):
      return "Unknown Codex elevation grant '\(id)'."
    case .invalidMode(let mode):
      return "Unsupported Codex elevation mode '\(mode)'."
    case .invalidDuration:
      return "maximum_duration_seconds must be between 30 and 3600."
    case .invalidTurnCount:
      return "maximum_turn_count must be between 1 and 100."
    case .threadRequired:
      return "thread-scoped-ttl requires an exact thread_id."
    case .requestExpired:
      return "The elevation request expired before local approval."
    case .alreadyResolved(let state):
      return "The elevation grant is already in terminal state '\(state)'."
    case .localApprovalRequired:
      return "Elevation approval and denial require the local-admin profile and a local caller."
    case .requesterMismatch:
      return "Only the bound requester or a local administrator may revoke this grant."
    case .claimMismatch:
      return "The elevation activation claim no longer matches the durable grant."
    }
  }
}

enum CodexElevationGrantService {
  static func request(
    owner: CodexRuntimeOwner?,
    database: GatewayDatabase?,
    threadID: String?,
    mode: CodexElevationGrantMode,
    reason: String,
    maximumDurationSeconds: Int,
    maximumTurnCount: Int?,
    now: Date = Date()
  ) throws -> CodexElevationGrantRecord {
    guard let database else { throw CodexElevationGrantError.persistenceUnavailable }
    guard let workspaceID = owner?.workspaceID, let profileID = owner?.profileID,
      let caller = owner?.caller, let connectionID = owner?.elevationConnectionID
    else {
      throw CodexElevationGrantError.missingRuntimeBinding
    }
    guard (30...3_600).contains(maximumDurationSeconds) else {
      throw CodexElevationGrantError.invalidDuration
    }
    if let maximumTurnCount, !(1...100).contains(maximumTurnCount) {
      throw CodexElevationGrantError.invalidTurnCount
    }
    if mode == .threadScopedTTL, threadID == nil {
      throw CodexElevationGrantError.threadRequired
    }
    let workspace = try database.workspace(id: workspaceID)
    guard let workspace else { throw CodexElevationGrantError.missingRuntimeBinding }
    let root = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
    let boundedReason = CodexApprovalRedactor.redactString(reason, maximumCharacters: 2_048)
    let record = CodexElevationGrantRecord(
      id: UUID().uuidString,
      workspaceID: workspaceID,
      canonicalRoot: root,
      profileID: profileID,
      requestingCaller: caller,
      requestingConnectionID: connectionID,
      threadID: threadID,
      requestedSandbox: "danger-full-access",
      reason: boundedReason,
      mode: mode,
      createdAt: now,
      requestExpiresAt: now.addingTimeInterval(900),
      maximumDurationSeconds: maximumDurationSeconds,
      maximumTurnCount: mode == .nextTurn ? 1 : maximumTurnCount,
      requestCorrelationID: UUID().uuidString,
      state: .pending,
      localApprovedAt: nil,
      activationAt: nil,
      expiresAt: nil,
      revokedAt: nil,
      resolvedAt: nil,
      resolutionReason: nil,
      approvalCorrelationID: nil,
      localApproverCaller: nil,
      consumedTurnCount: 0,
      consumedRuntimeIDs: [],
      consumedTurnIDs: [],
      inFlightClaimID: nil,
      inFlightAction: nil,
      updatedAt: now
    )
    try database.saveCodexElevationGrant(record)
    return record
  }

  static func approve(
    id: String,
    owner: CodexRuntimeOwner?,
    database: GatewayDatabase?,
    now: Date = Date()
  ) throws -> CodexElevationGrantRecord {
    guard let database else { throw CodexElevationGrantError.persistenceUnavailable }
    try requireLocalAdministrator(owner)
    try database.reconcileCodexElevationGrants(now: now)
    guard let current = try database.codexElevationGrant(id: id) else {
      throw CodexElevationGrantError.unknown(id)
    }
    guard current.workspaceID == owner?.workspaceID else {
      throw CodexElevationGrantError.unknown(id)
    }
    if current.requestExpiresAt <= now, current.state == .expired {
      throw CodexElevationGrantError.requestExpired
    }
    return try database.updateCodexElevationGrant(id: id) { grant in
      guard grant.state == .pending else {
        throw CodexElevationGrantError.alreadyResolved(grant.state.rawValue)
      }
      grant.state = .approved
      grant.localApprovedAt = now
      grant.expiresAt = now.addingTimeInterval(TimeInterval(grant.maximumDurationSeconds))
      grant.approvalCorrelationID = UUID().uuidString
      grant.localApproverCaller = owner?.caller
      grant.updatedAt = now
    }
  }

  static func deny(
    id: String,
    owner: CodexRuntimeOwner?,
    database: GatewayDatabase?,
    now: Date = Date()
  ) throws -> CodexElevationGrantRecord {
    guard let database else { throw CodexElevationGrantError.persistenceUnavailable }
    try requireLocalAdministrator(owner)
    try database.reconcileCodexElevationGrants(now: now)
    return try database.updateCodexElevationGrant(id: id) { grant in
      guard grant.workspaceID == owner?.workspaceID else {
        throw CodexElevationGrantError.unknown(id)
      }
      guard grant.state == .pending else {
        throw CodexElevationGrantError.alreadyResolved(grant.state.rawValue)
      }
      grant.state = .denied
      grant.resolvedAt = now
      grant.resolutionReason = "Denied by a local administrator."
      grant.approvalCorrelationID = UUID().uuidString
      grant.localApproverCaller = owner?.caller
      grant.updatedAt = now
    }
  }

  static func revoke(
    id: String,
    owner: CodexRuntimeOwner?,
    database: GatewayDatabase?,
    now: Date = Date()
  ) throws -> CodexElevationGrantRecord {
    guard let database else { throw CodexElevationGrantError.persistenceUnavailable }
    try database.reconcileCodexElevationGrants(now: now)
    return try database.updateCodexElevationGrant(id: id) { grant in
      if isLocalAdministrator(owner), grant.workspaceID != owner?.workspaceID {
        throw CodexElevationGrantError.unknown(id)
      }
      let localAdmin = isLocalAdministrator(owner) && grant.workspaceID == owner?.workspaceID
      let requester =
        grant.workspaceID == owner?.workspaceID
        && grant.profileID == owner?.profileID
        && grant.requestingCaller == owner?.caller
        && grant.requestingConnectionID == owner?.elevationConnectionID
      guard localAdmin || requester else { throw CodexElevationGrantError.requesterMismatch }
      guard grant.state.isEffective || grant.state == .pending else {
        throw CodexElevationGrantError.alreadyResolved(grant.state.rawValue)
      }
      grant.state = .revoked
      grant.revokedAt = now
      grant.resolvedAt = now
      grant.resolutionReason = "Revoked. Future turns use the configured safe sandbox."
      grant.inFlightClaimID = nil
      grant.inFlightAction = nil
      grant.updatedAt = now
    }
  }

  static func visibleGrants(
    owner: CodexRuntimeOwner?,
    database: GatewayDatabase?,
    state: CodexElevationGrantState? = nil,
    limit: Int = 100,
    now: Date = Date()
  ) throws -> [CodexElevationGrantRecord] {
    guard let database else { throw CodexElevationGrantError.persistenceUnavailable }
    try database.reconcileCodexElevationGrants(now: now)
    let isAdmin = isLocalAdministrator(owner)
    return try database.codexElevationGrants(
      workspaceID: owner?.workspaceID,
      state: state,
      limit: limit
    ).filter {
      isAdmin
        || ($0.profileID == owner?.profileID && $0.requestingCaller == owner?.caller
          && $0.requestingConnectionID == owner?.elevationConnectionID)
    }
  }

  static func read(
    id: String,
    owner: CodexRuntimeOwner?,
    database: GatewayDatabase?,
    now: Date = Date()
  ) throws -> CodexElevationGrantRecord {
    guard
      let record = try visibleGrants(owner: owner, database: database, limit: 5_000, now: now)
        .first(where: { $0.id == id })
    else {
      throw CodexElevationGrantError.unknown(id)
    }
    return record
  }

  static func effective(
    owner: CodexRuntimeOwner?,
    database: GatewayDatabase?,
    threadID: String?,
    configuredSandbox: CodexSandboxMode,
    now: Date = Date()
  ) throws -> JSONValue {
    let grants = try visibleGrants(owner: owner, database: database, limit: 5_000, now: now)
      .filter {
        $0.profileID == owner?.profileID
          && $0.requestingCaller == owner?.caller
          && $0.requestingConnectionID == owner?.elevationConnectionID
          && $0.state.isEffective && $0.inFlightClaimID == nil
          && ($0.threadID == nil || $0.threadID == threadID)
      }
    return .object([
      "requested_sandbox": grants.isEmpty ? .null : .string("danger-full-access"),
      "effective_sandbox": grants.isEmpty
        ? .string(configuredSandbox.rawValue) : .string("danger-full-access"),
      "effective_next_turn": .bool(!grants.isEmpty),
      "active_turn_unchanged": .bool(true),
      "matching_grants": .array(grants.map(\.json)),
    ])
  }

  static func reviewedJSON(
    _ grant: CodexElevationGrantRecord,
    database: GatewayDatabase?
  ) throws -> JSONValue {
    var object = grant.json.objectValue ?? [:]
    let workspace = try database?.workspace(id: grant.workspaceID)
    object["local_approval_review"] = .object([
      "workspace": .object([
        "id": .string(grant.workspaceID),
        "display_name": workspace.map { .string($0.displayName) } ?? .null,
        "canonical_root": .string(grant.canonicalRoot),
      ]),
      "binding": .object([
        "profile_id": .string(grant.profileID),
        "caller": .string(grant.requestingCaller),
        "connection_id": grant.requestingConnectionID.map(JSONValue.string) ?? .null,
        "thread_id": grant.threadID.map(JSONValue.string) ?? .null,
        "mode": .string(grant.mode.rawValue),
        "maximum_duration_seconds": .number(Double(grant.maximumDurationSeconds)),
        "maximum_turn_count": grant.maximumTurnCount.map { .number(Double($0)) } ?? .null,
      ]),
      "impact": .object([
        "codex_filesystem_sandbox": .string("danger-full-access"),
        "network_access": .bool(true),
        "git_metadata_direct_write": .bool(true),
        "sandbox_restriction_to_registered_workspace_removed": .bool(true),
        "macos_privacy_controls_still_apply": .bool(true),
        "computer_mcp_capabilities_unchanged": .bool(true),
        "active_turn_unchanged": .bool(true),
      ]),
      "reason": .string(grant.reason),
      "revoke": .object([
        "tool": .string("codex.app.elevation.revoke"),
        "arguments": .object(["grant_id": .string(grant.id)]),
        "cli_argv": .array([
          .string("computer-mcp"),
          .string("codex"),
          .string("elevation"),
          .string("revoke"),
          .string(grant.id),
          .string("--workspace-id"),
          .string(grant.workspaceID),
        ]),
      ]),
    ])
    return .object(object)
  }

  private static func requireLocalAdministrator(_ owner: CodexRuntimeOwner?) throws {
    guard isLocalAdministrator(owner) else {
      throw CodexElevationGrantError.localApprovalRequired
    }
  }

  private static func isLocalAdministrator(_ owner: CodexRuntimeOwner?) -> Bool {
    owner?.profileID == GatewayProfileID.localAdmin.rawValue
      && [
        GatewayCallerKind.localApp.rawValue,
        GatewayCallerKind.localCLI.rawValue,
        GatewayCallerKind.localMCP.rawValue,
      ].contains(owner?.caller)
  }
}
