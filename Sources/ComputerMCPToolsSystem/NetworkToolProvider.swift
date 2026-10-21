import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPToolKit

package struct NetworkToolProvider: GatewayToolProvider {
  package let id = "network"
  package let namespaces = ["network"]
  let environment: ToolEnvironment
  let configuration: GatewayConfiguration

  package init(environment: ToolEnvironment) {
    self.environment = environment
    self.configuration = environment.configuration
  }

  var workspaceScope: WorkspaceScope { environment.workspaceScope }
  var registeredCommands: RegisteredCommands { environment.registeredCommands }
  var commandRunner: any CommandRunning { environment.commandRunner }

  package func definitions() throws -> [ToolDefinition] {
    Self.toolDefinitions(toolMeta: workspaceScope.toolMeta).filter {
      configuration.builtin.enabled.contains($0.tool.name)
    }.sorted { $0.tool.name < $1.tool.name }
  }

  package func callTool(_ invocation: ToolInvocation) throws -> JSONValue {
    let name = invocation.name
    let object = invocation.arguments?.objectValue ?? [:]
    switch name {
    case "network.interfaces":
      try requireBuiltinEnabled(name)
      return try textResult(networkInterfaces(arguments: object))

    case "network.dns":
      try requireBuiltinEnabled(name)
      return try textResult(networkDNS(arguments: object))

    case "network.resolve":
      try requireBuiltinEnabled(name)
      return try textResult(networkResolve(arguments: object))

    case "network.proxy":
      try requireBuiltinEnabled(name)
      return try textResult(networkProxy(arguments: object))

    case "network.services":
      try requireBuiltinEnabled(name)
      return try textResult(networkServices(arguments: object))

    case "network.hardware_ports":
      try requireBuiltinEnabled(name)
      return try textResult(networkHardwarePorts(arguments: object))

    case "network.wifi":
      try requireBuiltinEnabled(name)
      return try textResult(networkWiFi(arguments: object))

    case "network.vpn":
      try requireBuiltinEnabled(name)
      return try textResult(networkVPN(arguments: object))

    case "network.locations":
      try requireBuiltinEnabled(name)
      return try textResult(networkLocations(arguments: object))

    case "network.routes":
      try requireBuiltinEnabled(name)
      return try textResult(networkRoutes(arguments: object))

    case "network.connections":
      try requireBuiltinEnabled(name)
      return try textResult(networkConnections(arguments: object))

    case "network.arp":
      try requireBuiltinEnabled(name)
      return try textResult(networkARP(arguments: object))

    case "network.ping":
      try requireBuiltinEnabled(name)
      return try textResult(networkPing(arguments: object))

    case "network.tcp_check":
      try requireBuiltinEnabled(name)
      return try textResult(networkTCPCheck(arguments: object))

    case "network.http_check":
      try requireBuiltinEnabled(name)
      return try textResult(networkHTTPCheck(arguments: object))

    case "network.listeners":
      try requireBuiltinEnabled(name)
      return try textResult(networkListeners(arguments: object))

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
