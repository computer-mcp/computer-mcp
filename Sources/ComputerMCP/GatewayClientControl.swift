import Foundation

/// Local presentation delegates to the owner of the selected connection.
enum GatewayClientControl: Sendable {
  case app(AppControlPlaneOperations)
  case http(GatewayHTTPApp, generation: UUID)

  static let contracts: [ControlToolContract] = [
    .init(
      "clients.list", arguments: ["id": .string, "after_id": .string, "limit": .integer],
      readOnly: true),
    .init(
      "clients.trusts", arguments: ["id": .string, "after_id": .string, "limit": .integer],
      readOnly: true),
    .init(
      "clients.allow",
      arguments: [
        "id": .string, "full_access": .boolean, "always_allow_client": .boolean,
        "expected_revision": .integer, "expected_trust_revision": .integer,
      ], required: ["id", "full_access", "expected_revision", "expected_trust_revision"],
      readOnly: false),
    .init(
      "clients.limit", arguments: ["id": .string, "mode": .string, "expected_revision": .integer],
      required: ["id", "mode", "expected_revision"], readOnly: false),
    .init(
      "clients.end", arguments: ["id": .string, "expected_revision": .integer],
      required: ["id", "expected_revision"], readOnly: false),
    .init(
      "clients.revoke", arguments: ["id": .string, "expected_revision": .integer],
      required: ["id", "expected_revision"], readOnly: false),
  ]

  func call(name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
    switch name {
    case "clients.list":
      let sessions = try await sessions()
      let trusts = try await trusts()
      return try page(sessions, key: "sessions", arguments: arguments) { session in
        var row = try ControlToolResponse.encodedPayload(session).objectValue ?? [:]
        row["trust_revision"] = .integer(
          trusts.first {
            $0.principalID == session.principalID && $0.profileID == session.profileID
              && $0.caller == session.caller
          }?.revision ?? 0)
        return .object(row)
      }
    case "clients.trusts":
      return try await page(trusts(), key: "trusts", arguments: arguments) {
        try ControlToolResponse.encodedPayload($0)
      }
    case "clients.allow":
      guard arguments["full_access"]?.boolValue == true else {
        throw GatewayToolError.invalidArguments("Full Access requires full_access: true.")
      }
      let id = try string("id", arguments)
      let lifetime: GatewayFullAccessLifetime =
        arguments["always_allow_client"]?.boolValue == true
        ? .alwaysAllowClient : .thisSession
      let revision = try revision("expected_revision", arguments)
      let trustRevision = try self.revision("expected_trust_revision", arguments)
      let snapshot: GatewayControlSessionSnapshot
      switch self {
      case .app(let owner):
        snapshot = try await owner.approveControlSession(
          id: id, lifetime: lifetime, expectedRevision: revision,
          expectedTrustRevision: trustRevision, enableShellFacility: true, approver: .localCLI)
      case .http(let owner, let generation):
        snapshot = try await owner.approveLocalControlSession(
          id: id, lifetime: lifetime, expectedRevision: revision,
          expectedTrustRevision: trustRevision, generation: generation)
      }
      return try ControlToolResponse.encodedPayload(snapshot)
    case "clients.limit":
      let id = try string("id", arguments)
      let revision = try revision("expected_revision", arguments)
      let mode: GatewayPermissionMode
      switch try string("mode", arguments) {
      case "observe": mode = .readOnly
      case "restricted": mode = .workspaceOperations
      default: throw GatewayToolError.invalidArguments("mode must be observe or restricted.")
      }
      let snapshot: GatewayControlSessionSnapshot
      switch self {
      case .app(let owner):
        snapshot = try await owner.limitControlSession(id: id, to: mode, expectedRevision: revision)
      case .http(let owner, let generation):
        snapshot = try await owner.limitLocalControlSession(
          id: id, to: mode, expectedRevision: revision, generation: generation)
      }
      return try ControlToolResponse.encodedPayload(snapshot)
    case "clients.end":
      let id = try string("id", arguments)
      let revision = try revision("expected_revision", arguments)
      switch self {
      case .app(let owner): try await owner.endControlSession(id: id, expectedRevision: revision)
      case .http(let owner, let generation):
        try await owner.endLocalControlSession(
          id: id, expectedRevision: revision, generation: generation)
      }
      return .object(["ended": .string(id)])
    case "clients.revoke":
      let id = try string("id", arguments)
      let revision = try revision("expected_revision", arguments)
      switch self {
      case .app(let owner):
        try owner.revokeClientTrust(id: id, expectedRevision: revision, approver: .localCLI)
      case .http(let owner, let generation):
        try await owner.revokeLocalClientTrust(
          id: id, expectedRevision: revision, generation: generation)
      }
      return .object(["revoked": .string(id)])
    default: throw GatewayToolError.unknownTool(name)
    }
  }

  private func sessions() async throws -> [GatewayControlSessionSnapshot] {
    switch self {
    case .app(let owner): await owner.controlSessions()
    case .http(let owner, let generation):
      try await owner.localControlSessions(generation: generation)
    }
  }

  private func trusts() async throws -> [GatewayClientTrust] {
    switch self {
    case .app(let owner): try owner.clientTrusts()
    case .http(let owner, let generation): try await owner.localClientTrusts(generation: generation)
    }
  }

  private func string(_ key: String, _ arguments: [String: JSONValue]) throws -> String {
    guard let value = arguments[key]?.stringValue, !value.isEmpty else {
      throw GatewayToolError.invalidArguments("Missing non-empty '\(key)'.")
    }
    return value
  }

  private func revision(_ key: String, _ arguments: [String: JSONValue]) throws -> Int64 {
    guard let value = arguments[key]?.intValue, value >= 0 else {
      throw GatewayToolError.invalidArguments("\(key) must be a non-negative integer.")
    }
    return Int64(value)
  }

  private func page<T: Identifiable>(
    _ values: [T], key: String, arguments: [String: JSONValue], encode: (T) throws -> JSONValue
  ) throws -> JSONValue where T.ID == String {
    let limit = arguments["limit"]?.intValue ?? 100
    guard (1...200).contains(limit) else {
      throw GatewayToolError.invalidArguments("limit must be between 1 and 200.")
    }
    let id = arguments["id"]?.stringValue
    let after = arguments["after_id"]?.stringValue
    let selected = values.filter { row in
      (id == nil || row.id == id) && (after.map { row.id > $0 } ?? true)
    }
    .sorted { $0.id < $1.id }
    let rows = selected.prefix(limit)
    return .object([
      key: .array(try rows.map(encode)),
      "next_after_id": selected.count > limit ? rows.last.map { .string($0.id) } ?? .null : .null,
    ])
  }
}
