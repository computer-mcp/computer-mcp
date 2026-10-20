import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import Foundation

/// Applies one profile's host-owned scope to every route into a downstream session.
package struct AuthorizedMCPClient: DownstreamMCPClient {
  private static let discovery = BlockingOperationExecutor(
    label: "computer-mcp.mcp-authorization-discovery", serial: false)
  private let base: any DownstreamMCPClient
  private let policy: MCPToolAccessPolicy
  private let policyProvider:
    (@Sendable ((any GatewaySessionAuthority)?) throws -> MCPToolAccessPolicy)?

  package init(
    base: any DownstreamMCPClient, policy: MCPToolAccessPolicy,
    policyProvider: (@Sendable ((any GatewaySessionAuthority)?) throws -> MCPToolAccessPolicy)? =
      nil
  ) {
    self.base = base
    self.policy = policy
    self.policyProvider = policyProvider
  }

  private func currentPolicy(context: InvocationContext) throws -> MCPToolAccessPolicy {
    try policyProvider?(context.session) ?? policy
  }

  package func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  )
    -> any DownstreamMCPClient
  {
    Self(
      base: base.makeScopedClient(
        workingDirectory: workingDirectory, environment: environment, hostContext: hostContext),
      policy: policy, policyProvider: policyProvider)
  }

  package func toolChanges() -> AsyncStream<Void> { base.toolChanges() }
  package func shutdown() async { await base.shutdown() }

  package func isServerVisible(_ server: MCPServerConfig, context: InvocationContext) -> Bool {
    (try? currentPolicy(context: context).isVisible(server)) ?? false
  }

  package func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    let policy = try currentPolicy(context: context)
    guard policy.canDiscoverTools(on: server) else { return [] }
    return try base.listTools(server: server, context: context).filter {
      let reference = MCPToolReference(serverID: server.id, toolName: $0.name)
      guard policy.allows(reference) else { return false }
      return try policy.allows(reference, riskFloor: $0.declaredRiskFloor)
    }
  }

  package func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    try callTool(server: server, name: name, arguments: arguments, requestID: nil, context: context)
  }

  package func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String?,
    context: InvocationContext
  )
    throws -> JSONValue
  {
    try requireTool(name, server: server, context: context)
    return try base.callTool(
      server: server, name: name, arguments: arguments, requestID: requestID, context: context)
  }

  package func startToolCall(
    server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String,
    context: InvocationContext
  )
    throws -> JSONValue
  {
    try requireTool(name, server: server, context: context)
    return try base.startToolCall(
      server: server, name: name, arguments: arguments, requestID: requestID, context: context)
  }

  package func callToolAsync(
    server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String?,
    context: InvocationContext
  )
    async throws -> JSONValue
  {
    try Task.checkCancellation()
    try await Self.discovery.perform {
      try requireTool(name, server: server, context: context)
    }
    try Task.checkCancellation()
    return try await base.callToolAsync(
      server: server, name: name, arguments: arguments, requestID: requestID, context: context)
  }

  package func listResources(server: MCPServerConfig, cursor: String?, context: InvocationContext)
    throws
    -> JSONValue
  {
    try requireServer(server, capability: "mcp.resources.list", context: context)
    return try base.listResources(server: server, cursor: cursor, context: context)
  }

  package func listResourceTemplates(
    server: MCPServerConfig, cursor: String?, context: InvocationContext
  )
    throws -> JSONValue
  {
    try requireServer(server, capability: "mcp.resources.templates.list", context: context)
    return try base.listResourceTemplates(server: server, cursor: cursor, context: context)
  }

  package func readResource(server: MCPServerConfig, uri: String, context: InvocationContext) throws
    -> JSONValue
  {
    try requireServer(server, capability: "mcp.resources.read", context: context)
    return try base.readResource(server: server, uri: uri, context: context)
  }

  package func listPrompts(server: MCPServerConfig, cursor: String?, context: InvocationContext)
    throws
    -> JSONValue
  {
    try requireServer(server, capability: "mcp.prompts.list", context: context)
    return try base.listPrompts(server: server, cursor: cursor, context: context)
  }

  package func getPrompt(
    server: MCPServerConfig, name: String, arguments: [String: String]?, context: InvocationContext
  ) throws
    -> JSONValue
  {
    try requireServer(server, capability: "mcp.prompts.get", context: context)
    return try base.getPrompt(server: server, name: name, arguments: arguments, context: context)
  }

  package func connectionStatus(server: MCPServerConfig, context: InvocationContext) throws
    -> JSONValue
  {
    guard isServerVisible(server, context: context) else {
      return .object(["state": .string("not_authorized")])
    }
    return try base.connectionStatus(server: server, context: context)
  }

  package func closeConnection(server: MCPServerConfig, context: InvocationContext) throws
    -> JSONValue
  {
    try requireServer(server, capability: "mcp.connections.close", context: context)
    return try base.closeConnection(server: server, context: context)
  }

  package func readEvents(
    server: MCPServerConfig, afterCursor: Int, maxResults: Int, context: InvocationContext
  ) throws -> JSONValue {
    try requireServer(server, capability: "mcp.events.read", context: context)
    return try base.readEvents(
      server: server, afterCursor: afterCursor, maxResults: maxResults, context: context)
  }

  package func readEvents(
    server: MCPServerConfig, afterCursor: Int, maxResults: Int, sessionID: String?,
    context: InvocationContext
  ) throws -> JSONValue {
    try requireServer(server, capability: "mcp.events.read", context: context)
    return try base.readEvents(
      server: server, afterCursor: afterCursor, maxResults: maxResults, sessionID: sessionID,
      context: context)
  }

  package func activeRequests(server: MCPServerConfig, context: InvocationContext) throws
    -> JSONValue
  {
    try requireServer(server, capability: "mcp.requests.list", context: context)
    return try base.activeRequests(server: server, context: context)
  }

  package func cancelRequest(
    server: MCPServerConfig, requestID: String, reason: String?, context: InvocationContext
  ) throws
    -> JSONValue
  {
    try requireServer(server, capability: "mcp.requests.cancel", context: context)
    return try base.cancelRequest(
      server: server, requestID: requestID, reason: reason, context: context)
  }

  private func requireTool(
    _ name: String, server: MCPServerConfig,
    context: InvocationContext
  ) throws {
    let reference = MCPToolReference(serverID: server.id, toolName: name)
    try requireToolGrant(reference, context: context)
    guard
      let tool = try base.listTools(server: server, context: context).first(where: {
        $0.name == name
      })
    else {
      throw GatewayToolError.invalidArguments(
        "[mcp.tool_unavailable] The downstream tool is not in the current catalog.")
    }
    let floor = try tool.declaredRiskFloor
    let policy = try currentPolicy(context: context)
    guard policy.allows(reference, riskFloor: floor) else {
      throw GatewayToolError.invalidArguments(
        "[policy.capability_denied] The profile does not grant the downstream tool's declared risk."
      )
    }
    try context.admission?.validate(
      reference: reference, risk: policy.configuration.mcpRisk(for: reference).raised(to: floor),
      hostServiceAction: tool.hostServiceAction)
  }

  package func readRequest(
    server: MCPServerConfig, requestID: String, offset: Int, maxBytes: Int,
    context: InvocationContext
  ) throws
    -> JSONValue
  {
    try requireServer(server, capability: "mcp.requests.read", context: context)
    let result = try base.readRequest(
      server: server, requestID: requestID, offset: offset, maxBytes: maxBytes, context: context)
    guard let tool = result.objectValue?["tool"]?.stringValue else {
      throw GatewayToolError.executionFailed(
        "Execution receipt is missing its original tool identity.")
    }
    // Receipt reads inspect host-owned output, not a new provider operation.
    // Rediscovery can wait behind the very operation whose receipt is being polled.
    try requireToolGrant(.init(serverID: server.id, toolName: tool), context: context)
    return result
  }

  private func requireToolGrant(_ reference: MCPToolReference, context: InvocationContext) throws {
    guard try currentPolicy(context: context).allows(reference) else {
      throw GatewayToolError.invalidArguments(
        "[policy.capability_denied] The profile does not grant this downstream MCP tool.")
    }
  }

  private func requireServer(
    _ server: MCPServerConfig, capability: String, context: InvocationContext
  ) throws {
    guard try currentPolicy(context: context).permitsServer(server, capability: capability) else {
      throw GatewayToolError.invalidArguments(
        "[policy.capability_denied] The profile does not grant this downstream MCP surface.")
    }
  }

}
