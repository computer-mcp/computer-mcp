import AppKit
import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPMacOS

@Suite(.nativeIntegration, .serialized)
final class MacOSToolProviderTests {
  @Test
  func testMacOSApplicationsReturnsBoundedApplicationSummary() throws {
    let provider = MacOSToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["macos.applications"])
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "macos.applications",
        arguments: .object([
          "include_system": .bool(true),
          "include_user": .bool(false),
          "max_results": .number(5),
          "max_depth": .number(2),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["include_system"]) == (.bool(true)))
    #expect((payload.objectValue?["include_user"]) == (.bool(false)))
    #expect((payload.objectValue?["max_depth"]) == (.number(2)))
    #expect((payload.objectValue?["application_count"]) != nil)
    #expect((payload.objectValue?["applications"]?.arrayValue) != nil)
  }

  @Test
  func testMacOSUserDirectoriesReturnsFixedDirectoryCatalog() throws {
    let provider = MacOSToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["macos.user_directories"])
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "macos.user_directories",
        arguments: .object([
          "include_missing": .bool(true),
          "include_system": .bool(true),
          "include_temporary": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let directories = try #require(payload.objectValue?["directories"]?.arrayValue)
    let byID = Dictionary(
      uniqueKeysWithValues: directories.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let id = object["id"]?.stringValue
        else {
          return nil
        }
        return (id, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("macos.user_directories")))
    #expect((payload.objectValue?["include_missing"]) == (.bool(true)))
    #expect((payload.objectValue?["include_system"]) == (.bool(true)))
    #expect((payload.objectValue?["include_temporary"]) == (.bool(true)))
    #expect((byID["home"]?["exists"]) == (.bool(true)))
    #expect((byID["home"]?["type"]) == (.string("directory")))
    #expect((byID["home"]?["path"]?.stringValue) != nil)
    #expect((byID["local_applications"]?["path"]) == (.string("/Applications")))
    #expect((byID["temporary"]?["exists"]) == (.bool(true)))
    #expect((byID["home"]?["children"]) == nil)
    #expect((byID["home"]?["contents"]) == nil)

    let filteredResult = try provider.callTool(
      .init(
        name: "macos.user_directories",
        arguments: .object([
          "include_missing": .bool(false),
          "include_system": .bool(false),
          "include_temporary": .bool(false),
        ]), context: .empty
      ))
    let filteredPayload = try decodeTextPayload(filteredResult)
    let filteredDirectories = try #require(
      filteredPayload.objectValue?["directories"]?.arrayValue)
    let filteredIDs = Set(filteredDirectories.compactMap { $0.objectValue?["id"]?.stringValue })
    #expect(!(filteredIDs.contains("local_applications")))
    #expect(!(filteredIDs.contains("system_applications")))
    #expect(!(filteredIDs.contains("temporary")))
    #expect(filteredIDs.contains("home"))
    #expect((filteredPayload.objectValue?["include_missing"]) == (.bool(false)))
  }

  @Test
  func testMacOSDefaultApplicationReturnsReadOnlyHandlerInfo() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("note.txt")
    try "hello\n".write(to: file, atomically: true, encoding: .utf8)

    var config = GatewayConfiguration.fixture(
      builtin: BuiltinConfig(enabled: ["macos.default_application"])
    )
    config.projectDirectory = directory
    let provider = MacOSToolProvider(environment: ToolEnvironment(configuration: config))

    let result = try provider.callTool(
      .init(
        name: "macos.default_application",
        arguments: .object([
          "path": .string("note.txt"),
          "include_candidates": .bool(true),
          "max_candidates": .number(2),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let target = try #require(payload.objectValue?["target"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("macos.default_application")))
    #expect((target["type"]) == (.string("path")))
    #expect((target["project_relative_path"]) == (.string("note.txt")))
    #expect((payload.objectValue?["include_candidates"]) == (.bool(true)))
    #expect((payload.objectValue?["max_candidates"]) == (.number(2)))
    #expect((payload.objectValue?["default_application_available"]) != nil)
    #expect((payload.objectValue?["default_application"]) != nil)
    #expect((payload.objectValue?["candidate_applications"]?.arrayValue?.count ?? 0) <= (2))

    let urlResult = try provider.callTool(
      .init(
        name: "macos.default_application",
        arguments: .object(["url": .string("https://example.com")]), context: .empty
      ))
    let urlPayload = try decodeTextPayload(urlResult)
    let urlTarget = try #require(urlPayload.objectValue?["target"]?.objectValue)
    #expect((urlTarget["type"]) == (.string("url")))
    #expect((urlTarget["scheme"]) == (.string("https")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "macos.default_application",
          arguments: .object([
            "path": .string("note.txt"),
            "url": .string("https://example.com"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("exactly one"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "macos.default_application",
          arguments: .object(["url": .string("file:///tmp/example.txt")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("url scheme"))
    }
  }

  @Test
  func testMacOSScreensReturnsReadOnlyDisplaySummary() throws {
    let provider = MacOSToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["macos.screens"])
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "macos.screens", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["screen_count"]) != nil)
    #expect((payload.objectValue?["screens"]?.arrayValue) != nil)
  }

  @Test
  func testMacOSSpotlightSearchUsesMDFindWithinProject() throws {
    let directory = try temporaryDirectory()
    let notes = directory.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let file = notes.appendingPathComponent("alpha.txt")
    try "alpha".write(to: file, atomically: true, encoding: .utf8)

    let runner = RecordingCommandRunner()
    runner.stdout =
      "\(file.path)\n/tmp/outside.txt\n\(notes.appendingPathComponent("missing.txt").path)\n"
    let provider = MacOSToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["macos.spotlight_search"]),
          projectDirectory: directory
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "macos.spotlight_search",
        arguments: .object([
          "path": .string("notes"),
          "query": .string("alpha"),
          "max_results": .number(5),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let results = try #require(payload.objectValue?["results"]?.arrayValue)

    #expect((runner.calls.first?.executable) == ("/usr/bin/mdfind"))
    #expect((runner.calls.first?.arguments) == (["-onlyin", notes.path, "alpha"]))
    #expect((payload.objectValue?["operation"]) == (.string("macos.spotlight_search")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("notes")))
    #expect((payload.objectValue?["returned_path_count"]) == (.number(3)))
    #expect((payload.objectValue?["result_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["skipped_escaped_results"]) == (.number(1)))
    #expect((payload.objectValue?["skipped_missing_results"]) == (.number(1)))
    #expect(
      (results.first?.objectValue?["project_relative_path"]) == (.string("notes/alpha.txt")))
  }

  @Test
  func testMacOSSpotlightSearchRejectsProjectEscapeAndBadBounds() throws {
    let directory = try temporaryDirectory()
    let provider = MacOSToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["macos.spotlight_search"]),
          projectDirectory: directory
        )
      ))

    expectThrows(
      try provider.callTool(
        .init(
          name: "macos.spotlight_search",
          arguments: .object([
            "path": .string("../outside"),
            "query": .string("alpha"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "macos.spotlight_search",
          arguments: .object([
            "query": .string("alpha"),
            "max_results": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }
  }

  @Test
  func testMacOSRunningApplicationsReturnsBoundedSessionSummary() throws {
    let provider = MacOSToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["macos.running_applications"])
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "macos.running_applications",
        arguments: .object([
          "include_background": .bool(true),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let applications = try #require(payload.objectValue?["applications"]?.arrayValue)

    #expect((payload.objectValue?["include_background"]) == (.bool(true)))
    #expect((payload.objectValue?["max_results"]) == (.number(1)))
    #expect((applications.count) <= (1))
    #expect((payload.objectValue?["application_count"]) != nil)
    #expect((payload.objectValue?["truncated"]) != nil)
  }

  @Test
  func testMacOSFrontmostApplicationReturnsOptionalApplicationSummary() throws {
    let provider = MacOSToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: ["macos.frontmost_application"])
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "macos.frontmost_application", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["available"]) != nil)
    #expect((payload.objectValue?["application"]) != nil)
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }

  private var directories: [ScopedTemporaryDirectory] = []

  private func temporaryDirectory() throws -> URL {
    let directory = try ScopedTemporaryDirectory()
    directories.append(directory)
    return directory.url
  }
}
