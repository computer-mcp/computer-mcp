import ComputerMCPCore
import ComputerMCPPermissions
import Foundation

/// Installed only for an admitted host management call; it cannot launch a provider process.
package struct GatewayManagementInvocation: InvocationExecutionAuthority {
  package let authorization: InvocationAuthorization
  package let pathAccess: (any HostPathAccessChecking)?

  package init(
    authorization: InvocationAuthorization, pathAccess: (any HostPathAccessChecking)?
  ) {
    self.authorization = authorization
    self.pathAccess = pathAccess
  }
}

/// Retains admission across asynchronous preparation and orders synchronous commits.
package struct GatewayManagementAuthorization: Sendable {
  package let session: GatewayControlSession
  package let context: ExecutionContext
  package let revision: Int64
  let requiresFullAccess: Bool
  let consent: GatewayFullAccessConsent?
  let invocation: InvocationAuthorization

  package init(
    session: GatewayControlSession, context: ExecutionContext, revision: Int64,
    requiresFullAccess: Bool, invocation: GatewayManagementInvocation
  ) throws {
    let authorization = invocation.authorization
    guard context.controlSession === session,
      authorization.invocation.principal
        == (try GatewayPermissionSubject(context: context)).principal,
      authorization.invocation.projectID == context.projectID,
      authorization.basis.contains(where: { basis in
        if case .connection(let id, _) = basis { return id == session.id }
        return false
      }),
      !requiresFullAccess || authorization.mode != .sandbox
    else { throw PermissionModelError.invalidAuthorization }
    self.session = session
    self.context = context
    self.revision = revision
    self.requiresFullAccess = requiresFullAccess
    self.consent = session.snapshot.fullAccessConsent
    self.invocation = authorization
  }

  func requireInvocationAccess(ledger: inout PermissionLedger) throws {
    guard try ledger.invocationAccess(invocation.id) == invocation else {
      throw PermissionModelError.invalidAuthorization
    }
  }

  package func perform<Result>(_ operation: () throws -> Result) throws -> Result {
    try session.withManagementAuthorization(
      context: context, expectedRevision: revision, requiresFullAccess: requiresFullAccess,
      operation: operation)
  }
}
