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

  package func isAccessible(_ path: URL, operation: HostPathOperation) -> Bool {
    (try? check(path, operation: operation, requestMissing: false)) != nil
  }

  package func check(_ path: URL, operation: HostPathOperation) throws {
    try check(path, operation: operation, requestMissing: true)
  }

  private func check(_ path: URL, operation: HostPathOperation, requestMissing: Bool) throws {
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
      do {
        try ledger.authorizePathUse(
          authorizationID, path: CanonicalPath(canonical.path), operation: operation)
        return .success(())
      } catch {
        let original = error
        guard requestMissing else { return .failure(original) }
        do {
          let decision = try ledger.recordHostPathNeed(
            authorizationID: authorizationID,
            path: .init(path: CanonicalPath(canonical.path), operation: operation), now: Date())
          switch decision {
          case .requests(let requests):
            return .failure(GatewayPermissionCallError.required(requests, afterDispatch: true))
          case .denied(let reason):
            return .failure(GatewayPermissionCallError.denied(reason))
          case .satisfied: return .failure(original)
          }
        } catch { return .failure(original) }
      }
    }
    try result.get()
  }
}
