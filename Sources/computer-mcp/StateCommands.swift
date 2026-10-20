import ArgumentParser
import ComputerMCP
import ComputerMCPCore
import ComputerMCPPersistence
import Foundation

struct State: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "state",
    abstract: "Move App state between Computer MCP installations.",
    subcommands: [StateImport.self]
  )
}

struct StateImport: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "import",
    abstract: "Import the state exported from an installation created before 0.1.0.",
    discussion: """
      Quit the App and stop every gateway, bridge and tunnel process first: the import \
      refuses a database that any process has open, a concurrent import and any remaining \
      SQLite sidecars after hot-journal recovery. Connections and imports coordinate through \
      <database>.lock. Staging creates no separate lock file. The previous database is kept \
      as <database>.before-import. The next run rolls back an interrupted import only after \
      refusing open files or SQLite sidecars at the database, backup and staged names.
      """
  )

  @Argument(help: "State export JSON file (schema 1).")
  var file: String

  @Option(name: .long, help: "Gateway database to replace (default: the App's database).")
  var database: String?

  func run() throws {
    let databaseURL =
      try database.map { URL(fileURLWithPath: $0).standardizedFileURL }
      ?? AppControlPlaneServiceDirectories.standard().database
    // The App keeps its manifest in Configuration/ next to the database.
    let configurationDirectory = databaseURL.deletingLastPathComponent()
      .appendingPathComponent("Configuration", isDirectory: true)
    let report = try GatewayStateImport.run(
      exportFile: URL(fileURLWithPath: file).standardizedFileURL, database: databaseURL
    ) { connection in
      try GatewayDatabase(connection: connection)
        .verifyImportedState(configurationDirectory: configurationDirectory)
    }
    printJSON(
      .object([
        "schema_version": .number(1),
        "database": .string(databaseURL.path),
        "previous_database": report.previousDatabase.map { .string($0.path) } ?? .null,
        "restored_interrupted_import": .bool(report.restoredInterruptedImport),
        "rows": .object(
          Dictionary(
            uniqueKeysWithValues: report.rowCounts.map { ($0.table, .integer(Int64($0.rows))) })
        ),
      ])
    )
  }
}
