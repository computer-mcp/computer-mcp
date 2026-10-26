import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsProject

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)
final class ProjectToolProviderTests {
  @Test
  func testProjectInfoReturnsNonSecretGatewaySummary() throws {
    let directory = try temporaryDirectory()
    let config = GatewayConfiguration(
      server: ServerConfig(
        name: "test-computer",
        http: HTTPServerConfig(
          publicBaseURL: "https://gateway.example.com",
          accessTokenEnv: "COMPUTER_MCP_TOKEN"
        )
      ),
      policy: PolicyConfig(defaultTimeoutMs: 12_000, maxOutputBytes: 4096),
      cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "git")]),
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(id: "fake", transport: .stdio, command: "/bin/cat")
      ]),
      tools: [
        ToolConfig(name: "fake.sample", adapter: .mcp, source: "fake", tool: "sample")
      ],
      builtin: BuiltinConfig(enabled: ["project.info"]),
      projectDirectory: directory
    )
    let provider = ProjectToolProvider(
      environment: ToolEnvironment(launcher: testExecutionLauncher(), configuration: config))

    let result = try provider.callTool(
      .init(
        name: "project.info", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["server"]?.objectValue?["name"]) == (.string("test-computer")))
    #expect(
      (payload.objectValue?["server"]?.objectValue?["http"]?.objectValue?["auth"])
        == (.string("bearer")))
    #expect(
      (payload.objectValue?["server"]?.objectValue?["http"]?.objectValue?["access_token_env"])
        == (.string("COMPUTER_MCP_TOKEN")))
    #expect(
      (payload.objectValue?["project"]?.objectValue?["root"])
        == (.string(directory.standardizedFileURL.path)))
    #expect((payload.objectValue?["cli"]?.objectValue?["ids"]) == (.array([.string("git")])))
    #expect(
      (payload.objectValue?["mcp"]?.objectValue?["server_ids"]) == (.array([.string("fake")])))
    #expect(
      (payload.objectValue?["builtin"]?.objectValue?["enabled"])
        == (.array([.string("project.info")])))
  }

  @Test
  func testProjectStatusReturnsBoundedTopLevelState() throws {
    let directory = try temporaryDirectory()
    try "hello".write(
      to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("Sources"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent(".git"),
      withIntermediateDirectories: true
    )
    try "hidden".write(
      to: directory.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("README.link"),
      withDestinationURL: directory.appendingPathComponent("README.md")
    )

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.status"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.status",
        arguments: .object([:]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let project = try #require(payload.objectValue?["project"]?.objectValue)
    let topLevel = try #require(payload.objectValue?["top_level"]?.objectValue)
    let vcs = try #require(payload.objectValue?["vcs"]?.objectValue)
    let gitMetadata = try #require(vcs["git_metadata_at_root"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("project.status")))
    #expect((project["root"]) == (.string(directory.standardizedFileURL.path)))
    #expect((project["exists"]) == (.bool(true)))
    #expect((project["is_directory"]) == (.bool(true)))
    #expect((topLevel["include_hidden"]) == (.bool(false)))
    #expect((topLevel["scanned_entry_count"]) == (.number(3)))
    #expect((topLevel["file_count"]) == (.number(1)))
    #expect((topLevel["directory_count"]) == (.number(1)))
    #expect((topLevel["symlink_count"]) == (.number(1)))
    #expect((topLevel["truncated"]) == (.bool(false)))
    #expect((gitMetadata["exists"]) == (.bool(true)))
    #expect((gitMetadata["type"]) == (.string("directory")))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.status",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_entries": .number(1),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedTopLevel = try #require(truncatedPayload.objectValue?["top_level"]?.objectValue)

    #expect((truncatedTopLevel["include_hidden"]) == (.bool(true)))
    #expect((truncatedTopLevel["scanned_entry_count"]) == (.number(1)))
    #expect((truncatedTopLevel["truncated"]) == (.bool(true)))
  }

  @Test
  func testProjectManifestsReturnsFixedCatalogPresence() throws {
    let directory = try temporaryDirectory()
    try "{}".write(
      to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "// swift-tools-version: 6.0".write(
      to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent(".github/workflows"),
      withIntermediateDirectories: true
    )

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.manifests"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.manifests",
        arguments: .object([:]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let project = try #require(payload.objectValue?["project"]?.objectValue)
    let manifests = try #require(payload.objectValue?["manifests"]?.arrayValue)
    let paths = manifests.compactMap { $0.objectValue?["path"]?.stringValue }

    #expect((payload.objectValue?["operation"]) == (.string("project.manifests")))
    #expect((project["root"]) == (.string(directory.standardizedFileURL.path)))
    #expect((payload.objectValue?["include_missing"]) == (.bool(false)))
    #expect((paths) == (["Package.swift", "package.json", ".github/workflows"]))
    #expect((payload.objectValue?["included_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_count"]) == (.number(3)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((manifests[0].objectValue?["kind"]) == (.string("file")))
    #expect((manifests[2].objectValue?["kind"]) == (.string("directory")))

    let missingResult = try provider.callTool(
      .init(
        name: "project.manifests",
        arguments: .object([
          "include_missing": .bool(true),
          "max_results": .number(2),
        ]), context: .empty
      ))
    let missingPayload = try decodeTextPayload(missingResult)
    let missingManifests = try #require(missingPayload.objectValue?["manifests"]?.arrayValue)

    #expect((missingPayload.objectValue?["include_missing"]) == (.bool(true)))
    #expect((missingPayload.objectValue?["included_count"]) == (.number(49)))
    #expect((missingPayload.objectValue?["returned_count"]) == (.number(2)))
    #expect((missingPayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((missingManifests[1].objectValue?["kind"]) == (.string("missing")))
  }

  @Test
  func testProjectRecentFilesReturnsBoundedMetadataOnlyOrder() throws {
    let directory = try temporaryDirectory()
    let nested = directory.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let oldFile = directory.appendingPathComponent("old.txt")
    let newFile = nested.appendingPathComponent("new.txt")
    let hiddenFile = directory.appendingPathComponent(".hidden.txt")
    try "old".write(to: oldFile, atomically: true, encoding: .utf8)
    try "new".write(to: newFile, atomically: true, encoding: .utf8)
    try "hidden".write(to: hiddenFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: oldFile.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newFile.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: hiddenFile.path)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.recent_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.recent_files",
        arguments: .object([:]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let paths = files.compactMap { $0.objectValue?["project_relative_path"]?.stringValue }

    #expect((payload.objectValue?["operation"]) == (.string("project.recent_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["matched_file_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((paths) == (["nested/new.txt", "old.txt"]))
    #expect((files[0].objectValue?["modified_at"]) != nil)

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.recent_files",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenFiles = try #require(hiddenPayload.objectValue?["files"]?.arrayValue)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["matched_file_count"]) == (.number(3)))
    #expect((hiddenPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((hiddenFiles[0].objectValue?["project_relative_path"]) == (.string(".hidden.txt")))
  }

  @Test
  func testProjectDirectoryStatsReturnsGroupedMetadataOnlyCounts() throws {
    let directory = try temporaryDirectory()
    let sources = directory.appendingPathComponent("Sources/App")
    let tests = directory.appendingPathComponent("Tests/AppTests")
    let docs = directory.appendingPathComponent("docs")
    let ci = directory.appendingPathComponent(".github/workflows")
    let config = directory.appendingPathComponent("config")
    let scripts = directory.appendingPathComponent("scripts")
    let dependency = directory.appendingPathComponent("node_modules/pkg")
    let hidden = directory.appendingPathComponent(".hidden")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ci, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

    let appFile = sources.appendingPathComponent("App.swift")
    try "swift-source-secret".write(to: appFile, atomically: true, encoding: .utf8)
    try "typescript-source-secret".write(
      to: sources.appendingPathComponent("view.tsx"), atomically: true, encoding: .utf8)
    try "test-source-secret".write(
      to: tests.appendingPathComponent("AppTests.swift"), atomically: true, encoding: .utf8)
    try "doc-secret".write(
      to: docs.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
    try "ci-secret".write(
      to: ci.appendingPathComponent("ci.yml"), atomically: true, encoding: .utf8)
    try "config-secret".write(
      to: config.appendingPathComponent("swift-format.json"), atomically: true, encoding: .utf8)
    let script = scripts.appendingPathComponent("deploy.sh")
    try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try "dependency-secret".write(
      to: dependency.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "hidden-source-secret".write(
      to: hidden.appendingPathComponent("hidden.swift"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: sources.appendingPathComponent("AppLink.swift"),
      withDestinationURL: appFile
    )

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.directory_stats"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.directory_stats",
        arguments: .object(["max_depth": .number(4)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let groups = try #require(payload.objectValue?["groups"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: groups.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.directory_stats")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["max_depth"]) == (.number(4)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(false)))
    #expect((byPath["Sources"]?["source_file_count"]) == (.number(2)))
    #expect((byPath["Sources"]?["symlink_count"]) == (.number(1)))
    #expect((byPath["Tests"]?["test_file_count"]) == (.number(1)))
    #expect((byPath["docs"]?["documentation_file_count"]) == (.number(1)))
    #expect((byPath[".github"]) == nil)
    #expect((byPath["config"]?["config_file_count"]) == (.number(1)))
    #expect((byPath["scripts"]?["executable_file_count"]) == (.number(1)))
    #expect((byPath["node_modules"]?["skipped_subtree_count"]) == (.number(1)))
    #expect((payload.objectValue?["hidden_skipped_count"]?.numberValue ?? 0) > (0))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.directory_stats",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["group_count"]?.numberValue ?? 0) > (1))
  }

  @Test
  func testProjectArtifactDirectoriesReturnsMetadataOnlyCandidates() throws {
    let directory = try temporaryDirectory()
    let build = directory.appendingPathComponent(".build/debug")
    let nodeModules = directory.appendingPathComponent("node_modules/pkg")
    let vendor = directory.appendingPathComponent("vendor/lib")
    let generated = directory.appendingPathComponent("Sources/generated")
    let hiddenCache = directory.appendingPathComponent(".hidden/.cache")
    let docs = directory.appendingPathComponent("Docs")
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hiddenCache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

    try "build-secret".write(
      to: build.appendingPathComponent("app.o"), atomically: true, encoding: .utf8)
    try "dependency-secret".write(
      to: nodeModules.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "vendor-secret".write(
      to: vendor.appendingPathComponent("source.swift"), atomically: true, encoding: .utf8)
    try "generated-secret".write(
      to: generated.appendingPathComponent("API.swift"), atomically: true, encoding: .utf8)
    try "cache-secret".write(
      to: hiddenCache.appendingPathComponent("cache.db"), atomically: true, encoding: .utf8)
    try "doc-secret".write(
      to: docs.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.artifact_directories"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.artifact_directories",
        arguments: .object(["max_depth": .number(4)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let directories = try #require(payload.objectValue?["directories"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: directories.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.artifact_directories")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((payload.objectValue?["artifact_directory_count"]) == (.number(5)))
    #expect((byPath[".build"]?["category"]) == (.string("build_output")))
    #expect((byPath[".build"]?["kind"]) == (.string("swiftpm_build")))
    #expect((byPath[".build"]?["cleanup_risk"]) == (.string("recreatable")))
    #expect((byPath["node_modules"]?["category"]) == (.string("dependency_install")))
    #expect((byPath["vendor"]?["cleanup_risk"]) == (.string("review")))
    #expect((byPath["Sources/generated"]?["category"]) == (.string("generated_candidate")))
    #expect((byPath[".hidden/.cache"]?["kind"]) == (.string("generic_cache")))
    #expect((byPath[".build/debug"]) == nil)
    #expect((byPath["Docs"]) == nil)
    #expect(
      (byPath[".build"]?["disk_usage_context"]?.objectValue?["tool"])
        == (.string("file.disk_usage")))
    #expect((byPath[".build"]?["tree_context"]?.objectValue?["tool"]) == (.string("file.tree")))
    #expect(
      (byPath[".build"]?["directory_stats_context"]?.objectValue?["tool"])
        == (.string("project.directory_stats")))
    #expect(!(String(describing: payload).contains("build-secret")))
    #expect(!(String(describing: payload).contains("dependency-secret")))
    #expect(!(String(describing: payload).contains("generated-secret")))

    let visibleOnlyResult = try provider.callTool(
      .init(
        name: "project.artifact_directories",
        arguments: .object([
          "include_hidden": .bool(false),
          "max_depth": .number(4),
        ]), context: .empty
      ))
    let visibleOnlyPayload = try decodeTextPayload(visibleOnlyResult)
    let visibleOnlyDirectories = try #require(
      visibleOnlyPayload.objectValue?["directories"]?.arrayValue)
    let visibleOnlyPaths = visibleOnlyDirectories.compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }
    #expect(!(visibleOnlyPaths.contains(".build")))
    #expect(!(visibleOnlyPaths.contains(".hidden/.cache")))
    #expect(visibleOnlyPaths.contains("node_modules"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.artifact_directories",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "project.artifact_directories",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "project.artifact_directories",
          arguments: .object(["path": .string("Docs/guide.md")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a directory"))
    }
  }

  @Test
  func testProjectEmptyDirectoriesReturnsActualEmptyDirectoryMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let empty = directory.appendingPathComponent("empty")
    let nestedEmpty = directory.appendingPathComponent("nested/child")
    let nonEmpty = directory.appendingPathComponent("non-empty")
    let onlyHiddenFile = directory.appendingPathComponent("only-hidden-file")
    let hiddenEmpty = directory.appendingPathComponent(".hidden-empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nestedEmpty, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nonEmpty, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: onlyHiddenFile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hiddenEmpty, withIntermediateDirectories: true)
    try "visible-secret".write(
      to: nonEmpty.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try "hidden-secret".write(
      to: onlyHiddenFile.appendingPathComponent(".keep"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("empty-link"),
      withDestinationURL: empty
    )

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.empty_directories"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.empty_directories",
        arguments: .object(["max_depth": .number(4)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let directories = try #require(payload.objectValue?["directories"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: directories.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.empty_directories")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["empty_directory_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(false)))
    #expect((byPath["empty"]?["child_count"]) == (.number(0)))
    #expect((byPath["empty"]?["depth"]) == (.number(1)))
    #expect((byPath["empty"]?["is_root"]) == (.bool(false)))
    #expect(
      (byPath["empty"]?["project.reveal"]?.objectValue?["arguments"]?.objectValue?["path"])
        == (.string("empty")))
    #expect((byPath["nested/child"]?["child_count"]) == (.number(0)))
    #expect((byPath["non-empty"]) == nil)
    #expect((byPath["only-hidden-file"]) == nil)
    #expect((byPath[".hidden-empty"]) == nil)
    #expect((byPath["empty-link"]) == nil)

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.empty_directories",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenDirectories = try #require(hiddenPayload.objectValue?["directories"]?.arrayValue)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["empty_directory_count"]) == (.number(3)))
    #expect((hiddenPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect(
      (hiddenDirectories.first?.objectValue?["project_relative_path"])
        == (.string(".hidden-empty")))

    let scopedResult = try provider.callTool(
      .init(
        name: "project.empty_directories",
        arguments: .object(["path": .string("empty")]), context: .empty
      ))
    let scopedPayload = try decodeTextPayload(scopedResult)
    let scopedDirectory = try #require(
      scopedPayload.objectValue?["directories"]?.arrayValue?.first)
    #expect((scopedPayload.objectValue?["empty_directory_count"]) == (.number(1)))
    #expect((scopedDirectory.objectValue?["project_relative_path"]) == (.string("empty")))
    #expect((scopedDirectory.objectValue?["depth"]) == (.number(0)))
    #expect((scopedDirectory.objectValue?["is_root"]) == (.bool(true)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "project.empty_directories",
          arguments: .object(["path": .string("non-empty/file.txt")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a directory"))
    }
  }

  @Test
  func testProjectGitChangesParsesPorcelainStatusFromRegisteredGitProvider() throws {
    let runner = RecordingCommandRunner()
    runner.stdout =
      " M README.md\0A  Sources/App.swift\0R  Sources/New.swift\0Sources/Old.swift\0?? notes.txt\0"
    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["project.git_changes"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "project.git_changes",
        arguments: .object([
          "paths": .array([.string("Sources")]),
          "max_results": .number(3),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let changes = try #require(payload.objectValue?["changes"]?.arrayValue)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "Sources"]))
    #expect((payload.objectValue?["operation"]) == (.string("project.git_changes")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["change_count"]) == (.number(4)))
    #expect((payload.objectValue?["returned_count"]) == (.number(3)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["status_counts"]?.objectValue?[" M"]) == (.number(1)))
    #expect((payload.objectValue?["status_counts"]?.objectValue?["R "]) == (.number(1)))
    #expect((changes[0].objectValue?["project_relative_path"]) == (.string("README.md")))
    #expect((changes[0].objectValue?["index_status"]) == (.string(" ")))
    #expect((changes[0].objectValue?["worktree_status"]) == (.string("M")))
    #expect((changes[2].objectValue?["project_relative_path"]) == (.string("Sources/New.swift")))
    #expect((changes[2].objectValue?["original_path"]) == (.string("Sources/Old.swift")))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["stdout_bytes"])
        == (.number(Double(runner.stdout.utf8.count))))
  }

  @Test
  func testProjectFileTypesReturnsMetadataOnlyExtensionHistogram() throws {
    let directory = try temporaryDirectory()
    let nested = directory.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    try "one".write(
      to: nested.appendingPathComponent("One.swift"), atomically: true, encoding: .utf8)
    try "two".write(
      to: nested.appendingPathComponent("Two.SWIFT"), atomically: true, encoding: .utf8)
    try "doc".write(
      to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try "make".write(
      to: directory.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
    try "secret".write(
      to: directory.appendingPathComponent(".secret.json"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.file_types"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.file_types",
        arguments: .object([:]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let groups = try #require(payload.objectValue?["file_types"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("project.file_types")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["regular_file_count"]) == (.number(4)))
    #expect((payload.objectValue?["distinct_extension_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_group_count"]) == (.number(3)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((groups[0].objectValue?["extension"]) == (.string("swift")))
    #expect((groups[0].objectValue?["display"]) == (.string(".swift")))
    #expect((groups[0].objectValue?["file_count"]) == (.number(2)))
    #expect((groups[1].objectValue?["extension"]) == (.string("")))
    #expect((groups[1].objectValue?["display"]) == (.string("[none]")))
    #expect((groups[1].objectValue?["file_count"]) == (.number(1)))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.file_types",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_groups": .number(1),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenGroups = try #require(hiddenPayload.objectValue?["file_types"]?.arrayValue)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["regular_file_count"]) == (.number(5)))
    #expect((hiddenPayload.objectValue?["distinct_extension_count"]) == (.number(4)))
    #expect((hiddenPayload.objectValue?["returned_group_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((hiddenGroups[0].objectValue?["extension"]) == (.string("swift")))
  }

  @Test
  func testProjectLargeFilesReturnsBoundedMetadataOnlyOrder() throws {
    let directory = try temporaryDirectory()
    let nested = directory.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let smallFile = directory.appendingPathComponent("small.txt")
    let largeFile = nested.appendingPathComponent("large.bin")
    let hiddenFile = directory.appendingPathComponent(".hidden.bin")
    try "1".write(to: smallFile, atomically: true, encoding: .utf8)
    try String(repeating: "2", count: 20).write(to: largeFile, atomically: true, encoding: .utf8)
    try String(repeating: "3", count: 30).write(to: hiddenFile, atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.large_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.large_files",
        arguments: .object([:]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let paths = files.compactMap { $0.objectValue?["project_relative_path"]?.stringValue }

    #expect((payload.objectValue?["operation"]) == (.string("project.large_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["regular_file_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((paths) == (["nested/large.bin", "small.txt"]))
    #expect((files[0].objectValue?["size_bytes"]) == (.number(20)))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.large_files",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenFiles = try #require(hiddenPayload.objectValue?["files"]?.arrayValue)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["regular_file_count"]) == (.number(3)))
    #expect((hiddenPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((hiddenFiles[0].objectValue?["project_relative_path"]) == (.string(".hidden.bin")))
    #expect((hiddenFiles[0].objectValue?["size_bytes"]) == (.number(30)))
  }

  @Test
  func testProjectSymlinksReturnsRawDestinationsAndContainment() throws {
    let directory = try temporaryDirectory()
    let outsideDirectory = try temporaryDirectory()
    let nested = directory.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let target = directory.appendingPathComponent("target.txt")
    let outsideTarget = outsideDirectory.appendingPathComponent("outside.txt")
    try "target".write(to: target, atomically: true, encoding: .utf8)
    try "outside".write(to: outsideTarget, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: nested.appendingPathComponent("inside.link").path,
      withDestinationPath: "../target.txt"
    )
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("outside.link"),
      withDestinationURL: outsideTarget
    )
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent(".hidden.link"),
      withDestinationURL: target
    )

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.symlinks"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.symlinks",
        arguments: .object([:]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let symlinks = try #require(payload.objectValue?["symlinks"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: symlinks.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.symlinks")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["symlink_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((byPath["nested/inside.link"]?["destination"]) == (.string("../target.txt")))
    #expect((byPath["nested/inside.link"]?["target_project_contained"]) == (.bool(true)))
    #expect((byPath["outside.link"]?["target_exists"]) == (.bool(true)))
    #expect((byPath["outside.link"]?["target_project_contained"]) == (.bool(false)))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.symlinks",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenSymlinks = try #require(hiddenPayload.objectValue?["symlinks"]?.arrayValue)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["symlink_count"]) == (.number(3)))
    #expect((hiddenPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect(
      (hiddenSymlinks[0].objectValue?["project_relative_path"]) == (.string(".hidden.link")))
  }

  @Test
  func testProjectExecutableFilesReturnsMetadataOnlyExecutableFiles() throws {
    let directory = try temporaryDirectory()
    let scripts = directory.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)

    let executable = scripts.appendingPathComponent("run.sh")
    let regular = directory.appendingPathComponent("notes.txt")
    let hidden = directory.appendingPathComponent(".secret-tool")
    try "run".write(to: executable, atomically: true, encoding: .utf8)
    try "notes".write(to: regular, atomically: true, encoding: .utf8)
    try "hidden".write(to: hidden, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: regular.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hidden.path)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.executable_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.executable_files",
        arguments: .object([:]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("project.executable_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["executable_file_count"]) == (.number(1)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((files[0].objectValue?["project_relative_path"]) == (.string("scripts/run.sh")))
    #expect((files[0].objectValue?["is_executable"]) == (.bool(true)))
    #expect((files[0].objectValue?["type"]) == (.string("file")))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.executable_files",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenFiles = try #require(hiddenPayload.objectValue?["files"]?.arrayValue)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["executable_file_count"]) == (.number(2)))
    #expect((hiddenPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((hiddenFiles[0].objectValue?["project_relative_path"]) == (.string(".secret-tool")))
  }

  @Test
  func testProjectTodosReturnsBoundedMarkerMatches() throws {
    let directory = try temporaryDirectory()
    let sources = directory.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try """
    TODO first
    fixme lower
    HACK third
    notodos word
    NOTE custom
    """.write(to: sources.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try "TODO hidden".write(
      to: directory.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
    try Data([0, 84, 79, 68, 79]).write(to: sources.appendingPathComponent("Binary.dat"))

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.todos"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.todos",
        arguments: .object([
          "max_matches": .number(2)
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let matches = try #require(payload.objectValue?["matches"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("project.todos")))
    #expect(
      (payload.objectValue?["markers"])
        == (.array([.string("TODO"), .string("FIXME"), .string("HACK"), .string("XXX")])))
    #expect((payload.objectValue?["case_sensitive"]) == (.bool(false)))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["match_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((matches[0].objectValue?["marker"]) == (.string("TODO")))
    #expect((matches[0].objectValue?["project_relative_path"]) == (.string("Sources/App.swift")))
    #expect((matches[0].objectValue?["line"]) == (.number(1)))
    #expect((matches[0].objectValue?["column"]) == (.number(1)))
    #expect((matches[1].objectValue?["marker"]) == (.string("FIXME")))
    #expect((matches[1].objectValue?["line"]) == (.number(2)))
    #expect((matches[1].objectValue?["preview"]) == (.string("fixme lower")))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.todos",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_matches": .number(10),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenMatches = try #require(hiddenPayload.objectValue?["matches"]?.arrayValue)
    let hiddenPaths = hiddenMatches.compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }

    #expect(hiddenPaths.contains(".hidden.md"))
    #expect((hiddenPayload.objectValue?["match_count"]) == (.number(4)))

    let customResult = try provider.callTool(
      .init(
        name: "project.todos",
        arguments: .object([
          "path": .string("Sources"),
          "markers": .array([.string("NOTE")]),
        ]), context: .empty
      ))
    let customPayload = try decodeTextPayload(customResult)
    let customMatch = try #require(
      customPayload.objectValue?["matches"]?.arrayValue?.first?.objectValue)

    #expect((customPayload.objectValue?["markers"]) == (.array([.string("NOTE")])))
    #expect((customPayload.objectValue?["match_count"]) == (.number(1)))
    #expect((customMatch["marker"]) == (.string("NOTE")))
    #expect((customMatch["line"]) == (.number(5)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "project.todos",
          arguments: .object(["markers": .array([.string("")])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("markers must not contain empty strings"))
    }
  }

  @Test
  func testProjectEnvFilesReturnsKeyMetadataWithoutValues() throws {
    let directory = try temporaryDirectory()
    let app = directory.appendingPathComponent("app")
    let hidden = directory.appendingPathComponent(".hidden")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

    try """
    # comment
    API_KEY=topsecret-123
    export DATABASE_URL=postgres://secret
    EMPTY=
    NO_VALUE
    BAD-KEY=value
    """.write(to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "NESTED_TOKEN=nested-secret\n".write(
      to: app.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
    try "HIDDEN_TOKEN=hidden-secret\n".write(
      to: hidden.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "PLAIN=ignored\n".write(
      to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.env_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.env_files",
        arguments: .object([:]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let envFiles = try #require(payload.objectValue?["env_files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: envFiles.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.env_files")))
    #expect((payload.objectValue?["values_redacted"]) == (.bool(true)))
    #expect((payload.objectValue?["include_hidden_directories"]) == (.bool(false)))
    #expect((payload.objectValue?["env_file_count"]) == (.number(2)))
    #expect((byPath[".env"]) != nil)
    #expect((byPath["app/.env.local"]) != nil)
    #expect((byPath[".hidden/.env"]) == nil)
    #expect(!(text.contains("topsecret-123")))
    #expect(!(text.contains("postgres://secret")))
    #expect(!(text.contains("nested-secret")))
    #expect(!(text.contains("hidden-secret")))

    let rootKeys = try #require(byPath[".env"]?["keys"]?.arrayValue)
    let rootKeyObjects = rootKeys.compactMap(\.objectValue)
    #expect((byPath[".env"]?["key_count"]) == (.number(4)))
    #expect((byPath[".env"]?["invalid_line_count"]) == (.number(1)))
    #expect((rootKeyObjects[0]["name"]) == (.string("API_KEY")))
    #expect((rootKeyObjects[0]["line"]) == (.number(2)))
    #expect((rootKeyObjects[0]["has_value"]) == (.bool(true)))
    #expect((rootKeyObjects[1]["name"]) == (.string("DATABASE_URL")))
    #expect((rootKeyObjects[1]["exported"]) == (.bool(true)))
    #expect((rootKeyObjects[2]["name"]) == (.string("EMPTY")))
    #expect((rootKeyObjects[2]["value_empty"]) == (.bool(true)))
    #expect((rootKeyObjects[3]["name"]) == (.string("NO_VALUE")))
    #expect((rootKeyObjects[3]["has_value"]) == (.bool(false)))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.env_files",
        arguments: .object(["include_hidden_directories": .bool(true)]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenFiles = try #require(hiddenPayload.objectValue?["env_files"]?.arrayValue)
    let hiddenPaths = hiddenFiles.compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/.env"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.env_files",
        arguments: .object([
          "path": .string(".env"),
          "max_keys_per_file": .number(1),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedFile = try #require(truncatedPayload.objectValue?["env_files"]?.arrayValue?.first)
      .objectValue
    #expect((truncatedFile?["key_count"]) == (.number(1)))
    #expect((truncatedFile?["keys_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testProjectDependencyFilesReturnsManifestAndLockMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let app = directory.appendingPathComponent("app")
    let nested = app.appendingPathComponent("nested")
    let hidden = directory.appendingPathComponent(".hidden")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

    try "{}".write(
      to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "lock".write(
      to: directory.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
    try "<project><artifactId>app</artifactId></project>".write(
      to: directory.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
    try "[project]".write(
      to: app.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
    try "pytest".write(
      to: app.appendingPathComponent("requirements-dev.txt"), atomically: true, encoding: .utf8)
    try "swift".write(
      to: nested.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "hidden".write(
      to: hidden.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
    try "ignored".write(
      to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.dependency_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.dependency_files",
        arguments: .object(["max_depth": .number(1)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.dependency_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["dependency_file_count"]) == (.number(5)))
    #expect((byPath["package.json"]?["ecosystem"]) == (.string("node")))
    #expect((byPath["package.json"]?["role"]) == (.string("manifest")))
    #expect((byPath["pnpm-lock.yaml"]?["role"]) == (.string("lock")))
    #expect((byPath["pom.xml"]?["ecosystem"]) == (.string("jvm")))
    #expect((byPath["pom.xml"]?["xml_readable"]) == (.bool(true)))
    #expect((byPath["pom.xml"]?["xml_context"]?.objectValue?["tool"]) == (.string("xml.read")))
    #expect((byPath["app/pyproject.toml"]?["ecosystem"]) == (.string("python")))
    #expect((byPath["app/requirements-dev.txt"]?["role"]) == (.string("requirements")))
    #expect((byPath["app/nested/Package.swift"]) == nil)
    #expect((byPath[".hidden/Cargo.toml"]) == nil)
    #expect((byPath["notes.txt"]) == nil)

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.dependency_files",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_depth": .number(1),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/Cargo.toml"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.dependency_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.dependency_files",
        arguments: .object(["path": .string("package.json")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["dependency_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["project_relative_path"]) == (.string("package.json")))
  }

  @Test
  func testProjectRootsGroupsDependencyMetadataByDirectory() throws {
    let directory = try temporaryDirectory()
    let app = directory.appendingPathComponent("app")
    let swiftPackage = directory.appendingPathComponent("packages/swift-lib")
    let hidden = directory.appendingPathComponent(".hidden")
    let nodeModules = directory.appendingPathComponent("node_modules/pkg")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: swiftPackage, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)

    try "{}".write(
      to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "lock".write(
      to: directory.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
    try "[project]".write(
      to: app.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
    try "pytest".write(
      to: app.appendingPathComponent("requirements-dev.txt"), atomically: true, encoding: .utf8)
    try "// swift".write(
      to: swiftPackage.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "cargo".write(
      to: hidden.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
    try "{}".write(
      to: nodeModules.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.project_roots"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.project_roots",
        arguments: .object(["max_depth": .number(3)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let roots = try #require(payload.objectValue?["project_roots"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: roots.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.project_roots")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["project_root_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_count"]) == (.number(3)))
    #expect((payload.objectValue?["dependency_file_count"]) == (.number(5)))
    #expect((byPath["."]?["is_project_root"]) == (.bool(true)))
    #expect((byPath["."]?["ecosystems"]) == (.array([.string("node")])))
    #expect((byPath["."]?["manifest_files"]) == (.array([.string("package.json")])))
    #expect((byPath["."]?["lock_files"]) == (.array([.string("pnpm-lock.yaml")])))
    #expect((byPath["app"]?["ecosystems"]) == (.array([.string("python")])))
    #expect(
      (byPath["app"]?["manifest_files"])
        == (.array([.string("app/pyproject.toml"), .string("app/requirements-dev.txt")])))
    #expect(
      (byPath["packages/swift-lib"]?["manifest_files"])
        == (.array([.string("packages/swift-lib/Package.swift")])))
    #expect((byPath[".hidden"]) == nil)
    #expect((byPath["node_modules/pkg"]) == nil)

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.project_roots",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_depth": .number(1),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenRoots = try #require(hiddenPayload.objectValue?["project_roots"]?.arrayValue)
      .compactMap {
        $0.objectValue?["project_relative_path"]?.stringValue
      }
    #expect(hiddenRoots.contains(".hidden"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.project_roots",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.project_roots",
        arguments: .object(["path": .string("package.json")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["project_root_count"]) == (.number(1)))
    let singleRoot = try #require(
      singleFilePayload.objectValue?["project_roots"]?.arrayValue?.first
    )
    #expect((singleRoot.objectValue?["project_relative_path"]) == (.string(".")))
  }

  @Test
  func testProjectDocumentationFilesReturnsDocumentationMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let app = directory.appendingPathComponent("app")
    let docs = directory.appendingPathComponent("docs")
    let reference = directory.appendingPathComponent("Documentation/Reference")
    let source = directory.appendingPathComponent("Sources")
    let hidden = directory.appendingPathComponent(".hidden")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

    try "overview-secret".write(
      to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try "agent-secret".write(
      to: directory.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "license-secret".write(
      to: directory.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
    try "subproject-secret".write(
      to: app.appendingPathComponent("README.mdx"), atomically: true, encoding: .utf8)
    try "guide-secret".write(
      to: docs.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
    try "reference-secret".write(
      to: reference.appendingPathComponent("Tools.rst"), atomically: true, encoding: .utf8)
    try "ignored-secret".write(
      to: source.appendingPathComponent("design.md"), atomically: true, encoding: .utf8)
    try "hidden-secret".write(
      to: hidden.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.documentation_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.documentation_files",
        arguments: .object(["max_depth": .number(2)]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.documentation_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["documentation_file_count"]) == (.number(6)))
    #expect((byPath["README.md"]?["category"]) == (.string("overview")))
    #expect(
      (byPath["README.md"]?["markdown_links_context"]?.objectValue?["tool"])
        == (.string("markdown.links")))
    #expect(
      (byPath["README.md"]?["markdown_link_check_context"]?.objectValue?["tool"])
        == (.string("markdown.link_check")))
    #expect(
      (byPath["README.md"]?["markdown_link_check_context"]?.objectValue?["path"])
        == (.string("README.md")))
    #expect((byPath["AGENTS.md"]?["category"]) == (.string("agent_instructions")))
    #expect((byPath["LICENSE"]?["category"]) == (.string("license")))
    #expect((byPath["LICENSE"]?["markdown_link_check_context"]) == (.null))
    #expect((byPath["app/README.mdx"]?["category"]) == (.string("overview")))
    #expect(
      (byPath["app/README.mdx"]?["markdown_link_check_context"]?.objectValue?["tool"])
        == (.string("markdown.link_check")))
    #expect((byPath["docs/guide.md"]?["source"]) == (.string("documentation_directory")))
    #expect(
      (byPath["Documentation/Reference/Tools.rst"]?["category"]) == (.string("documentation")))
    #expect((byPath["Sources/design.md"]) == nil)
    #expect((byPath[".hidden/README.md"]) == nil)
    #expect(!(text.contains("overview-secret")))
    #expect(!(text.contains("agent-secret")))
    #expect(!(text.contains("guide-secret")))
    #expect(!(text.contains("reference-secret")))
    #expect(!(text.contains("ignored-secret")))
    #expect(!(text.contains("hidden-secret")))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.documentation_files",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_depth": .number(1),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/README.md"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.documentation_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.documentation_files",
        arguments: .object(["path": .string("AGENTS.md")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["documentation_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["project_relative_path"]) == (.string("AGENTS.md")))
    #expect((singleFile?["category"]) == (.string("agent_instructions")))
  }

  @Test
  func testProjectAgentFilesReturnsInstructionEntryMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let app = directory.appendingPathComponent("app")
    let github = directory.appendingPathComponent(".github")
    let cursorRules = directory.appendingPathComponent(".cursor/rules")
    let skill = directory.appendingPathComponent("skills/computer-mcp-config")
    let docs = directory.appendingPathComponent("docs")
    let dependency = directory.appendingPathComponent("node_modules/pkg")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: github, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cursorRules, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)

    try "agent-secret".write(
      to: directory.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "claude-secret".write(
      to: app.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    try "copilot-secret".write(
      to: github.appendingPathComponent("copilot-instructions.md"),
      atomically: true,
      encoding: .utf8
    )
    try "cursor-secret".write(
      to: cursorRules.appendingPathComponent("project.mdc"), atomically: true, encoding: .utf8)
    try "skill-secret".write(
      to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try "not-agent-secret".write(
      to: docs.appendingPathComponent("instructions.md"), atomically: true, encoding: .utf8)
    try "dependency-secret".write(
      to: dependency.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.agent_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.agent_files", arguments: .object([:]), context: .empty))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.agent_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((payload.objectValue?["agent_file_count"]) == (.number(5)))
    #expect((byPath["AGENTS.md"]?["kind"]) == (.string("codex")))
    #expect((byPath["AGENTS.md"]?["scope_project_relative_path"]) == (.string(".")))
    #expect((byPath["AGENTS.md"]?["read_context"]?.objectValue?["tool"]) == (.string("file.read")))
    #expect((byPath["AGENTS.md"]?["read_context"]?.objectValue?["path"]) == (.string("AGENTS.md")))
    #expect((byPath["app/CLAUDE.md"]?["kind"]) == (.string("claude")))
    #expect((byPath["app/CLAUDE.md"]?["scope_project_relative_path"]) == (.string("app")))
    #expect((byPath[".github/copilot-instructions.md"]?["kind"]) == (.string("github_copilot")))
    #expect((byPath[".cursor/rules/project.mdc"]?["kind"]) == (.string("cursor_rule")))
    #expect((byPath["skills/computer-mcp-config/SKILL.md"]?["kind"]) == (.string("codex_skill")))
    #expect((byPath["docs/instructions.md"]) == nil)
    #expect((byPath["node_modules/pkg/AGENTS.md"]) == nil)
    #expect(!(text.contains("agent-secret")))
    #expect(!(text.contains("claude-secret")))
    #expect(!(text.contains("copilot-secret")))
    #expect(!(text.contains("cursor-secret")))
    #expect(!(text.contains("skill-secret")))
    #expect(!(text.contains("dependency-secret")))

    let visibleOnlyResult = try provider.callTool(
      .init(
        name: "project.agent_files",
        arguments: .object(["include_hidden": .bool(false)]), context: .empty
      ))
    let visibleOnlyPayload = try decodeTextPayload(visibleOnlyResult)
    let visibleOnlyFiles = try #require(
      visibleOnlyPayload.objectValue?["files"]?.arrayValue
    )
    let visibleOnlyPaths = visibleOnlyFiles.compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }
    #expect(visibleOnlyPaths.contains("AGENTS.md"))
    #expect(visibleOnlyPaths.contains("app/CLAUDE.md"))
    #expect(!(visibleOnlyPaths.contains(".github/copilot-instructions.md")))
    #expect(!(visibleOnlyPaths.contains(".cursor/rules/project.mdc")))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.agent_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.agent_files",
        arguments: .object(["path": .string("AGENTS.md")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["agent_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["project_relative_path"]) == (.string("AGENTS.md")))
    #expect((singleFile?["kind"]) == (.string("codex")))
  }

  @Test
  func testProjectInstructionsReturnsApplicableInstructionChain() throws {
    let directory = try temporaryDirectory()
    let app = directory.appendingPathComponent("app")
    let feature = app.appendingPathComponent("feature")
    let sources = feature.appendingPathComponent("Sources")
    let github = directory.appendingPathComponent(".github")
    let cursorRules = feature.appendingPathComponent(".cursor/rules")
    let docs = directory.appendingPathComponent("docs")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: github, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cursorRules, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

    try "root instructions".write(
      to: directory.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try "copilot instructions".write(
      to: github.appendingPathComponent("copilot-instructions.md"),
      atomically: true,
      encoding: .utf8
    )
    try "app instructions".write(
      to: app.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    try "feature cursor instructions".write(
      to: cursorRules.appendingPathComponent("style.mdc"), atomically: true, encoding: .utf8)
    try "not scoped".write(
      to: docs.appendingPathComponent("instructions.md"), atomically: true, encoding: .utf8)
    try "print(\"hello\")\n".write(
      to: sources.appendingPathComponent("Feature.swift"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.instructions"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.instructions",
        arguments: .object(["path": .string("app/feature/Sources/Feature.swift")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let paths = files.compactMap { $0.objectValue?["project_relative_path"]?.stringValue }

    #expect((payload.objectValue?["operation"]) == (.string("project.instructions")))
    #expect((payload.objectValue?["target_exists"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["scope_project_relative_path"]) == (.string("app/feature/Sources")))
    #expect(
      (paths)
        == ([
          "AGENTS.md",
          ".github/copilot-instructions.md",
          "app/CLAUDE.md",
          "app/feature/.cursor/rules/style.mdc",
        ]))
    #expect((files[0].objectValue?["scope_project_relative_path"]) == (.string(".")))
    #expect((files[0].objectValue?["apply_order"]) == (.number(0)))
    #expect((files[0].objectValue?["kind"]) == (.string("codex")))
    #expect((files[0].objectValue?["content"]) == (.string("root instructions")))
    #expect((files[0].objectValue?["content_truncated"]) == (.bool(false)))
    #expect((files[0].objectValue?["valid_utf8"]) == (.bool(true)))
    #expect((files[1].objectValue?["kind"]) == (.string("github_copilot")))
    #expect((files[2].objectValue?["scope_project_relative_path"]) == (.string("app")))
    #expect((files[3].objectValue?["kind"]) == (.string("cursor_rule")))
    #expect(!(paths.contains("docs/instructions.md")))

    let futureResult = try provider.callTool(
      .init(
        name: "project.instructions",
        arguments: .object(["path": .string("app/feature/NewFile.swift")]), context: .empty
      ))
    let futurePayload = try decodeTextPayload(futureResult)
    #expect((futurePayload.objectValue?["target_exists"]) == (.bool(false)))
    #expect(
      (futurePayload.objectValue?["scope_project_relative_path"]) == (.string("app/feature")))

    let metadataOnlyResult = try provider.callTool(
      .init(
        name: "project.instructions",
        arguments: .object([
          "path": .string("app/feature/Sources/Feature.swift"),
          "include_content": .bool(false),
        ]), context: .empty
      ))
    let metadataOnlyPayload = try decodeTextPayload(metadataOnlyResult)
    let metadataOnlyFile = try #require(
      metadataOnlyPayload.objectValue?["files"]?.arrayValue?.first?.objectValue)
    #expect((metadataOnlyFile["content_included"]) == (.bool(false)))
    #expect((metadataOnlyFile["content"]) == (.null))

    let truncatedContentResult = try provider.callTool(
      .init(
        name: "project.instructions",
        arguments: .object([
          "path": .string("app/feature/Sources/Feature.swift"),
          "max_bytes_per_file": .number(4),
        ]), context: .empty
      ))
    let truncatedContentPayload = try decodeTextPayload(truncatedContentResult)
    let truncatedFile = try #require(
      truncatedContentPayload.objectValue?["files"]?.arrayValue?.first?.objectValue)
    #expect((truncatedFile["content"]) == (.string("root")))
    #expect((truncatedFile["content_truncated"]) == (.bool(true)))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.instructions",
        arguments: .object([
          "path": .string("app/feature/Sources/Feature.swift"),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "project.instructions",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path escapes project"))
    }
  }

  @Test
  func testProjectTestFilesReturnsTestFileMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let tests = directory.appendingPathComponent("Tests/AppTests")
    let src = directory.appendingPathComponent("Sources/App")
    let web = directory.appendingPathComponent("__tests__")
    let docs = directory.appendingPathComponent("docs")
    let hidden = directory.appendingPathComponent(".hidden")
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

    try "swift-test-secret".write(
      to: tests.appendingPathComponent("UserTests.swift"), atomically: true, encoding: .utf8)
    try "spec-secret".write(
      to: src.appendingPathComponent("user.spec.ts"), atomically: true, encoding: .utf8)
    try "prefix-secret".write(
      to: src.appendingPathComponent("test_login.py"), atomically: true, encoding: .utf8)
    try "web-secret".write(
      to: web.appendingPathComponent("Button.test.tsx"), atomically: true, encoding: .utf8)
    try "ignored-doc-secret".write(
      to: docs.appendingPathComponent("test-plan.md"), atomically: true, encoding: .utf8)
    try "ignored-source-secret".write(
      to: src.appendingPathComponent("contest.go"), atomically: true, encoding: .utf8)
    try "hidden-secret".write(
      to: hidden.appendingPathComponent("test_hidden.py"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.test_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.test_files",
        arguments: .object(["max_depth": .number(3)]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.test_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["test_file_count"]) == (.number(4)))
    #expect((byPath["Tests/AppTests/UserTests.swift"]?["language"]) == (.string("swift")))
    #expect(
      (byPath["Tests/AppTests/UserTests.swift"]?["match_source"]) == (.string("test_directory")))
    #expect((byPath["Sources/App/user.spec.ts"]?["style"]) == (.string("dot_spec")))
    #expect((byPath["Sources/App/test_login.py"]?["style"]) == (.string("test_prefix")))
    #expect((byPath["__tests__/Button.test.tsx"]?["language"]) == (.string("typescript")))
    #expect((byPath["docs/test-plan.md"]) == nil)
    #expect((byPath["Sources/App/contest.go"]) == nil)
    #expect((byPath[".hidden/test_hidden.py"]) == nil)
    #expect(!(text.contains("swift-test-secret")))
    #expect(!(text.contains("spec-secret")))
    #expect(!(text.contains("prefix-secret")))
    #expect(!(text.contains("web-secret")))
    #expect(!(text.contains("ignored-doc-secret")))
    #expect(!(text.contains("ignored-source-secret")))
    #expect(!(text.contains("hidden-secret")))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.test_files",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_depth": .number(1),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/test_hidden.py"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.test_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.test_files",
        arguments: .object(["path": .string("Sources/App/user.spec.ts")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["test_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["project_relative_path"]) == (.string("Sources/App/user.spec.ts")))
    #expect((singleFile?["style"]) == (.string("dot_spec")))
  }

  @Test
  func testProjectCIFilesReturnsPipelineMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let github = directory.appendingPathComponent(".github/workflows")
    let circle = directory.appendingPathComponent(".circleci")
    let buildkite = directory.appendingPathComponent(".buildkite")
    let docs = directory.appendingPathComponent("docs")
    let nested = directory.appendingPathComponent("app")
    try FileManager.default.createDirectory(at: github, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: circle, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: buildkite, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    try "github-secret".write(
      to: github.appendingPathComponent("build.yml"), atomically: true, encoding: .utf8)
    try "circle-secret".write(
      to: circle.appendingPathComponent("config.yml"), atomically: true, encoding: .utf8)
    try "buildkite-secret".write(
      to: buildkite.appendingPathComponent("pipeline.yml"), atomically: true, encoding: .utf8)
    try "gitlab-secret".write(
      to: directory.appendingPathComponent(".gitlab-ci.yml"), atomically: true, encoding: .utf8)
    try "jenkins-secret".write(
      to: directory.appendingPathComponent("Jenkinsfile"), atomically: true, encoding: .utf8)
    try "azure-secret".write(
      to: nested.appendingPathComponent("azure-pipelines.yaml"), atomically: true, encoding: .utf8)
    try "ignored-doc-secret".write(
      to: docs.appendingPathComponent("workflow.yml"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.ci_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.ci_files",
        arguments: .object(["max_depth": .number(3)]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.ci_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((payload.objectValue?["ci_file_count"]) == (.number(6)))
    #expect((byPath[".github/workflows/build.yml"]?["provider"]) == (.string("github_actions")))
    #expect(
      (byPath[".github/workflows/build.yml"]?["match_source"]) == (.string("workflow_directory")))
    #expect((byPath[".circleci/config.yml"]?["provider"]) == (.string("circleci")))
    #expect((byPath[".buildkite/pipeline.yml"]?["provider"]) == (.string("buildkite")))
    #expect((byPath[".gitlab-ci.yml"]?["provider"]) == (.string("gitlab_ci")))
    #expect((byPath["Jenkinsfile"]?["provider"]) == (.string("jenkins")))
    #expect((byPath["app/azure-pipelines.yaml"]?["provider"]) == (.string("azure_pipelines")))
    #expect((byPath["docs/workflow.yml"]) == nil)
    #expect(!(text.contains("github-secret")))
    #expect(!(text.contains("circle-secret")))
    #expect(!(text.contains("buildkite-secret")))
    #expect(!(text.contains("gitlab-secret")))
    #expect(!(text.contains("jenkins-secret")))
    #expect(!(text.contains("azure-secret")))
    #expect(!(text.contains("ignored-doc-secret")))

    let visibleOnlyResult = try provider.callTool(
      .init(
        name: "project.ci_files",
        arguments: .object([
          "include_hidden": .bool(false),
          "max_depth": .number(3),
        ]), context: .empty
      ))
    let visibleOnlyPayload = try decodeTextPayload(visibleOnlyResult)
    let visibleOnlyPaths = try #require(visibleOnlyPayload.objectValue?["files"]?.arrayValue)
      .compactMap {
        $0.objectValue?["project_relative_path"]?.stringValue
      }
    #expect(!(visibleOnlyPaths.contains(".github/workflows/build.yml")))
    #expect(!(visibleOnlyPaths.contains(".gitlab-ci.yml")))
    #expect(visibleOnlyPaths.contains("Jenkinsfile"))
    #expect(visibleOnlyPaths.contains("app/azure-pipelines.yaml"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.ci_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.ci_files",
        arguments: .object(["path": .string(".github/workflows/build.yml")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["ci_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["provider"]) == (.string("github_actions")))
  }

  @Test
  func testProjectInfraFilesReturnsDeploymentMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let devcontainer = directory.appendingPathComponent(".devcontainer")
    let k8s = directory.appendingPathComponent("k8s")
    let helm = directory.appendingPathComponent("charts/app")
    let infra = directory.appendingPathComponent("infra")
    let config = directory.appendingPathComponent("config")
    let data = directory.appendingPathComponent("data")
    let hidden = directory.appendingPathComponent(".hidden")
    let terraformCache = directory.appendingPathComponent(".terraform/modules")
    let dependency = directory.appendingPathComponent("node_modules/pkg")
    let build = directory.appendingPathComponent("build")
    try FileManager.default.createDirectory(at: devcontainer, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: k8s, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: helm, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: infra, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: terraformCache, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

    try "docker-secret".write(
      to: directory.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
    try "compose-secret".write(
      to: directory.appendingPathComponent("docker-compose.yml"), atomically: true,
      encoding: .utf8)
    try "{\"image\":\"secret\"}\n".write(
      to: devcontainer.appendingPathComponent("devcontainer.json"), atomically: true,
      encoding: .utf8)
    try "k8s-secret".write(
      to: k8s.appendingPathComponent("deployment.yaml"), atomically: true, encoding: .utf8)
    try "helm-chart-secret".write(
      to: helm.appendingPathComponent("Chart.yaml"), atomically: true, encoding: .utf8)
    try "helm-values-secret".write(
      to: helm.appendingPathComponent("values.yaml"), atomically: true, encoding: .utf8)
    try "terraform-secret".write(
      to: infra.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
    try "wrangler-secret".write(
      to: directory.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)
    try "config-secret".write(
      to: config.appendingPathComponent("settings.yaml"), atomically: true, encoding: .utf8)
    try "{\"fields\":[\"id\"]}\n".write(
      to: data.appendingPathComponent("schema.json"), atomically: true, encoding: .utf8)
    try "hidden-secret".write(
      to: hidden.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
    try "terraform-cache-secret".write(
      to: terraformCache.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
    try "dependency-secret".write(
      to: dependency.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
    try "build-secret".write(
      to: build.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.infra_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.infra_files",
        arguments: .object(["max_depth": .number(4)]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.infra_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["infra_file_count"]) == (.number(8)))
    #expect((byPath["Dockerfile"]?["provider"]) == (.string("docker")))
    #expect((byPath["Dockerfile"]?["kind"]) == (.string("image_build")))
    #expect((byPath["docker-compose.yml"]?["provider"]) == (.string("docker_compose")))
    #expect((byPath[".devcontainer/devcontainer.json"]?["provider"]) == (.string("devcontainer")))
    #expect((byPath[".devcontainer/devcontainer.json"]?["json_readable"]) == (.bool(true)))
    #expect(
      (byPath[".devcontainer/devcontainer.json"]?["json_context"]?.objectValue?["tool"])
        == (.string("json.read")))
    #expect((byPath["k8s/deployment.yaml"]?["provider"]) == (.string("kubernetes")))
    #expect((byPath["k8s/deployment.yaml"]?["match_source"]) == (.string("infra_directory")))
    #expect((byPath["k8s/deployment.yaml"]?["yaml_readable"]) == (.bool(true)))
    #expect(
      (byPath["k8s/deployment.yaml"]?["yaml_context"]?.objectValue?["tool"])
        == (.string("yaml.read")))
    #expect((byPath["charts/app/Chart.yaml"]?["provider"]) == (.string("helm")))
    #expect((byPath["charts/app/values.yaml"]?["provider"]) == (.string("helm")))
    #expect((byPath["infra/main.tf"]?["provider"]) == (.string("terraform")))
    #expect((byPath["wrangler.toml"]?["provider"]) == (.string("cloudflare")))
    #expect((byPath["wrangler.toml"]?["toml_readable"]) == (.bool(true)))
    #expect(
      (byPath["wrangler.toml"]?["toml_context"]?.objectValue?["tool"]) == (.string("toml.read")))
    #expect(
      (byPath["Dockerfile"]?["read_lines_context"]?.objectValue?["tool"])
        == (.string("file.read_lines")))
    #expect((byPath["config/settings.yaml"]) == nil)
    #expect((byPath["data/schema.json"]) == nil)
    #expect((byPath[".hidden/Dockerfile"]) == nil)
    #expect((byPath[".terraform/modules/main.tf"]) == nil)
    #expect((byPath["node_modules/pkg/Dockerfile"]) == nil)
    #expect((byPath["build/Dockerfile"]) == nil)
    #expect(!(text.contains("docker-secret")))
    #expect(!(text.contains("compose-secret")))
    #expect(!(text.contains("k8s-secret")))
    #expect(!(text.contains("helm-chart-secret")))
    #expect(!(text.contains("helm-values-secret")))
    #expect(!(text.contains("terraform-secret")))
    #expect(!(text.contains("wrangler-secret")))
    #expect(!(text.contains("config-secret")))
    #expect(!(text.contains("hidden-secret")))
    #expect(!(text.contains("dependency-secret")))
    #expect(!(text.contains("build-secret")))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.infra_files",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_depth": .number(2),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/Dockerfile"))
    #expect(!(hiddenPaths.contains(".terraform/modules/main.tf")))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.infra_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.infra_files",
        arguments: .object(["path": .string("wrangler.toml")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["infra_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["provider"]) == (.string("cloudflare")))
  }

  @Test
  func testProjectConfigFilesReturnsToolingMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let vscode = directory.appendingPathComponent(".vscode")
    let source = directory.appendingPathComponent("src")
    let docs = directory.appendingPathComponent("docs")
    try FileManager.default.createDirectory(at: vscode, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

    try "editor-secret".write(
      to: directory.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
    try "swift-format-secret".write(
      to: directory.appendingPathComponent(".swift-format"), atomically: true, encoding: .utf8)
    try "prettier-secret".write(
      to: directory.appendingPathComponent(".prettierrc.json"), atomically: true, encoding: .utf8)
    try "eslint-secret".write(
      to: directory.appendingPathComponent("eslint.config.js"), atomically: true, encoding: .utf8)
    try "typescript-secret".write(
      to: directory.appendingPathComponent("tsconfig.app.json"), atomically: true, encoding: .utf8)
    try "vscode-secret".write(
      to: vscode.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    try "npm-secret".write(
      to: directory.appendingPathComponent(".npmrc"), atomically: true, encoding: .utf8)
    try "ruff-secret".write(
      to: source.appendingPathComponent("ruff.toml"), atomically: true, encoding: .utf8)
    try "env-secret".write(
      to: directory.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "ignored-config-secret".write(
      to: docs.appendingPathComponent("config.yml"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.config_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.config_files",
        arguments: .object(["max_depth": .number(3)]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.config_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((payload.objectValue?["config_file_count"]) == (.number(8)))
    #expect((byPath[".editorconfig"]?["tool"]) == (.string("editorconfig")))
    #expect((byPath[".editorconfig"]?["category"]) == (.string("editor")))
    #expect((byPath[".swift-format"]?["tool"]) == (.string("swift-format")))
    #expect((byPath[".prettierrc.json"]?["tool"]) == (.string("prettier")))
    #expect((byPath["eslint.config.js"]?["tool"]) == (.string("eslint")))
    #expect((byPath["eslint.config.js"]?["match_source"]) == (.string("filename_pattern")))
    #expect((byPath["tsconfig.app.json"]?["tool"]) == (.string("typescript")))
    #expect((byPath[".vscode/settings.json"]?["tool"]) == (.string("vscode")))
    #expect((byPath[".vscode/settings.json"]?["match_source"]) == (.string("config_directory")))
    #expect((byPath[".npmrc"]?["category"]) == (.string("package_manager")))
    #expect((byPath["src/ruff.toml"]?["tool"]) == (.string("ruff")))
    #expect((byPath[".env"]) == nil)
    #expect((byPath["docs/config.yml"]) == nil)
    #expect(!(text.contains("editor-secret")))
    #expect(!(text.contains("swift-format-secret")))
    #expect(!(text.contains("prettier-secret")))
    #expect(!(text.contains("eslint-secret")))
    #expect(!(text.contains("typescript-secret")))
    #expect(!(text.contains("vscode-secret")))
    #expect(!(text.contains("npm-secret")))
    #expect(!(text.contains("ruff-secret")))
    #expect(!(text.contains("env-secret")))
    #expect(!(text.contains("ignored-config-secret")))

    let visibleOnlyResult = try provider.callTool(
      .init(
        name: "project.config_files",
        arguments: .object([
          "include_hidden": .bool(false),
          "max_depth": .number(3),
        ]), context: .empty
      ))
    let visibleOnlyPayload = try decodeTextPayload(visibleOnlyResult)
    let visibleOnlyPaths = try #require(visibleOnlyPayload.objectValue?["files"]?.arrayValue)
      .compactMap {
        $0.objectValue?["project_relative_path"]?.stringValue
      }
    #expect(!(visibleOnlyPaths.contains(".editorconfig")))
    #expect(!(visibleOnlyPaths.contains(".vscode/settings.json")))
    #expect(!(visibleOnlyPaths.contains(".npmrc")))
    #expect(visibleOnlyPaths.contains("eslint.config.js"))
    #expect(visibleOnlyPaths.contains("tsconfig.app.json"))
    #expect(visibleOnlyPaths.contains("src/ruff.toml"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.config_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.config_files",
        arguments: .object(["path": .string(".vscode/settings.json")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["config_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["tool"]) == (.string("vscode")))
  }

  @Test
  func testProjectIgnoreFilesReturnsBoundaryMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let app = directory.appendingPathComponent("app")
    let hidden = directory.appendingPathComponent(".hidden")
    let gitInfo = directory.appendingPathComponent(".git/info")
    let dependency = directory.appendingPathComponent("node_modules/pkg")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gitInfo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)

    try "git-ignore-secret".write(
      to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try "docker-ignore-secret".write(
      to: app.appendingPathComponent(".dockerignore"), atomically: true, encoding: .utf8)
    try "rg-ignore-secret".write(
      to: directory.appendingPathComponent(".rgignore"), atomically: true, encoding: .utf8)
    try "agent-ignore-secret".write(
      to: hidden.appendingPathComponent(".aiexclude"), atomically: true, encoding: .utf8)
    try "git-exclude-secret".write(
      to: gitInfo.appendingPathComponent("exclude"), atomically: true, encoding: .utf8)
    try "dependency-ignore-secret".write(
      to: dependency.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try "not-ignore-secret".write(
      to: app.appendingPathComponent("ignore.txt"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.ignore_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.ignore_files",
        arguments: .object(["max_depth": .number(3)]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.ignore_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((payload.objectValue?["ignore_file_count"]) == (.number(4)))
    #expect((byPath[".gitignore"]?["provider"]) == (.string("git")))
    #expect((byPath[".gitignore"]?["category"]) == (.string("source_control_ignore")))
    #expect((byPath[".gitignore"]?["read_context"]?.objectValue?["tool"]) == (.string("file.read")))
    #expect(
      (byPath[".gitignore"]?["read_context"]?.objectValue?["path"]) == (.string(".gitignore")))
    #expect((byPath[".rgignore"]?["provider"]) == (.string("ripgrep")))
    #expect((byPath["app/.dockerignore"]?["provider"]) == (.string("docker")))
    #expect((byPath[".hidden/.aiexclude"]?["category"]) == (.string("agent_context_ignore")))
    #expect((byPath[".git/info/exclude"]) == nil)
    #expect((byPath["node_modules/pkg/.gitignore"]) == nil)
    #expect((byPath["app/ignore.txt"]) == nil)
    #expect(!(text.contains("git-ignore-secret")))
    #expect(!(text.contains("docker-ignore-secret")))
    #expect(!(text.contains("rg-ignore-secret")))
    #expect(!(text.contains("agent-ignore-secret")))
    #expect(!(text.contains("git-exclude-secret")))
    #expect(!(text.contains("dependency-ignore-secret")))
    #expect(!(text.contains("not-ignore-secret")))

    let visibleOnlyResult = try provider.callTool(
      .init(
        name: "project.ignore_files",
        arguments: .object([
          "include_hidden": .bool(false),
          "max_depth": .number(3),
        ]), context: .empty
      ))
    let visibleOnlyPayload = try decodeTextPayload(visibleOnlyResult)
    let visibleOnlyFiles = try #require(visibleOnlyPayload.objectValue?["files"]?.arrayValue)
    #expect(visibleOnlyFiles.isEmpty)

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.ignore_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.ignore_files",
        arguments: .object(["path": .string(".git/info/exclude")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["ignore_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["match_source"]) == (.string("git_info_exclude")))
  }

  @Test
  func testProjectAssetFilesReturnsAssetMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let images = directory.appendingPathComponent("Resources/Images")
    let fonts = directory.appendingPathComponent("Resources/Fonts")
    let docs = directory.appendingPathComponent("Docs")
    let hidden = directory.appendingPathComponent(".hidden")
    let dependency = directory.appendingPathComponent("node_modules/pkg")
    let build = directory.appendingPathComponent("build")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

    try "png-secret".write(
      to: images.appendingPathComponent("Logo.PNG"), atomically: true, encoding: .utf8)
    try "svg-secret".write(
      to: images.appendingPathComponent("icon.svg"), atomically: true, encoding: .utf8)
    try "font-secret".write(
      to: fonts.appendingPathComponent("Inter.woff2"), atomically: true, encoding: .utf8)
    try "pdf-secret".write(
      to: docs.appendingPathComponent("Pitch.pdf"), atomically: true, encoding: .utf8)
    try "video-secret".write(
      to: directory.appendingPathComponent("demo.mov"), atomically: true, encoding: .utf8)
    try "hidden-secret".write(
      to: hidden.appendingPathComponent("secret.png"), atomically: true, encoding: .utf8)
    try "dependency-secret".write(
      to: dependency.appendingPathComponent("package.png"), atomically: true, encoding: .utf8)
    try "build-secret".write(
      to: build.appendingPathComponent("generated.png"), atomically: true, encoding: .utf8)
    try "source-secret".write(
      to: directory.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.asset_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.asset_files",
        arguments: .object(["max_depth": .number(4)]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.asset_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["asset_file_count"]) == (.number(5)))
    #expect((byPath["Resources/Images/Logo.PNG"]?["category"]) == (.string("image")))
    #expect((byPath["Resources/Images/Logo.PNG"]?["subtype"]) == (.string("bitmap")))
    #expect((byPath["Resources/Images/Logo.PNG"]?["extension"]) == (.string("png")))
    #expect(
      (byPath["Resources/Images/Logo.PNG"]?["image_info_context"]?.objectValue?["tool"])
        == (.string("image.info")))
    #expect(
      (byPath["Resources/Images/Logo.PNG"]?["image_info_context"]?.objectValue?["path"])
        == (.string("Resources/Images/Logo.PNG")))
    #expect((byPath["Resources/Images/icon.svg"]?["subtype"]) == (.string("vector")))
    #expect(
      (byPath["Resources/Images/icon.svg"]?["image_info_context"]?.objectValue?["tool"])
        == (.string("image.info")))
    #expect((byPath["Resources/Fonts/Inter.woff2"]?["category"]) == (.string("font")))
    #expect((byPath["Resources/Fonts/Inter.woff2"]?["image_info_context"]) == nil)
    #expect((byPath["Docs/Pitch.pdf"]?["category"]) == (.string("document")))
    #expect((byPath["Docs/Pitch.pdf"]?["subtype"]) == (.string("pdf")))
    #expect(
      (byPath["Docs/Pitch.pdf"]?["pdf_info_context"]?.objectValue?["tool"]) == (.string("pdf.info"))
    )
    #expect(
      (byPath["Docs/Pitch.pdf"]?["pdf_info_context"]?.objectValue?["path"])
        == (.string("Docs/Pitch.pdf")))
    #expect(
      (byPath["Docs/Pitch.pdf"]?["pdf_text_context"]?.objectValue?["tool"]) == (.string("pdf.text"))
    )
    #expect(
      (byPath["Docs/Pitch.pdf"]?["pdf_text_context"]?.objectValue?["path"])
        == (.string("Docs/Pitch.pdf")))
    #expect((byPath["demo.mov"]?["category"]) == (.string("video")))
    #expect((byPath["demo.mov"]?["pdf_info_context"]) == nil)
    #expect((byPath["demo.mov"]?["pdf_text_context"]) == nil)
    #expect(
      (byPath["demo.mov"]?["media_info_context"]?.objectValue?["tool"]) == (.string("media.info")))
    #expect(
      (byPath["demo.mov"]?["media_info_context"]?.objectValue?["path"]) == (.string("demo.mov")))
    #expect((byPath["demo.mov"]?["stat_context"]?.objectValue?["tool"]) == (.string("file.stat")))
    #expect(
      (byPath["demo.mov"]?["metadata_context"]?.objectValue?["tool"]) == (.string("file.metadata")))
    #expect((byPath[".hidden/secret.png"]) == nil)
    #expect((byPath["node_modules/pkg/package.png"]) == nil)
    #expect((byPath["build/generated.png"]) == nil)
    #expect((byPath["App.swift"]) == nil)
    #expect(!(text.contains("png-secret")))
    #expect(!(text.contains("svg-secret")))
    #expect(!(text.contains("font-secret")))
    #expect(!(text.contains("pdf-secret")))
    #expect(!(text.contains("video-secret")))
    #expect(!(text.contains("hidden-secret")))
    #expect(!(text.contains("dependency-secret")))
    #expect(!(text.contains("build-secret")))
    #expect(!(text.contains("source-secret")))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.asset_files",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_depth": .number(2),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/secret.png"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.asset_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.asset_files",
        arguments: .object(["path": .string("Resources/Fonts/Inter.woff2")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["asset_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["category"]) == (.string("font")))
  }

  @Test
  func testProjectArchiveFilesReturnsArchiveMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let archives = directory.appendingPathComponent("Archives")
    let packages = directory.appendingPathComponent("Packages")
    let installers = directory.appendingPathComponent("Installers")
    let dist = directory.appendingPathComponent("dist")
    let hidden = directory.appendingPathComponent(".hidden")
    let dependency = directory.appendingPathComponent("node_modules/pkg")
    let build = directory.appendingPathComponent("build")
    try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: installers, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

    try "zip-secret".write(
      to: archives.appendingPathComponent("app.zip"), atomically: true, encoding: .utf8)
    try "tar-secret".write(
      to: archives.appendingPathComponent("source.tar.gz"), atomically: true, encoding: .utf8)
    try "package-secret".write(
      to: packages.appendingPathComponent("module.nupkg"), atomically: true, encoding: .utf8)
    try "dmg-secret".write(
      to: installers.appendingPathComponent("app.dmg"), atomically: true, encoding: .utf8)
    try "stream-secret".write(
      to: directory.appendingPathComponent("logs.gz"), atomically: true, encoding: .utf8)
    try "release-secret".write(
      to: dist.appendingPathComponent("release.zip"), atomically: true, encoding: .utf8)
    try "hidden-secret".write(
      to: hidden.appendingPathComponent("secret.zip"), atomically: true, encoding: .utf8)
    try "dependency-secret".write(
      to: dependency.appendingPathComponent("package.zip"), atomically: true, encoding: .utf8)
    try "build-secret".write(
      to: build.appendingPathComponent("generated.tar"), atomically: true, encoding: .utf8)
    try "source-secret".write(
      to: directory.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.archive_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.archive_files",
        arguments: .object(["max_depth": .number(4)]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.archive_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["archive_file_count"]) == (.number(6)))
    #expect((byPath["Archives/app.zip"]?["category"]) == (.string("archive")))
    #expect((byPath["Archives/app.zip"]?["format"]) == (.string("zip")))
    #expect((byPath["Archives/app.zip"]?["extension"]) == (.string("zip")))
    #expect((byPath["Archives/app.zip"]?["list_supported"]) == (.bool(true)))
    #expect(
      (byPath["Archives/app.zip"]?["list_context"]?.objectValue?["tool"])
        == (.string("archive.list")))
    #expect(
      (byPath["Archives/app.zip"]?["read_file_context"]?.objectValue?["tool"])
        == (.string("archive.read_file")))
    #expect((byPath["Archives/app.zip"]?["read_file_context"]?.objectValue?["entry"]) == (.null))
    #expect((byPath["Archives/source.tar.gz"]?["format"]) == (.string("tar_gzip")))
    #expect((byPath["Archives/source.tar.gz"]?["extension"]) == (.string("tar.gz")))
    #expect((byPath["Archives/source.tar.gz"]?["list_supported"]) == (.bool(true)))
    #expect((byPath["Packages/module.nupkg"]?["category"]) == (.string("application_package")))
    #expect((byPath["Packages/module.nupkg"]?["list_supported"]) == (.bool(false)))
    #expect((byPath["Packages/module.nupkg"]?["list_context"]) == (.null))
    #expect((byPath["Packages/module.nupkg"]?["read_file_context"]) == (.null))
    #expect((byPath["Installers/app.dmg"]?["category"]) == (.string("disk_image")))
    #expect((byPath["logs.gz"]?["category"]) == (.string("compressed_stream")))
    #expect((byPath["dist/release.zip"]?["list_supported"]) == (.bool(true)))
    #expect((byPath["logs.gz"]?["stat_context"]?.objectValue?["tool"]) == (.string("file.stat")))
    #expect(
      (byPath["logs.gz"]?["metadata_context"]?.objectValue?["tool"]) == (.string("file.metadata")))
    #expect((byPath[".hidden/secret.zip"]) == nil)
    #expect((byPath["node_modules/pkg/package.zip"]) == nil)
    #expect((byPath["build/generated.tar"]) == nil)
    #expect((byPath["App.swift"]) == nil)
    #expect(!(text.contains("zip-secret")))
    #expect(!(text.contains("tar-secret")))
    #expect(!(text.contains("package-secret")))
    #expect(!(text.contains("dmg-secret")))
    #expect(!(text.contains("stream-secret")))
    #expect(!(text.contains("release-secret")))
    #expect(!(text.contains("hidden-secret")))
    #expect(!(text.contains("dependency-secret")))
    #expect(!(text.contains("build-secret")))
    #expect(!(text.contains("source-secret")))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.archive_files",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_depth": .number(2),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/secret.zip"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.archive_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.archive_files",
        arguments: .object(["path": .string("Archives/source.tar.gz")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["archive_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["format"]) == (.string("tar_gzip")))
  }

  @Test
  func testProjectLogFilesReturnsLogMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let logs = directory.appendingPathComponent("logs")
    let runtime = directory.appendingPathComponent("var")
    let build = directory.appendingPathComponent("build")
    let crash = directory.appendingPathComponent("crash")
    let hidden = directory.appendingPathComponent(".hidden")
    let dependency = directory.appendingPathComponent("node_modules/pkg")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: crash, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)

    try "app-secret".write(
      to: logs.appendingPathComponent("app.log"), atomically: true, encoding: .utf8)
    try "current-secret".write(
      to: logs.appendingPathComponent("current"), atomically: true, encoding: .utf8)
    try "jsonl-secret".write(
      to: logs.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
    try "access-secret".write(
      to: runtime.appendingPathComponent("access.log"), atomically: true, encoding: .utf8)
    try "out-secret".write(
      to: build.appendingPathComponent("task.out"), atomically: true, encoding: .utf8)
    try "crash-secret".write(
      to: crash.appendingPathComponent("report.ips"), atomically: true, encoding: .utf8)
    try "rotated-secret".write(
      to: directory.appendingPathComponent("app.log.1"), atomically: true, encoding: .utf8)
    try "hidden-secret".write(
      to: hidden.appendingPathComponent("debug.log"), atomically: true, encoding: .utf8)
    try "dependency-secret".write(
      to: dependency.appendingPathComponent("error.log"), atomically: true, encoding: .utf8)
    try "source-secret".write(
      to: directory.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try "asset-secret".write(
      to: logs.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.log_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.log_files",
        arguments: .object(["max_depth": .number(4)]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.log_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["log_file_count"]) == (.number(7)))
    #expect((byPath["logs/app.log"]?["category"]) == (.string("application_log")))
    #expect((byPath["logs/app.log"]?["kind"]) == (.string("log")))
    #expect((byPath["logs/app.log"]?["match_source"]) == (.string("extension")))
    #expect((byPath["logs/current"]?["match_source"]) == (.string("logs_directory")))
    #expect((byPath["logs/current"]?["extension"]) == (.string("")))
    #expect((byPath["logs/events.jsonl"]?["match_source"]) == (.string("logs_directory")))
    #expect((byPath["var/access.log"]?["kind"]) == (.string("access")))
    #expect((byPath["build/task.out"]?["kind"]) == (.string("stdout")))
    #expect((byPath["crash/report.ips"]?["category"]) == (.string("crash_report")))
    #expect((byPath["app.log.1"]?["match_source"]) == (.string("rotated_suffix")))
    #expect(
      (byPath["logs/app.log"]?["tail_context"]?.objectValue?["tool"]) == (.string("file.tail")))
    #expect(
      (byPath["logs/app.log"]?["search_context"]?.objectValue?["tool"]) == (.string("file.search")))
    #expect(
      (byPath["logs/app.log"]?["stat_context"]?.objectValue?["tool"]) == (.string("file.stat")))
    #expect((byPath[".hidden/debug.log"]) == nil)
    #expect((byPath["node_modules/pkg/error.log"]) == nil)
    #expect((byPath["App.swift"]) == nil)
    #expect((byPath["logs/image.png"]) == nil)
    #expect(!(text.contains("app-secret")))
    #expect(!(text.contains("current-secret")))
    #expect(!(text.contains("jsonl-secret")))
    #expect(!(text.contains("access-secret")))
    #expect(!(text.contains("out-secret")))
    #expect(!(text.contains("crash-secret")))
    #expect(!(text.contains("rotated-secret")))
    #expect(!(text.contains("hidden-secret")))
    #expect(!(text.contains("dependency-secret")))
    #expect(!(text.contains("source-secret")))
    #expect(!(text.contains("asset-secret")))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.log_files",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_depth": .number(2),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/debug.log"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.log_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.log_files",
        arguments: .object(["path": .string("logs/current")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["log_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["match_source"]) == (.string("logs_directory")))
  }

  @Test
  func testProjectDataFilesReturnsDataMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let data = directory.appendingPathComponent("data")
    let fixtures = directory.appendingPathComponent("fixtures")
    let exports = directory.appendingPathComponent("exports")
    let config = directory.appendingPathComponent("config")
    let hidden = directory.appendingPathComponent(".hidden")
    let dependency = directory.appendingPathComponent("node_modules/pkg")
    let build = directory.appendingPathComponent("build")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

    try "id,name\n1,Ada\n".write(
      to: data.appendingPathComponent("customers.csv"), atomically: true, encoding: .utf8)
    try "{\"event\":\"ready\"}\n".write(
      to: data.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
    try "{\"fields\":[\"id\"]}\n".write(
      to: data.appendingPathComponent("schema.json"), atomically: true, encoding: .utf8)
    try "<dataset><name>xml-secret</name></dataset>".write(
      to: data.appendingPathComponent("metadata.xml"), atomically: true, encoding: .utf8)
    try "name: sample\n".write(
      to: fixtures.appendingPathComponent("sample.yaml"), atomically: true, encoding: .utf8)
    try "parquet-secret".write(
      to: exports.appendingPathComponent("report.parquet"), atomically: true, encoding: .utf8)
    try "sqlite-secret".write(
      to: directory.appendingPathComponent("app.sqlite"), atomically: true, encoding: .utf8)
    try "{\"config\":true}\n".write(
      to: config.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    try "hidden-secret".write(
      to: hidden.appendingPathComponent("secret.csv"), atomically: true, encoding: .utf8)
    try "dependency-secret".write(
      to: dependency.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
    try "generated-secret".write(
      to: build.appendingPathComponent("generated.csv"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.data_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.data_files",
        arguments: .object(["max_depth": .number(4)]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.data_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["data_file_count"]) == (.number(7)))
    #expect((byPath["data/customers.csv"]?["category"]) == (.string("tabular_data")))
    #expect((byPath["data/customers.csv"]?["format"]) == (.string("csv")))
    #expect((byPath["data/customers.csv"]?["text_readable"]) == (.bool(true)))
    #expect(
      (byPath["data/customers.csv"]?["read_lines_context"]?.objectValue?["tool"])
        == (.string("file.read_lines")))
    #expect(
      (byPath["data/customers.csv"]?["count_context"]?.objectValue?["tool"])
        == (.string("file.count")))
    #expect((byPath["data/events.jsonl"]?["format"]) == (.string("json_lines")))
    #expect((byPath["data/events.jsonl"]?["jsonl_readable"]) == (.bool(true)))
    #expect(
      (byPath["data/events.jsonl"]?["jsonl_context"]?.objectValue?["tool"])
        == (.string("jsonl.read")))
    #expect((byPath["data/schema.json"]?["match_source"]) == (.string("data_directory")))
    #expect((byPath["data/schema.json"]?["json_readable"]) == (.bool(true)))
    #expect(
      (byPath["data/schema.json"]?["json_context"]?.objectValue?["tool"]) == (.string("json.read")))
    #expect((byPath["data/metadata.xml"]?["format"]) == (.string("xml")))
    #expect((byPath["data/metadata.xml"]?["xml_readable"]) == (.bool(true)))
    #expect(
      (byPath["data/metadata.xml"]?["xml_context"]?.objectValue?["tool"]) == (.string("xml.read")))
    #expect((byPath["fixtures/sample.yaml"]?["format"]) == (.string("yaml")))
    #expect((byPath["fixtures/sample.yaml"]?["yaml_readable"]) == (.bool(true)))
    #expect(
      (byPath["fixtures/sample.yaml"]?["yaml_context"]?.objectValue?["tool"])
        == (.string("yaml.read")))
    #expect((byPath["exports/report.parquet"]?["category"]) == (.string("columnar_data")))
    #expect((byPath["exports/report.parquet"]?["read_lines_context"]) == (.null))
    #expect((byPath["app.sqlite"]?["category"]) == (.string("database")))
    #expect(
      (byPath["app.sqlite"]?["metadata_context"]?.objectValue?["tool"])
        == (.string("file.metadata")))
    #expect((byPath["config/settings.json"]) == nil)
    #expect((byPath[".hidden/secret.csv"]) == nil)
    #expect((byPath["node_modules/pkg/data.csv"]) == nil)
    #expect((byPath["build/generated.csv"]) == nil)
    #expect(!(text.contains("Ada")))
    #expect(!(text.contains("ready")))
    #expect(!(text.contains("fields")))
    #expect(!(text.contains("xml-secret")))
    #expect(!(text.contains("name: sample")))
    #expect(!(text.contains("parquet-secret")))
    #expect(!(text.contains("sqlite-secret")))
    #expect(!(text.contains("config")))
    #expect(!(text.contains("hidden-secret")))
    #expect(!(text.contains("dependency-secret")))
    #expect(!(text.contains("generated-secret")))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.data_files",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_depth": .number(2),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/secret.csv"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.data_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.data_files",
        arguments: .object(["path": .string("app.sqlite")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["data_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["format"]) == (.string("sqlite")))
  }

  @Test
  func testProjectSchemaFilesReturnsSchemaMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let api = directory.appendingPathComponent("api")
    let schemas = directory.appendingPathComponent("schemas")
    let graphql = directory.appendingPathComponent("graphql")
    let proto = directory.appendingPathComponent("proto")
    let prisma = directory.appendingPathComponent("prisma")
    let migrations = directory.appendingPathComponent("db/migrations")
    let config = directory.appendingPathComponent("config")
    let data = directory.appendingPathComponent("data")
    let hidden = directory.appendingPathComponent(".hidden")
    let dependency = directory.appendingPathComponent("node_modules/pkg")
    let build = directory.appendingPathComponent("build")
    try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: schemas, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: graphql, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: proto, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: prisma, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: migrations, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

    try "secret-openapi-title".write(
      to: api.appendingPathComponent("openapi.yaml"), atomically: true, encoding: .utf8)
    try "secret-json-schema-field".write(
      to: schemas.appendingPathComponent("user.schema.json"), atomically: true,
      encoding: .utf8)
    try "<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\"></xs:schema>".write(
      to: schemas.appendingPathComponent("user.xsd"), atomically: true, encoding: .utf8)
    try "secret-avro-field".write(
      to: schemas.appendingPathComponent("order.avsc"), atomically: true, encoding: .utf8)
    try "secretGraphqlField".write(
      to: graphql.appendingPathComponent("schema.graphql"), atomically: true, encoding: .utf8)
    try "secret_proto_field".write(
      to: proto.appendingPathComponent("user.proto"), atomically: true, encoding: .utf8)
    try "secret_prisma_field".write(
      to: prisma.appendingPathComponent("schema.prisma"), atomically: true, encoding: .utf8)
    try "secret_sql_column".write(
      to: migrations.appendingPathComponent("001_create_users.sql"), atomically: true,
      encoding: .utf8)
    try "{\"config\":true}\n".write(
      to: config.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    try "{\"fields\":[\"id\"]}\n".write(
      to: data.appendingPathComponent("schema.json"), atomically: true, encoding: .utf8)
    try "hidden-schema-secret".write(
      to: hidden.appendingPathComponent("hidden.proto"), atomically: true, encoding: .utf8)
    try "dependency-schema-secret".write(
      to: dependency.appendingPathComponent("schema.graphql"), atomically: true, encoding: .utf8)
    try "generated-schema-secret".write(
      to: build.appendingPathComponent("generated.proto"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.schema_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.schema_files",
        arguments: .object(["max_depth": .number(4)]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.schema_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["schema_file_count"]) == (.number(8)))
    #expect((byPath["api/openapi.yaml"]?["schema_kind"]) == (.string("openapi")))
    #expect((byPath["api/openapi.yaml"]?["match_source"]) == (.string("filename")))
    #expect((byPath["api/openapi.yaml"]?["yaml_readable"]) == (.bool(true)))
    #expect(
      (byPath["api/openapi.yaml"]?["yaml_context"]?.objectValue?["tool"]) == (.string("yaml.read")))
    #expect((byPath["schemas/user.schema.json"]?["schema_kind"]) == (.string("json_schema")))
    #expect((byPath["schemas/user.schema.json"]?["json_readable"]) == (.bool(true)))
    #expect(
      (byPath["schemas/user.schema.json"]?["json_context"]?.objectValue?["tool"])
        == (.string("json.read")))
    #expect((byPath["schemas/user.xsd"]?["schema_kind"]) == (.string("xml_schema")))
    #expect((byPath["schemas/user.xsd"]?["xml_readable"]) == (.bool(true)))
    #expect(
      (byPath["schemas/user.xsd"]?["xml_context"]?.objectValue?["tool"]) == (.string("xml.read")))
    #expect((byPath["schemas/order.avsc"]?["schema_kind"]) == (.string("avro_schema")))
    #expect((byPath["graphql/schema.graphql"]?["schema_kind"]) == (.string("graphql")))
    #expect((byPath["proto/user.proto"]?["schema_kind"]) == (.string("protobuf")))
    #expect((byPath["prisma/schema.prisma"]?["category"]) == (.string("database_schema")))
    #expect(
      (byPath["db/migrations/001_create_users.sql"]?["schema_kind"]) == (.string("sql_migration")))
    #expect(
      (byPath["db/migrations/001_create_users.sql"]?["match_source"])
        == (.string("schema_directory")))
    #expect(
      (byPath["api/openapi.yaml"]?["read_lines_context"]?.objectValue?["tool"])
        == (.string("file.read_lines")))
    #expect(
      (byPath["api/openapi.yaml"]?["stat_context"]?.objectValue?["tool"]) == (.string("file.stat")))
    #expect((byPath["config/settings.json"]) == nil)
    #expect((byPath["data/schema.json"]) == nil)
    #expect((byPath[".hidden/hidden.proto"]) == nil)
    #expect((byPath["node_modules/pkg/schema.graphql"]) == nil)
    #expect((byPath["build/generated.proto"]) == nil)
    #expect(!(text.contains("secret-openapi-title")))
    #expect(!(text.contains("secret-json-schema-field")))
    #expect(!(text.contains("www.w3.org")))
    #expect(!(text.contains("secret-avro-field")))
    #expect(!(text.contains("secretGraphqlField")))
    #expect(!(text.contains("secret_proto_field")))
    #expect(!(text.contains("secret_prisma_field")))
    #expect(!(text.contains("secret_sql_column")))
    #expect(!(text.contains("hidden-schema-secret")))
    #expect(!(text.contains("dependency-schema-secret")))
    #expect(!(text.contains("generated-schema-secret")))

    let hiddenResult = try provider.callTool(
      .init(
        name: "project.schema_files",
        arguments: .object([
          "include_hidden": .bool(true),
          "max_depth": .number(2),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/hidden.proto"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.schema_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.schema_files",
        arguments: .object(["path": .string("api/openapi.yaml")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["schema_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["schema_kind"]) == (.string("openapi")))
  }

  @Test
  func testProjectSourceFilesReturnsSourceMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let sources = directory.appendingPathComponent("Sources/App")
    let tests = directory.appendingPathComponent("Tests/AppTests")
    let scripts = directory.appendingPathComponent("scripts")
    let hidden = directory.appendingPathComponent(".hidden")
    let build = directory.appendingPathComponent("build")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

    try "swift-source-secret".write(
      to: sources.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try "typescript-source-secret".write(
      to: sources.appendingPathComponent("view.tsx"), atomically: true, encoding: .utf8)
    try "style-source-secret".write(
      to: sources.appendingPathComponent("main.css"), atomically: true, encoding: .utf8)
    try "sql-source-secret".write(
      to: sources.appendingPathComponent("query.sql"), atomically: true, encoding: .utf8)
    try "script-source-secret".write(
      to: scripts.appendingPathComponent("deploy.sh"), atomically: true, encoding: .utf8)
    try "test-source-secret".write(
      to: tests.appendingPathComponent("AppTests.swift"), atomically: true, encoding: .utf8)
    try "hidden-source-secret".write(
      to: hidden.appendingPathComponent("hidden.py"), atomically: true, encoding: .utf8)
    try "generated-source-secret".write(
      to: build.appendingPathComponent("generated.swift"), atomically: true, encoding: .utf8)
    try "doc-secret".write(
      to: sources.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.source_files"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.source_files",
        arguments: .object(["max_depth": .number(4)]), context: .empty
      ))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["project_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.source_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["include_tests"]) == (.bool(false)))
    #expect((payload.objectValue?["source_file_count"]) == (.number(5)))
    #expect((byPath["Sources/App/App.swift"]?["language"]) == (.string("swift")))
    #expect((byPath["Sources/App/App.swift"]?["kind"]) == (.string("source")))
    #expect((byPath["Sources/App/view.tsx"]?["language"]) == (.string("typescript")))
    #expect((byPath["Sources/App/main.css"]?["kind"]) == (.string("style")))
    #expect((byPath["Sources/App/query.sql"]?["kind"]) == (.string("query")))
    #expect((byPath["scripts/deploy.sh"]?["kind"]) == (.string("script")))
    #expect((byPath["Tests/AppTests/AppTests.swift"]) == nil)
    #expect((byPath[".hidden/hidden.py"]) == nil)
    #expect((byPath["build/generated.swift"]) == nil)
    #expect((byPath["Sources/App/notes.md"]) == nil)
    #expect(!(text.contains("swift-source-secret")))
    #expect(!(text.contains("typescript-source-secret")))
    #expect(!(text.contains("style-source-secret")))
    #expect(!(text.contains("sql-source-secret")))
    #expect(!(text.contains("script-source-secret")))
    #expect(!(text.contains("test-source-secret")))
    #expect(!(text.contains("hidden-source-secret")))
    #expect(!(text.contains("generated-source-secret")))
    #expect(!(text.contains("doc-secret")))

    let withTestsResult = try provider.callTool(
      .init(
        name: "project.source_files",
        arguments: .object([
          "include_tests": .bool(true),
          "include_hidden": .bool(true),
          "max_depth": .number(4),
        ]), context: .empty
      ))
    let withTestsPayload = try decodeTextPayload(withTestsResult)
    let withTestsPaths = try #require(withTestsPayload.objectValue?["files"]?.arrayValue)
      .compactMap {
        $0.objectValue?["project_relative_path"]?.stringValue
      }
    #expect(withTestsPaths.contains("Tests/AppTests/AppTests.swift"))
    #expect(withTestsPaths.contains(".hidden/hidden.py"))
    #expect(!(withTestsPaths.contains("build/generated.swift")))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.source_files",
        arguments: .object(["max_results": .number(1)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.source_files",
        arguments: .object(["path": .string("Sources/App/view.tsx")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["source_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["language"]) == (.string("typescript")))
  }

  @Test
  func testProjectOutlineReturnsBoundedMechanicalMarkersAcrossFiles() throws {
    let directory = try temporaryDirectory()
    let sources = directory.appendingPathComponent("Sources/App")
    let tests = directory.appendingPathComponent("Tests/AppTests")
    let hidden = directory.appendingPathComponent(".hidden")
    let build = directory.appendingPathComponent("build")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

    try """
    # Project

    ```swift
    struct IgnoredFence {}
    ```

    ## Usage
    """.write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try """
    import Foundation
    struct AppModel {}
    func runApp() {}
    """.write(to: sources.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try "struct AppTests {}\n".write(
      to: tests.appendingPathComponent("AppTests.swift"), atomically: true, encoding: .utf8)
    try "def hidden_function():\n  pass\n".write(
      to: hidden.appendingPathComponent("hidden.py"), atomically: true, encoding: .utf8)
    try "struct GeneratedSecret {}\n".write(
      to: build.appendingPathComponent("Generated.swift"), atomically: true, encoding: .utf8)
    try "plain text".write(
      to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.outline"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.outline",
        arguments: .object(["max_depth": .number(4)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let items = try #require(payload.objectValue?["items"]?.arrayValue)
    let names = items.compactMap { $0.objectValue?["name"]?.stringValue }

    #expect((payload.objectValue?["operation"]) == (.string("project.outline")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["include_tests"]) == (.bool(false)))
    #expect((payload.objectValue?["include_imports"]) == (.bool(false)))
    #expect((payload.objectValue?["outline_file_count"]) == (.number(2)))
    #expect(names.contains("Project"))
    #expect(names.contains("Usage"))
    #expect(names.contains("AppModel"))
    #expect(names.contains("runApp"))
    #expect(!(names.contains("Foundation")))
    #expect(!(names.contains("IgnoredFence")))
    #expect(!(names.contains("AppTests")))
    #expect(!(names.contains("hidden_function")))
    #expect(!(names.contains("GeneratedSecret")))
    #expect(!(names.contains("notes")))
    let firstAppItem = try #require(
      items.first {
        $0.objectValue?["project_relative_path"] == .string("Sources/App/App.swift")
      }?.objectValue
    )
    #expect((firstAppItem["language"]) == (.string("swift")))
    #expect((firstAppItem["read_context"]?.objectValue?["tool"]) == (.string("file.read_context")))
    #expect((firstAppItem["outline_context"]?.objectValue?["tool"]) == (.string("file.outline")))

    let expandedResult = try provider.callTool(
      .init(
        name: "project.outline",
        arguments: .object([
          "include_hidden": .bool(true),
          "include_tests": .bool(true),
          "include_imports": .bool(true),
          "max_depth": .number(4),
        ]), context: .empty
      ))
    let expandedPayload = try decodeTextPayload(expandedResult)
    let expandedNames = try #require(expandedPayload.objectValue?["items"]?.arrayValue)
      .compactMap {
        $0.objectValue?["name"]?.stringValue
      }
    #expect(expandedNames.contains("Foundation"))
    #expect(expandedNames.contains("AppTests"))
    #expect(expandedNames.contains("hidden_function"))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.outline",
        arguments: .object([
          "max_depth": .number(4),
          "max_items": .number(3),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(3)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.outline",
        arguments: .object(["path": .string("Sources/App/App.swift")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["outline_file_count"]) == (.number(1)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "project.outline",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }
  }

  @Test
  func testProjectCommandsReturnsManifestCommandEntrypoints() throws {
    let directory = try temporaryDirectory()
    let cargo = directory.appendingPathComponent("crates/app")
    let cargoSource = cargo.appendingPathComponent("src")
    let bad = directory.appendingPathComponent("bad")
    let hidden = directory.appendingPathComponent(".hidden")
    let nodeModules = directory.appendingPathComponent("node_modules/pkg")
    try FileManager.default.createDirectory(at: cargoSource, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)

    try """
    {
      "scripts": {
        "build": "vite build",
        "test": "vitest run"
      }
    }
    """.write(
      to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "build test:\n\t@echo running\n\nclean:\n\t@echo clean\n".write(
      to: directory.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
    try "// swift-tools-version: 6.0\n".write(
      to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try """
    [package]
    name = "app"
    version = "0.1.0"
    """.write(to: cargo.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
    try "fn main() {}\n".write(
      to: cargoSource.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
    try "{".write(to: bad.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "{\"scripts\":{\"hidden\":\"echo hidden\"}}".write(
      to: hidden.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "{\"scripts\":{\"ignored\":\"echo ignored\"}}".write(
      to: nodeModules.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          cli: CLISectionConfig(commands: [
            CLICommandConfig(id: "npm", executable: "npm"),
            CLICommandConfig(id: "make", executable: "make"),
            CLICommandConfig(id: "swift", executable: "swift"),
          ]),
          builtin: BuiltinConfig(enabled: ["project.commands"]),
          projectDirectory: directory
        )
      ))

    let result = try provider.callTool(
      .init(
        name: "project.commands",
        arguments: .object(["max_depth": .number(4)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let commands = try #require(payload.objectValue?["commands"]?.arrayValue)
    let byKey = Dictionary(
      uniqueKeysWithValues: commands.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let source = object["source_project_relative_path"]?.stringValue,
          let ecosystem = object["ecosystem"]?.stringValue,
          let name = object["name"]?.stringValue
        else {
          return nil
        }
        return ("\(source)|\(ecosystem)|\(name)", object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("project.commands")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["manifest_count"]) == (.number(5)))
    #expect((payload.objectValue?["command_count"]) == (.number(11)))
    #expect((payload.objectValue?["returned_count"]) == (.number(11)))
    #expect((payload.objectValue?["scan_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["file_truncated_count"]) == (.number(0)))

    #expect((byKey["package.json|node|build"]?["definition"]) == (.string("vite build")))
    #expect((byKey["package.json|node|build"]?["executor_tool"]) == (.string("cli.exec")))
    #expect((byKey["package.json|node|build"]?["suggested_cli_id"]) == (.string("npm")))
    #expect((byKey["package.json|node|build"]?["registered_cli_provider"]) == (.bool(true)))
    #expect(
      (byKey["package.json|node|build"]?["argv"]) == (.array([.string("run"), .string("build")])))
    #expect((byKey["Makefile|make|clean"]?["argv"]) == (.array([.string("clean")])))
    #expect((byKey["Package.swift|swift|build"]?["argv"]) == (.array([.string("build")])))
    #expect(
      (byKey["Package.swift|swift|describe"]?["argv"])
        == (.array([.string("package"), .string("describe"), .string("--type"), .string("json")])))
    #expect((byKey["crates/app/Cargo.toml|rust|run"]?["argv"]) == (.array([.string("run")])))
    #expect((byKey["crates/app/Cargo.toml|rust|run"]?["registered_cli_provider"]) == (.bool(false)))
    #expect(
      (byKey["crates/app/Cargo.toml|rust|run"]?["cwd_project_relative_path"])
        == (.string("crates/app")))
    #expect((byKey[".hidden/package.json|node|hidden"]) == nil)
    #expect((byKey["node_modules/pkg/package.json|node|ignored"]) == nil)

    let parseErrors = try #require(payload.objectValue?["parse_errors"]?.arrayValue)
    #expect((parseErrors.count) == (1))
    #expect(
      (parseErrors.first?.objectValue?["source_project_relative_path"])
        == (.string("bad/package.json")))

    let truncatedResult = try provider.callTool(
      .init(
        name: "project.commands",
        arguments: .object(["max_results": .number(2)]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(2)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try provider.callTool(
      .init(
        name: "project.commands",
        arguments: .object(["path": .string("Package.swift")]), context: .empty
      ))
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["manifest_count"]) == (.number(1)))
    #expect((singleFilePayload.objectValue?["command_count"]) == (.number(3)))
  }

  @Test
  func testProjectGitChangesIsExposedOnlyWhenEnabled() throws {
    let disabled = ProjectToolProvider(
      environment: ToolEnvironment(launcher: testExecutionLauncher(), configuration: .fixture()))
    #expect(
      !((try disabled.definitions()).map(\.tool.name).contains("project.git_changes")))
    let enabled = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(builtin: .init(enabled: ["project.git_changes"]))))
    #expect((try enabled.definitions()).map(\.tool.name).contains("project.git_changes"))
  }

  @Test
  func testProjectGitChangesRequiresGitProvider() {
    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(builtin: .init(enabled: ["project.git_changes"]))))
    expectThrows(
      try provider.callTool(
        .init(name: "project.git_changes", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }
  }

  private var temporaryDirectories: [ScopedTemporaryDirectory] = []

  private func temporaryDirectory() throws -> URL {
    let directory = try ScopedTemporaryDirectory()
    temporaryDirectories.append(directory)
    return directory.url
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}
