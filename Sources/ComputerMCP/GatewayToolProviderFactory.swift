import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPlatform
import ComputerMCPProcess

package protocol GatewayToolProviderFactory: Sendable {
  /// Creates workspace-owned providers whose routing and shutdown belong to the runtime.
  func makeProviders(
    configuration: GatewayConfiguration,
    commandRunner: any CommandRunning,
    processManager: any ProcessManaging,
    shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient,
    hostContext: MCPHostContext
  ) -> (
    registry: GatewayToolRegistry,
    additionalProviders: @Sendable () throws -> [any GatewayToolProvider]
  )
}
