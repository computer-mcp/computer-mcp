import ComputerMCPControlPlane
import ComputerMCPGateway
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformDarwin

/// Prepared composition; constructing it does not activate permission migration or
/// publish a second authority in the running App. Both adapters share one store.
package struct MacOSPermissionServices: Sendable {
  package let gateway: GatewayPermissionService
  package let control: PermissionControlService

  package init(
    connection: GatewayDatabaseConnection, counter: any AuthorizationEpochCounter,
    policyReader: any ManagedPolicyReading = DarwinManagedPolicyReader(),
    owner: @escaping @Sendable () throws -> GatewayPermissionOwner
  ) {
    let store = SQLitePermissionStore(connection: connection, counter: counter)
    gateway = GatewayPermissionService(store: store, policyReader: policyReader)
    control = PermissionControlService(service: gateway, owner: owner)
  }
}
