/// Shared by the tunnel's authorization servers and listener, including while the
/// listener is starting. The callback borrows the listener without owning it.
package actor GatewayOAuthSessions {
  private var endSessions: (@Sendable (String) async -> Void)?

  package init() {}

  func attach(_ endSessions: @escaping @Sendable (String) async -> Void) {
    self.endSessions = endSessions
  }

  package func end(principalID: String) async {
    await endSessions?(principalID)
  }
}
