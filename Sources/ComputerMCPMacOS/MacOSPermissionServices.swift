import ComputerMCPControlPlane
import ComputerMCPGateway
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformDarwin

/// App and gateway adapters share the database's cached authority and execution owner.
package struct MacOSPermissionServices: Sendable {
  package let gateway: GatewayPermissionService
  package let control: PermissionControlService

  package init(
    database: GatewayDatabase, counter: any AuthorizationEpochCounter,
    platform: PlatformServices = MacOSPlatform.services,
    owner: @escaping @Sendable () throws -> GatewayPermissionOwner
  ) throws {
    try database.claimPermissionComposition(.app)
    _ = database.permissionStore(counter: counter)
    gateway = try database.permissionRuntime(platform: platform).service
    control = PermissionControlService(service: gateway, owner: owner)
  }
}
