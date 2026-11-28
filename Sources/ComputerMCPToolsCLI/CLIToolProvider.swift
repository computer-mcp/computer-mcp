import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPProcess
import ComputerMCPToolKit
import Foundation

package struct CLIToolProvider: GatewayToolProvider {
  package let id = "cli"
  package let namespaces = ["cli"]
  let environment: ToolEnvironment
  private let providerDiscovery: @Sendable (CLICommandConfig) throws -> CLIProviderDiscovery?
  let discoveryCache = CLIProviderTreeCache()

  package init(
    environment: ToolEnvironment,
    providerDiscovery: @escaping @Sendable (CLICommandConfig) throws -> CLIProviderDiscovery? = {
      _ in nil
    }
  ) {
    self.environment = environment
    self.providerDiscovery = providerDiscovery
  }

  package func definitions() throws -> [ToolDefinition] {
    guard !environment.configuration.cli.commands.isEmpty else { return [] }
    var definitions = Self.toolDefinitions(toolMeta: environment.projectScope.toolMeta)
    if !discoveryCache.diagnostics.isEmpty,
      let index = definitions.firstIndex(where: { $0.tool.name == "cli.list" })
    {
      var meta = definitions[index].tool.meta?.objectValue ?? [:]
      meta["discovery_errors"] = .object(discoveryCache.diagnostics.mapValues(JSONValue.string))
      let definition = definitions[index]
      let tool = definition.tool
      definitions[index] = ToolDefinition(
        tool: MCPTool(
          name: tool.name, title: tool.title,
          description: tool.description, inputSchema: tool.inputSchema,
          outputSchema: tool.outputSchema,
          annotations: tool.annotations, meta: .object(meta), mcpReference: tool.mcpReference),
        capability: definition.capability)
    }
    return definitions
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    return try dispatch(invocation)
  }

  private func dispatch(_ invocation: ToolInvocation) throws -> JSONValue {
    let name = invocation.name
    let object = invocation.arguments?.objectValue ?? [:]
    switch name {
    case "cli.list":
      try requireCLIProviders()
      return try textResult(cliList())

    case "cli.describe":
      try requireCLIProviders()
      return try textResult(cliDescribe(arguments: object))

    case "cli.status":
      try requireCLIProviders()
      return try textResult(cliStatus(arguments: object))

    case "cli.help":
      try requireCLIProviders()
      return try textResult(runCLIHelp(arguments: object))

    case "cli.exec":
      try requireCLIProviders()
      return try textResult(runCLIExec(arguments: object))

    default:
      throw GatewayToolError.unknownTool(name)
    }
  }

  /// Loads an immutable provider generation for each configured CLI tree.
  package func treeProviders() throws -> [any GatewayToolProvider] {
    try environment.configuration.cli.commands.compactMap { command in
      guard let source = command.tree else { return nil }
      let discovery: CLIProviderDiscovery?
      do { discovery = source.kind == .file ? nil : try providerDiscovery(command) } catch {
        discoveryCache.failed(command.id, error: error)
        return nil
      }
      if discovery == nil, source.kind != .file {
        // A plugin exporter runs only as provider discovery, never under the caller's execution.
        guard source.packageRoot == nil else {
          discoveryCache.failed(
            command.id,
            error: GatewayToolError.executionFailed(
              "Plugin CLI tree discovery is unavailable in this context."))
          return nil
        }
        // Direct registrations retain caller-bound executable inspection.
        guard InvocationExecution.current != nil else { return nil }
      }
      var command = command
      command.env = environment.environment.merging(command.env) { _, value in value }
      let tree: CLITree
      if let discovery {
        do {
          tree = try discoveryCache.load(
            command: command,
            project: environment.configuration.projectDirectory, discovery: discovery,
            execution: environment.registeredCommands.inspectionExecution)
        } catch {
          return nil
        }
      } else {
        tree = try source.load(
          command: command, project: environment.configuration.projectDirectory,
          execution: environment.registeredCommands.inspectionExecution)
      }
      return CLITreeToolProvider(
        registration: command, tree: tree, project: environment.configuration.projectDirectory,
        execution: environment.registeredCommands.execution,
        timeoutMilliseconds: command.defaultTimeoutMs
          ?? environment.configuration.policy.defaultTimeoutMs,
        maxOutputBytes: environment.configuration.policy.maxOutputBytes)
    }
  }
}
