import ComputerMCP
import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPlatform
import ComputerMCPPlatformDarwin
import ComputerMCPProcess
import ComputerMCPToolKit
import ComputerMCPToolsCLI
import ComputerMCPToolsGit
import ComputerMCPToolsShell

package struct MacOSToolProviders: GatewayToolProviderFactory {
  package init() {}

  package func makeProviders(
    configuration: GatewayConfiguration,
    commandRunner: any CommandRunning,
    processManager: any ProcessManaging,
    shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient,
    hostContext: MCPHostContext
  ) -> (
    registry: GatewayToolRegistry,
    additionalProviders: @Sendable () throws -> [any GatewayToolProvider]
  ) {
    let environment = ToolEnvironment(
      configuration: configuration, commandRunner: commandRunner,
      processManager: processManager, shellManager: shellManager,
      mediaInspector: DarwinMediaInspector())
    let cli = CLIToolProvider(environment: environment)
    let providers: [any GatewayToolProvider] = [
      GitToolProvider(environment: environment), cli, ProcessToolProvider(environment: environment),
      ShellToolProvider(environment: environment),
    ]
    let computerUse = ComputerUseGatewayProvider()
    return (
      registry: GatewayToolRegistry(
        toolEnvironment: environment,
        mcpClient: mcpClient,
        hostContext: hostContext),
      additionalProviders: { providers + (try cli.treeProviders()) + [computerUse] }
    )
  }
}
