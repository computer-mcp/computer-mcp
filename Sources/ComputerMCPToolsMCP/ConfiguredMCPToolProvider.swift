import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPToolKit
import Foundation

/// Holds a validated workspace catalog. The lock serializes discovery and protects the last success.
package final class ConfiguredMCPToolProvider: GatewayToolProvider, @unchecked Sendable {
  package let id = "configured"
  private let mcp: MCPToolProvider
  private let toolDefinitions: [ToolDefinition]?
  private let catalogLock = NSLock()
  private var catalog: [ToolDefinition]?
  private static let calls = BlockingOperationExecutor(
    label: "computer-mcp.configured-mcp-calls", serial: false)

  package init(environment: ToolEnvironment, mcpClient: any DownstreamMCPClient) {
    self.mcp = MCPToolProvider(environment: environment, mcpClient: mcpClient)
    self.toolDefinitions = nil
  }

  private init(mcp: MCPToolProvider, definitions: [ToolDefinition]) {
    self.mcp = mcp
    self.toolDefinitions = definitions
  }

  /// Retains one generation's bindings independently of later discovery and validation failures.
  package func snapshot() throws -> ConfiguredMCPToolProvider {
    try ConfiguredMCPToolProvider(mcp: mcp, definitions: catalogDefinitions(refresh: true))
  }

  package func definitions() throws -> [ToolDefinition] {
    try catalogDefinitions(refresh: true)
  }

  private func catalogDefinitions(refresh: Bool) throws -> [ToolDefinition] {
    if let toolDefinitions { return toolDefinitions }
    return try catalogLock.withLock {
      if !refresh, let catalog { return catalog }
      let definitions = try discoverDefinitions()
      catalog = definitions
      return definitions
    }
  }

  private func catalogTool(named name: String) throws -> MCPTool {
    guard
      let tool = try catalogDefinitions(refresh: false).first(where: { $0.tool.name == name })?.tool
    else { throw GatewayToolError.unknownTool(name) }
    return tool
  }

  private func discoverDefinitions() throws -> [ToolDefinition] {
    let context = InvocationContext.empty
    var definitions = try mcp.definitions()
    let builtinCount = definitions.count
    for configuredTool in mcp.configuration.tools {
      guard let target = configuredTool.tool,
        let server = mcp.configuration.mcp.servers.first(where: { $0.id == configuredTool.source }),
        mcp.mcpClient.isServerVisible(server, context: context), server.permitsTool(target),
        let downstream = try mcp.permittedDownstreamTools(server: server, context: context).first(
          where: { $0.name == target })
      else { continue }
      let tool = try toolDefinition(for: configuredTool, downstream: downstream)
      try appendDefinition(try downstreamDefinition(for: tool), to: &definitions)
    }

    for server in mcp.configuration.mcp.servers where server.exposure.includesReexport {
      guard let prefix = server.prefix else {
        throw GatewayToolError.invalidArguments(
          "MCP server '\(server.id)' uses reexport exposure but has no prefix.")
      }
      let downstreamDefinitions = try mcp.permittedDownstreamTools(server: server, context: context)
        .map {
          try downstreamDefinition(for: $0.prefixed(prefix, serverID: server.id))
        }
      let existing = Set(definitions.map(\.tool.name))
      if let conflict = downstreamDefinitions.first(where: { existing.contains($0.tool.name) }) {
        throw GatewayToolError.invalidArguments(
          "Reexported tool name conflicts: \(conflict.tool.name)")
      }
      definitions.append(contentsOf: downstreamDefinitions)
    }
    return Array(definitions.dropFirst(builtinCount))
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let definition = try catalogTool(named: invocation.name)
    let reference = try reference(for: definition, context: invocation.context)
    return try mcp.mcpClient.callTool(
      server: reference.server, name: reference.toolName,
      arguments: invocation.arguments ?? .object([:]), context: invocation.context)
  }

  package func callToolAsync(_ invocation: ToolInvocation) async throws -> JSONValue {
    try Task.checkCancellation()
    let definition = try await Self.calls.perform { try self.catalogTool(named: invocation.name) }
    try Task.checkCancellation()
    let reference = try reference(for: definition, context: invocation.context)
    return try await mcp.mcpClient.callToolAsync(
      server: reference.server, name: reference.toolName,
      arguments: invocation.arguments ?? .object([:]), requestID: nil, context: invocation.context)
  }

  private func reference(for definition: MCPTool, context: InvocationContext) throws
    -> (server: MCPServerConfig, toolName: String)
  {
    guard let reference = definition.mcpReference else {
      throw GatewayToolError.invalidArguments(
        "Downstream tool '\(definition.name)' requires a registered MCP reference.")
    }
    let server = try mcp.mcpServer(reference.serverID, context: context)
    try mcp.requireDownstreamToolAllowed(reference.toolName, server: server)
    return (server, reference.toolName)
  }

  private func toolDefinition(for tool: ToolConfig, downstream: MCPTool) throws -> MCPTool {
    MCPTool(
      name: tool.name,
      description: tool.description
        ?? "Call configured \(tool.adapter.rawValue) tool \(tool.name).",
      inputSchema: try tool.inputSchemaValue(),
      outputSchema: nil,
      meta: downstream.meta,
      mcpReference: tool.tool.map { MCPToolReference(serverID: tool.source, toolName: $0) }
    )
  }

  private func appendDefinition(
    _ definition: ToolDefinition, to definitions: inout [ToolDefinition]
  ) throws {
    if definitions.contains(where: { $0.tool.name == definition.tool.name }) {
      throw GatewayToolError.invalidArguments(
        "Configured tool name conflicts: \(definition.tool.name)")
    }
    definitions.append(definition)
  }

  private func downstreamDefinition(for tool: MCPTool) throws -> ToolDefinition {
    guard let reference = tool.mcpReference else {
      throw GatewayToolError.invalidArguments(
        "Downstream tool '\(tool.name)' requires a registered MCP reference.")
    }
    return ToolDefinition(
      tool: tool,
      capability: CapabilityDescriptor(
        id: tool.name,
        risk: try mcp.configuration.mcpRisk(for: reference, declaredBy: tool),
        workspaceRequirement: .optional,
        usesNetwork: true,
        mcpReference: reference,
        equivalentCapabilityIDs: mcp.configuration.mcpCapabilityIDs(for: reference),
        hostServiceAction: try tool.hostServiceAction
      )
    )
  }

}
