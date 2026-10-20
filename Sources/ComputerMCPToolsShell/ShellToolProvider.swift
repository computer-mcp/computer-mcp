import ComputerMCPCore
import ComputerMCPToolKit

package struct ShellToolProvider: GatewayToolProvider {
  package let id = "shell"
  let environment: ToolEnvironment

  package init(environment: ToolEnvironment) {
    self.environment = environment
  }

  package func definitions() throws -> [ToolDefinition] {
    Self.toolDefinitions(toolMeta: environment.workspaceScope.toolMeta).filter { definition in
      if definition.tool.name.hasPrefix("process.") {
        return !environment.configuration.cli.commands.isEmpty
      }
      return environment.configuration.policy.shellEnabled
    }
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let name = invocation.name
    let object = invocation.arguments?.objectValue ?? [:]
    switch name {
    case "process.spawn":
      try requireCLIProviders()
      return try textResult(spawnProcess(arguments: object))

    case "process.list":
      try requireCLIProviders()
      return try textResult(listProcesses())

    case "process.read":
      try requireCLIProviders()
      return try textResult(readProcess(arguments: object))

    case "process.cancel":
      try requireCLIProviders()
      return try textResult(cancelProcess(arguments: object))

    case "shell.run":
      try requireShellEnabled()
      return try textResult(runShell(arguments: object))

    case "shell.spawn":
      try requireShellEnabled()
      return try textResult(spawnShell(arguments: object))

    case "shell.list":
      try requireShellEnabled()
      return try textResult(listShellSessions(arguments: object))

    case "shell.read":
      try requireShellEnabled()
      return try textResult(readShellSession(arguments: object))

    case "shell.write":
      try requireShellEnabled()
      return try textResult(writeShellSession(arguments: object))

    case "shell.cancel":
      try requireShellEnabled()
      return try textResult(cancelShellSession(arguments: object))

    default:
      throw GatewayToolError.unknownTool(name)
    }
  }
}
