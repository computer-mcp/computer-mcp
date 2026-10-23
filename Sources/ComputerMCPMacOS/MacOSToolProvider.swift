import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPToolKit

package struct MacOSToolProvider: GatewayToolProvider {
  package let id = "macos"
  package let namespaces = ["macos"]
  let environment: ToolEnvironment
  let configuration: GatewayConfiguration

  package init(environment: ToolEnvironment) {
    self.environment = environment
    self.configuration = environment.configuration
  }

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
    case "macos.user_directories":
      try requireBuiltinEnabled(name)
      return try textResult(macOSUserDirectories(arguments: object))

    case "macos.default_application":
      try requireBuiltinEnabled(name)
      return try textResult(macOSDefaultApplication(arguments: object))

    case "macos.applications":
      try requireBuiltinEnabled(name)
      return try textResult(macOSApplications(arguments: object))

    case "macos.screens":
      try requireBuiltinEnabled(name)
      return try textResult(macOSScreens())

    case "macos.spotlight_search":
      try requireBuiltinEnabled(name)
      return try textResult(macOSSpotlightSearch(arguments: object))

    case "macos.running_applications":
      try requireBuiltinEnabled(name)
      return try textResult(macOSRunningApplications(arguments: object))

    case "macos.frontmost_application":
      try requireBuiltinEnabled(name)
      return try textResult(macOSFrontmostApplication())

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
