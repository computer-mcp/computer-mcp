import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsStructured

@Suite(.nativeIntegration)
struct StructuredOperationGuardTests {
  @Test(arguments: ["sqlite.query", "sqlite.schema"])
  func sqliteWithoutRegisteredCommandFailsBeforeExecution(tool: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let database = temporary.url.appendingPathComponent("database.sqlite")
    try Data().write(to: database)
    let runner = RecordingCommandRunner()
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: .init(builtin: .init(enabled: [tool]), projectDirectory: temporary.url),
        commandRunner: runner))
    #expect(
      throws: GatewayToolError.disabled("SQLite inspection is unavailable on this platform.")
    ) {
      _ = try provider.callTool(
        .init(
          name: tool,
          arguments: .object([
            "path": .string("database.sqlite"), "query": .string("SELECT 1"),
          ]), context: .empty))
    }
    #expect(runner.calls.isEmpty)
    #expect(try Data(contentsOf: database).isEmpty)
  }

  @Test(arguments: ["sqlite.query", "sqlite.schema"], [false, true])
  func sqliteIgnoresHomeInitialization(tool: String, projectHome: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.appendingPathComponent("project")
    let home = projectHome ? root : temporary.url.appendingPathComponent("owner-home")
    for directory in [root, home] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let marker = temporary.url.appendingPathComponent("executed")
    try Data(".shell touch '\(marker.path)'\n".utf8).write(
      to: home.appendingPathComponent(".sqliterc"))
    try Data().write(to: root.appendingPathComponent("database.sqlite"))
    let environment = ["PATH": systemUtilityPath, "HOME": home.path]
    let command = (try? testExecutable("sqlite3")).map {
      CLICommandConfig(id: "sqlite3", executable: $0)
    }
    if let command {
      let initializer = ToolEnvironment(
        configuration: .init(projectDirectory: root), environment: environment)
      let initialized = try initializer.commandRunner.run(
        executable: command.executable,
        arguments: [
          "-init", "/dev/null", "-safe", root.appendingPathComponent("database.sqlite").path,
          "CREATE TABLE sample (value TEXT)",
        ],
        workingDirectory: root, environment: [:], timeoutMilliseconds: 10_000, maxOutputBytes: 4096)
      try #require(initialized.exitCode == 0)
    }
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: .init(enabled: [tool]), projectDirectory: root),
        environment: environment,
        sqliteCommand: command))
    let invocation = ToolInvocation(
      name: tool,
      arguments: .object([
        "path": .string("database.sqlite"), "query": .string("SELECT 1 AS value"),
      ]), context: .empty)
    if command != nil {
      _ = try provider.callTool(invocation)
    } else {
      #expect(
        throws: GatewayToolError.disabled("SQLite inspection is unavailable on this platform.")
      ) {
        _ = try provider.callTool(invocation)
      }
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test(arguments: ["json.write", "plist.write"], ["hardlink", "symlink", "git"])
  func structuredWritesEnforceFileBoundary(tool: String, kind: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let original = root.appendingPathComponent("original")
    try Data("original".utf8).write(to: original)
    var path = "target"
    if kind == "hardlink" {
      try FileManager.default.linkItem(at: original, to: root.appendingPathComponent(path))
    } else if kind == "symlink" {
      try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent(path), withDestinationURL: original)
    } else {
      path = ".git/config"
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: [tool]), projectDirectory: root)))
    #expect(throws: (any Error).self) {
      _ = try provider.callTool(
        .init(
          name: tool,
          arguments: .object([
            "path": .string(path), "value": .object(["value": .integer(1)]),
            "overwrite": .bool(true),
            "dry_run": .bool(false), "confirm_write": .bool(true),
          ]), context: .empty))
    }
    #expect(try Data(contentsOf: original) == Data("original".utf8))
  }

  @Test(arguments: ["edit('value', 'touch marker')", "writefile('marker', 'value')"])
  func sqliteSafeModeBlocksHostSideEffects(expression: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    try Data().write(to: root.appendingPathComponent("database.sqlite"))
    let command = (try? testExecutable("sqlite3")).map {
      CLICommandConfig(id: "sqlite3", executable: $0)
    }
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.query"]), projectDirectory: root),
        sqliteCommand: command))
    let invocation = ToolInvocation(
      name: "sqlite.query",
      arguments: .object([
        "path": .string("database.sqlite"), "query": .string("SELECT \(expression)"),
      ]), context: .empty)
    if command != nil {
      #expect(throws: (any Error).self) { _ = try provider.callTool(invocation) }
    } else {
      #expect(
        throws: GatewayToolError.disabled("SQLite inspection is unavailable on this platform.")
      ) {
        _ = try provider.callTool(invocation)
      }
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
  }
}
