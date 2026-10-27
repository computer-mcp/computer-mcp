import ComputerMCPGateway
import ComputerMCPTestSupport

func fixturePermissionDatabase(path: String) throws -> GatewayDatabase {
  let database = try GatewayDatabase(path: path)
  _ = database.permissionStore(counter: TestAuthorizationEpochCounter.shared(forDatabasePath: path))
  return database
}
