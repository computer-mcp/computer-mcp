import ComputerMCP
import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess

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
    (
      registry: GatewayToolRegistry(
        configuration: configuration,
        commandRunner: commandRunner,
        processManager: processManager,
        shellManager: shellManager,
        mcpClient: mcpClient,
        hostContext: hostContext),
      additionalProviders: [ComputerUseGatewayProvider()]
    )
  }
}
