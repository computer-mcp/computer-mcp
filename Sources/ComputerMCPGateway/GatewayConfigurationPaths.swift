import ComputerMCPConfiguration
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import Foundation
import GRDB

/// Independent sources retain protection when they happen to name the same root.
package enum GatewayConfigurationPaths {
  static let configurationKey = "permission.configuration-paths"
  static let platformKey = "permission.platform-paths"

  package static func capture(_ configuration: GatewayConfiguration) throws -> Set<PathRule> {
    var rules: Set<PathRule> = []
    for path in configuration.hostDataPaths.map(\.path)
      + configuration.transports.openAI.compactMap(\.profileDirectory)
    {
      let resolved = try ProjectPathResolver.resolve(
        path,
        relativeTo: path.hasPrefix("/") ? URL(fileURLWithPath: "/") : configuration.projectDirectory
      )
      rules.insert(.init(root: try CanonicalPath(resolved.path), kind: .hostData))
    }
    for root in configuration.skills.roots {
      let resolved = try ProjectPathResolver.resolve(
        root.path,
        relativeTo: root.path.hasPrefix("/")
          ? URL(fileURLWithPath: "/") : configuration.projectDirectory)
      rules.insert(.init(root: try CanonicalPath(resolved.path), kind: .skillLibrary))
    }
    return rules
  }

  static func read(_ key: String, database: Database) throws -> Set<PathRule>? {
    guard let record = try RuntimeSettingRecord.fetchOne(database, key: key) else { return nil }
    guard record.value.utf8.count <= 4_194_304 else {
      throw PermissionPersistenceError.invalidCurrentState
    }
    return try JSONDecoder().decode(Set<PathRule>.self, from: Data(record.value.utf8))
  }

  static func save(_ rules: Set<PathRule>, key: String, database: Database) throws {
    let facts = Set(rules.map { PathRule(root: $0.root, kind: $0.kind) })
    if let stored = try read(key, database: database),
      Set(stored.map { PathRule(root: $0.root, kind: $0.kind) }) == facts
    {
      return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(facts)
    guard data.count <= 4_194_304 else { throw PermissionPersistenceError.invalidCurrentState }
    try RuntimeSettingRecord(
      key: key, value: String(decoding: data, as: UTF8.self), updatedAt: Date()
    ).save(database)
  }
}
