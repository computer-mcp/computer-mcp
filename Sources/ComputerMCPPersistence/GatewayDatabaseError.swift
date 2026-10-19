import Foundation

package enum GatewayDatabaseError: Error, LocalizedError, Equatable {
  case configurationChanged
  case invalidStoredValue(String)
  case invalidOperationTicketTransition(String)
  case operationTicketUnknown(String)
  case operationTicketPrincipalMismatch(String)
  case operationTicketExpired(String)
  case operationTicketUnavailable(id: String, state: String)

  package var errorDescription: String? {
    switch self {
    case .configurationChanged:
      return
        "The gateway configuration changed during preparation. Reload before applying this change."
    case .invalidStoredValue(let message):
      return message
    case .invalidOperationTicketTransition(let message):
      return message
    case .operationTicketUnknown(let id):
      return "Unknown operation ticket '\(id)'."
    case .operationTicketPrincipalMismatch(let id):
      return "Operation ticket '\(id)' is bound to another principal."
    case .operationTicketExpired(let id):
      return "Operation ticket '\(id)' has expired."
    case .operationTicketUnavailable(let id, let state):
      return "Operation ticket '\(id)' cannot be claimed from state '\(state)'."
    }
  }
}

/// The database's migration ledger names migrations this version does not have, which
/// means it was created before the 0.1.0 schema. It is left unchanged.
package struct UnsupportedDatabaseSchema: Error, LocalizedError, Equatable {
  package let identifiers: [String]

  package var errorDescription: String? {
    "This database was created before Computer MCP 0.1.0 and cannot be opened "
      + "(migrations: \(identifiers.joined(separator: ", "))). Its workspaces, profiles and "
      + "settings move to a new database through a state import."
  }
}
