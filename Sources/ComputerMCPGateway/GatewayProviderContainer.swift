import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import ComputerMCPWorktrees
import Foundation
import GRDB

/// Only the host storage owner constructs a verified opening into protected storage.
package struct GatewayProviderContainer: Codable, Sendable {
  package let identity: PluginIdentity
  package let reservation: UUID
  fileprivate let storage: VerifiedFileIdentity
  private let directories: [String: VerifiedFileIdentity]

  package var storageRoot: CanonicalPath { try! .init(storage.path) }
  package var root: CanonicalPath { try! .init(directories["root"]!.path) }
  package var sandbox: SandboxProviderContainer {
    get throws {
      try .init(
        root: .init(root.string), home: .init(directories["home"]!.path),
        cache: .init(directories["cache"]!.path), state: .init(directories["state"]!.path))
    }
  }

  fileprivate init(
    identity: PluginIdentity, reservation: UUID, storage: VerifiedFileIdentity,
    directories: [String: VerifiedFileIdentity]
  ) throws {
    self.identity = identity
    self.reservation = reservation
    self.storage = storage
    self.directories = directories
    try validate()
  }

  private func validate() throws {
    _ = try CanonicalPath(storage.path)
    let root = URL(fileURLWithPath: storage.path).appendingPathComponent(reservation.uuidString)
    guard storage.isDirectory, Set(directories.keys) == ["root", "home", "cache", "state"],
      directories["root"]?.path == root.path,
      directories.values.allSatisfy(\.isDirectory),
      ["home", "cache", "state"].allSatisfy({
        directories[$0]?.path == root.appendingPathComponent($0).path
      })
    else { throw FileIdentityError.changed }
  }

  private enum CodingKeys: String, CodingKey { case identity, reservation, storage, directories }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      identity: values.decode(PluginIdentity.self, forKey: .identity),
      reservation: values.decode(UUID.self, forKey: .reservation),
      storage: values.decode(VerifiedFileIdentity.self, forKey: .storage),
      directories: values.decode([String: VerifiedFileIdentity].self, forKey: .directories))
  }

  package func verify() throws {
    try validate()
    try storage.verify(URL(fileURLWithPath: storage.path))
    for directory in directories.values {
      try directory.verify(URL(fileURLWithPath: directory.path))
    }
  }
}

extension GatewayDatabase {
  /// A committed reservation precedes filesystem creation. An incomplete reservation
  /// refuses reuse; files without stored identity evidence are never adopted.
  package func prepareProviderContainer(_ identity: PluginIdentity) throws
    -> GatewayProviderContainer
  {
    guard let location = providerContainerRoot else { throw FileIdentityError.unavailable }
    let key = ProviderAuthorityRecord(identity: identity, payload: Data())
    _ = try key.identity
    let rootReservation = try connection.writer.write { database -> (UUID, Data?, Bool) in
      if let row = try Row.fetchOne(
        database, sql: "SELECT reservation, payload FROM providerStorage WHERE id = 1")
      {
        guard let id = UUID(uuidString: row["reservation"]) else { throw FileIdentityError.changed }
        return (id, row["payload"], false)
      }
      let id = UUID()
      try database.execute(
        sql: "INSERT INTO providerStorage (id, reservation) VALUES (1, ?)",
        arguments: [id.uuidString])
      return (id, nil, true)
    }
    let storage: VerifiedFileIdentity
    if rootReservation.2 {
      let parent = try WorktreeDirectory(location.deletingLastPathComponent())
      let directory = try parent.child(location.lastPathComponent, create: true, exclusive: true)
      storage = try VerifiedFileIdentity.capture(directory.url)
      try directory.synchronize()
      try connection.writer.write { database in
        try database.execute(
          sql:
            "UPDATE providerStorage SET payload = ? WHERE id = 1 AND reservation = ? AND payload IS NULL",
          arguments: [try storage.evidence, rootReservation.0.uuidString])
        guard database.changesCount == 1 else { throw FileIdentityError.changed }
      }
    } else {
      guard let payload = rootReservation.1 else { throw FileIdentityError.unavailable }
      storage = try JSONDecoder().decode(VerifiedFileIdentity.self, from: payload)
      guard storage.path == location.path else { throw FileIdentityError.changed }
    }
    try storage.verify(location)
    let selected = try connection.writer.write { database -> (UUID, Data?, Bool) in
      if let row = try Row.fetchOne(
        database,
        sql: "SELECT reservation, payload FROM providerContainers WHERE kind = ? AND name = ?",
        arguments: [key.kind, key.name])
      {
        guard let id = UUID(uuidString: row["reservation"]) else { throw FileIdentityError.changed }
        return (id, row["payload"], false)
      }
      let id = UUID()
      try database.execute(
        sql: "INSERT INTO providerContainers (kind, name, reservation) VALUES (?, ?, ?)",
        arguments: [key.kind, key.name, id.uuidString])
      return (id, nil, true)
    }
    let container: GatewayProviderContainer
    if selected.2 {
      let parent = try WorktreeDirectory(location)
      let directory = try parent.child(selected.0.uuidString, create: true, exclusive: true)
      var directories = ["root": try VerifiedFileIdentity.capture(directory.url)]
      for name in ["home", "cache", "state"] {
        let child = try directory.child(name, create: true, exclusive: true)
        directories[name] = try VerifiedFileIdentity.capture(child.url)
        try child.synchronize()
      }
      try directory.synchronize()
      container = try .init(
        identity: identity, reservation: selected.0, storage: storage, directories: directories)
      try container.verify()
      try connection.writer.write { database in
        try database.execute(
          sql:
            "UPDATE providerContainers SET payload = ? WHERE kind = ? AND name = ? AND reservation = ? AND payload IS NULL",
          arguments: [
            try JSONEncoder().encode(container), key.kind, key.name, selected.0.uuidString,
          ])
        guard database.changesCount == 1 else { throw FileIdentityError.changed }
      }
    } else {
      guard let payload = selected.1, payload.count <= 65536 else {
        throw FileIdentityError.unavailable
      }
      container = try JSONDecoder().decode(GatewayProviderContainer.self, from: payload)
      guard container.identity == identity, container.reservation == selected.0,
        container.storage == storage
      else { throw FileIdentityError.changed }
    }
    try container.verify()
    return container
  }
}
