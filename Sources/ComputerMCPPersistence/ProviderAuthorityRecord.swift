import ComputerMCPPermissions
import Foundation
import GRDB

/// Provider approval and its owner ceiling share the permission ledger transaction.
/// The payload codec belongs to the gateway; this store never invents a client profile.
package struct ProviderAuthorityRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
  package static let databaseTableName = "permissionProviders"
  package let kind: String
  package let name: String
  package var payload: Data
  package var ownerPolicy: Data?
  package var policyEpoch: String?

  package init(identity: PluginIdentity, payload: Data) {
    switch identity {
    case .package(let name): (kind, self.name) = ("package", name)
    case .localServer(let name): (kind, self.name) = ("local-server", name)
    }
    self.payload = payload
  }

  package var identity: PluginIdentity {
    get throws {
      guard !name.isEmpty, name != "*", name.utf8.count <= 256,
        !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
      else { throw PermissionPersistenceError.invalidCurrentState }
      switch kind {
      case "package": return .package(name)
      case "local-server": return .localServer(name)
      default: throw PermissionPersistenceError.invalidCurrentState
      }
    }
  }

  package static func load(_ identity: PluginIdentity, in database: Database) throws -> Self? {
    let key = Self(identity: identity, payload: Data())
    return try filter(Column("kind") == key.kind && Column("name") == key.name).fetchOne(database)
  }
}
