import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsStructured

@Suite(.nativeIntegration)
struct StructuredOperationGuardTests {
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
    let executable = try testExecutable("sqlite3")
    let initializer = ToolEnvironment(
      configuration: .init(projectDirectory: root), environment: environment)
    let initialized = try initializer.commandRunner.run(
      executable: executable,
      arguments: [
        "-init", "/dev/null", "-safe", root.appendingPathComponent("database.sqlite").path,
        "CREATE TABLE sample (value TEXT)",
      ],
      workingDirectory: root, environment: [:], timeoutMilliseconds: 10_000, maxOutputBytes: 4096)
    try #require(initialized.exitCode == 0)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: .init(enabled: [tool]), projectDirectory: root),
        environment: environment,
        sqliteCommand: .init(id: "sqlite3", executable: executable)))
    _ = try provider.callTool(
      .init(
        name: tool,
        arguments: .object([
          "path": .string("database.sqlite"), "query": .string("SELECT 1 AS value"),
        ]), context: .empty))
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
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.query"]), projectDirectory: root),
        sqliteCommand: .init(id: "sqlite3", executable: try testExecutable("sqlite3"))))
    #expect(throws: (any Error).self) {
      _ = try provider.callTool(
        .init(
          name: "sqlite.query",
          arguments: .object([
            "path": .string("database.sqlite"), "query": .string("SELECT \(expression)"),
          ]), context: .empty))
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
  }
}
