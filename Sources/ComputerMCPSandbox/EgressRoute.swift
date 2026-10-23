/// The selected system route for a numeric destination. A tunnel route takes precedence over
/// connected-subnet classification; callers still reject loopback before consulting the route.
package struct EgressRoute: Sendable, Equatable {
  package let interface: String
  package let interfaceIndex: UInt32
  package let interfaceAddresses: [String]
  package let isTunnel: Bool
  package let isDirect: Bool

  package init(
    interface: String, interfaceIndex: UInt32, interfaceAddresses: [String] = [], isTunnel: Bool,
    isDirect: Bool
  ) {
    self.interface = interface
    self.interfaceIndex = interfaceIndex
    self.interfaceAddresses = interfaceAddresses.sorted()
    self.isTunnel = isTunnel
    self.isDirect = isDirect
  }
}

package protocol EgressRouting: Sendable {
  /// Must query current routing state and throw when it cannot determine a route.
  func route(to numericAddress: String) throws -> EgressRoute
  /// Observation must be active before returning. Failure to observe further changes is terminal.
  func observeChanges(_ handler: @escaping @Sendable (EgressRouteEvent) -> Void) throws
    -> any EgressRouteObservation
}

package enum EgressRouteEvent: Sendable {
  case changed
  case unavailable
}

package protocol EgressRouteObservation: Sendable {
  func cancel()
}
