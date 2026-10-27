import ComputerMCPControlPlane
import ComputerMCPEgress
import ComputerMCPGateway
import ComputerMCPPlatformDarwin
import ComputerMCPProcess

package enum MacOSPlatform {
  package static var services: PlatformServices {
    services(launcher: ExecutionLauncher(platform: DarwinExecutionPlatform()))
  }

  package static func services(launcher: ExecutionLauncher) -> PlatformServices {
    PlatformServices(
      launcher: launcher,
      projectGrants: ProjectBookmarkService(),
      pluginDirectories: DarwinPluginArchiveDirectoryFactory(),
      applications: ApplicationBundleLookup(),
      toolProviders: MacOSToolProviders(launcher: launcher),
      managementToolNames: GatewayRemoteManagement.toolNames,
      executableSearchDirectories: ExternalProviderDiscovery.macOSSearchDirectories,
      gitExecutable: "/usr/bin/git",
      fileChanges: { try DirectoryEventFileChangeMonitor(fileURL: $0) },
      permissionPolicyReader: DarwinManagedPolicyReader(),
      executionProxy: { id, policy in
        try await EgressProxy.start(
          executionID: id.uuidString, policy: policy, routing: DarwinEgressRouting(),
          limits: EgressLimits())
      }
    )
  }
}
