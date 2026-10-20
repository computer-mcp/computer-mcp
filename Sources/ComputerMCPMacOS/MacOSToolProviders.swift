import ComputerMCPComputerUse
import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDelivery
import ComputerMCPDownstream
import ComputerMCPGateway
import ComputerMCPPlatform
import ComputerMCPPlatformDarwin
import ComputerMCPProcess
import ComputerMCPToolKit
import ComputerMCPToolsCLI
import ComputerMCPToolsFiles
import ComputerMCPToolsGit
import ComputerMCPToolsMCP
import ComputerMCPToolsShell
import ComputerMCPToolsSkills
import ComputerMCPToolsStructured
import ComputerMCPToolsSystem
import ComputerMCPToolsWorkspace

package struct MacOSToolProviders: GatewayToolProviderFactory {
  package init() {}

  package func makeProviders(
    configuration: GatewayConfiguration,
    commandRunner: any CommandRunning,
    processManager: any ProcessManaging,
    shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient,
    hostContext: MCPHostContext
  ) -> GatewayToolRegistry {
    let environment = ToolEnvironment(
      configuration: configuration, commandRunner: commandRunner,
      processManager: processManager, shellManager: shellManager,
      mediaInspector: DarwinMediaInspector(),
      sqliteCommand: .init(id: "sqlite3", executable: "/usr/bin/sqlite3"),
      builtinExecutables: [
        "file": "/usr/bin/file", "wc": "/usr/bin/wc", "du": "/usr/bin/du",
        "mdls": "/usr/bin/mdls", "diff": "/usr/bin/diff", "curl": "/usr/bin/curl",
        "zipinfo": "/usr/bin/zipinfo", "tar": "/usr/bin/tar", "unzip": "/usr/bin/unzip",
        "zip": "/usr/bin/zip",
        "sw_vers": "/usr/bin/sw_vers", "pmset": "/usr/bin/pmset", "ps": "/bin/ps",
        "log": "/usr/bin/log", "launchctl": "/bin/launchctl", "ifconfig": "/sbin/ifconfig",
        "scutil": "/usr/sbin/scutil", "networksetup": "/usr/sbin/networksetup",
        "netstat": "/usr/sbin/netstat", "arp": "/usr/sbin/arp", "ping": "/sbin/ping",
        "nc": "/usr/bin/nc", "lsof": "/usr/sbin/lsof",
      ],
      extendedAttributes: DarwinExtendedAttributes(), fileTrasher: DarwinFileTrasher(),
      workspaceOpener: DarwinWorkspaceOpener(commandRunner: commandRunner),
      systemProbe: DarwinSystemProbe())
    return makeProviders(
      toolEnvironment: environment, mcpClient: mcpClient, hostContext: hostContext)
  }

  package func makeProviders(
    toolEnvironment environment: ToolEnvironment,
    mcpClient: any DownstreamMCPClient,
    hostContext: (any MCPHostEnvironment)? = nil
  ) -> GatewayToolRegistry {
    let configuration = environment.configuration
    let client = mcpClient.makeScopedClient(
      workingDirectory: configuration.workspaceDirectory, environment: environment.environment,
      hostContext: hostContext)
    let mcp = MCPToolProvider(environment: environment, mcpClient: client)
    let cli = CLIToolProvider(environment: environment)
    let delivery = DeliveryToolProvider(environment: environment)
    let providers: [any GatewayToolProvider] = [
      delivery,
      cli, ProcessToolProvider(environment: environment),
      ShellToolProvider(environment: environment),
      mcp, SkillsToolProvider(environment: environment),
      WorkspaceToolProvider(environment: environment),
      FilesToolProvider(environment: environment), StructuredToolProvider(environment: environment),
      GitToolProvider(environment: environment), SystemToolProvider(environment: environment),
      NetworkToolProvider(environment: environment), MacOSToolProvider(environment: environment),
    ]
    let computerUse = ComputerUseGatewayProvider()
    return GatewayToolRegistry(
      providers: {
        let configured = try ConfiguredMCPToolProvider(environment: environment, mcpClient: client)
          .snapshot()
        return try configured.listed(among: providers) + (try cli.treeProviders()) + [computerUse]
      },
      invalidations: client.toolChanges(),
      refreshInterval: configuration.mcp.servers.contains {
        $0.enabled && $0.exposure.includesReexport
      }
        || configuration.cli.commands.contains { $0.tree != nil } ? .seconds(30) : nil,
      downstreamPolicy: { try mcp.downstreamPolicy(for: $0, context: $1) },
      shutdown: {
        await delivery.shutdown()
        await environment.shellManager.shutdown()
        await environment.registeredCommands.execution.shutdown()
        await client.shutdown()
      })
  }
}
