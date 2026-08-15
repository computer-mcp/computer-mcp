import Foundation

struct CodexGatewayProvider: GatewayToolProvider, Sendable {
  let id = "codex"

  private let configuration: CodexConfig
  private let appServer: (any CodexAppServerRuntimeProtocol)?
  private let exec: (any CodexExecRuntimeProtocol)?
  private let mcp: (any CodexMCPRuntimeProtocol)?
  private let tools: [MCPTool]

  init(
    configuration: CodexConfig,
    appServer: (any CodexAppServerRuntimeProtocol)?,
    exec: (any CodexExecRuntimeProtocol)?,
    mcp: (any CodexMCPRuntimeProtocol)?
  ) {
    self.configuration = configuration
    self.appServer = appServer
    self.exec = exec
    self.mcp = mcp
    tools = Self.makeTools(
      appServerEnabled: appServer != nil,
      execEnabled: exec != nil,
      mcpEnabled: mcp != nil
    )
  }

  init(
    configuration: CodexConfig,
    workspaceURL: URL,
    maxOutputBytes: Int = 1_048_576
  ) {
    self.init(
      configuration: configuration,
      appServer: configuration.appServerEnabled
        ? LiveCodexAppServerRuntime(
          configuration: configuration,
          workspaceURL: workspaceURL,
          maxOutputBytes: maxOutputBytes
        )
        : nil,
      exec: configuration.execEnabled
        ? LiveCodexExecRuntime(
          configuration: configuration,
          workspaceURL: workspaceURL,
          maxOutputBytes: maxOutputBytes
        )
        : nil,
      mcp: configuration.mcpEnabled
        ? LiveCodexMCPRuntime(
          configuration: configuration,
          workspaceURL: workspaceURL,
          maxOutputBytes: maxOutputBytes
        )
        : nil
    )
  }

  func listTools() throws -> [MCPTool] {
    tools
  }

