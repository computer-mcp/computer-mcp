import ComputerMCPCore
import ComputerMCPToolKit

package struct ProcessToolProvider: GatewayToolProvider {
  package let id = "process"
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

    default:
      throw GatewayToolError.unknownTool(name)
    }
  }
}
