import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import Foundation

/// Workspace-owned inputs shared by tool providers. The host owns runtime shutdown.
package struct ToolEnvironment: Sendable {
  package let configuration: GatewayConfiguration
  package let workspaceScope: WorkspaceScope
  package let registeredCommands: RegisteredCommands
  package let commandRunner: any CommandRunning
  package let environment: [String: String]
  package let processManager: any ProcessManaging
  package let shellManager: any ShellManaging

  package init(
    configuration: GatewayConfiguration,
    commandRunner: (any CommandRunning)? = nil,
    processManager: any ProcessManaging = ManagedProcessRegistry(),
    shellManager: any ShellManaging = SubprocessShellRuntime(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.configuration = configuration
    let toolMeta: JSONValue? =
      configuration.server.http.accessTokenEnv == nil
      ? .object(["securitySchemes": .array([.object(["type": .string("noauth")])])]) : nil
    self.workspaceScope = WorkspaceScope(configuration: configuration, toolMeta: toolMeta)
    let commandRunner = commandRunner ?? ProcessCommandRunner(environment: environment)
    self.commandRunner = commandRunner
    self.registeredCommands = RegisteredCommands(
      configuration: configuration, commandRunner: commandRunner, environment: environment)
    self.environment = environment
    self.processManager = processManager
    self.shellManager = shellManager
  }
}
