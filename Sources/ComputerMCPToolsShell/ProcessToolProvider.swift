import ComputerMCPCore
import ComputerMCPProcess
import ComputerMCPToolKit

package struct ProcessToolProvider: GatewayToolProvider {
  package let id = "process"
  package let namespaces = ["process"]
  let environment: ToolEnvironment

  package init(environment: ToolEnvironment) {
    self.environment = environment
  }

  package func definitions() throws -> [ToolDefinition] {
    guard !environment.configuration.cli.commands.isEmpty else { return [] }
    return Self.toolDefinitions(toolMeta: environment.projectScope.toolMeta)
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let descriptor = try definitions().first { $0.tool.name == invocation.name }?.capability
    let policy: HostExecutionPolicy =
      descriptor == nil || descriptor?.risk == .readOnly
        || descriptor?.projectRequirement == ProjectRequirement.none ? .readOnly : .fullAccess
    return try ExecutionRecovery.$key.withValue(invocation.context.executionRecoveryKey) {
      try HostExecutionPolicy.$current.withValue(policy) { try dispatch(invocation) }
    }
  }

  private func dispatch(_ invocation: ToolInvocation) throws -> JSONValue {
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

    case "process.write":
      try requireCLIProviders()
      return try textResult(writeProcess(arguments: object))

    case "process.cancel":
      try requireCLIProviders()
      return try textResult(cancelProcess(arguments: object))

    default:
      throw GatewayToolError.unknownTool(name)
    }
  }
}
