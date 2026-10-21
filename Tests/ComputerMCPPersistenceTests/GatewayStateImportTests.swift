import ComputerMCPPlatformPOSIX
import Foundation
import GRDB
import Testing

@testable import ComputerMCPPersistence

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct GatewayStateImportTests {
  @Test func importsEveryColumnUnchanged() throws {
    let directory = try TemporaryDirectory()
    let report = try Self.importState(Self.export(), into: directory.database)

    #expect(report.previousDatabase == nil)
    #expect(!report.restoredInterruptedImport)
    #expect(report.rowCounts.map(\.table) == Self.tables)
    #expect(report.rowCounts.map(\.rows) == [1, 1, 0, 1, 1, 2, 1, 1, 0, 0])
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.database.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(directory.entries() == ["gateway.sqlite", "gateway.sqlite.lock"])

    let database = try DatabaseQueue(path: directory.database.path)
    try database.read { database in
      let workspace = try #require(try Row.fetchOne(database, sql: "SELECT * FROM workspaces"))
      #expect(workspace["bookmarkData"] as Data? == Data([0, 1, 2, 255]))
      #expect(workspace["bookmarkIsStale"] as Int64? == 0)
      #expect(workspace["createdAt"] as String? == "2026-10-01 08:00:00.000")
      #expect(
        try String.fetchAll(database, sql: "SELECT canonicalRootPath FROM workspaceCanonicalRoots")
          == ["/Users/example/project"])
      let profile = try #require(try Row.fetchOne(database, sql: "SELECT * FROM profiles"))
      #expect(profile["capabilityIDsJSON"] as String? == #"["file.read","git.status"]"#)
      #expect(profile["authorizationRevision"] as Int64? == 3)
      #expect(
        try String.fetchOne(database, sql: "SELECT profile FROM clientControlTrust")
          == #"{"mode":"operate","shell":false}"#)
      #expect(
        try String.fetchAll(database, sql: "SELECT value FROM runtimeSettings ORDER BY key")
          == ["chatgpt-operate", #"["chatgpt"]"#])
      let plugin = try #require(try Row.fetchOne(database, sql: "SELECT * FROM pluginState"))
      #expect(plugin["revision"] as Int64? == 4)
      #expect(
        plugin["payloadJSON"] as String?
          == #"{"installations":[{"registeredAt":782000000.25,"root":"file:///plugins/a/"}],"revision":4}"#
      )
      #expect(
        try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations")
          == ["gateway-initial"])
    }
  }

  @Test func replacesAnEarlierDatabaseAndKeepsItsCommittedRows() throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)

    let report = try Self.importState(Self.export(), into: directory.database)

    #expect(report.previousDatabase == directory.previous)
    #expect(try Self.dump(directory.previous) == before)
    #expect(try Self.ledger(directory.database) == ["gateway-initial"])
    #expect(
      directory.entries() == [
        "gateway.sqlite", "gateway.sqlite.before-import", "gateway.sqlite.lock",
      ])
  }

  @Test func refusesADatabaseThatIsOpen() throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)
    let holder = try FileHandle(forReadingFrom: directory.database)

    Self.expectInUse(directory.database.path) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try Self.dump(directory.database) == before)
    #expect(directory.entries() == ["gateway.sqlite", "gateway.sqlite.lock"])

    try holder.close()
    #expect(try Self.importState(Self.export(), into: directory.database).previousDatabase != nil)
  }

  @Test func refusesADatabaseWithThisVersionsSchema() throws {
    let directory = try TemporaryDirectory()
    _ = try GatewayDatabaseConnection(path: directory.database.path)
    let before = try Self.dump(directory.database)

    #expect(throws: GatewayStateImportError.databaseAlreadyCurrent(directory.database.path)) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try Self.dump(directory.database) == before)
    #expect(directory.entries() == ["gateway.sqlite", "gateway.sqlite.lock"])
  }

  @Test(arguments: [false, true])
  func refusesWhenThePreviousDatabaseNameIsTaken(withDatabase: Bool) throws {
    let directory = try TemporaryDirectory()
    if withDatabase { try Self.makeEarlierDatabase(at: directory.database) }
    try Data("kept".utf8).write(to: directory.previous)

    #expect(throws: GatewayStateImportError.previousDatabaseExists(directory.previous.path)) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try Data(contentsOf: directory.previous) == Data("kept".utf8))
    let expected =
      withDatabase
      ? ["gateway.sqlite", "gateway.sqlite.before-import", "gateway.sqlite.lock"]
      : ["gateway.sqlite.before-import", "gateway.sqlite.lock"]
    #expect(directory.entries() == expected)
  }

  @Test func failedVerificationLeavesTheEarlierDatabaseUsable() throws {
    struct Unusable: Error {}
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)

    #expect(throws: Unusable.self) {
      try GatewayStateImport.run(
        exportFile: Self.write(Self.export(), to: directory.export), database: directory.database
      ) { _ in throw Unusable() }
    }
    #expect(try Self.dump(directory.database) == before)
    #expect(directory.entries() == ["gateway.sqlite", "gateway.sqlite.lock"])
    #expect(throws: UnsupportedDatabaseSchema(identifiers: ["initial-schema"])) {
      try GatewayDatabaseConnection(path: directory.database.path)
    }
  }

  @Test(arguments: ["file", "directory", "symlink"])
  func refusesAnUnownedStagedPath(_ kind: String) throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Data(contentsOf: directory.database)
    if kind == "directory" {
      try FileManager.default.createDirectory(
        at: directory.staged, withIntermediateDirectories: true)
      try Data("kept".utf8).write(to: directory.staged.appendingPathComponent("file"))
    } else if kind == "symlink" {
      try FileManager.default.createSymbolicLink(
        atPath: directory.staged.path, withDestinationPath: "missing.sqlite")
    } else {
      try Data("kept".utf8).write(to: directory.staged)
    }
    let staged = try GatewayStateImport.FileIdentity.require(directory.staged)
    let stagedLock = URL(fileURLWithPath: directory.staged.path + ".lock")
    let lock = try FileLock(path: stagedLock.path, mode: .shared)
    defer { lock.release() }
    let lockIdentity = try GatewayStateImport.FileIdentity.require(stagedLock)

    #expect(throws: GatewayStateImportError.unexpectedFile(directory.staged.path)) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try Data(contentsOf: directory.database) == before)
    #expect(try GatewayStateImport.FileIdentity.require(directory.staged) == staged)
    #expect(try GatewayStateImport.FileIdentity.require(stagedLock) == lockIdentity)
    if kind == "symlink" {
      #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: directory.staged.path)
          == "missing.sqlite")
    } else {
      let contents =
        kind == "directory" ? directory.staged.appendingPathComponent("file") : directory.staged
      #expect(try Data(contentsOf: contents) == Data("kept".utf8))
    }
  }

  @Test func anExportAtTheStagedPathIsPreserved() throws {
    let directory = try TemporaryDirectory()
    _ = try Self.write(Self.export(), to: directory.staged)
    let before = try Data(contentsOf: directory.staged)
    #expect(throws: GatewayStateImportError.unexpectedFile(directory.staged.path)) {
      try GatewayStateImport.run(exportFile: directory.staged, database: directory.database) { _ in
      }
    }
    #expect(try Data(contentsOf: directory.staged) == before)
    #expect(directory.entries() == ["gateway.sqlite.import", "gateway.sqlite.lock"])
  }

  @Test(arguments: GatewayStateImport.Paths.sidecars)
  func refusesUnownedStagedSidecars(_ suffix: String) throws {
    let directory = try TemporaryDirectory()
    let sidecar = URL(fileURLWithPath: directory.staged.path + suffix)
    try Data("kept".utf8).write(to: sidecar)
    #expect(throws: GatewayStateImportError.sidecarExists(sidecar.path)) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try Data(contentsOf: sidecar) == Data("kept".utf8))
    #expect(directory.entries() == ["gateway.sqlite.import" + suffix, "gateway.sqlite.lock"])
  }

  @Test func verificationUsesTheOwnedConnectionAndImportClosesItBeforeReplacement() throws {
    let directory = try TemporaryDirectory()
    var retained: GatewayDatabaseConnection?
    try GatewayStateImport.run(
      exportFile: Self.write(Self.export(), to: directory.export), database: directory.database
    ) { connection in
      retained = connection
      #expect(connection.fileURL == directory.staged)
      #expect(
        try connection.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM profiles") }
          == 1)
      let attributes = try FileManager.default.attributesOfItem(atPath: directory.staged.path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
      #expect(directory.entries() == ["gateway.sqlite.import", "gateway.sqlite.lock"])
    }
    try withExtendedLifetime(retained) { () throws in
      #expect(
        try !ProcessTable.processesHoldingOpen(path: directory.database.path).contains(getpid()))
      #expect(directory.entries() == ["gateway.sqlite", "gateway.sqlite.lock"])
    }
  }

  @Test func failedVerificationPreservesAForeignStagedIdentity() throws {
    let directory = try TemporaryDirectory()
    struct Unusable: Error {}
    #expect(throws: Unusable.self) {
      try GatewayStateImport.run(
        exportFile: Self.write(Self.export(), to: directory.export), database: directory.database
      ) { _ in
        try FileManager.default.moveItem(
          at: directory.staged, to: directory.url.appendingPathComponent("owned.sqlite"))
        try Data("foreign".utf8).write(to: directory.staged)
        throw Unusable()
      }
    }
    #expect(try Data(contentsOf: directory.staged) == Data("foreign".utf8))
  }

  @Test(arguments: [
    ExportDefect.schemaVersion, .unknownColumn, .missingColumn, .missingNullableColumn,
    .unsupportedValue, .missingTable,
  ])
  func invalidExportChangesNothing(_ defect: ExportDefect) throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)
    var export = Self.export()
    switch defect {
    case .schemaVersion: export["schema_version"] = 2
    case .unknownColumn: export["profiles"] = [Self.profile.merging(["extra": 1]) { $1 }]
    case .missingColumn:
      var profile = Self.profile
      profile["authorizationRevision"] = nil
      export["profiles"] = [profile]
    case .missingNullableColumn:
      var revisions = export["configurationRevisions"] as! [[String: Any]]
      revisions[0]["activatedAt"] = nil
      export["configurationRevisions"] = revisions
    case .unsupportedValue:
      export["runtimeSettings"] = [["key": "a", "value": [1], "updatedAt": "x"]]
    case .missingTable: export["pluginState"] = nil
    }

    #expect(throws: GatewayStateImportError.self) {
      try Self.importState(export, into: directory.database)
    }
    #expect(try Self.dump(directory.database) == before)
    #expect(directory.entries() == ["gateway.sqlite", "gateway.sqlite.lock"])
  }

  @Test func openConnectionPreventsImportUntilItCloses() throws {
    let directory = try TemporaryDirectory()
    var connection: GatewayDatabaseConnection? = try GatewayDatabaseConnection(
      path: directory.database.path)
    let before = try Data(contentsOf: directory.database)
    _ = withExtendedLifetime(connection) {
      Self.expectInUse(directory.database.path) {
        try Self.importState(Self.export(), into: directory.database)
      }
    }
    #expect(try Data(contentsOf: directory.database) == before)
    connection = nil
    let lock = try FileLock(path: directory.lock.path, mode: .exclusive)
    lock.release()
  }

  @Test func importPreventsConnectionsAndConcurrentImports() throws {
    let directory = try TemporaryDirectory()
    let file = try Self.write(Self.export(), to: directory.export)
    try GatewayStateImport.run(exportFile: file, database: directory.database) { _ in
      #expect(throws: StateImportInProgress(path: directory.database.path)) {
        try GatewayDatabaseConnection(path: directory.database.path)
      }
      Self.expectInUse(directory.database.path) {
        try GatewayStateImport.run(exportFile: file, database: directory.database) { _ in }
      }
    }
    _ = try GatewayDatabaseConnection(path: directory.database.path)
  }

  @Test(arguments: [false, true], GatewayStateImport.Paths.sidecars)
  func refusesOrphanSidecars(withDatabase: Bool, suffix: String) throws {
    let directory = try TemporaryDirectory()
    if withDatabase { try Self.makeEarlierDatabase(at: directory.database) }
    let sidecar = URL(fileURLWithPath: directory.database.path + suffix)
    let contents = Data(repeating: 0, count: 16)
    try contents.write(to: sidecar)
    let before = withDatabase ? try Data(contentsOf: directory.database) : nil

    #expect(throws: GatewayStateImportError.sidecarExists(sidecar.path)) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try Data(contentsOf: sidecar) == contents)
    if let before {
      #expect(try Data(contentsOf: directory.database) == before)
    } else {
      #expect(!FileManager.default.fileExists(atPath: directory.database.path))
    }
  }

  @Test func rollsBackAGenuineHotJournalBeforeReplacing() throws {
    let directory = try TemporaryDirectory()
    let source = directory.url.deletingLastPathComponent().appendingPathComponent("crash.sqlite")
    try Self.makeEarlierDatabase(at: source)
    let queue = try DatabaseQueue(path: source.path)
    let committed = Data(repeating: 1, count: 8192)
    try queue.write { database in
      try database.execute(sql: "CREATE TABLE payloads (id INTEGER PRIMARY KEY, value BLOB)")
      for id in 0..<64 {
        try database.execute(sql: "INSERT INTO payloads VALUES (?, ?)", arguments: [id, committed])
      }
    }
    let before = try Data(contentsOf: source)
    try queue.writeWithoutTransaction { database in
      try database.execute(sql: "PRAGMA journal_mode = DELETE")
      try database.execute(sql: "PRAGMA cache_size = 5")
      try database.execute(sql: "PRAGMA cache_spill = ON")
      try database.execute(sql: "BEGIN IMMEDIATE")
      defer { try? database.execute(sql: "ROLLBACK") }
      try database.execute(
        sql: "UPDATE payloads SET value = ?", arguments: [Data(repeating: 2, count: 8192)])
      try database.execute(sql: "INSERT INTO workspaces VALUES ('uncommitted', '/uncommitted')")
      #expect(try Data(contentsOf: source) != before)
      let journal = URL(fileURLWithPath: source.path + "-journal")
      #expect(
        try Data(contentsOf: journal).prefix(8)
          == Data([0xd9, 0xd5, 5, 0xf9, 0x20, 0xa1, 0x63, 0xd7]))
      try FileManager.default.copyItem(at: source, to: directory.database)
      try FileManager.default.copyItem(
        at: journal, to: URL(fileURLWithPath: directory.database.path + "-journal"))
    }
    try queue.close()

    try Self.importState(Self.export(), into: directory.database)

    try DatabaseQueue(path: directory.previous.path).read { database throws -> Void in
      #expect(try String.fetchAll(database, sql: "SELECT id FROM workspaces") == ["W0"])
      #expect(
        try Int.fetchOne(
          database, sql: "SELECT count(*) FROM payloads WHERE value = ?", arguments: [committed])
          == 64)
      #expect(try Int.fetchOne(database, sql: "SELECT count(*) FROM payloads") == 64)
    }
    #expect(
      directory.entries() == [
        "gateway.sqlite", "gateway.sqlite.before-import", "gateway.sqlite.lock",
      ])
  }

  @Test(arguments: RecoveryStep.allCases)
  func recoveryResumesAtEveryReplacementAndRecoveryStep(_ step: RecoveryStep) throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)
    try Self.interruptReplacement(in: directory, at: step)
    let lock = try FileLock(path: directory.lock.path, mode: .exclusive)
    defer { lock.release() }

    #expect(throws: StateImportInProgress(path: directory.database.path)) {
      try GatewayDatabaseConnection(path: directory.database.path)
    }
    #expect(
      try GatewayStateImport.recover(.init(database: directory.database))
        == (step != .recordRemoved))
    #expect(try !GatewayStateImport.recover(.init(database: directory.database)))
    #expect(try Self.dump(directory.database) == before)
    #expect(directory.entries() == ["gateway.sqlite", "gateway.sqlite.lock"])
  }

  @Test(arguments: ["database", "previous"])
  func recoveryReportsAMissingRecordedFileWithoutChangingAnything(_ name: String) throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    try Self.interruptReplacement(in: directory, at: .stagedRenamed)
    let missing = name == "database" ? directory.database : directory.previous
    let kept = directory.url.deletingLastPathComponent().appendingPathComponent("kept")
    try FileManager.default.moveItem(at: missing, to: kept)
    let before = try directory.snapshot()

    #expect(throws: GatewayStateImportError.missingFile(missing.path)) {
      try GatewayStateImport.recover(.init(database: directory.database))
    }
    #expect(try directory.snapshot() == before)
  }

  @Test func aConcurrentRetryCannotStartRecovery() throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let old = try Self.dump(directory.database)
    try Self.interruptReplacement(in: directory, at: .stagedRenamed)
    let lock = try FileLock(path: directory.lock.path, mode: .exclusive)
    let before = try directory.snapshot()
    Self.expectInUse(directory.database.path) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try directory.snapshot() == before)
    lock.release()
    let report = try Self.importState(Self.export(), into: directory.database)
    #expect(report.restoredInterruptedImport)
    #expect(try Self.dump(directory.previous) == old)
  }

  @Test(arguments: ["database", "previous", "staged"], [""] + GatewayStateImport.Paths.sidecars)
  func recoveryRefusesOpenParticipantsBeforeChangingFiles(_ name: String, suffix: String) throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    try Self.interruptReplacement(in: directory, at: name == "staged" ? .recorded : .stagedRenamed)
    let database =
      name == "database"
      ? directory.database : name == "previous" ? directory.previous : directory.staged
    let url = URL(fileURLWithPath: database.path + suffix)
    if !suffix.isEmpty { try Data("sidecar".utf8).write(to: url) }
    let holder = try FileHandle(forReadingFrom: url)
    defer { try? holder.close() }
    let before = try directory.snapshot()
    Self.expectInUse(url.path) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try directory.snapshot() == before)
    #expect(
      GatewayStateImportError.databaseInUse(path: url.path, processIDs: [getpid()])
        .localizedDescription.contains(url.path))
  }

  @Test(arguments: ["database", "previous", "staged"], GatewayStateImport.Paths.sidecars)
  func recoveryRefusesEverySidecarBeforeChangingFiles(_ name: String, suffix: String) throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    try Self.interruptReplacement(in: directory, at: .stagedRenamed)
    let database =
      name == "database"
      ? directory.database : name == "previous" ? directory.previous : directory.staged
    let sidecar = URL(fileURLWithPath: database.path + suffix)
    try Data("sidecar".utf8).write(to: sidecar)
    let before = try directory.snapshot()

    #expect(throws: GatewayStateImportError.sidecarExists(sidecar.path)) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try directory.snapshot() == before)
  }

  @Test(arguments: [false, true])
  func recoversACompleteTemporaryRecordBeforeOrAfterPublication(published: Bool) throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)
    try Self.interruptReplacement(in: directory, at: .recorded)
    try FileManager.default.moveItem(at: directory.replacing, to: directory.replacingTemporary)
    if published {
      try FileManager.default.linkItem(at: directory.replacingTemporary, to: directory.replacing)
    }
    let lock = try FileLock(path: directory.lock.path, mode: .exclusive)
    defer { lock.release() }

    #expect(try GatewayStateImport.recover(.init(database: directory.database)))
    #expect(try !GatewayStateImport.recover(.init(database: directory.database)))
    #expect(try Self.dump(directory.database) == before)
    #expect(directory.entries() == ["gateway.sqlite", "gateway.sqlite.lock"])
  }

  @Test(arguments: ["empty", "truncated", "missingPrevious", "foreignStaged", "missingStaged"])
  func preservesAnUnrecognizedTemporaryRecord(_ defect: String) throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    try Self.interruptReplacement(in: directory, at: .recorded)
    try FileManager.default.moveItem(at: directory.replacing, to: directory.replacingTemporary)
    var expected = GatewayStateImportError.invalidReplacementRecord(
      directory.replacingTemporary.path)
    switch defect {
    case "empty": try Data().write(to: directory.replacingTemporary)
    case "truncated": try Data(#"{"previous":"#.utf8).write(to: directory.replacingTemporary)
    case "missingPrevious":
      let record = try JSONDecoder().decode(
        GatewayStateImport.ReplacementRecord.self,
        from: Data(contentsOf: directory.replacingTemporary))
      try JSONSerialization.data(withJSONObject: [
        "staged": ["device": record.staged.device, "inode": record.staged.inode]
      ])
      .write(to: directory.replacingTemporary)
    case "foreignStaged":
      try Data("foreign".utf8).write(to: directory.staged, options: .atomic)
      expected = .unexpectedFile(directory.replacingTemporary.path)
    default:
      try FileManager.default.removeItem(at: directory.staged)
      expected = .unexpectedFile(directory.replacingTemporary.path)
    }
    let before = try directory.snapshot()

    #expect(throws: expected) { try Self.importState(Self.export(), into: directory.database) }
    #expect(try directory.snapshot() == before)
  }

  @Test func recoveryPreservesAForeignTemporaryRecordBesideAPublishedRecord() throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    try Self.interruptReplacement(in: directory, at: .stagedRenamed)
    try Data("foreign".utf8).write(to: directory.replacingTemporary)
    let before = try directory.snapshot()

    #expect(throws: GatewayStateImportError.unexpectedFile(directory.replacingTemporary.path)) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try directory.snapshot() == before)
  }

  @Test func recordPublicationNeverOverwritesAnExistingRecord() throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Data(contentsOf: directory.database)
    #expect(throws: GatewayStateImportError.unexpectedFile(directory.replacing.path)) {
      try GatewayStateImport.run(
        exportFile: Self.write(Self.export(), to: directory.export), database: directory.database
      ) { _ in try Data("foreign".utf8).write(to: directory.replacing) }
    }
    #expect(try Data(contentsOf: directory.database) == before)
    #expect(try Data(contentsOf: directory.replacing) == Data("foreign".utf8))
    let temporary = try JSONDecoder().decode(
      GatewayStateImport.ReplacementRecord.self,
      from: Data(contentsOf: directory.replacingTemporary))
    #expect(try temporary.previous == GatewayStateImport.FileIdentity.require(directory.database))
    #expect(try temporary.staged == GatewayStateImport.FileIdentity.require(directory.staged))
  }

  @Test(arguments: MissingDatabaseStep.allCases)
  func recoveryResumesAnInstallationIntoAMissingDatabase(_ step: MissingDatabaseStep) throws {
    let directory = try TemporaryDirectory()
    try Self.interruptInstallation(in: directory, at: step)
    let lock = try FileLock(path: directory.lock.path, mode: .exclusive)
    defer { lock.release() }

    #expect(
      try GatewayStateImport.recover(.init(database: directory.database))
        == (step != .recordRemoved))
    #expect(try !GatewayStateImport.recover(.init(database: directory.database)))
    #expect(directory.entries() == ["gateway.sqlite.lock"])
  }

  @Test(arguments: [MissingDatabaseStep.recorded, .databaseLinked, .stagedUnlinked])
  func importsAfterAnInterruptedInstallationIntoAMissingDatabase(_ step: MissingDatabaseStep) throws
  {
    let directory = try TemporaryDirectory()
    try Self.interruptInstallation(in: directory, at: step)
    #expect(throws: InterruptedStateImport(path: directory.database.path)) {
      try GatewayDatabaseConnection(path: directory.database.path)
    }
    let report = try Self.importState(Self.export(), into: directory.database)

    #expect(report.restoredInterruptedImport)
    #expect(report.previousDatabase == nil)
    #expect(try Self.ledger(directory.database) == ["gateway-initial"])
    #expect(directory.entries() == ["gateway.sqlite", "gateway.sqlite.lock"])
  }

  @Test(arguments: ["database", "previous", "staged"])
  func missingDatabaseRecoveryPreservesEveryForeignIdentity(_ name: String) throws {
    let directory = try TemporaryDirectory()
    try Self.interruptInstallation(in: directory, at: .databaseLinked)
    let url =
      name == "database"
      ? directory.database : name == "previous" ? directory.previous : directory.staged
    try Data("foreign".utf8).write(to: url, options: .atomic)
    let before = try directory.snapshot()
    #expect(throws: GatewayStateImportError.unexpectedFile(url.path)) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try directory.snapshot() == before)
  }

  @Test func interruptedReplacementPreventsOpeningAfterTheImportLockIsReleased() throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    try Self.interruptReplacement(in: directory, at: .stagedRenamed)
    #expect(throws: InterruptedStateImport(path: directory.database.path)) {
      try GatewayDatabaseConnection(path: directory.database.path)
    }
  }

  @Test(
    arguments: ["database", "previous", "staged"],
    [RecoveryStep.recorded, .previousLinked, .stagedRenamed])
  func recoveryPreservesEveryFileWhenANameHasAForeignIdentity(_ name: String, step: RecoveryStep)
    throws
  {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    try Self.interruptReplacement(in: directory, at: step)
    let url =
      name == "database"
      ? directory.database : name == "previous" ? directory.previous : directory.staged
    try Data("foreign".utf8).write(to: url, options: .atomic)
    let lock = try FileLock(path: directory.lock.path, mode: .exclusive)
    defer { lock.release() }
    let before = try directory.snapshot()

    for _ in 0..<2 {
      #expect(throws: GatewayStateImportError.unexpectedFile(url.path)) {
        try GatewayStateImport.recover(.init(database: directory.database))
      }
      #expect(try directory.snapshot() == before)
    }
    #expect(
      GatewayStateImportError.unexpectedFile(url.path).localizedDescription.contains(url.path))
  }

  @Test func aLateBackupCollisionPreservesAllFiles() throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)
    #expect(throws: GatewayStateImportError.unexpectedFile(directory.previous.path)) {
      try GatewayStateImport.run(
        exportFile: Self.write(Self.export(), to: directory.export), database: directory.database
      ) { _ in
        try Data("foreign".utf8).write(to: directory.previous)
      }
    }
    #expect(try Self.dump(directory.database) == before)
    #expect(try Data(contentsOf: directory.previous) == Data("foreign".utf8))
    #expect(FileManager.default.fileExists(atPath: directory.staged.path))
    #expect(FileManager.default.fileExists(atPath: directory.replacing.path))
  }

  @Test func aDatabaseAppearingDuringImportIsNeverOverwritten() throws {
    let directory = try TemporaryDirectory()
    #expect(throws: GatewayStateImportError.unexpectedFile(directory.database.path)) {
      try GatewayStateImport.run(
        exportFile: Self.write(Self.export(), to: directory.export), database: directory.database
      ) { _ in
        try Data("foreign".utf8).write(to: directory.database)
      }
    }
    #expect(try Data(contentsOf: directory.database) == Data("foreign".utf8))
  }

  @Test func importAfterAnInterruptionRestoresThenImports() throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)
    try Self.interruptReplacement(in: directory, at: .stagedRenamed)

    let report = try Self.importState(Self.export(), into: directory.database)

    #expect(report.restoredInterruptedImport)
    #expect(try Self.dump(directory.previous) == before)
    #expect(try Self.ledger(directory.database) == ["gateway-initial"])
    #expect(
      directory.entries() == [
        "gateway.sqlite", "gateway.sqlite.before-import", "gateway.sqlite.lock",
      ])
  }

  @Test(arguments: [UInt64(Int64.max) + 1, UInt64.max])
  func scalarIntegersOutsideInt64AreInvalid(_ value: UInt64) throws {
    let directory = try TemporaryDirectory()
    var export = Self.export()
    export["profiles"] = [Self.profile.merging(["authorizationRevision": value]) { $1 }]
    #expect(throws: GatewayStateImportError.self) {
      try Self.importState(export, into: directory.database)
    }
    #expect(directory.entries() == ["gateway.sqlite.lock"])
  }

  @Test func jsonNumbersRoundTripAtIntegerBoundaries() throws {
    let directory = try TemporaryDirectory()
    var export = Self.export()
    export["pluginState"] = [["id": 1, "revision": 4, "payloadJSON": "__numbers__"]]
    let numbers =
      #"{"signed":9223372036854775807,"unsigned":9223372036854775808,"maximum":18446744073709551615,"inode":9223372036854775809,"negative":-42,"real":1.25}"#
    let text = String(decoding: try JSONSerialization.data(withJSONObject: export), as: UTF8.self)
      .replacingOccurrences(of: #""__numbers__""#, with: numbers)
    try Data(text.utf8).write(to: directory.export)
    try GatewayStateImport.run(exportFile: directory.export, database: directory.database) { _ in }
    let payload = try #require(
      try DatabaseQueue(path: directory.database.path).read {
        try String.fetchOne($0, sql: "SELECT payloadJSON FROM pluginState")
      })
    struct Numbers: Decodable {
      let signed: Int64
      let unsigned: UInt64
      let maximum: UInt64
      let inode: UInt64
      let negative: Int64
      let real: Double
    }
    let decoded = try JSONDecoder().decode(Numbers.self, from: Data(payload.utf8))
    #expect(decoded.signed == Int64.max)
    #expect(decoded.unsigned == UInt64(Int64.max) + 1)
    #expect(decoded.maximum == UInt64.max)
    #expect(decoded.inode == UInt64(Int64.max) + 2)
    #expect(decoded.negative == -42)
    #expect(decoded.real == 1.25)
    #expect(payload.contains("9223372036854775808"))
    #expect(payload.contains("18446744073709551615"))
  }

  @Test func blobEnvelopeTakesPrecedenceInJSONColumns() throws {
    let directory = try TemporaryDirectory()
    var export = Self.export()
    let payload = Data(#"{"revision":4,"installations":[]}"#.utf8)
    export["pluginState"] = [
      [
        "id": 1, "revision": 4,
        "payloadJSON": ["encoding": "base64", "data": payload.base64EncodedString()],
      ]
    ]
    try Self.importState(export, into: directory.database)
    try DatabaseQueue(path: directory.database.path).read { database throws -> Void in
      #expect(
        try String.fetchOne(database, sql: "SELECT typeof(payloadJSON) FROM pluginState") == "blob")
      #expect(try Data.fetchOne(database, sql: "SELECT payloadJSON FROM pluginState") == payload)
    }
  }

  enum ExportDefect: Sendable {
    case schemaVersion, unknownColumn, missingColumn, missingNullableColumn, unsupportedValue,
      missingTable
  }
  enum RecoveryStep: CaseIterable, Sendable {
    case recorded, previousLinked, stagedRenamed, previousRestored, previousUnlinked,
      stagedUnlinked, recordRemoved
  }
  enum MissingDatabaseStep: CaseIterable, Sendable {
    case recorded, databaseLinked, stagedUnlinked, databaseUnlinked, stagedRolledBack, recordRemoved
  }

  private static func interruptInstallation(
    in directory: TemporaryDirectory, at step: MissingDatabaseStep
  )
    throws
  {
    let lock = try FileLock(path: directory.lock.path, mode: .exclusive)
    defer { lock.release() }
    let staged = try DatabaseQueue(path: directory.staged.path)
    try GatewayDatabaseConnection.migrator.migrate(staged)
    try staged.close()
    let record = GatewayStateImport.ReplacementRecord(
      previous: nil, staged: try GatewayStateImport.FileIdentity.require(directory.staged))
    let data = try JSONEncoder().encode(record)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["previous"] is NSNull)
    try data.write(to: directory.replacing)
    if step != .recorded {
      try FileManager.default.linkItem(at: directory.staged, to: directory.database)
    }
    if step == .stagedUnlinked {
      try FileManager.default.removeItem(at: directory.staged)
    }
    if step == .databaseUnlinked || step == .stagedRolledBack || step == .recordRemoved {
      try FileManager.default.removeItem(at: directory.database)
    }
    if step == .stagedRolledBack || step == .recordRemoved {
      try FileManager.default.removeItem(at: directory.staged)
    }
    if step == .recordRemoved { try FileManager.default.removeItem(at: directory.replacing) }
  }

  private static func interruptReplacement(in directory: TemporaryDirectory, at step: RecoveryStep)
    throws
  {
    let lock = try FileLock(path: directory.lock.path, mode: .exclusive)
    defer { lock.release() }
    let staged = try DatabaseQueue(path: directory.staged.path)
    try GatewayDatabaseConnection.migrator.migrate(staged)
    try staged.close()
    let record = GatewayStateImport.ReplacementRecord(
      previous: try GatewayStateImport.FileIdentity.require(directory.database),
      staged: try GatewayStateImport.FileIdentity.require(directory.staged))
    try JSONEncoder().encode(record).write(to: directory.replacing)
    if step != .recorded {
      guard link(directory.database.path, directory.previous.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    if step == .stagedRenamed || step == .previousRestored {
      try renameFile(directory.staged, to: directory.database)
    }
    if step == .previousRestored {
      try renameFile(directory.previous, to: directory.database)
    }
    if step == .previousUnlinked || step == .stagedUnlinked || step == .recordRemoved {
      try FileManager.default.removeItem(at: directory.previous)
    }
    if step == .stagedUnlinked || step == .recordRemoved {
      try FileManager.default.removeItem(at: directory.staged)
    }
    if step == .recordRemoved { try FileManager.default.removeItem(at: directory.replacing) }
  }

  /// A process that a concurrent test forks shares this process's descriptors until it
  /// executes, so the reported holders include this process and may include such a child.
  private static func expectInUse(
    _ path: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () throws -> Void
  ) {
    let error = #expect(throws: GatewayStateImportError.self, sourceLocation: sourceLocation) {
      try operation()
    }
    guard case .databaseInUse(let reportedPath, let processIDs)? = error else {
      Issue.record(
        "Expected databaseInUse, got \(String(describing: error))", sourceLocation: sourceLocation)
      return
    }
    #expect(reportedPath == path, sourceLocation: sourceLocation)
    #expect(processIDs.contains(getpid()), sourceLocation: sourceLocation)
  }

  private static func renameFile(_ source: URL, to destination: URL) throws {
    #if canImport(Darwin)
      let result = Darwin.rename(source.path, destination.path)
    #else
      let result = Glibc.rename(source.path, destination.path)
    #endif
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  private static let tables = [
    "workspaces", "workspaceCanonicalRoots", "workspaceAliases", "profiles",
    "clientControlTrust", "runtimeSettings", "configurationRevisions", "pluginState",
    "pluginOwnedDirectories", "pluginDerivedWorkspaces",
  ]

  private static var profile: [String: Any] {
    [
      "id": "chatgpt-operate", "capabilityIDsJSON": ["file.read", "git.status"],
      "workspaceIDsJSON": ["W1"], "allowedCallersJSON": ["secure-tunnel"], "fullShellEnabled": 0,
      "updatedAt": "2026-10-01 08:00:00.000", "mcpServerIDsJSON": [], "mode": "operate",
      "confirmationPolicy": "never", "authorizationRevision": 3,
    ]
  }

  /// A schema 1 export in the form the M3 exporter writes.
  private static func export() -> [String: Any] {
    [
      "schema_version": 1,
      "source": ["database_sha256": "0", "row_counts": [:], "grdb_migrations": ["initial-schema"]],
      "workspaces": [
        [
          "id": "W1", "displayName": "Project", "rootPath": "/Users/example/project",
          "bookmarkData": ["encoding": "base64", "data": "AAEC/w=="], "bookmarkIsStale": 0,
          "createdAt": "2026-10-01 08:00:00.000", "updatedAt": "2026-10-01 08:00:00.000",
          "workspaceCanonicalRoots": [
            [
              "canonicalRootPath": "/Users/example/project", "workspaceID": "W1",
              "createdAt": "2026-10-01 08:00:00.000",
            ]
          ],
        ]
      ],
      "workspaceAliases": [],
      "profiles": [profile],
      "clientControlTrust": [
        [
          "id": "trust-1", "principalID": "credential:a", "profileID": "chatgpt-operate",
          "caller": "secure-tunnel", "revision": 1, "profile": ["mode": "operate", "shell": false],
          "fullAccessAllowed": 0, "updatedAt": "2026-10-01 08:00:00.000",
        ]
      ],
      "runtimeSettings": [
        ["key": "active-gateway-profile", "value": "chatgpt-operate", "updatedAt": "2026-10-01"],
        ["key": "desired-running-openai-tunnels", "value": ["chatgpt"], "updatedAt": "2026-10-01"],
      ],
      "configurationRevisions": [
        [
          "id": "R1", "digest": "abc", "manifest": "schema_version = 1\n",
          "createdAt": "2026-10-01 08:00:00.000", "activatedAt": "2026-10-01 08:00:00.000",
          "activationError": NSNull(),
        ]
      ],
      "pluginState": [
        [
          "id": 1, "revision": 4,
          "payloadJSON": [
            "revision": 4,
            "installations": [["registeredAt": 782_000_000.25, "root": "file:///plugins/a/"]],
          ],
        ]
      ],
      "pluginOwnedDirectories": [],
      "pluginDerivedWorkspaces": [],
      "configuration_toml": "schema_version = 1\n",
      "secret_references": [["service": "com.example.secrets", "account": "tunnel.chatgpt"]],
      "dropped": ["auditEvents": 3],
      "exported_at": "2026-10-19T03:07:00Z",
    ]
  }

  @discardableResult
  private static func importState(_ export: [String: Any], into database: URL) throws
    -> GatewayStateImport.Report
  {
    let file = database.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("export.json")
    return try GatewayStateImport.run(exportFile: write(export, to: file), database: database) {
      _ in
    }
  }

  private static func write(_ export: [String: Any], to url: URL) throws -> URL {
    try JSONSerialization.data(withJSONObject: export).write(to: url)
    return url
  }

  /// A database as a version before 0.1.0 left it.
  private static func makeEarlierDatabase(at url: URL) throws {
    let database = try DatabaseQueue(path: url.path)
    try database.write { database in
      try database.execute(
        sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
      try database.execute(sql: "INSERT INTO grdb_migrations VALUES ('initial-schema')")
      try database.execute(sql: "CREATE TABLE workspaces (id TEXT PRIMARY KEY, rootPath TEXT)")
      try database.execute(sql: "INSERT INTO workspaces VALUES ('W0', '/Users/example/old')")
    }
  }

  private static func ledger(_ url: URL) throws -> [String] {
    try DatabaseQueue(path: url.path).read {
      try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")
    }
  }

  /// Schema and rows, read by a plain SQLite connection as an earlier version would open it.
  private static func dump(_ url: URL) throws -> [String] {
    try DatabaseQueue(path: url.path).read { database in
      var lines: [String] = []
      for (name, sql) in try Row.fetchAll(
        database,
        sql: "SELECT name, sql FROM sqlite_schema WHERE type = 'table' ORDER BY name"
      ).map({ ($0["name"] as String, $0["sql"] as String) }) {
        lines.append(sql)
        lines += try Row.fetchAll(database, sql: "SELECT * FROM \(name.quotedDatabaseIdentifier)")
          .map(\.description)
      }
      return lines
    }
  }
}

/// A database directory, with the export written beside it.
private final class TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

  var lock: URL { url.appendingPathComponent("gateway.sqlite.lock") }
  var export: URL { url.deletingLastPathComponent().appendingPathComponent("export.json") }
  var database: URL { url.appendingPathComponent("gateway.sqlite") }
  var staged: URL { url.appendingPathComponent("gateway.sqlite.import") }
  var previous: URL { url.appendingPathComponent("gateway.sqlite.before-import") }
  var replacing: URL { url.appendingPathComponent("gateway.sqlite.import-replacing") }
  var replacingTemporary: URL { url.appendingPathComponent("gateway.sqlite.import-replacing.tmp") }

  func snapshot() throws -> [String: Data] {
    try Dictionary(
      uniqueKeysWithValues: entries().map {
        ($0, try Data(contentsOf: url.appendingPathComponent($0)))
      })
  }

  func entries() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
  }
}
