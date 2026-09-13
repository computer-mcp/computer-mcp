import Foundation

/// Host-owned approval tools. Requester identity comes from the gateway connection.
struct CodexElevationTools: GatewayToolProvider {
  let id = "codex-elevation"
  let owner: CodexRuntimeOwner?
  let database: GatewayDatabase?

  func listTools() throws -> [MCPTool] { Self.tools }

  func capability(for tool: MCPTool) -> CapabilityDescriptor {
    CapabilityDescriptor(
      id: tool.name,
      risk: Self.readOnlyNames.contains(tool.name) ? .readOnly : .workspaceWrite,
      workspaceRequirement: .required,
      localOnly: tool.name == "codex.app.elevation.approve"
        || tool.name == "codex.app.elevation.deny",
      usesNetwork: true)
  }

  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    let object = arguments?.objectValue ?? [:]
    let result: JSONValue
    do {
      switch name {
      case "codex.app.elevation.request":
        let modeValue = try Self.requiredString("mode", in: object)
        guard let mode = CodexElevationGrantMode(rawValue: modeValue) else {
          throw GatewayToolError.invalidArguments(
            "codex.app.elevation_mode_invalid: Use next-turn, thread-scoped-ttl, or bounded-time."
          )
        }
        let threadID = try Self.optionalString("thread_id", in: object).map {
          try Self.validatedIdentifier($0, key: "thread_id")
        }
        let grant = try CodexElevationGrantService.request(
          owner: owner,
          database: database,
          threadID: threadID,
          mode: mode,
          reason: try Self.requiredString("reason", in: object),
          maximumDurationSeconds: try Self.boundedInt(
            "maximum_duration_seconds",
            in: object,
            default: 300,
            range: 30...3_600
          ),
          maximumTurnCount: try Self.optionalBoundedInt(
            "maximum_turn_count",
            in: object,
            range: 1...100
          )
        )
        let effective = try effectiveElevation(owner: owner, threadID: threadID)
        result = .object([
          "grant": try reviewedElevationGrant(grant),
          "effective_sandbox": effectiveSandbox(from: effective),
          "effective": effective,
          "local_approval_required": .bool(true),
        ])
      case "codex.app.elevation.list":
        let requestedState = try Self.optionalString("state", in: object)
        let state = try requestedState.map { rawValue in
          guard let state = CodexElevationGrantState(rawValue: rawValue) else {
            throw GatewayToolError.invalidArguments(
              "codex.app.elevation_state_invalid: Unknown elevation state '\(rawValue)'."
            )
          }
          return state
        }
        let grants = try CodexElevationGrantService.visibleGrants(
          owner: owner,
          database: database,
          state: state,
          limit: try Self.boundedInt("limit", in: object, default: 100, range: 1...1_000)
        )
        result = .object([
          "grants": .array(try grants.map(reviewedElevationGrant))
        ])
      case "codex.app.elevation.read":
        result = .object([
          "grant": try reviewedElevationGrant(
            CodexElevationGrantService.read(
              id: Self.requiredIdentifier("grant_id", in: object),
              owner: owner,
              database: database
            )
          )
        ])
      case "codex.app.elevation.approve":
        let grant = try CodexElevationGrantService.approve(
          id: Self.requiredIdentifier("grant_id", in: object),
          owner: owner,
          database: database
        )
        let effective = try effectiveElevation(for: grant)
        result = .object([
          "grant": try reviewedElevationGrant(grant),
          "active_turn_unchanged": .bool(true),
          "effective_next_eligible_start": .bool(
            effectiveSandbox(from: effective) == .string("danger-full-access")
          ),
          "effective": effective,
        ])
      case "codex.app.elevation.deny":
        let grant = try CodexElevationGrantService.deny(
          id: Self.requiredIdentifier("grant_id", in: object),
          owner: owner,
          database: database
        )
        result = .object([
          "grant": try reviewedElevationGrant(grant),
          "effective": try effectiveElevation(for: grant),
        ])
      case "codex.app.elevation.revoke":
        let grant = try CodexElevationGrantService.revoke(
          id: Self.requiredIdentifier("grant_id", in: object),
          owner: owner,
          database: database
        )
        let effective = try effectiveElevation(for: grant)
        result = .object([
          "grant": try reviewedElevationGrant(grant),
          "active_turn_unchanged": .bool(true),
          "effective_next_turn": effectiveSandbox(from: effective),
          "effective": effective,
        ])
      case "codex.app.elevation.effective":
        let threadID = try Self.optionalString("thread_id", in: object).map {
          try Self.validatedIdentifier($0, key: "thread_id")
        }
        result = try CodexElevationGrantService.effective(
          owner: owner,
          database: database,
          threadID: threadID
        )
      default:
        throw GatewayToolError.unknownTool(name)
      }
    } catch let error as GatewayToolError {
      throw error
    } catch {
      throw GatewayToolError.executionFailed(
        CodexApprovalRedactor.redactString(error.localizedDescription))
    }
    return try Self.resultEnvelope(result)
  }

  func shutdown() async {
    if let connectionID = owner?.elevationConnectionID {
      _ = try? database?.invalidateCodexElevationGrants(
        workspaceID: owner?.workspaceID,
        profileID: owner?.profileID,
        requestingConnectionID: connectionID,
        reason: "The bound gateway connection closed."
      )
    }
  }

  private func effectiveElevation(
    owner: CodexRuntimeOwner?,
    threadID: String?
  ) throws -> JSONValue {
    try CodexElevationGrantService.effective(
      owner: owner,
      database: database,
      threadID: threadID
    )
  }

  private func effectiveElevation(for grant: CodexElevationGrantRecord) throws -> JSONValue {
    try effectiveElevation(
      owner: CodexRuntimeOwner(
        workspaceID: grant.workspaceID,
        profileID: grant.profileID,
        caller: grant.requestingCaller,
        transport: nil,
        socketConnectionID: grant.requestingConnectionID,
        tunnelInstanceID: nil,
        tunnelProfileID: nil
      ),
      threadID: grant.threadID
    )
  }

  private func reviewedElevationGrant(_ grant: CodexElevationGrantRecord) throws -> JSONValue {
    try CodexElevationGrantService.reviewedJSON(grant, database: database)
  }

  private func effectiveSandbox(from effective: JSONValue) -> JSONValue {
    effective.objectValue?["effective_sandbox"]
      ?? .null
  }

  private static func requiredString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard let value = object[key]?.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= 1_048_576
    else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_required: '\(key)' must be a non-empty string."
      )
    }
    return value
  }

  private static func requiredIdentifier(
    _ key: String,
    in object: [String: JSONValue],
    maximumBytes: Int = 1_024
  ) throws -> String {
    try validatedIdentifier(
      requiredString(key, in: object),
      key: key,
      maximumBytes: maximumBytes
    )
  }

  private static func validatedIdentifier(
    _ value: String,
    key: String,
    maximumBytes: Int = 1_024
  ) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count <= maximumBytes,
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
      CodexApprovalRedactor.redactString(trimmed, maximumCharacters: 8_192) == trimmed
    else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be a bounded opaque identifier."
      )
    }
    return trimmed
  }

  private static func optionalString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String? {
    guard let raw = object[key] else { return nil }
    guard let value = raw.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= 1_048_576
    else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be a non-empty string when provided."
      )
    }
    return value
  }

  private static func boundedInt(
    _ key: String,
    in object: [String: JSONValue],
    default defaultValue: Int,
    range: ClosedRange<Int>
  ) throws -> Int {
    let value: Int
    if let raw = object[key] {
      guard let supplied = raw.intValue else {
        throw GatewayToolError.invalidArguments(
          "codex.argument_invalid: '\(key)' must be an integer between \(range.lowerBound) and \(range.upperBound)."
        )
      }
      value = supplied
    } else {
      value = defaultValue
    }
    guard range.contains(value) else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be between \(range.lowerBound) and \(range.upperBound)."
      )
    }
    return value
  }

  private static func optionalBoundedInt(
    _ key: String,
    in object: [String: JSONValue],
    range: ClosedRange<Int>
  ) throws -> Int? {
    guard let raw = object[key] else { return nil }
    guard let value = raw.intValue, range.contains(value) else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be an integer between \(range.lowerBound) and \(range.upperBound)."
      )
    }
    return value
  }

  private static func resultEnvelope(_ value: JSONValue) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let text = String(decoding: try encoder.encode(value), as: UTF8.self)
    return .object([
      "content": .array([
        .object([
          "type": .string("text"),
          "text": .string(text),
        ])
      ]),
      "structuredContent": .object(["result": value]),
      "isError": .bool(false),
    ])
  }

  private static let tools: [MCPTool] = [
    tool(
      "codex.app.elevation.request",
      "Request a locally approved, workspace/profile/caller-bound danger-full-access grant. The request does not change the current turn or effective sandbox.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "mode": .object([
            "type": .string("string"),
            "enum": .array(CodexElevationGrantMode.allCases.map { .string($0.rawValue) }),
          ]),
          "reason": stringSchema(),
          "maximum_duration_seconds": integerSchema(minimum: 30, maximum: 3_600),
          "maximum_turn_count": integerSchema(minimum: 1, maximum: 100),
        ],
        required: ["mode", "reason"]
      ),
      write: true
    ),
    tool(
      "codex.app.elevation.list",
      "List redacted scoped-elevation receipts visible to the bound requester or local administrator.",
      objectSchema(
        properties: [
          "state": stringSchema(),
          "limit": integerSchema(minimum: 1, maximum: 1_000),
        ]
      )
    ),
    tool(
      "codex.app.elevation.read",
      "Read one redacted scoped-elevation receipt visible to the bound requester or local administrator.",
      objectSchema(properties: ["grant_id": stringSchema()], required: ["grant_id"])
    ),
    tool(
      "codex.app.elevation.approve",
      "Locally approve an exact pending elevation request. Approval affects only a future eligible thread/turn start and never hot-switches an active turn.",
      objectSchema(properties: ["grant_id": stringSchema()], required: ["grant_id"]),
      write: true
    ),
    tool(
      "codex.app.elevation.deny",
      "Locally deny an exact pending elevation request.",
      objectSchema(properties: ["grant_id": stringSchema()], required: ["grant_id"]),
      write: true
    ),
    tool(
      "codex.app.elevation.revoke",
      "Revoke a bound elevation grant. The active turn remains unchanged and future turns return to the configured safe sandbox.",
      objectSchema(properties: ["grant_id": stringSchema()], required: ["grant_id"]),
      write: true
    ),
    tool(
      "codex.app.elevation.effective",
      "Report requested and effective Codex sandbox state for a future eligible start without changing runtime state.",
      objectSchema(properties: ["thread_id": stringSchema()])
    ),
  ]

  private static let readOnlyNames: Set<String> = [
    "codex.app.elevation.list", "codex.app.elevation.read", "codex.app.elevation.effective",
  ]

  private static func tool(
    _ name: String, _ description: String, _ inputSchema: JSONValue, write: Bool = false
  ) -> MCPTool {
    MCPTool(
      name: name, description: description, inputSchema: inputSchema,
      outputSchema: MCPTool.resultEnvelopeSchema,
      annotations: .init(
        readOnlyHint: !write, destructiveHint: false, idempotentHint: !write, openWorldHint: write))
  }

  private static func objectSchema(
    properties: [String: JSONValue] = [:],
    required: [String] = []
  ) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("object"),
      "properties": .object(properties),
      "additionalProperties": .bool(false),
    ]
    if !required.isEmpty {
      schema["required"] = .array(required.map(JSONValue.string))
    }
    return .object(schema)
  }

  private static func stringSchema() -> JSONValue {
    .object([
      "type": .string("string"),
      "minLength": .number(1),
      "maxLength": .number(1_048_576),
    ])
  }

  private static func integerSchema(minimum: Int, maximum: Int? = nil) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("integer"),
      "minimum": .number(Double(minimum)),
    ]
    if let maximum {
      schema["maximum"] = .number(Double(maximum))
    }
    return .object(schema)
  }
}
