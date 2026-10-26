import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPersistence
import ComputerMCPTestSupport
import Testing

@testable import ComputerMCPControlPlane

@Suite struct PermissionControlServiceTests {
  @Test func localOwnerValidationRemainsRequiredForDiagnostics() throws {
    enum Failure: Error { case revoked }
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let gateway = GatewayPermissionService(
      store: SQLitePermissionStore(
        connection: connection, counter: TestAuthorizationEpochCounter()),
      policyReader: TestManagedPolicyReader())
    let owner = try GatewayPermissionOwner(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
      validate: { throw Failure.revoked })
    let control = PermissionControlService(service: gateway, owner: { owner })
    #expect(throws: Failure.revoked) { try control.view() }
  }
}
