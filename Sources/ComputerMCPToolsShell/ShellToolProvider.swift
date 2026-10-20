import ComputerMCPCore
import ComputerMCPToolKit

package struct ShellToolProvider: GatewayToolProvider {
  package let id = "shell"
  package let namespaces = ["shell"]
  let environment: ToolEnvironment

  package init(environment: ToolEnvironment) {
    self.environment = environment
  }

  package func definitions() throws -> [ToolDefinition] {
    guard environment.configuration.policy.shellEnabled else { return [] }
    return Self.toolDefinitions(toolMeta: environment.workspaceScope.toolMeta)
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let name = invocation.name
    let object = invocation.arguments?.objectValue ?? [:]
    switch name {
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
