import ComputerMCPCore
import ComputerMCPPersistence
import Foundation
import GRDB

package enum GatewayPermissionComposition: String { case app, standalone }

extension GatewayDatabase {
  /// Inspect an existing file without schema migration or counter access.
  package static func requireStandaloneDatabase(at location: URL) throws {
    guard FileManager.default.fileExists(atPath: location.path) else { return }
    var configuration = Configuration()
    configuration.readonly = true
    let connection = try DatabaseQueue(path: location.path, configuration: configuration)
    defer { try? connection.close() }
    try connection.read { database in
      let tables = Set(
        try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
      let owner =
        try tables.contains("runtimeSettings")
        ? String.fetchOne(
          database, sql: "SELECT value FROM runtimeSettings WHERE key = 'permission.composition'")
        : nil
      let activated =
        try tables.contains("configurationRevisions")
        ? Int.fetchOne(
          database, sql: "SELECT COUNT(*) FROM configurationRevisions WHERE activatedAt IS NOT NULL"
        ) ?? 0 : 0
      guard
        owner == GatewayPermissionComposition.standalone.rawValue || owner == nil && activated == 0
      else {
        throw GatewayDatabaseError.invalidStoredValue(
          "This database belongs to the App permission composition. Use its local control socket; use a separate --database for standalone service."
        )
      }
    }
  }

  /// Composition ownership precedes counter selection. It does not authorize a
  /// caller; it prevents two unrelated external watermarks from adopting one DB.
  package func claimPermissionComposition(_ owner: GatewayPermissionComposition) throws {
    try connection.writer.write { database in
      let key = "permission.composition"
      let recorded = try RuntimeSettingRecord.fetchOne(database, key: key)
      let activationCount =
        try Int.fetchOne(
          database, sql: "SELECT COUNT(*) FROM configurationRevisions WHERE activatedAt IS NOT NULL"
        ) ?? 0
      let legacyApp = recorded == nil && owner == .standalone && activationCount > 0
      guard !legacyApp, recorded == nil || recorded?.value == owner.rawValue else {
        throw GatewayDatabaseError.invalidStoredValue(
          "This database belongs to a different permission composition. Use the App's local control socket for its database; use a separate --database for standalone service."
        )
      }
      if recorded == nil {
        try RuntimeSettingRecord(key: key, value: owner.rawValue, updatedAt: Date()).insert(
          database)
      }
    }
  }
}
