import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPToolKit

package struct MCPToolProvider: GatewayToolProvider {
  package let id = "mcp"
  package let namespaces = ["mcp"]
  let environment: ToolEnvironment
  let configuration: GatewayConfiguration
  let mcpClient: any DownstreamMCPClient

  /// The composition root supplies a client scoped to this project and owns its shutdown.
  package init(environment: ToolEnvironment, mcpClient: any DownstreamMCPClient) {
    self.environment = environment
    self.mcpClient = mcpClient
    var configuration = environment.configuration
    let disabledMCPIDs = Set(configuration.mcp.servers.filter { !$0.enabled }.map(\.id))
    configuration.mcp.servers.removeAll { !$0.enabled }
    configuration.tools.removeAll { disabledMCPIDs.contains($0.source) }
    self.configuration = configuration
  }

  var registeredCommands: RegisteredCommands { environment.registeredCommands }

  package func definitions() throws -> [ToolDefinition] {
    configuration.mcp.servers.isEmpty
      ? [] : Self.toolDefinitions(toolMeta: environment.projectScope.toolMeta)
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let name = invocation.name
    let object = invocation.arguments?.objectValue ?? [:]
    let context = invocation.context
    switch name {
    case "mcp.servers.list":
      try requireMCPProviders()
      return try textResult(mcpServerList(context: context))

    case "mcp.servers.status":
      try requireMCPProviders()
      return try textResult(mcpServerStatus(arguments: object, context: context))

    case "mcp.tools.list":
      try requireMCPProviders()
      return try textResult(listDownstreamMCPTools(arguments: object, context: context))

    case "mcp.tools.describe":
      try requireMCPProviders()
      return try textResult(describeDownstreamMCPTool(arguments: object, context: context))

    case "mcp.tools.find":
      try requireMCPProviders()
      return try textResult(findDownstreamMCPTools(arguments: object, context: context))

    case "mcp.tools.call":
      try requireMCPProviders()
      return try callDownstreamMCPTool(arguments: object, context: context)

    case "mcp.resources.list":
      try requireMCPProviders()
      return try textResult(listDownstreamMCPResources(arguments: object, context: context))

    case "mcp.resources.templates.list":
      try requireMCPProviders()
      return try textResult(listDownstreamMCPResourceTemplates(arguments: object, context: context))

    case "mcp.resources.read":
      try requireMCPProviders()
      return try textResult(readDownstreamMCPResource(arguments: object, context: context))

    case "mcp.prompts.list":
      try requireMCPProviders()
      return try textResult(listDownstreamMCPPrompts(arguments: object, context: context))

    case "mcp.prompts.get":
      try requireMCPProviders()
      return try textResult(getDownstreamMCPPrompt(arguments: object, context: context))

    case "mcp.events.read":
      try requireMCPProviders()
      return try textResult(readDownstreamMCPEvents(arguments: object, context: context))

    case "mcp.requests.list":
      try requireMCPProviders()
      return try textResult(listDownstreamMCPRequests(arguments: object, context: context))

    case "mcp.requests.read":
      try requireMCPProviders()
      return try textResult(readDownstreamMCPRequest(arguments: object, context: context))

    case "mcp.requests.cancel":
      try requireMCPProviders()
      return try textResult(cancelDownstreamMCPRequest(arguments: object, context: context))

    case "mcp.connections.close":
      try requireMCPProviders()
      guard Set(object.keys) == ["server"] else {
        throw GatewayToolError.invalidArguments("Supply only the selected MCP server id.")
      }
      return try textResult(
        mcpClient.closeConnection(
          server: mcpServer(requiredString("server", in: object), context: context),
          context: context))

    default:
      throw GatewayToolError.unknownTool(name)
    }
  }

  package func callToolAsync(_ invocation: ToolInvocation) async throws -> JSONValue {
    try Task.checkCancellation()
    if invocation.name == "mcp.tools.call" {
      try requireMCPProviders()
      let object = invocation.arguments?.objectValue ?? [:]
      if try optionalBool("wait_for_result", in: object) ?? true {
        let server = try mcpServer(
          requiredString("server", in: object), context: invocation.context)
        let name = try requiredString("tool", in: object)
        try requireDownstreamToolAllowed(name, server: server)
        return try textResult(
          await mcpClient.callToolAsync(
            server: server, name: name, arguments: object["arguments"] ?? .object([:]),
            requestID: optionalString("request_id", in: object), context: invocation.context))
      }
    }
    return try await Self.calls.perform { try self.callTool(invocation) }
  }

  package func downstreamPolicy(
    for reference: MCPToolReference, context: InvocationContext
  ) throws -> MCPToolAdmissionPolicy {
    let server = try mcpServer(reference.serverID, context: context)
    try requireDownstreamToolAllowed(reference.toolName, server: server)
    guard
      let tool = try permittedDownstreamTools(server: server, context: context).first(where: {
        $0.name == reference.toolName
      })
    else {
      throw GatewayToolError.invalidArguments(
        "[mcp.tool_unavailable] The downstream tool is not available in the current authorized catalog."
      )
    }
    return try .init(
      risk: configuration.mcpRisk(for: reference, declaredBy: tool),
      hostServiceAction: tool.hostServiceAction)
  }

  private static let calls = BlockingOperationExecutor(
    label: "computer-mcp.mcp-calls", serial: false)
}
