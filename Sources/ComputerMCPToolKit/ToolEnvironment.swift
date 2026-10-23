import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import Foundation

/// Project-owned inputs shared by tool providers. The host owns runtime shutdown.
package struct ToolEnvironment: Sendable {
  package let launcher: ExecutionLauncher
  package let configuration: GatewayConfiguration
  package let projectScope: ProjectScope
  package let registeredCommands: RegisteredCommands
  package let commandRunner: any CommandRunning
  package let environment: [String: String]
  package let processManager: any ProcessManaging
  package let shellManager: any ShellManaging
  package let extendedAttributes: (any ExtendedAttributes)?
  package let fileTrasher: (any FileTrashing)?
  package let projectOpener: (any ProjectOpener)?
  package let systemProbe: (any SystemProbe)?
  package let mediaInspector: (any MediaInspector)?

  package init(
    launcher: ExecutionLauncher = ExecutionLauncher(),
    configuration: GatewayConfiguration,
    commandRunner: (any CommandRunning)? = nil,
    processManager: (any ProcessManaging)? = nil,
    shellManager: (any ShellManaging)? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    mediaInspector: (any MediaInspector)? = nil,
    sqliteCommand: CLICommandConfig? = nil,
    builtinExecutables: [String: String] = [:],
    extendedAttributes: (any ExtendedAttributes)? = nil,
    fileTrasher: (any FileTrashing)? = nil,
    projectOpener: (any ProjectOpener)? = nil,
    systemProbe: (any SystemProbe)? = nil
  ) {
    self.launcher = launcher
    self.configuration = configuration
    let toolMeta: JSONValue? =
      configuration.server.http.accessTokenEnv == nil
      ? .object(["securitySchemes": .array([.object(["type": .string("noauth")])])]) : nil
    self.projectScope = ProjectScope(configuration: configuration, toolMeta: toolMeta)
    let commandRunner =
      commandRunner ?? ProcessCommandRunner(launcher: launcher, environment: environment)
    self.commandRunner = commandRunner
    self.registeredCommands = RegisteredCommands(
      configuration: configuration, launcher: launcher, commandRunner: commandRunner,
      environment: environment,
      sqliteCommand: sqliteCommand, builtinExecutables: builtinExecutables)
    self.environment = environment
    let shells = shellManager ?? ShellSessionRuntime(launcher: launcher)
    self.processManager = processManager ?? ManagedProcessRegistry(launcher: launcher)
    self.shellManager = shells
    self.systemProbe = systemProbe
    self.mediaInspector = mediaInspector
    self.extendedAttributes = extendedAttributes
    self.fileTrasher = fileTrasher
    self.projectOpener = projectOpener
  }
}
