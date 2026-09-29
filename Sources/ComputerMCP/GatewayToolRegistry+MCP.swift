import Foundation

extension GatewayToolRegistry {
  internal func requireMCPProviders() throws {
    guard !configuration.mcp.servers.isEmpty else {
      throw GatewayToolError.disabled(
        "Downstream MCP gateway tools require at least one configured server.")
    }
  }

  internal func mcpServerList() -> JSONValue {
    .array(
      configuration.mcp.servers.filter { mcpClient.isServerVisible($0) }.map { server in
        .object([
          "id": .string(server.id),
          "transport": .string(server.transport.rawValue),
          "exposure": .string(server.exposure.rawValue),
          "capabilities": .array(server.capabilities.map { .string($0) }),
        ])
      })
  }

  internal func mcpServerStatus(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try optionalString("server", in: object)
    let servers: [MCPServerConfig]
    if let id {
      servers = [try mcpServer(id)]
    } else {
      servers = configuration.mcp.servers.filter { mcpClient.isServerVisible($0) }
    }

    return .object([
      "servers": .array(try servers.map { try mcpServerStatus($0) })
    ])
  }

  internal func mcpServerStatus(_ server: MCPServerConfig) throws -> JSONValue {
    var object: [String: JSONValue] = [
      "id": .string(server.id),
      "transport": .string(server.transport.rawValue),
      "exposure": .string(server.exposure.rawValue),
      "prefix": server.prefix.map(JSONValue.string) ?? .null,
      "capabilities": .array(server.capabilities.map { .string($0) }),
      "startup_timeout_ms": server.startupTimeoutMs.map { .integer(Int64($0)) } ?? .null,
      "request_timeout_ms": server.requestTimeoutMs.map { .integer(Int64($0)) } ?? .null,
      "env": .array(mcpEnvironmentEntries(server)),
    ]

    switch server.transport {
    case .stdio:
      let command = server.command ?? ""
      let resolved = resolveExecutable(
        command,
        base: server.resolvedWorkingDirectory(base: configuration.workspaceDirectory),
        defaultBase: configuration.workspaceDirectory,
        overrides: server.env
      )
      object["command"] = .string(command)
      object["args"] = .array(server.args.map { .string($0) })
      object["cwd"] = .string(
        server.resolvedWorkingDirectory(base: configuration.workspaceDirectory).standardizedFileURL
          .path)
      object["command_resolution"] = executableResolutionJSON(resolved)
      object["ready"] = .bool(resolved.status == .passed)
      object["readiness_scope"] = .string("file_and_interpreter_checks")

    case .streamableHTTP, .http, .sse:
      object["url"] = server.url.map(JSONValue.string) ?? .null
      object["url_status"] = httpURLStatus(server.url)
      object["ready"] = .bool(server.url.flatMap(URL.init(string:)) != nil)
    }

    object["connection"] = try mcpClient.connectionStatus(server: server)
    return .object(object)
  }

  internal func listDownstreamMCPTools(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("server", in: object)
    let server = try mcpServer(id)
    return .array(try permittedDownstreamTools(server: server).map(\.json))
  }

  internal func describeDownstreamMCPTool(arguments object: [String: JSONValue]) throws -> JSONValue
  {
    let id = try requiredString("server", in: object)
    let name = try requiredString("tool", in: object)
    let server = try mcpServer(id)
    let tools = try permittedDownstreamTools(server: server)
    guard let tool = tools.first(where: { $0.name == name }) else {
      throw GatewayToolError.invalidArguments(
        "Unknown downstream MCP tool '\(name)' on server '\(id)'.")
    }

    return .object([
      "server": .string(id),
      "tool": .string(name),
      "tool_count": .integer(Int64(tools.count)),
      "definition": tool.json,
      "call_context": .object([
        "tool": .string("mcp.tools.call"),
        "arguments": .object([
          "server": .string(id),
          "tool": .string(name),
          "arguments": .object([:]),
        ]),
      ]),
    ])
  }

