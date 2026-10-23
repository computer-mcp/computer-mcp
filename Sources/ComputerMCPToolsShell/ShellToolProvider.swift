import ComputerMCPCore
import ComputerMCPProcess
import ComputerMCPToolKit

package struct ShellToolProvider: GatewayToolProvider {
  private static let blocking = BlockingOperationExecutor(
    label: "computer-mcp.shell-calls", serial: false)
  package let id = "shell"
  package let namespaces = ["shell"]
  let environment: ToolEnvironment

  package init(environment: ToolEnvironment) {
    self.environment = environment
  }

  package func definitions() throws -> [ToolDefinition] {
    guard environment.configuration.policy.shellEnabled else { return [] }
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

  package func callToolAsync(_ invocation: ToolInvocation) async throws -> JSONValue {
    try Task.checkCancellation()
    if invocation.name == "shell.write" {
      try requireShellEnabled()
      return try await ExecutionRecovery.$key.withValue(invocation.context.executionRecoveryKey) {
        try textResult(
          await writeShellSessionAsync(arguments: invocation.arguments?.objectValue ?? [:]))
      }
    }
    return try await Self.blocking.perform { try self.callTool(invocation) }
  }

}
