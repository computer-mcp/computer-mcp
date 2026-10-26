import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Foundation

/// A retained checker selects the durable call; it never caches permissions.
package struct GatewayPathAccess: HostPathAccessChecking {
  private let store: SQLitePermissionStore
  private let authorizationID: UUID

  package init(store: SQLitePermissionStore, authorizationID: UUID) {
    self.store = store
    self.authorizationID = authorizationID
  }

  package func check(_ path: URL, operation: HostPathOperation) throws {
    let canonical = try ProjectPathResolver.resolve(
      path.path, relativeTo: URL(fileURLWithPath: "/"))
    let operation: PathOperation =
      switch operation {
      case .read: .read
      case .write: .write
      case .openDirectory: .openDirectory
      case .listDirectory: .listDirectory
      }
    let result: Result<Void, any Error> = try store.transactionWithDatabase { _, ledger in
      Result {
        try ledger.authorizePathUse(
          authorizationID, path: CanonicalPath(canonical.path), operation: operation)
      }
    }
    try result.get()
  }
}
