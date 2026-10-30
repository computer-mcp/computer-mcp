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
  private let additionalAuthorizationIDs: Set<UUID>
  private let validateInvocation: (@Sendable () throws -> Void)?
  private let validateWorktree: (@Sendable () throws -> Void)?

  package init(
    store: SQLitePermissionStore, authorizationID: UUID,
    additionalAuthorizationIDs: Set<UUID> = [],
    validateWorktree: (@Sendable () throws -> Void)? = nil,
    validateInvocation: (@Sendable () throws -> Void)? = nil
  ) {
    self.store = store
    self.authorizationID = authorizationID
    self.additionalAuthorizationIDs = additionalAuthorizationIDs
    self.validateWorktree = validateWorktree
    self.validateInvocation = validateInvocation
  }

  package func isAccessible(_ path: URL, operation: HostPathOperation) -> Bool {
    (try? check(path, operation: operation, requestMissing: false)) != nil
  }

  package func check(_ path: URL, operation: HostPathOperation) throws {
    try check(path, operation: operation, requestMissing: true)
  }

  private func check(_ path: URL, operation: HostPathOperation, requestMissing: Bool) throws {
    try validateInvocation?()
    if operation == .write { try validateWorktree?() }
    let canonical = try ProjectPathResolver.resolve(
      path.path, relativeTo: URL(fileURLWithPath: "/"))
    let operation: PathOperation =
      switch operation {
      case .read: .read
      case .write: .write
      case .openDirectory: .openDirectory
      case .listDirectory: .listDirectory
      }
    let result: Result<Void, any Error> = try store.transactionWithDatabase { database, ledger in
      var checkedAuthorizationID = authorizationID
      do {
        for record in try GatewayDatabase.availableDerivedProjects(in: database) {
          guard case .host = record.provenance else { continue }
          let root = try ProjectPathResolver.resolve(
            record.root, relativeTo: URL(fileURLWithPath: "/"))
          guard ProjectPathResolver.contains(canonical, in: root) else { continue }
          guard ledger.authorizations[authorizationID]?.invocation.projectID == record.projectID
          else {
            throw PermissionModelError.invalidAuthorization
          }
          try record.worktree?.verifyContent()
        }
        for id in additionalAuthorizationIDs.union([authorizationID]) {
          checkedAuthorizationID = id
          try ledger.authorizePathUse(
            id, path: CanonicalPath(canonical.path), operation: operation)
        }
        return .success(())
      } catch {
        let original = error
        guard requestMissing else { return .failure(original) }
        do {
          let decision = try ledger.recordHostPathNeed(
            authorizationID: checkedAuthorizationID,
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
