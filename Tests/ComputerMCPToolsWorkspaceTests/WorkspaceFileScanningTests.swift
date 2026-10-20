import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPToolsFiles
import Foundation
import Testing

@testable import ComputerMCPToolsWorkspace

@Suite(.nativeIntegration)
struct WorkspaceFileScanningTests {
  @Test
  func testRecursiveReadOnlyScansPreserveSymlinksWithoutFollowingThem() throws {
    let temporary = try ScopedTemporaryDirectory()
    let container = temporary.url
    defer { try? FileManager.default.removeItem(at: container) }
    let workspace = container.appendingPathComponent("workspace", isDirectory: true)
    let outside = container.appendingPathComponent("outside", isDirectory: true)
    let links = workspace.appendingPathComponent("Links", isDirectory: true)
    try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try "LOCAL_KEY=local-value\n".write(
      to: workspace.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "# TODO local\n".write(
      to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try "OUTSIDE_SCAN_SECRET=must-not-be-read\n".write(
      to: outside.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "OUTSIDE_SCAN_SECRET\n".write(
      to: outside.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: links.appendingPathComponent("missing").path,
      withDestinationPath: "../missing.txt"
    )
    try FileManager.default.createSymbolicLink(
      atPath: links.appendingPathComponent("readme.md").path,
      withDestinationPath: "../README.md"
    )
    try FileManager.default.createSymbolicLink(
      at: links.appendingPathComponent("outside.env"),
      withDestinationURL: outside.appendingPathComponent(".env")
    )
    try FileManager.default.createSymbolicLink(
      at: links.appendingPathComponent("outside.txt"),
      withDestinationURL: outside.appendingPathComponent("outside.txt")
    )

    let environment = ToolEnvironment(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: [
          "file.find", "file.list", "file.search", "file.tree", "workspace.env_files",
          "workspace.todos",
        ]),
        workspaceDirectory: workspace
      )
    )
    let files = FilesToolProvider(environment: environment)
    let workspaceProvider = WorkspaceToolProvider(environment: environment)

    let listResult = try files.callTool(
      .init(
        name: "file.list",
        arguments: .object([
          "path": .string("."),
          "include_hidden": .bool(true),
          "recursive_depth": .number(2),
          "max_entries": .number(100),
        ]), context: .empty
      ))
    let listPayload = try decodeTextPayload(listResult)
    let entries = try #require(listPayload.objectValue?["entries"]?.arrayValue)
    func entry(at path: String) -> [String: JSONValue]? {
      entries.first {
        $0.objectValue?["workspace_relative_path"] == .string(path)
      }?.objectValue
    }
    #expect((entry(at: "Links/missing")?["type"]) == (.string("symlink")))
    #expect((entry(at: "Links/readme.md")?["type"]) == (.string("symlink")))
    #expect((entry(at: "Links/outside.env")?["type"]) == (.string("symlink")))
    #expect((entry(at: "Links/outside.txt")?["type"]) == (.string("symlink")))

    let treeResult = try files.callTool(
      .init(
        name: "file.tree",
        arguments: .object([
          "path": .string("."),
          "include_hidden": .bool(true),
          "max_depth": .number(3),
          "max_entries": .number(100),
        ]), context: .empty
      ))
    let treePayload = try decodeTextPayload(treeResult)
    #expect((treePayload.objectValue?["truncated"]) == (.bool(false)))
    #expect((treePayload.objectValue?["entry_count"]?.numberValue ?? 0) >= 7)

    let findResult = try files.callTool(
      .init(
        name: "file.find",
        arguments: .object([
          "path": .string("."),
          "query": .string("missing"),
          "include_hidden": .bool(true),
        ]), context: .empty
      ))
    let findPayload = try decodeTextPayload(findResult)
    let findResults = try #require(findPayload.objectValue?["results"]?.arrayValue)
    #expect(
      findResults.contains {
        $0.objectValue?["workspace_relative_path"] == .string("Links/missing")
          && $0.objectValue?["type"] == .string("symlink")
      })

    let searchResult = try files.callTool(
      .init(
        name: "file.search",
        arguments: .object([
          "path": .string("."),
          "query": .string("OUTSIDE_SCAN_SECRET"),
          "include_hidden": .bool(true),
        ]), context: .empty
      ))
    let searchPayload = try decodeTextPayload(searchResult)
    #expect((searchPayload.objectValue?["match_count"]) == (.number(0)))

    let todosResult = try workspaceProvider.callTool(
      .init(
        name: "workspace.todos",
        arguments: .object([
          "path": .string("."),
          "markers": .array([.string("OUTSIDE_SCAN_SECRET")]),
          "include_hidden": .bool(true),
        ]), context: .empty
      ))
    let todosPayload = try decodeTextPayload(todosResult)
    #expect((todosPayload.objectValue?["match_count"]) == (.number(0)))

    let envResult = try workspaceProvider.callTool(
      .init(
        name: "workspace.env_files",
        arguments: .object([
          "path": .string("."),
          "include_hidden_directories": .bool(true),
        ]), context: .empty
      ))
    let envPayload = try decodeTextPayload(envResult)
    let envFiles = try #require(envPayload.objectValue?["env_files"]?.arrayValue)
    #expect((envPayload.objectValue?["env_file_count"]) == (.number(1)))
    #expect(
      envFiles.first?.objectValue?["workspace_relative_path"] == .string(".env"))
    let keys = try #require(envFiles.first?.objectValue?["keys"]?.arrayValue)
    #expect((keys.map { $0.objectValue?["name"] }) == [.string("LOCAL_KEY")])
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}
