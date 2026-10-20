import ComputerMCPPlatformPOSIX
import Foundation
import GRDB

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Moves the state exported from an installation created before 0.1.0 into a database with
/// this version's schema, in place of that installation's database.
///
/// The export (schema 1) holds complete rows of the preserved tables. The rows are written
/// unchanged into a staged database next to the target, counted and verified, and only then
/// put in place; the previous database is kept as `<database>.before-import`.
/// While the replacement is underway a `<database>.import-replacing` record exists, the
/// database is not opened, and the next import first restores the previous database.
package enum GatewayStateImport {
  package struct Report: Equatable, Sendable {
    /// Imported rows per preserved table, in import order.
    package var rowCounts: [TableCount]
    /// Where the replaced database is kept, or nil when there was none.
    package var previousDatabase: URL?
    /// Whether an interrupted earlier import was rolled back first.
    package var restoredInterruptedImport: Bool
  }

  package struct TableCount: Equatable, Sendable {
    package var table: String
    package var rows: Int
  }

  /// Imports `exportFile` into `database`. `verify` reads the staged database at the given
  /// path with the domain decoders and throws when this version cannot use its state; every
  /// connection it opens must be closed when it returns.
  @discardableResult
  package static func run(
    exportFile: URL, database: URL, verify: (URL) throws -> Void
  ) throws -> Report {
    let paths = Paths(database: database.standardizedFileURL)
    let lock: FileLock
    do {
      lock = try FileLock(path: paths.lock.path, mode: .exclusive)
    } catch FileLockError.held {
      throw GatewayStateImportError.databaseInUse(
        processIDs: (try? ProcessTable.processesHoldingOpen(path: paths.lock.path)) ?? [])
    }
    defer { lock.release() }
    let restored = try recover(paths)
    let tables = try ExportedTables(data: Data(contentsOf: exportFile))
    try requireUnused(paths)
    // SQLite may clean up WAL files when a read-write connection closes. This database
    // uses rollback journals, so preserve any WAL/SHM for explicit recovery before opening.
    try requireNoSidecars(paths, suffixes: ["-wal", "-shm"])
    let previous = try classifyExisting(paths)
    try requireNoSidecars(paths)
    if previous != nil, try FileIdentity.read(paths.previous) != nil {
      throw GatewayStateImportError.previousDatabaseExists(paths.previous.path)
    }
    let counts: [TableCount]
    do {
      try paths.removeStaged()
      counts = try stage(tables, at: paths.staged)
      try verify(paths.staged)
      for sidecar in Paths.sidecars where paths.exists(paths.staged, sidecar) {
        throw GatewayStateImportError.stagedDatabaseStillOpen
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: paths.staged.path)
      try requireUnused(paths)
      try requireNoSidecars(paths)
    } catch {
      try? paths.removeStaged()
      throw error
    }
    if let previous {
      try replace(paths, previous: previous)
    } else {
      guard link(paths.staged.path, paths.database.path) == 0 else {
        if errno == EEXIST { throw GatewayStateImportError.unexpectedFile(paths.database.path) }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try syncDirectory(paths.directory)
      try remove(paths.staged, in: paths.directory)
    }
    try paths.removeStaged()
    return Report(
      rowCounts: counts, previousDatabase: previous != nil ? paths.previous : nil,
      restoredInterruptedImport: restored)
  }

  /// Whether a replacement of `database` was interrupted: it is then not opened until the
  /// next import restores the previous database.
  package static func isReplacing(_ database: URL) -> Bool {
    let paths = Paths(database: database.standardizedFileURL)
    return (try? FileIdentity.read(paths.replacing)) != nil
  }

  /// Rolls back an interrupted replacement while the caller holds the exclusive lock.
  /// Validate every name before changing any of them; each mutation is durable before the
  /// next one, so recovery can resume after any of its own steps.
  @discardableResult
  static func recover(_ paths: Paths) throws -> Bool {
    guard try FileIdentity.read(paths.replacing) != nil else { return false }
    let record = try JSONDecoder().decode(
      ReplacementRecord.self, from: Data(contentsOf: paths.replacing))
    let database = try FileIdentity.read(paths.database)
    let previous = try FileIdentity.read(paths.previous)
    let staged = try FileIdentity.read(paths.staged)
    if let database, database != record.previous && database != record.staged {
      throw GatewayStateImportError.unexpectedFile(paths.database.path)
    }
    if let previous, previous != record.previous {
      throw GatewayStateImportError.unexpectedFile(paths.previous.path)
    }
    if let staged, staged != record.staged {
      throw GatewayStateImportError.unexpectedFile(paths.staged.path)
    }
    guard database != nil else {
      throw GatewayStateImportError.unexpectedFile(paths.database.path)
    }
    if database == record.staged {
      guard previous == record.previous else {
        throw GatewayStateImportError.unexpectedFile(paths.previous.path)
      }
      try rename(paths.previous, to: paths.database)
      try syncDirectory(paths.directory)
    } else if previous == record.previous {
      try remove(paths.previous, in: paths.directory)
    }
    if staged == record.staged { try remove(paths.staged, in: paths.directory) }
    try remove(paths.replacing, in: paths.directory)
    return true
  }

  private static func replace(_ paths: Paths, previous: FileIdentity) throws {
    let record = ReplacementRecord(
      previous: previous, staged: try FileIdentity.require(paths.staged))
    try createRecord(record, at: paths.replacing)
    try syncDirectory(paths.directory)
    do {
      guard link(paths.database.path, paths.previous.path) == 0 else {
        if errno == EEXIST { throw GatewayStateImportError.unexpectedFile(paths.previous.path) }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try syncDirectory(paths.directory)
      guard try FileIdentity.read(paths.database) == record.previous else {
        throw GatewayStateImportError.unexpectedFile(paths.database.path)
      }
      try rename(paths.staged, to: paths.database)
      try syncDirectory(paths.directory)
    } catch {
      try recover(paths)
      throw error
    }
    try remove(paths.replacing, in: paths.directory)
  }

  /// A plain read-write opener lets SQLite roll back a hot journal. That rollback is the
  /// only change classification may make to the previous database; no migrations run.
  private static func classifyExisting(_ paths: Paths) throws -> FileIdentity? {
    guard let identity = try FileIdentity.read(paths.database) else { return nil }
    let current = try DatabaseQueue(path: paths.database.path).read { database in
      do {
        try GatewayDatabaseConnection.checkSchema(database)
      } catch is UnsupportedDatabaseSchema {
        return false
      }
      return try database.tableExists("grdb_migrations")
    }
    guard !current else {
      throw GatewayStateImportError.databaseAlreadyCurrent(paths.database.path)
    }
    return identity
  }

  private static func requireNoSidecars(_ paths: Paths, suffixes: [String] = Paths.sidecars) throws
  {
    for suffix in suffixes {
      let url = URL(fileURLWithPath: paths.database.path + suffix)
      if try FileIdentity.read(url) != nil {
        throw GatewayStateImportError.sidecarExists(url.path)
      }
    }
  }

  private static func requireUnused(_ paths: Paths) throws {
    var holders = Set<Int32>()
    for suffix in [""] + Paths.sidecars where paths.exists(paths.database, suffix) {
      holders.formUnion(try ProcessTable.processesHoldingOpen(path: paths.database.path + suffix))
    }
    guard holders.isEmpty else {
      throw GatewayStateImportError.databaseInUse(processIDs: holders.sorted())
    }
  }

  private static func stage(_ tables: ExportedTables, at url: URL) throws -> [TableCount] {
    let connection = try GatewayDatabaseConnection(path: url.path)
    return try connection.writer.write { database in
      try tables.tables.map { table, rows in
        let columns = Set(try database.columns(in: table).map(\.name))
        for row in rows {
          let names = row.keys.sorted()
          guard Set(names) == columns else {
            throw GatewayStateImportError.invalidExport(
              "\(table) must contain exactly this schema's columns")
          }
          let values = try names.map {
            try row[$0]!.databaseValue(table: table, column: $0, row: row)
          }
          try database.execute(
            sql: "INSERT INTO \(table.quotedDatabaseIdentifier) ("
              + names.map(\.quotedDatabaseIdentifier).joined(separator: ", ") + ") VALUES ("
              + Array(repeating: "?", count: names.count).joined(separator: ", ") + ")",
            arguments: StatementArguments(values))
        }
        let imported =
          try Int.fetchOne(
            database, sql: "SELECT count(*) FROM \(table.quotedDatabaseIdentifier)") ?? 0
        guard imported == rows.count else {
          throw GatewayStateImportError.invalidExport("\(table) did not import every row")
        }
        return TableCount(table: table, rows: imported)
      }
    }
  }

  struct FileIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64

    static func read(_ url: URL) throws -> Self? {
      var status = stat()
      guard lstat(url.path, &status) == 0 else {
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return Self(device: UInt64(truncatingIfNeeded: status.st_dev), inode: UInt64(status.st_ino))
    }

    static func require(_ url: URL) throws -> Self {
      guard let identity = try read(url) else {
        throw GatewayStateImportError.unexpectedFile(url.path)
      }
      return identity
    }
  }

  struct ReplacementRecord: Codable {
    let previous: FileIdentity
    let staged: FileIdentity
  }

  private static func createRecord(_ record: ReplacementRecord, at url: URL) throws {
    let data = try JSONEncoder().encode(record)
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        offset += count
      }
    }
    guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  private static func rename(_ source: URL, to destination: URL) throws {
    #if canImport(Darwin)
      let result = Darwin.rename(source.path, destination.path)
    #else
      let result = Glibc.rename(source.path, destination.path)
    #endif
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  private static func remove(_ url: URL, in directory: URL) throws {
    guard unlink(url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    try syncDirectory(directory)
  }

  private static func syncDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  struct Paths {
    /// SQLite names these after the database path.
    static let sidecars = ["-journal", "-wal", "-shm"]

    let database: URL
    var directory: URL { database.deletingLastPathComponent() }
    var lock: URL { sibling(".lock") }
    var staged: URL { sibling(".import") }
    var previous: URL { sibling(".before-import") }
    var replacing: URL { sibling(".import-replacing") }

    func exists(_ url: URL, _ suffix: String) -> Bool {
      FileManager.default.fileExists(atPath: url.path + suffix)
    }

    func removeStaged() throws {
      for suffix in [""] + Self.sidecars + [".lock"] where exists(staged, suffix) {
        try FileManager.default.removeItem(atPath: staged.path + suffix)
      }
    }

    private func sibling(_ suffix: String) -> URL {
      directory.appendingPathComponent(database.lastPathComponent + suffix)
    }
  }
}

package enum GatewayStateImportError: Error, LocalizedError, Equatable {
  case invalidExport(String)
  case databaseInUse(processIDs: [Int32])
  case databaseAlreadyCurrent(String)
  case previousDatabaseExists(String)
  case sidecarExists(String)
  case unexpectedFile(String)
  case stagedDatabaseStillOpen

  package var errorDescription: String? {
    switch self {
    case .invalidExport(let reason):
      return "The state export cannot be imported: \(reason)."
    case .databaseInUse(let processIDs):
      return "The database is in use"
        + (processIDs.isEmpty
          ? "" : " by process " + processIDs.map(String.init).joined(separator: ", "))
        + ". Quit Computer MCP and stop its gateway, bridge and tunnel processes, then import again."
    case .databaseAlreadyCurrent(let path):
      return "The database at \(path) already uses this version's schema; nothing was imported."
    case .previousDatabaseExists(let path):
      return "\(path) already exists. Move it elsewhere, then import again."
    case .sidecarExists(let path):
      return
        "SQLite sidecar \(path) still exists. Recover it before importing; it was left unchanged."
    case .unexpectedFile(let path):
      return
        "The file at \(path) does not have the expected import identity; it was left unchanged."
    case .stagedDatabaseStillOpen:
      return "The staged database was still open after verification; nothing was replaced."
    }
  }
}

/// The preserved tables of a schema 1 export, in import order.
private struct ExportedTables {
  static let order = [
    "workspaces", "workspaceCanonicalRoots", "workspaceAliases", "profiles",
    "clientControlTrust", "runtimeSettings", "configurationRevisions", "pluginState",
    "pluginOwnedDirectories", "pluginDerivedWorkspaces",
  ]

  let tables: [(String, [[String: ExportValue]])]

  init(data: Data) throws {
    let root: [String: ExportValue]
    do {
      root = try JSONDecoder().decode([String: ExportValue].self, from: data)
    } catch {
      throw GatewayStateImportError.invalidExport("the file is not a JSON object")
    }
    guard root["schema_version"] == .integer(1) else {
      throw GatewayStateImportError.invalidExport("only schema_version 1 is supported")
    }
    func rows(_ value: ExportValue?, _ table: String) throws -> [[String: ExportValue]] {
      guard case .array(let items)? = value else {
        throw GatewayStateImportError.invalidExport("\(table) is not an array of rows")
      }
      return try items.map {
        guard case .object(let row) = $0 else {
          throw GatewayStateImportError.invalidExport("\(table) is not an array of rows")
        }
        return row
      }
    }
    var workspaces = try rows(root["workspaces"], "workspaces")
    var roots: [[String: ExportValue]] = []
    for index in workspaces.indices {
      roots += try rows(
        workspaces[index].removeValue(forKey: "workspaceCanonicalRoots"),
        "workspaceCanonicalRoots")
    }
    tables = try Self.order.map { table in
      switch table {
      case "workspaces": (table, workspaces)
      case "workspaceCanonicalRoots": (table, roots)
      default: (table, try rows(root[table], table))
      }
    }
  }
}

/// A JSON value of the export. Integers and reals stay distinct so stored SQLite types and
/// JSON numbers keep their form.
private enum ExportValue: Codable, Equatable {
  case null
  case bool(Bool)
  case integer(Int64)
  case unsignedInteger(UInt64)
  case real(Double)
  case string(String)
  case array([ExportValue])
  case object([String: ExportValue])

  /// Runtime settings whose value the export decoded from JSON text.
  static let jsonRuntimeSettings: Set<String> = [
    "desired-running-openai-tunnels", "desired-running-cloudflare-tunnels",
  ]

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(UInt64.self) {
      self = .unsignedInteger(value)
    } else if let value = try? container.decode(Double.self) {
      self = .real(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([ExportValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: ExportValue].self))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .unsignedInteger(let value): try container.encode(value)
    case .real(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  /// The stored value of `column`. The export decoded JSON text in columns named `…JSON`,
  /// in `clientControlTrust.profile` and in the tunnel-list runtime settings; BLOBs are
  /// `{"encoding": "base64", "data": …}`.
  func databaseValue(
    table: String, column: String, row: [String: ExportValue]
  ) throws -> DatabaseValue {
    let isJSON =
      column.hasSuffix("JSON") || (table == "clientControlTrust" && column == "profile")
      || (table == "runtimeSettings" && column == "value"
        && Self.jsonRuntimeSettings.contains(where: { row["key"] == .string($0) }))
    if self == .null { return .null }
    if case .object(let value) = self,
      value.count == 2 && value["encoding"] == .string("base64")
    {
      guard case .string(let encoded)? = value["data"], let data = Data(base64Encoded: encoded)
      else {
        throw GatewayStateImportError.invalidExport("\(table).\(column) holds an invalid BLOB")
      }
      return data.databaseValue
    }
    if isJSON {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return String(decoding: try encoder.encode(self), as: UTF8.self).databaseValue
    }
    switch self {
    case .integer(let value): return value.databaseValue
    case .real(let value): return value.databaseValue
    case .string(let value): return value.databaseValue
    default: break
    }
    throw GatewayStateImportError.invalidExport("\(table).\(column) holds an unsupported value")
  }
}
