import ComputerMCPCore
import Foundation

/// Captured before asynchronous preparation; only the commit runs under its lock.
package struct GatewayManagementAuthorization: Sendable {
  package let session: GatewayControlSession
  package let context: ExecutionContext
  package let revision: Int64
  let requiresFullAccess: Bool
  let consent: GatewayFullAccessConsent?

  package init(
    session: GatewayControlSession, context: ExecutionContext, revision: Int64,
    requiresFullAccess: Bool
  ) {
    self.session = session
    self.context = context
    self.revision = revision
    self.requiresFullAccess = requiresFullAccess
    self.consent = session.snapshot.fullAccessConsent
  }

  package func perform<Result>(_ operation: () throws -> Result) throws -> Result {
    try session.withManagementAuthorization(
      context: context, expectedRevision: revision, requiresFullAccess: requiresFullAccess,
      operation: operation)
  }
}
