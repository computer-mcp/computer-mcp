import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPlatform
import ComputerMCPProcess

package protocol GatewayToolProviderFactory: Sendable {
  /// Creates workspace-owned providers whose routing and shutdown belong to the runtime.
  /// The provider source is reevaluated for each catalog generation and may fail discovery.
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
