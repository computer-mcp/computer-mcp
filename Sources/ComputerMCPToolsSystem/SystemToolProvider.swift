import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPToolKit

package struct SystemToolProvider: GatewayToolProvider {
  package let id = "system"
  package let namespaces = ["system", "logs", "service", "env"]
  let environment: ToolEnvironment
  let configuration: GatewayConfiguration

  package init(environment: ToolEnvironment) {
    self.environment = environment
    var configuration = environment.configuration
    let disabledMCPIDs = Set(configuration.mcp.servers.filter { !$0.enabled }.map(\.id))
    configuration.mcp.servers.removeAll { !$0.enabled }
    configuration.tools.removeAll { disabledMCPIDs.contains($0.source) }
    self.configuration = configuration
  }

  var processEnvironment: [String: String] { environment.environment }

  var projectScope: ProjectScope { environment.projectScope }
  var registeredCommands: RegisteredCommands { environment.registeredCommands }
  var commandRunner: any CommandRunning { environment.commandRunner }

  package func definitions() throws -> [ToolDefinition] {
    Self.toolDefinitions(toolMeta: projectScope.toolMeta).filter {
      configuration.builtin.enabled.contains($0.tool.name)
    }.sorted { $0.tool.name < $1.tool.name }
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let name = invocation.name
    let object = invocation.arguments?.objectValue ?? [:]
    switch name {
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

    case "env.describe":
      try requireBuiltinEnabled(name)
      return try textResult(describeEnvironment())

    default:
      throw GatewayToolError.unknownTool(name)
    }
  }

  private func requireBuiltinEnabled(_ name: String) throws {
    guard configuration.builtin.enabled.contains(name) else {
      throw GatewayToolError.disabled("\(name) is disabled by configuration.")
    }
  }
}
