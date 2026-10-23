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

/// The database's schema is not one this version creates: its migration ledger names
/// migrations this version does not have (`identifiers`), or it holds tables without a
/// ledger (`identifiers` is empty). It is left unchanged.
package struct UnsupportedDatabaseSchema: Error, LocalizedError, Equatable {
  package let identifiers: [String]

  package var errorDescription: String? {
    let schema =
      identifiers.isEmpty
      ? "tables without a migration ledger"
      : "migrations: \(identifiers.joined(separator: ", "))"
    return "This database's schema (\(schema)) is not one this version of Computer MCP uses, "
      + "so it was left unchanged."
  }
}