  func capability(for tool: MCPTool) -> CapabilityDescriptor {
    let readOnly = Self.readOnlyToolNames.contains(tool.name)
    return CapabilityDescriptor(
      id: tool.name,
      risk: readOnly ? .readOnly : .workspaceWrite,
      workspaceRequirement: .required,
      localOnly: false,
      usesNetwork: true
    )
  }

  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    throw GatewayToolError.executionFailed(
      "codex.async_required: Codex tools require the asynchronous MCP execution path."
    )
  }

  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    let object = arguments?.objectValue ?? [:]
    let result: JSONValue
    do {
      switch name {
      case "codex.app.status":
        result = try await tryAppServer().status()
      case "codex.app.methods.list":
        result = Self.appMethodsList()
      case "codex.app.methods.describe":
        result = try Self.appMethodDescription(
          method: Self.requiredString("method", in: object)
        )
      case "codex.app.methods.call":
        result = try await tryAppServer().call(
          method: Self.requiredString("method", in: object),
          params: object["params"]
        )
      case "codex.app.thread.start":
        result = try await tryAppServer().call(
          method: "thread/start",
          params: try Self.threadStartParams(in: object)
        )
      case "codex.app.thread.list":
        result = try await tryAppServer().call(
          method: "thread/list",
          params: try Self.threadListParams(in: object)
        )
      case "codex.app.thread.read":
        result = try await tryAppServer().call(
          method: "thread/read",
          params: try Self.threadReadParams(in: object)
        )
      case "codex.app.thread.fork":
        result = try await tryAppServer().call(
          method: "thread/fork",
          params: try Self.threadForkParams(in: object)
        )
      case "codex.app.turn.start":
        result = try await tryAppServer().call(
          method: "turn/start",
          params: try turnStartParams(in: object)
        )
      case "codex.app.turn.interrupt":
        result = try await tryAppServer().call(
          method: "turn/interrupt",
          params: try Self.turnInterruptParams(in: object)
        )
      case "codex.app.review.start":
        result = try await tryAppServer().call(
          method: "review/start",
          params: try Self.reviewStartParams(in: object)
        )
      case "codex.app.models.list":
        result = try await tryAppServer().call(
          method: "model/list",
          params: try Self.modelListParams(in: object)
        )
      case "codex.app.skills.list":
        result = try await tryAppServer().call(
          method: "skills/list",
          params: try Self.skillsListParams(in: object)
        )
      case "codex.app.apps.list":
        result = try await tryAppServer().call(
          method: "app/list",
          params: try Self.appsListParams(in: object)
        )
      case "codex.app.events.read":
        result = try await tryAppServer().events(
          afterCursor: try Self.nonnegativeInt("after_cursor", in: object, default: 0),
          maxResults: try Self.boundedInt(
            "max_results",
            in: object,
            default: 100,
            range: 1...1_000
          )
        )
      case "codex.app.requests.list":
        result = try await tryAppServer().pendingRequests()
      case "codex.app.requests.respond":
        result = try await tryAppServer().respond(
          requestID: Self.requiredString("request_id", in: object),
          response: object["response"] ?? .object([:])
        )

      case "codex.exec.start":
        result = try await tryExec().start(
          prompt: Self.requiredString("prompt", in: object),
          model: Self.optionalString("model", in: object)
        )
      case "codex.exec.resume":
        result = try await tryExec().resume(
          upstreamSessionID: Self.requiredString("upstream_session_id", in: object),
          prompt: Self.optionalString("prompt", in: object)
        )
      case "codex.exec.list":
        result = try await tryExec().list()
      case "codex.exec.events":
        result = try await tryExec().events(
          sessionID: Self.requiredString("session_id", in: object),
          afterCursor: Self.nonnegativeInt("after_cursor", in: object, default: 0),
          maxResults: Self.boundedInt(
            "max_results",
            in: object,
            default: 100,
            range: 1...1_000
          )
        )
      case "codex.exec.result":
        result = try await tryExec().result(
          sessionID: Self.requiredString("session_id", in: object)
        )
      case "codex.exec.cancel":
        result = try await tryExec().cancel(
          sessionID: Self.requiredString("session_id", in: object)
        )

      case "codex.mcp.status":
        result = try await tryMCP().status()
      case "codex.mcp.tools.list":
        result = try await tryMCP().tools()
      case "codex.mcp.run":
        result = try await tryMCP().run(
          prompt: Self.requiredString("prompt", in: object),
          model: Self.optionalString("model", in: object)
        )
      case "codex.mcp.reply":
        result = try await tryMCP().reply(
          threadID: Self.requiredString("thread_id", in: object),
          prompt: Self.requiredString("prompt", in: object)
        )
      case "codex.mcp.calls.list":
        result = try await tryMCP().calls()
      case "codex.mcp.events":
        result = try await tryMCP().events(
          callID: Self.requiredString("call_id", in: object),
          afterCursor: Self.nonnegativeInt("after_cursor", in: object, default: 0),
          maxResults: Self.boundedInt(
            "max_results",
            in: object,
            default: 100,
            range: 1...1_000
          )
        )
      case "codex.mcp.result":
        result = try await tryMCP().result(
          callID: Self.requiredString("call_id", in: object)
        )
      case "codex.mcp.approvals.list":
        result = try await tryMCP().pendingApprovals(
          callID: Self.requiredString("call_id", in: object)
        )
      case "codex.mcp.approval.respond":
        result = try await tryMCP().respondToApproval(
          callID: Self.requiredString("call_id", in: object),
          approvalID: Self.requiredString("approval_id", in: object),
          decision: Self.requiredString("decision", in: object)
        )
      case "codex.mcp.cancel":
        result = try await tryMCP().cancel(
          callID: Self.requiredString("call_id", in: object)
        )
      default:
        throw GatewayToolError.unknownTool(name)
      }
    } catch let error as GatewayToolError {
      throw error
    } catch {
      throw GatewayToolError.executionFailed(error.localizedDescription)
    }
    return try Self.resultEnvelope(result)
  }

  func shutdown() async {
    await appServer?.shutdown()
    await exec?.shutdown()
    await mcp?.shutdown()
  }

  private func tryAppServer() throws -> any CodexAppServerRuntimeProtocol {
    guard let appServer else {
      throw GatewayToolError.disabled(
        "codex.app.disabled: Codex App Server is disabled by local configuration."
      )
    }
    return appServer
  }

  private func tryExec() throws -> any CodexExecRuntimeProtocol {
    guard let exec else {
      throw GatewayToolError.disabled(
        "codex.exec.disabled: Codex Exec is disabled by local configuration."
      )
    }
    return exec
  }

  private func tryMCP() throws -> any CodexMCPRuntimeProtocol {
    guard let mcp else {
      throw GatewayToolError.disabled(
        "codex.mcp.disabled: Codex MCP is disabled by local configuration."
      )
    }
    return mcp
  }

  private static func appMethodsList() -> JSONValue {
    .object([
      "methods": .array(
        CodexAppServerMethodCatalog.methods.map { method in
          .object([
            "method": .string(method.method),
            "description": .string(method.description),
            "takes_params": .bool(method.takesParams),
            "risk": .string(method.risk.rawValue),
          ])
        }
      )
    ])
  }

  private static func appMethodDescription(method: String) throws -> JSONValue {
    guard let descriptor = CodexAppServerMethodCatalog.method(named: method) else {
      throw GatewayToolError.invalidArguments(
        "codex.app.method_not_allowed: App Server method '\(method)' is not in the reviewed allowlist."
      )
    }
    return .object([
      "method": .string(descriptor.method),
      "description": .string(descriptor.description),
      "takes_params": .bool(descriptor.takesParams),
      "risk": .string(descriptor.risk.rawValue),
      "call_context": .object([
        "tool": .string("codex.app.methods.call"),
        "method": .string(descriptor.method),
      ]),
    ])
  }

  private static func params(in object: [String: JSONValue]) throws -> JSONValue {
    guard let value = object["params"] else {
      return .object([:])
    }
    guard value.objectValue != nil else {
      throw GatewayToolError.invalidArguments(
        "codex.params_invalid: params must be a JSON object."
      )
    }
    return value
  }

  private static func threadStartParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(
      in: object,
      allowed: ["model", "ephemeral", "personality", "service_tier"]
    )
    var params: [String: JSONValue] = [:]
    try copyOptionalString("model", to: "model", from: object, into: &params)
    try copyOptionalBool("ephemeral", to: "ephemeral", from: object, into: &params)
    try copyOptionalString("personality", to: "personality", from: object, into: &params)
    try copyOptionalString("service_tier", to: "serviceTier", from: object, into: &params)
    return .object(params)
  }

  private static func threadListParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(
      in: object,
      allowed: [
        "archived", "cursor", "limit", "search_term", "sort_direction", "sort_key",
        "source_kinds",
      ]
    )
    var params: [String: JSONValue] = [:]
    try copyOptionalBool("archived", to: "archived", from: object, into: &params)
    try copyOptionalString("cursor", to: "cursor", from: object, into: &params)
    try copyOptionalInt("limit", to: "limit", from: object, range: 1...1_000, into: &params)
    try copyOptionalString("search_term", to: "searchTerm", from: object, into: &params)
    try copyOptionalString(
      "sort_direction",
      to: "sortDirection",
      from: object,
      into: &params
    )
    try copyOptionalString("sort_key", to: "sortKey", from: object, into: &params)
    try copyOptionalStringArray(
      "source_kinds",
      to: "sourceKinds",
      from: object,
      into: &params
    )
    return .object(params)
  }

  private static func threadReadParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: ["thread_id", "include_turns"])
    return .object([
      "threadId": .string(try requiredString("thread_id", in: object)),
      "includeTurns": .bool(try optionalBool("include_turns", in: object) ?? true),
    ])
  }

  private static func threadForkParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(
      in: object,
      allowed: ["thread_id", "model", "ephemeral", "service_tier"]
    )
    var params: [String: JSONValue] = [
      "threadId": .string(try requiredString("thread_id", in: object))
    ]
    try copyOptionalString("model", to: "model", from: object, into: &params)
    try copyOptionalBool("ephemeral", to: "ephemeral", from: object, into: &params)
    try copyOptionalString("service_tier", to: "serviceTier", from: object, into: &params)
    return .object(params)
  }

  private func turnStartParams(in object: [String: JSONValue]) throws -> JSONValue {
    try Self.validateKeys(
      in: object,
      allowed: [
        "thread_id", "prompt", "model", "effort", "personality", "service_tier", "summary",
        "output_schema", "collaboration_mode",
      ]
    )
    var params: [String: JSONValue] = [
      "threadId": .string(try Self.requiredString("thread_id", in: object)),
      "input": .array([
        .object([
          "type": .string("text"),
          "text": .string(try Self.requiredString("prompt", in: object)),
        ])
      ]),
    ]
    try Self.copyOptionalString("model", to: "model", from: object, into: &params)
    try Self.copyOptionalString("effort", to: "effort", from: object, into: &params)
    try Self.copyOptionalString("personality", to: "personality", from: object, into: &params)
    try Self.copyOptionalString("service_tier", to: "serviceTier", from: object, into: &params)
    try Self.copyOptionalString("summary", to: "summary", from: object, into: &params)
    try Self.copyOptionalObject("output_schema", to: "outputSchema", from: object, into: &params)

    if let mode = try Self.optionalString("collaboration_mode", in: object) {
      guard configuration.experimentalAPI else {
        throw GatewayToolError.invalidArguments(
          "codex.app.collaboration_mode_unavailable: experimental_api must be enabled."
        )
      }
      guard ["default", "plan"].contains(mode) else {
        throw GatewayToolError.invalidArguments(
          "codex.argument_invalid: 'collaboration_mode' must be 'default' or 'plan'."
        )
      }
      let model = try Self.requiredString("model", in: object)
      var settings: [String: JSONValue] = ["model": .string(model)]
      if let effort = try Self.optionalString("effort", in: object) {
        settings["reasoning_effort"] = .string(effort)
      }
      params["collaborationMode"] = .object([
        "mode": .string(mode),
        "settings": .object(settings),
      ])
    }
    return .object(params)
  }

  private static func turnInterruptParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: ["thread_id", "turn_id"])
    return .object([
      "threadId": .string(try requiredString("thread_id", in: object)),
      "turnId": .string(try requiredString("turn_id", in: object)),
    ])
  }

  private static func reviewStartParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: ["thread_id", "target", "delivery"])
    guard let target = object["target"], target.objectValue != nil else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_required: 'target' must be a JSON object."
      )
    }
    var params: [String: JSONValue] = [
      "threadId": .string(try requiredString("thread_id", in: object)),
      "target": target,
    ]
    if let delivery = try optionalString("delivery", in: object) {
      guard ["inline", "detached"].contains(delivery) else {
        throw GatewayToolError.invalidArguments(
          "codex.argument_invalid: 'delivery' must be 'inline' or 'detached'."
        )
      }
      params["delivery"] = .string(delivery)
    }
    return .object(params)
  }

  private static func modelListParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: ["cursor", "include_hidden", "limit"])
    var params: [String: JSONValue] = [:]
    try copyOptionalString("cursor", to: "cursor", from: object, into: &params)
    try copyOptionalBool("include_hidden", to: "includeHidden", from: object, into: &params)
    try copyOptionalInt("limit", to: "limit", from: object, range: 1...1_000, into: &params)
    return .object(params)
  }

  private static func skillsListParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: ["force_reload"])
    var params: [String: JSONValue] = [:]
    try copyOptionalBool("force_reload", to: "forceReload", from: object, into: &params)
    return .object(params)
  }

  private static func appsListParams(in object: [String: JSONValue]) throws -> JSONValue {
    try validateKeys(in: object, allowed: [])
    return .object([:])
  }

  private static func validateKeys(
    in object: [String: JSONValue],
    allowed: Set<String>
  ) throws {
    guard let key = object.keys.sorted().first(where: { !allowed.contains($0) }) else {
      return
    }
    throw GatewayToolError.invalidArguments(
      "codex.argument_unknown: '\(key)' is not accepted by this typed tool."
    )
  }

  private static func optionalBool(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> Bool? {
    guard let raw = object[key] else { return nil }
    guard let value = raw.boolValue else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be a boolean."
      )
    }
    return value
  }

  private static func copyOptionalString(
    _ key: String,
    to targetKey: String,
    from object: [String: JSONValue],
    into result: inout [String: JSONValue]
  ) throws {
    if let value = try optionalString(key, in: object) {
      result[targetKey] = .string(value)
    }
  }

  private static func copyOptionalBool(
    _ key: String,
    to targetKey: String,
    from object: [String: JSONValue],
    into result: inout [String: JSONValue]
  ) throws {
    if let value = try optionalBool(key, in: object) {
      result[targetKey] = .bool(value)
    }
  }

  private static func copyOptionalInt(
    _ key: String,
    to targetKey: String,
    from object: [String: JSONValue],
    range: ClosedRange<Int>,
    into result: inout [String: JSONValue]
  ) throws {
    guard let raw = object[key] else { return }
    guard let value = raw.intValue, range.contains(value) else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be an integer between \(range.lowerBound) and \(range.upperBound)."
      )
    }
    result[targetKey] = .number(Double(value))
  }

  private static func copyOptionalObject(
    _ key: String,
    to targetKey: String,
    from object: [String: JSONValue],
    into result: inout [String: JSONValue]
  ) throws {
    guard let value = object[key] else { return }
    guard value.objectValue != nil else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be a JSON object."
      )
    }
    result[targetKey] = value
  }

  private static func copyOptionalStringArray(
    _ key: String,
    to targetKey: String,
    from object: [String: JSONValue],
    into result: inout [String: JSONValue]
  ) throws {
    guard let raw = object[key] else { return }
    guard let values = raw.arrayValue,
      values.allSatisfy({ value in
        guard let string = value.stringValue else { return false }
        return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be an array of non-empty strings."
      )
    }
    result[targetKey] = .array(values)
  }

  private static func requiredString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard let value = object[key]?.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_required: '\(key)' must be a non-empty string."
      )
    }
    return value
  }

  private static func optionalString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String? {
    guard let raw = object[key] else { return nil }
    guard let value = raw.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be a non-empty string when provided."
      )
    }
    return value
  }

  private static func nonnegativeInt(
    _ key: String,
    in object: [String: JSONValue],
    default defaultValue: Int
  ) throws -> Int {
    let value = object[key]?.intValue ?? defaultValue
    guard value >= 0 else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be nonnegative."
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
    let value = object[key]?.intValue ?? defaultValue
    guard range.contains(value) else {
      throw GatewayToolError.invalidArguments(
        "codex.argument_invalid: '\(key)' must be between \(range.lowerBound) and \(range.upperBound)."
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

  private static func makeTools(
    appServerEnabled: Bool,
    execEnabled: Bool,
    mcpEnabled: Bool
  ) -> [MCPTool] {
    var result: [MCPTool] = []
    if appServerEnabled {
      result.append(contentsOf: appServerTools)
    }
    if execEnabled {
      result.append(contentsOf: execTools)
    }
    if mcpEnabled {
      result.append(contentsOf: mcpTools)
    }
    return result
  }

  private static let readAnnotations = MCPToolAnnotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
  )

  private static let writeAnnotations = MCPToolAnnotations(
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: true
  )

  private static let emptySchema = objectSchema()
  private static let cursorSchema = objectSchema(
    properties: [
      "after_cursor": integerSchema(minimum: 0),
      "max_results": integerSchema(minimum: 1, maximum: 1_000),
    ]
  )

  private static let appServerTools: [MCPTool] = [
    tool(
      "codex.app.status", "Read the persistent Codex App Server connection status.", emptySchema),
    tool(
      "codex.app.methods.list",
      "List reviewed Codex App Server RPC methods. Authentication, configuration mutation, marketplace mutation, raw shell, filesystem bypass, and remote pairing methods are never included.",
      emptySchema
    ),
    tool(
      "codex.app.methods.describe",
      "Describe one reviewed Codex App Server RPC and the fixed follow-up call context.",
      objectSchema(properties: ["method": stringSchema()], required: ["method"])
    ),
    tool(
      "codex.app.methods.call",
      "Call one reviewed Codex App Server RPC. The gateway fixes cwd, sandbox, and approval policy and rejects instruction/config overrides.",
      objectSchema(
        properties: [
          "method": stringSchema(),
          "params": .object([
            "type": .string("object"),
            "additionalProperties": .bool(true),
          ]),
        ],
        required: ["method"]
      ),
      write: true
    ),
    tool(
      "codex.app.thread.start", "Start a Codex thread in the bound workspace.",
      objectSchema(
        properties: [
          "model": stringSchema(),
          "ephemeral": booleanSchema(),
          "personality": stringSchema(),
          "service_tier": stringSchema(),
        ]
      ),
      write: true),
    tool(
      "codex.app.thread.list",
      "List Codex threads restricted to the bound workspace.",
      objectSchema(
        properties: [
          "archived": booleanSchema(),
          "cursor": stringSchema(),
          "limit": integerSchema(minimum: 1, maximum: 1_000),
          "search_term": stringSchema(),
          "sort_direction": stringSchema(),
          "sort_key": stringSchema(),
          "source_kinds": arraySchema(items: stringSchema()),
        ]
      )
    ),
    tool(
      "codex.app.thread.read", "Read one Codex thread after verifying its workspace.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "include_turns": booleanSchema(),
        ],
        required: ["thread_id"]
      )
    ),
    tool(
      "codex.app.thread.fork", "Fork a Codex thread in the bound workspace.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "model": stringSchema(),
          "ephemeral": booleanSchema(),
          "service_tier": stringSchema(),
        ],
        required: ["thread_id"]
      ),
      write: true),
    tool(
      "codex.app.turn.start", "Start a Codex turn with gateway-owned sandbox and approval policy.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "prompt": stringSchema(),
          "model": stringSchema(),
          "effort": stringSchema(),
          "personality": stringSchema(),
          "service_tier": stringSchema(),
          "summary": stringSchema(),
          "output_schema": freeObjectSchema(),
          "collaboration_mode": .object([
            "type": .string("string"),
            "enum": .array([.string("default"), .string("plan")]),
            "description": .string(
              "Optional App Server collaboration mode. Plan mode enables ordinary user-input requests; model must also be supplied."
            ),
          ]),
        ],
        required: ["thread_id", "prompt"]
      ), write: true),
    tool(
      "codex.app.turn.interrupt", "Interrupt an active Codex turn.",
      objectSchema(
        properties: ["thread_id": stringSchema(), "turn_id": stringSchema()],
        required: ["thread_id", "turn_id"]
      ), write: true),
    tool(
      "codex.app.review.start", "Start a Codex review for a verified workspace thread.",
      objectSchema(
        properties: [
          "thread_id": stringSchema(),
          "target": freeObjectSchema(),
          "delivery": .object([
            "type": .string("string"),
            "enum": .array([.string("inline"), .string("detached")]),
          ]),
        ],
        required: ["thread_id", "target"]
      ), write: true),
    tool(
      "codex.app.models.list", "List models exposed by Codex App Server.",
      objectSchema(
        properties: [
          "cursor": stringSchema(),
          "include_hidden": booleanSchema(),
          "limit": integerSchema(minimum: 1, maximum: 1_000),
        ]
      )
    ),
    tool(
      "codex.app.skills.list", "List Skills for the bound workspace.",
      objectSchema(properties: ["force_reload": booleanSchema()])
    ),
    tool("codex.app.apps.list", "List apps exposed by Codex App Server.", emptySchema),
    tool(
      "codex.app.events.read", "Read App Server notifications by monotonic cursor.", cursorSchema),
    tool(
      "codex.app.requests.list",
      "List pending ordinary user-input requests. Permission and credential requests are rejected automatically.",
      emptySchema),
    tool(
      "codex.app.requests.respond",
      "Respond to one pending ordinary user-input request. This cannot approve permissions or credentials.",
      objectSchema(
        properties: [
          "request_id": stringSchema(),
          "response": .object([:]),
        ],
        required: ["request_id", "response"]
      ),
      write: true
    ),
  ]

  private static let execTools: [MCPTool] = [
    tool(
      "codex.exec.start",
      "Start an isolated `codex exec` JSONL session. cwd, sandbox, approval policy, writable roots, and config overrides are fixed locally.",
      objectSchema(
        properties: ["prompt": stringSchema(), "model": stringSchema()],
        required: ["prompt"]
      ),
      write: true
    ),
    tool(
      "codex.exec.resume",
      "Resume one upstream Codex Exec session under the same fixed workspace and policy.",
      objectSchema(
        properties: [
          "upstream_session_id": stringSchema(),
          "prompt": stringSchema(),
        ],
        required: ["upstream_session_id"]
      ),
      write: true
    ),
    tool("codex.exec.list", "List gateway-owned Codex Exec sessions.", emptySchema),
    tool(
      "codex.exec.events",
      "Read JSONL events for one Codex Exec session by monotonic cursor.",
      sessionCursorSchema(id: "session_id")
    ),
    tool(
      "codex.exec.result",
      "Read the terminal result for one completed Codex Exec session.",
      objectSchema(properties: ["session_id": stringSchema()], required: ["session_id"])
    ),
    tool(
      "codex.exec.cancel",
      "Cancel one running Codex Exec session.",
      objectSchema(properties: ["session_id": stringSchema()], required: ["session_id"]),
      write: true
    ),
  ]

  private static let mcpTools: [MCPTool] = [
    tool(
      "codex.mcp.status", "Read the persistent `codex mcp-server` connection status.", emptySchema),
    tool("codex.mcp.tools.list", "List tools reported by `codex mcp-server`.", emptySchema),
    tool(
      "codex.mcp.run",
      "Start the Codex MCP `codex` tool with gateway-owned cwd, sandbox, approval policy, and no instruction/config overrides.",
      objectSchema(
        properties: ["prompt": stringSchema(), "model": stringSchema()],
        required: ["prompt"]
      ),
      write: true
    ),
    tool(
      "codex.mcp.reply",
      "Reply to an existing Codex MCP thread.",
      objectSchema(
        properties: ["thread_id": stringSchema(), "prompt": stringSchema()],
        required: ["thread_id", "prompt"]
      ),
      write: true
    ),
    tool("codex.mcp.calls.list", "List gateway-owned Codex MCP calls.", emptySchema),
    tool(
      "codex.mcp.events",
      "Read server messages and approval events for one Codex MCP call by cursor.",
      sessionCursorSchema(id: "call_id")
    ),
    tool(
      "codex.mcp.result",
      "Read the current or terminal result for one Codex MCP call.",
      objectSchema(properties: ["call_id": stringSchema()], required: ["call_id"])
    ),
    tool(
      "codex.mcp.approvals.list",
      "List pending command or patch approvals for one Codex MCP call.",
      objectSchema(properties: ["call_id": stringSchema()], required: ["call_id"])
    ),
    tool(
      "codex.mcp.approval.respond",
      "Allow or deny one pending Codex MCP approval. Allow is accepted only when every cwd, grant root, and patch path stays within the bound workspace.",
      objectSchema(
        properties: [
          "call_id": stringSchema(),
          "approval_id": stringSchema(),
          "decision": .object([
            "type": .string("string"),
            "enum": .array([.string("allow"), .string("deny")]),
          ]),
        ],
        required: ["call_id", "approval_id", "decision"]
      ),
      write: true
    ),
    tool(
      "codex.mcp.cancel",
      "Request cancellation for one active Codex MCP call.",
      objectSchema(properties: ["call_id": stringSchema()], required: ["call_id"]),
      write: true
    ),
  ]

  private static let readOnlyToolNames = Set(
    (appServerTools + execTools + mcpTools)
      .filter { $0.annotations?.readOnlyHint == true }
      .map(\.name)
  )

  private static func tool(
    _ name: String,
    _ description: String,
    _ inputSchema: JSONValue,
    write: Bool = false
  ) -> MCPTool {
    MCPTool(
      name: name,
      description: description,
      inputSchema: inputSchema,
      outputSchema: MCPTool.resultEnvelopeSchema,
      annotations: write ? writeAnnotations : readAnnotations
    )
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

  private static func sessionCursorSchema(id: String) -> JSONValue {
    objectSchema(
      properties: [
        id: stringSchema(),
        "after_cursor": integerSchema(minimum: 0),
        "max_results": integerSchema(minimum: 1, maximum: 1_000),
      ],
      required: [id]
    )
  }

  private static func stringSchema() -> JSONValue {
    .object(["type": .string("string"), "minLength": .number(1)])
  }

  private static func booleanSchema() -> JSONValue {
    .object(["type": .string("boolean")])
  }

  private static func freeObjectSchema() -> JSONValue {
    .object([
      "type": .string("object"),
      "additionalProperties": .bool(true),
    ])
  }

  private static func arraySchema(items: JSONValue) -> JSONValue {
    .object([
      "type": .string("array"),
      "items": items,
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
