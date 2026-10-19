/// Live authority of one connected client, owned by the gateway. Contexts and
/// downstream hops carry the instance itself, so restriction and revocation checks
/// read its current state; contexts compare sessions by identity.
package protocol GatewaySessionAuthority: AnyObject, Sendable {
  var id: String { get }
  /// Current revision; any consent or profile change after capture increments it.
  var revision: Int64 { get }
  /// Narrows `grant` to what this session currently allows for `context`.
  func apply(to grant: ProfileGrant, context: ExecutionContext) throws -> ProfileGrant
  /// Fails when the session ended or its revision differs from `expected`.
  func requireRevision(_ expected: Int64?) throws
}

/// The session on whose behalf the current task runs.
package enum GatewaySessionScope {
  @TaskLocal package static var current: (any GatewaySessionAuthority)?
}
