import Foundation

/// Applies one profile's host-owned scope to every route into a downstream session.
struct AuthorizedMCPClient: DownstreamMCPClient {
  let base: any DownstreamMCPClient
  let policy: MCPToolAccessPolicy
  var policyProvider: (@Sendable () throws -> MCPToolAccessPolicy)? = nil

  private var currentPolicy: MCPToolAccessPolicy {
    get throws { try policyProvider?() ?? policy }
  }

  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  )
    -> any DownstreamMCPClient
  {
    Self(
      base: base.makeScopedClient(
        workingDirectory: workingDirectory, environment: environment, hostContext: hostContext),
      policy: policy, policyProvider: policyProvider)
  }

  func toolChanges() -> AsyncStream<Void> { base.toolChanges() }
  func shutdown() async { await base.shutdown() }

  func isServerVisible(_ server: MCPServerConfig) -> Bool {
    (try? currentPolicy.isVisible(server)) ?? false
  }

  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    let policy = try currentPolicy
    guard policy.canDiscoverTools(on: server) else { return [] }
    return try base.listTools(server: server).filter {
      policy.allows(.init(serverID: server.id, toolName: $0.name))
    }
  }

  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    try callTool(server: server, name: name, arguments: arguments, requestID: nil)
  }

  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String?)
    throws -> JSONValue
  {
    try requireTool(name, server: server)
    return try base.callTool(server: server, name: name, arguments: arguments, requestID: requestID)
  }

  func startToolCall(server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String)
    throws -> JSONValue
  {
    try requireTool(name, server: server)
    return try base.startToolCall(
      server: server, name: name, arguments: arguments, requestID: requestID)
  }

  func callToolAsync(
    server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String?
  )
    async throws -> JSONValue
  {
    try requireTool(name, server: server)
    return try await base.callToolAsync(
      server: server, name: name, arguments: arguments, requestID: requestID)
  }

  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue {
    try requireServer(server, capability: "mcp.resources.list")
    return try base.listResources(server: server, cursor: cursor)
  }

  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue {
    try requireServer(server, capability: "mcp.resources.templates.list")
    return try base.listResourceTemplates(server: server, cursor: cursor)
  }

  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue {
    try requireServer(server, capability: "mcp.resources.read")
    return try base.readResource(server: server, uri: uri)
  }

  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue {
    try requireServer(server, capability: "mcp.prompts.list")
    return try base.listPrompts(server: server, cursor: cursor)
  }

  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  {
    try requireServer(server, capability: "mcp.prompts.get")
    return try base.getPrompt(server: server, name: name, arguments: arguments)
  }

  func connectionStatus(server: MCPServerConfig) throws -> JSONValue {
    guard isServerVisible(server) else { return .object(["state": .string("not_authorized")]) }
    return try base.connectionStatus(server: server)
  }

  func readEvents(server: MCPServerConfig, afterCursor: Int, maxResults: Int) throws -> JSONValue {
    try requireServer(server, capability: "mcp.events.read")
    return try base.readEvents(server: server, afterCursor: afterCursor, maxResults: maxResults)
  }

  func readEvents(
    server: MCPServerConfig, afterCursor: Int, maxResults: Int, sessionID: String?
  ) throws -> JSONValue {
    try requireServer(server, capability: "mcp.events.read")
    return try base.readEvents(
      server: server, afterCursor: afterCursor, maxResults: maxResults, sessionID: sessionID)
  }

  func activeRequests(server: MCPServerConfig) throws -> JSONValue {
    try requireServer(server, capability: "mcp.requests.list")
    return try base.activeRequests(server: server)
  }

  func cancelRequest(server: MCPServerConfig, requestID: String, reason: String?) throws
    -> JSONValue
  {
    try requireServer(server, capability: "mcp.requests.cancel")
    return try base.cancelRequest(server: server, requestID: requestID, reason: reason)
  }

  private func requireTool(_ name: String, server: MCPServerConfig) throws {
    guard try currentPolicy.allows(.init(serverID: server.id, toolName: name)) else {
      throw GatewayToolError.invalidArguments(
        "[policy.capability_denied] The profile does not grant this downstream MCP tool.")
    }
  }

  func readRequest(server: MCPServerConfig, requestID: String, offset: Int, maxBytes: Int) throws
    -> JSONValue
  {
    try requireServer(server, capability: "mcp.requests.read")
    let result = try base.readRequest(
      server: server, requestID: requestID, offset: offset, maxBytes: maxBytes)
    guard let tool = result.objectValue?["tool"]?.stringValue else {
      throw GatewayToolError.executionFailed(
        "Execution receipt is missing its original tool identity.")
    }
    try requireTool(tool, server: server)
    return result
  }

  private func requireServer(_ server: MCPServerConfig, capability: String) throws {
    guard try currentPolicy.permitsServer(server, capability: capability) else {
      throw GatewayToolError.invalidArguments(
        "[policy.capability_denied] The profile does not grant this downstream MCP surface.")
    }
  }

}
