import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPToolKit
import Foundation
import NIOConcurrencyHelpers

/// Owns configured source definitions, gateway tool schemas, and dispatch.
package final class GatewayToolRegistry: @unchecked Sendable {
  private static let calls = BlockingOperationExecutor(
    label: "computer-mcp.registry-calls", serial: false)

  // Shared host-scope definitions survive failed listings. The lock also serializes discovery.
  private let catalog = NIOLockedValueBox<[ToolDefinition]?>(nil)

  internal let configuration: GatewayConfiguration

  internal let workspaceScope: WorkspaceScope

  internal let commandRunner: CommandRunning

  private let shellManager: ShellManaging

  internal let mcpClient: DownstreamMCPClient

  internal let environment: [String: String]

  internal let registeredCommands: RegisteredCommands

  package convenience init(
    configuration: GatewayConfiguration,
    commandRunner: CommandRunning? = nil,
    processManager: ProcessManaging = ManagedProcessRegistry(),
    shellManager: ShellManaging = SubprocessShellRuntime(),
    mcpClient: DownstreamMCPClient = MCPProxyClient(),
    hostContext: MCPHostContext? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.init(
      toolEnvironment: ToolEnvironment(
        configuration: configuration, commandRunner: commandRunner,
        processManager: processManager, shellManager: shellManager, environment: environment),
      mcpClient: mcpClient, hostContext: hostContext)
  }

  package init(
    toolEnvironment: ToolEnvironment,
    mcpClient: DownstreamMCPClient = MCPProxyClient(),
    hostContext: MCPHostContext? = nil
  ) {
    let configuration = toolEnvironment.configuration
    var enabledConfiguration = configuration
    let disabledMCPIDs = Set(configuration.mcp.servers.filter { !$0.enabled }.map(\.id))
    enabledConfiguration.mcp.servers.removeAll { !$0.enabled }
    enabledConfiguration.tools.removeAll { disabledMCPIDs.contains($0.source) }
    self.configuration = enabledConfiguration
    self.workspaceScope = toolEnvironment.workspaceScope
    self.commandRunner = toolEnvironment.commandRunner
    self.registeredCommands = toolEnvironment.registeredCommands
    self.shellManager = toolEnvironment.shellManager
    self.environment = toolEnvironment.environment
    self.mcpClient = mcpClient.makeScopedClient(
      workingDirectory: configuration.workspaceDirectory, environment: toolEnvironment.environment,
      hostContext: hostContext)
  }

  internal var hasReexportedMCPServers: Bool {
    configuration.mcp.servers.contains { $0.exposure.includesReexport }
  }

  internal var hasCLITrees: Bool { configuration.cli.commands.contains { $0.tree != nil } }

  package func toolChanges(context: InvocationContext) -> AsyncStream<Void> {
    mcpClient.toolChanges()
  }

  package func shutdown() async {
    await shellManager.shutdown()
    await registeredCommands.execution.shutdown()
    await mcpClient.shutdown()
  }

  /// Registered gateway and optionally reexported downstream MCP tools.
  package func listTools(context: InvocationContext) throws -> [MCPTool] {
    try definitions(context: context).map(\.tool)
  }

  package func definitions(context: InvocationContext) throws -> [ToolDefinition] {
    try catalogDefinitions(refresh: true)
  }

  private func catalogDefinitions(refresh: Bool) throws -> [ToolDefinition] {
    try catalog.withLockedValue { catalog in
      if !refresh, let catalog { return catalog }
      let definitions = try discoverDefinitions()
      catalog = definitions
      return definitions
    }
  }

  private func catalogTool(named name: String) throws -> MCPTool? {
    try catalogDefinitions(refresh: false).first(where: { $0.tool.name == name })?.tool
  }

  private func discoverDefinitions() throws -> [ToolDefinition] {
    let context = InvocationContext.empty
    var definitions = Self.gatewayDefinitions(
      builtins: Set(configuration.builtin.enabled),
      hasMCPProviders: !configuration.mcp.servers.isEmpty,
      toolMeta: workspaceScope.toolMeta
    )

    for configuredTool in configuration.tools {
      guard let target = configuredTool.tool,
        let server = configuration.mcp.servers.first(where: { $0.id == configuredTool.source }),
        mcpClient.isServerVisible(server, context: context), server.permitsTool(target),
        let downstream = try permittedDownstreamTools(server: server, context: context).first(
          where: {
            $0.name == target
          })
      else { continue }
      let tool = try toolDefinition(for: configuredTool, downstream: downstream)
      try appendDefinition(try downstreamDefinition(for: tool), to: &definitions)
    }

    for server in configuration.mcp.servers where server.exposure.includesReexport {
      guard let prefix = server.prefix else {
        throw GatewayToolError.invalidArguments(
          "MCP server '\(server.id)' uses reexport exposure but has no prefix.")
      }
      let downstreamDefinitions = try permittedDownstreamTools(server: server, context: context).map
      {
        try downstreamDefinition(for: $0.prefixed(prefix, serverID: server.id))
      }
      let existing = Set(definitions.map(\.tool.name))
      if let conflict = downstreamDefinitions.first(where: { existing.contains($0.tool.name) }) {
        throw GatewayToolError.invalidArguments(
          "Reexported tool name conflicts: \(conflict.tool.name)")
      }
      definitions.append(contentsOf: downstreamDefinitions)
    }

    return definitions
  }

  /// Validates arguments, executes a tool, and returns MCP tool content.
  package func callTool(name: String, arguments: JSONValue?, context: InvocationContext)
    throws -> JSONValue
  {
    if let definition = try catalogTool(named: name), definition.mcpReference != nil {
      return try callTool(definition: definition, arguments: arguments, context: context)
    }
    let object = arguments?.objectValue ?? [:]

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

    case "system.info":
      try requireBuiltinEnabled(name)
      return try textResult(systemInfo())

    case "system.kernel":
      try requireBuiltinEnabled(name)
      return try textResult(systemKernel())

    case "system.software":
      try requireBuiltinEnabled(name)
      return try textResult(systemSoftware(arguments: object))

    case "system.locale":
      try requireBuiltinEnabled(name)
      return try textResult(systemLocale())

    case "system.memory":
      try requireBuiltinEnabled(name)
      return try textResult(systemMemory())

    case "system.load":
      try requireBuiltinEnabled(name)
      return try textResult(systemLoad())

    case "system.cpu":
      try requireBuiltinEnabled(name)
      return try textResult(systemCPU())

    case "system.thermal":
      try requireBuiltinEnabled(name)
      return try textResult(systemThermal())

    case "system.time":
      try requireBuiltinEnabled(name)
      return try textResult(systemTime())

    case "system.uptime":
      try requireBuiltinEnabled(name)
      return try textResult(systemUptime())

    case "system.user":
      try requireBuiltinEnabled(name)
      return try textResult(systemUser())

    case "system.groups":
      try requireBuiltinEnabled(name)
      return try textResult(systemGroups())

    case "system.power":
      try requireBuiltinEnabled(name)
      return try textResult(systemPower(arguments: object))

    case "system.volumes":
      try requireBuiltinEnabled(name)
      return try textResult(systemVolumes(arguments: object))

    case "system.processes":
      try requireBuiltinEnabled(name)
      return try textResult(systemProcesses(arguments: object))

    case "system.which":
      try requireBuiltinEnabled(name)
      return try textResult(systemWhich(arguments: object))

    case "system.path":
      try requireBuiltinEnabled(name)
      return try textResult(systemPath(arguments: object))

    case "logs.query":
      try requireBuiltinEnabled(name)
      return try textResult(logsQuery(arguments: object))

    case "service.status":
      try requireBuiltinEnabled(name)
      return try textResult(serviceStatus(arguments: object))

    case "network.interfaces":
      try requireBuiltinEnabled(name)
      return try textResult(networkInterfaces(arguments: object))

    case "network.dns":
      try requireBuiltinEnabled(name)
      return try textResult(networkDNS(arguments: object))

    case "network.resolve":
      try requireBuiltinEnabled(name)
      return try textResult(networkResolve(arguments: object))

    case "network.proxy":
      try requireBuiltinEnabled(name)
      return try textResult(networkProxy(arguments: object))

    case "network.services":
      try requireBuiltinEnabled(name)
      return try textResult(networkServices(arguments: object))

    case "network.hardware_ports":
      try requireBuiltinEnabled(name)
      return try textResult(networkHardwarePorts(arguments: object))

    case "network.wifi":
      try requireBuiltinEnabled(name)
      return try textResult(networkWiFi(arguments: object))

    case "network.vpn":
      try requireBuiltinEnabled(name)
      return try textResult(networkVPN(arguments: object))

    case "network.locations":
      try requireBuiltinEnabled(name)
      return try textResult(networkLocations(arguments: object))

    case "network.routes":
      try requireBuiltinEnabled(name)
      return try textResult(networkRoutes(arguments: object))

    case "network.connections":
      try requireBuiltinEnabled(name)
      return try textResult(networkConnections(arguments: object))

    case "network.arp":
      try requireBuiltinEnabled(name)
      return try textResult(networkARP(arguments: object))

    case "network.ping":
      try requireBuiltinEnabled(name)
      return try textResult(networkPing(arguments: object))

    case "network.tcp_check":
      try requireBuiltinEnabled(name)
      return try textResult(networkTCPCheck(arguments: object))

    case "network.http_check":
      try requireBuiltinEnabled(name)
      return try textResult(networkHTTPCheck(arguments: object))

    case "network.listeners":
      try requireBuiltinEnabled(name)
      return try textResult(networkListeners(arguments: object))

    case "macos.user_directories":
      try requireBuiltinEnabled(name)
      return try textResult(macOSUserDirectories(arguments: object))

    case "macos.default_application":
      try requireBuiltinEnabled(name)
      return try textResult(macOSDefaultApplication(arguments: object))

    case "macos.applications":
      try requireBuiltinEnabled(name)
      return try textResult(macOSApplications(arguments: object))

    case "macos.screens":
      try requireBuiltinEnabled(name)
      return try textResult(macOSScreens())

    case "macos.spotlight_search":
      try requireBuiltinEnabled(name)
      return try textResult(macOSSpotlightSearch(arguments: object))

    case "macos.running_applications":
      try requireBuiltinEnabled(name)
      return try textResult(macOSRunningApplications(arguments: object))

    case "macos.frontmost_application":
      try requireBuiltinEnabled(name)
      return try textResult(macOSFrontmostApplication())

    case "env.describe":
      try requireBuiltinEnabled(name)
      return try textResult(describeEnvironment())

    default:
      throw GatewayToolError.unknownTool(name)
    }
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

  private func requireBuiltinEnabled(_ name: String) throws {
    guard configuration.builtin.enabled.contains(name) else {
      throw GatewayToolError.disabled("\(name) is disabled by configuration.")
    }
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
        risk: try configuration.mcpRisk(for: reference, declaredBy: tool),
        workspaceRequirement: .optional,
        usesNetwork: true,
        mcpReference: reference,
        equivalentCapabilityIDs: configuration.mcpCapabilityIDs(for: reference),
        hostServiceAction: try tool.hostServiceAction
      )
    )
  }

  internal func downstreamPolicy(
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

  internal func callTool(
    definition: MCPTool, arguments: JSONValue?, context: InvocationContext
  ) throws -> JSONValue {
    guard let reference = definition.mcpReference else {
      return try callTool(name: definition.name, arguments: arguments, context: context)
    }
    let server = try mcpServer(reference.serverID, context: context)
    try requireDownstreamToolAllowed(reference.toolName, server: server)
    return try mcpClient.callTool(
      server: server, name: reference.toolName, arguments: arguments ?? .object([:]),
      context: context)
  }

  internal func callToolAsync(
    definition tool: MCPTool, arguments: JSONValue?, context: InvocationContext
  ) async throws -> JSONValue {
    try Task.checkCancellation()
    let definition: MCPTool
    if tool.mcpReference == nil {
      definition = try await Self.calls.perform {
        try self.catalogTool(named: tool.name) ?? tool
      }
    } else {
      definition = tool
    }
    try Task.checkCancellation()
    if let reference = definition.mcpReference {
      let server = try mcpServer(reference.serverID, context: context)
      try requireDownstreamToolAllowed(reference.toolName, server: server)
      return try await mcpClient.callToolAsync(
        server: server, name: reference.toolName, arguments: arguments ?? .object([:]),
        requestID: nil, context: context)
    }
    if definition.name == "mcp.tools.call" {
      let object = arguments?.objectValue ?? [:]
      if try optionalBool("wait_for_result", in: object) ?? true {
        let server = try mcpServer(requiredString("server", in: object), context: context)
        let name = try requiredString("tool", in: object)
        try requireDownstreamToolAllowed(name, server: server)
        return try textResult(
          await mcpClient.callToolAsync(
            server: server, name: name, arguments: object["arguments"] ?? .object([:]),
            requestID: optionalString("request_id", in: object), context: context))
      }
    }
    return try await Self.calls.perform {
      try self.callTool(definition: definition, arguments: arguments, context: context)
    }
  }
}