  internal func findDownstreamMCPTools(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("server", in: object)
    let query = try requiredString("query", in: object)
    let matchMode = try fileNameMatchMode(try optionalString("match", in: object) ?? "contains")
    let field = try mcpToolFindField(try optionalString("field", in: object) ?? "all")
    let caseSensitive = try optionalBool("case_sensitive", in: object) ?? false
    let maxResults = optionalInt("max_results", in: object) ?? 50
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 1_000)

    let server = try mcpServer(id)
    let tools = try permittedDownstreamTools(server: server)
    var results: [MCPTool] = []
    var truncated = false
    for tool in tools
    where mcpTool(tool, matches: query, field: field, mode: matchMode, caseSensitive: caseSensitive)
    {
      guard results.count < maxResults else {
        truncated = true
        break
      }
      results.append(tool)
    }

    return .object([
      "server": .string(id),
      "query": .string(query),
      "match": .string(matchMode.rawValue),
      "field": .string(field.rawValue),
      "case_sensitive": .bool(caseSensitive),
      "max_results": .integer(Int64(maxResults)),
      "tool_count": .integer(Int64(tools.count)),
      "result_count": .integer(Int64(results.count)),
      "truncated": .bool(truncated),
      "tools": .array(results.map(\.json)),
    ])
  }

  internal func callDownstreamMCPTool(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("server", in: object)
    let name = try requiredString("tool", in: object)
    let server = try mcpServer(id)
    try requireDownstreamToolAllowed(name, server: server)
    let waitForResult = try optionalBool("wait_for_result", in: object) ?? true
    let requestID = try optionalString("request_id", in: object)
    if !waitForResult {
      guard let requestID, !requestID.isEmpty else {
        throw GatewayToolError.invalidArguments(
          "request_id is required when wait_for_result is false."
        )
      }
      return try textResult(
        mcpClient.startToolCall(
          server: server,
          name: name,
          arguments: object["arguments"] ?? .object([:]),
          requestID: requestID
        )
      )
    }
    return try textResult(
      mcpClient.callTool(
        server: server,
        name: name,
        arguments: object["arguments"] ?? .object([:]),
        requestID: requestID
      )
    )
  }

  internal func readDownstreamMCPEvents(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("server", in: object)
    let afterCursor = optionalInt("after_cursor", in: object) ?? 0
    let maxResults = optionalInt("max_results", in: object) ?? 100
    guard afterCursor >= 0 else {
      throw GatewayToolError.invalidArguments("after_cursor must be zero or greater.")
    }
    try validateBoundedPositive(maxResults, name: "max_results", upperBound: 500)
    return try mcpClient.readEvents(
      server: mcpServer(id),
      afterCursor: afterCursor,
      maxResults: maxResults,
      sessionID: try optionalString("session_id", in: object)
    )
  }

  internal func listDownstreamMCPRequests(arguments object: [String: JSONValue]) throws -> JSONValue
  {
    let id = try requiredString("server", in: object)
    return try mcpClient.activeRequests(server: mcpServer(id))
  }

  internal func cancelDownstreamMCPRequest(arguments object: [String: JSONValue]) throws
    -> JSONValue
  {
    let id = try requiredString("server", in: object)
    let requestID = try requiredString("request_id", in: object)
    return try mcpClient.cancelRequest(
      server: mcpServer(id),
      requestID: requestID,
      reason: try optionalString("reason", in: object)
    )
  }

  internal func readDownstreamMCPRequest(arguments object: [String: JSONValue]) throws -> JSONValue
  {
    let id = try requiredString("server", in: object)
    let requestID = try requiredString("request_id", in: object)
    return try mcpClient.readRequest(
      server: mcpServer(id), requestID: requestID,
      offset: optionalInt("offset", in: object) ?? 0,
      maxBytes: optionalInt("max_bytes", in: object) ?? 32_768)
  }

  internal func listDownstreamMCPResources(arguments object: [String: JSONValue]) throws
    -> JSONValue
  {
    let id = try requiredString("server", in: object)
    let cursor = try optionalString("cursor", in: object)
    let server = try mcpServer(id)
    let result = try mcpClient.listResources(server: server, cursor: cursor)
    let resourceValues = result.objectValue?["resources"]?.arrayValue ?? []
    let resources = resourceValues.map { downstreamMCPResourceJSON($0, serverID: id) }
    let nextCursor =
      result.objectValue?["nextCursor"]?.stringValue
      ?? result.objectValue?["next_cursor"]?.stringValue

    return .object([
      "server": .string(id),
      "cursor": cursor.map(JSONValue.string) ?? .null,
      "resource_count": .integer(Int64(resources.count)),
      "next_cursor": nextCursor.map(JSONValue.string) ?? .null,
      "resources": .array(resources),
    ])
  }

  internal func listDownstreamMCPResourceTemplates(arguments object: [String: JSONValue]) throws
    -> JSONValue
  {
    let id = try requiredString("server", in: object)
    let cursor = try optionalString("cursor", in: object)
    let server = try mcpServer(id)
    let result = try mcpClient.listResourceTemplates(server: server, cursor: cursor)
    let templates =
      result.objectValue?["resourceTemplates"]?.arrayValue
      ?? result.objectValue?["templates"]?.arrayValue
      ?? []
    let nextCursor =
      result.objectValue?["nextCursor"]?.stringValue
      ?? result.objectValue?["next_cursor"]?.stringValue

    return .object([
      "server": .string(id),
      "cursor": cursor.map(JSONValue.string) ?? .null,
      "template_count": .integer(Int64(templates.count)),
      "next_cursor": nextCursor.map(JSONValue.string) ?? .null,
      "resource_templates": .array(templates),
    ])
  }

  internal func readDownstreamMCPResource(arguments object: [String: JSONValue]) throws -> JSONValue
  {
    let id = try requiredString("server", in: object)
    let uri = try requiredString("uri", in: object)
    let server = try mcpServer(id)
    let result = try mcpClient.readResource(server: server, uri: uri)
    let contents = result.objectValue?["contents"]?.arrayValue ?? []

    return .object([
      "server": .string(id),
      "uri": .string(uri),
      "content_count": .integer(Int64(contents.count)),
      "contents": .array(contents),
    ])
  }

  private func downstreamMCPResourceJSON(_ resource: JSONValue, serverID: String) -> JSONValue {
    guard var object = resource.objectValue else {
      return resource
    }
    if let uri = object["uri"]?.stringValue {
      object["read_context"] = .object([
        "tool": .string("mcp.resources.read"),
        "arguments": .object([
          "server": .string(serverID),
          "uri": .string(uri),
        ]),
      ])
    }
    return .object(object)
  }

  internal func listDownstreamMCPPrompts(arguments object: [String: JSONValue]) throws -> JSONValue
  {
    let id = try requiredString("server", in: object)
    let cursor = try optionalString("cursor", in: object)
    let server = try mcpServer(id)
    let result = try mcpClient.listPrompts(server: server, cursor: cursor)
    let promptValues = result.objectValue?["prompts"]?.arrayValue ?? []
    let prompts = promptValues.map { downstreamMCPPromptJSON($0, serverID: id) }
    let nextCursor =
      result.objectValue?["nextCursor"]?.stringValue
      ?? result.objectValue?["next_cursor"]?.stringValue

    return .object([
      "server": .string(id),
      "cursor": cursor.map(JSONValue.string) ?? .null,
      "prompt_count": .integer(Int64(prompts.count)),
      "next_cursor": nextCursor.map(JSONValue.string) ?? .null,
      "prompts": .array(prompts),
    ])
  }

  internal func getDownstreamMCPPrompt(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("server", in: object)
    let name = try requiredString("name", in: object)
    let promptArguments = try optionalStringMap("arguments", in: object)
    let server = try mcpServer(id)
    let result = try mcpClient.getPrompt(server: server, name: name, arguments: promptArguments)
    let messages = result.objectValue?["messages"]?.arrayValue ?? []

    return .object([
      "server": .string(id),
      "name": .string(name),
      "arguments": promptArguments.map(jsonObject) ?? .null,
      "description": result.objectValue?["description"] ?? .null,
      "message_count": .integer(Int64(messages.count)),
      "messages": .array(messages),
    ])
  }

  private func downstreamMCPPromptJSON(_ prompt: JSONValue, serverID: String) -> JSONValue {
    guard var object = prompt.objectValue else {
      return prompt
    }
    if let name = object["name"]?.stringValue {
      object["get_context"] = .object([
        "tool": .string("mcp.prompts.get"),
        "arguments": .object([
          "server": .string(serverID),
          "name": .string(name),
          "arguments": .object([:]),
        ]),
      ])
    }
    return .object(object)
  }

  private func mcpToolFindField(_ value: String) throws -> MCPToolFindField {
    guard let field = MCPToolFindField(rawValue: value) else {
      throw GatewayToolError.invalidArguments("field must be one of: name, description, all.")
    }
    return field
  }

  private func mcpTool(
    _ tool: MCPTool,
    matches query: String,
    field: MCPToolFindField,
    mode: FileNameMatchMode,
    caseSensitive: Bool
  ) -> Bool {
    switch field {
    case .name:
      return fileName(tool.name, matches: query, mode: mode, caseSensitive: caseSensitive)
    case .description:
      return fileName(tool.description, matches: query, mode: mode, caseSensitive: caseSensitive)
    case .all:
      return fileName(tool.name, matches: query, mode: mode, caseSensitive: caseSensitive)
        || fileName(tool.description, matches: query, mode: mode, caseSensitive: caseSensitive)
    }
  }

  private func mcpEnvironmentEntries(_ server: MCPServerConfig) -> [JSONValue] {
    let processEnvironment = ProcessInfo.processInfo.environment
    var declaredKeys = Set<String>()
    return server.env.keys.sorted().map { key in
      environmentEntry(
        key: key,
        owner: "mcp.\(server.id)",
        purpose: "env",
        valueOrigin: "configured_provider_env",
        processEnvironment: processEnvironment,
        declaredKeys: &declaredKeys
      )
    }
  }

  private func httpURLStatus(_ value: String?) -> JSONValue {
    guard let value, let url = URL(string: value) else {
      return .object([
        "valid": .bool(false),
        "scheme": .null,
        "host": .null,
        "path": .null,
      ])
    }

    return .object([
      "valid": .bool(true),
      "scheme": url.scheme.map(JSONValue.string) ?? .null,
      "host": url.host.map(JSONValue.string) ?? .null,
      "path": .string(url.path.isEmpty ? "/" : url.path),
    ])
  }

  internal func permittedDownstreamTools(server: MCPServerConfig) throws -> [MCPTool] {
    try mcpClient.listTools(server: server).filter { server.permitsTool($0.name) }
  }

  internal func requireDownstreamToolAllowed(
    _ name: String,
    server: MCPServerConfig
  ) throws {
    guard server.permitsTool(name) else {
      throw GatewayToolError.invalidArguments(
        "[mcp.tool_not_approved] Downstream MCP tool '\(name)' is not approved for server '\(server.id)'. "
          + "The host must select it in allowed_tools or explicitly grant allow_any_tool."
      )
    }
  }

  internal func mcpServer(_ id: String) throws -> MCPServerConfig {
    guard let server = configuration.mcp.servers.first(where: { $0.id == id }),
      mcpClient.isServerVisible(server)
    else {
      throw GatewayToolError.unknownMCPServer(id)
    }
    return server
  }
}

private enum MCPToolFindField: String {
  case name
  case description
  case all
}
