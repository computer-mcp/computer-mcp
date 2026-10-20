import ComputerMCP
import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPToolKit
import ComputerMCPToolsGit

package struct MacOSToolProviders: GatewayToolProviderFactory {
  package init() {}

  package func makeProviders(
    configuration: GatewayConfiguration,
    commandRunner: any CommandRunning,
    processManager: any ProcessManaging,
    shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient,
    hostContext: MCPHostContext
  ) -> (registry: GatewayToolRegistry, additionalProviders: [any GatewayToolProvider]) {
    let environment = ToolEnvironment(
      configuration: configuration, commandRunner: commandRunner,
      processManager: processManager, shellManager: shellManager)
    return (
      registry: GatewayToolRegistry(
        toolEnvironment: environment,
        mcpClient: mcpClient,
        hostContext: hostContext),
      additionalProviders: [
        GitToolProvider(environment: environment), ComputerUseGatewayProvider(),
      ]
    )
  }
}
