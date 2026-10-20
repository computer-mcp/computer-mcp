import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPToolKit

package struct CLIToolProvider: GatewayToolProvider {
  package let id = "cli"
  let environment: ToolEnvironment

  package init(environment: ToolEnvironment) {
    self.environment = environment
  }

  package func definitions() throws -> [ToolDefinition] {
    guard !environment.configuration.cli.commands.isEmpty else { return [] }
    return Self.toolDefinitions(toolMeta: environment.workspaceScope.toolMeta)
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
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
      var command = command
      command.env = environment.environment.merging(command.env) { _, value in value }
      let tree = try source.load(
        command: command, workspace: environment.configuration.workspaceDirectory,
        execution: environment.registeredCommands.execution)
      return CLITreeToolProvider(
        registration: command, tree: tree, workspace: environment.configuration.workspaceDirectory,
        execution: environment.registeredCommands.execution,
        timeoutMilliseconds: command.defaultTimeoutMs
          ?? environment.configuration.policy.defaultTimeoutMs,
        maxOutputBytes: environment.configuration.policy.maxOutputBytes)
    }
  }
}
