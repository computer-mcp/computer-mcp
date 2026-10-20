/// Live authority of one connected client, owned by the gateway. Contexts and
/// downstream hops carry the instance itself, so restriction and revocation checks
/// read its current state; contexts compare sessions by identity.
///
/// The gateway's control session is the only production conformer. A context or
/// task receives one only from the host's authenticated admission path; tool
/// arguments and transports never supply it.
package protocol GatewaySessionAuthority: AnyObject, Sendable {
  var id: String { get }
  /// Current revision; any consent or profile change after capture increments it.
  var revision: Int64 { get }
  /// Narrows `grant` to what this session currently allows for `context`.
  func apply(to grant: ProfileGrant, context: ExecutionContext) throws -> ProfileGrant
  /// Fails when the session ended or its revision differs from `expected`.
  func requireRevision(_ expected: Int64?) throws
}
