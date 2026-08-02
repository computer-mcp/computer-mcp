import AppKit
import CoreText
import Darwin
import Foundation
import PDFKit
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class GatewayToolRegistryTests {
  @Test
  func testGatewayToolsExposeCLIAndMCPTools() throws {
    let registry = GatewayToolRegistry(configuration: .fixture())
    let names = try registry.listTools().map(\.name)

    #expect(names.contains("cli.list"))
    #expect(names.contains("cli.describe"))
    #expect(names.contains("cli.status"))
    #expect(names.contains("cli.help"))
    #expect(names.contains("cli.exec"))
    #expect(names.contains("mcp.tools.call"))
    #expect(names.contains("mcp.tools.describe"))
    #expect(names.contains("mcp.tools.find"))
    #expect(names.contains("mcp.resources.list"))
    #expect(names.contains("mcp.resources.templates.list"))
    #expect(names.contains("mcp.resources.read"))
    #expect(names.contains("mcp.prompts.list"))
    #expect(names.contains("mcp.prompts.get"))
    #expect(names.contains("mcp.servers.status"))
    #expect(names.contains("process.list"))
    #expect(!(names.contains("file.read")))
    #expect(!(names.contains("shell.run")))
  }

  @Test
  func testGatewayToolsHideProviderAdaptersWhenNoProvidersAreConfigured() throws {
    let config = GatewayConfiguration.fixture(
      cli: CLISectionConfig(),
      mcp: MCPSectionConfig(),
      builtin: BuiltinConfig(enabled: ["system.time"])
    )
    let registry = GatewayToolRegistry(configuration: config)
    let tools = try registry.listTools()

    #expect((tools.map(\.name)) == (["system.time"]))
    #expect((tools.first?.annotations?.readOnlyHint) == (true))
    #expect((tools.first?.annotations?.destructiveHint) == (false))
    expectThrows(
      try registry.callTool(name: "cli.list", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("at least one configured provider"))
    }
    expectThrows(
      try registry.callTool(name: "mcp.servers.list", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("at least one configured server"))
    }
  }

  @Test
  func testGatewayToolsAdvertiseOperationalAnnotations() throws {
    let config = GatewayConfiguration.fixture(
      builtin: BuiltinConfig(
        enabled: ["system.time", "file.write", "file.mkdir", "git.commit"])
    )
    let registry = GatewayToolRegistry(configuration: config)
    let tools = try registry.listTools()
    let cliList = try #require(tools.first { $0.name == "cli.list" })
    let cliExec = try #require(tools.first { $0.name == "cli.exec" })
    let systemTime = try #require(tools.first { $0.name == "system.time" })
    let fileWrite = try #require(tools.first { $0.name == "file.write" })
    let fileMkdir = try #require(tools.first { $0.name == "file.mkdir" })
    let gitCommit = try #require(tools.first { $0.name == "git.commit" })

    #expect((cliList.annotations?.readOnlyHint) == (true))
    #expect((cliList.annotations?.destructiveHint) == (false))
    #expect((cliExec.annotations?.readOnlyHint) == (false))
    #expect((cliExec.annotations?.destructiveHint) == (true))
    #expect((systemTime.annotations?.readOnlyHint) == (true))
    #expect((systemTime.annotations?.openWorldHint) == (false))
    #expect((fileWrite.annotations?.readOnlyHint) == (false))
    #expect((fileWrite.annotations?.destructiveHint) == (true))
    #expect((fileMkdir.annotations?.readOnlyHint) == (false))
    #expect((fileMkdir.annotations?.destructiveHint) == (false))
    #expect((gitCommit.annotations?.readOnlyHint) == (false))
    #expect((gitCommit.annotations?.destructiveHint) == (false))
    #expect((systemTime.title) == ("System Time"))
    #expect((systemTime.outputSchema) == (MCPTool.resultEnvelopeSchema))
    #expect(
      (systemTime.json.objectValue?["annotations"]?.objectValue?["readOnlyHint"]) == (.bool(true)))
    #expect((systemTime.json.objectValue?["title"]) == (.string("System Time")))
    #expect((systemTime.json.objectValue?["outputSchema"]) == (MCPTool.resultEnvelopeSchema))
  }

  @Test
  func testGatewayToolResultsExposeMatchingStructuredContent() throws {
    let config = GatewayConfiguration.fixture(
      cli: CLISectionConfig(),
      mcp: MCPSectionConfig(),
      builtin: BuiltinConfig(enabled: ["system.time"])
    )
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(name: "system.time", arguments: .object([:]))
    let textPayload = try decodeTextPayload(result)

    #expect((result.objectValue?["structuredContent"]?.objectValue?["result"]) == (textPayload))
  }

  @Test
  func testNoAuthToolsAdvertiseNoAuthSecurityScheme() throws {
    let registry = GatewayToolRegistry(configuration: .fixture())
    let tool = try #require(try registry.listTools().first { $0.name == "cli.list" })

    #expect(
      (tool.meta?.objectValue?["securitySchemes"])
        == (.array([.object(["type": .string("noauth")])])))
    #expect(
      (tool.json.objectValue?["_meta"]?.objectValue?["securitySchemes"])
        == (.array([.object(["type": .string("noauth")])])))
  }

  @Test
  func testBearerProtectedToolsDoNotAdvertiseNoAuthSecurityScheme() throws {
    let config = GatewayConfiguration.fixture(
      server: ServerConfig(
        http: HTTPServerConfig(
          publicBaseURL: "https://gateway.example.com",
          accessTokenEnv: "COMPUTER_MCP_TOKEN"
        ))
    )
    let registry = GatewayToolRegistry(configuration: config)
    let tool = try #require(try registry.listTools().first { $0.name == "cli.list" })

    #expect((tool.meta) == nil)
  }

  @Test
  func testCLIListIncludesInterfaceAvailability() throws {
    let config = GatewayConfiguration.fixture(
      cli: CLISectionConfig(commands: [
        CLICommandConfig(
          id: "echo",
          executable: "/bin/echo",
          interface: CLIInterfaceConfig(formatFlag: "--format", defaultFormat: "json")
        )
      ])
    )
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(name: "cli.list", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((payload.arrayValue?.first?.objectValue?["id"]) == (.string("echo")))
    #expect((payload.arrayValue?.first?.objectValue?["has_interface"]) == (.bool(true)))
  }

  @Test
  func testCLIDescribeReturnsProviderInterface() throws {
    let config = GatewayConfiguration.fixture(
      cli: CLISectionConfig(commands: [
        CLICommandConfig(
          id: "echo",
          executable: "/bin/echo",
          cwd: "workspace",
          risk: "read-only",
          discovery: ["help"],
          interface: CLIInterfaceConfig(formatFlag: "--format", defaultFormat: "json")
        )
      ])
    )
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(
      name: "cli.describe",
      arguments: .object(["id": .string("echo")])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["id"]) == (.string("echo")))
    #expect((payload.objectValue?["cwd"]) == (.string("workspace")))
    #expect((payload.objectValue?["has_interface"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["interface"]?.objectValue?["format_flag"]) == (.string("--format")))
  }

  @Test
  func testCLIStatusReportsExecutableResolution() throws {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent("tool")
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let config = GatewayConfiguration.fixture(
      cli: CLISectionConfig(commands: [
        CLICommandConfig(id: "tool", executable: executable.path),
        CLICommandConfig(id: "missing", executable: "definitely-missing-computer-mcp-test"),
      ])
    )
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(
      name: "cli.status",
      arguments: .object(["id": .string("tool")])
    )
    let payload = try decodeTextPayload(result)
    let command = try #require(payload.objectValue?["commands"]?.arrayValue?.first?.objectValue)

    #expect((command["id"]) == (.string("tool")))
    #expect((command["exists"]) == (.bool(true)))
    #expect((command["is_executable"]) == (.bool(true)))
    #expect((command["resolved_path"]) == (.string(executable.path)))

    let allResult = try registry.callTool(name: "cli.status", arguments: .object([:]))
    let allPayload = try decodeTextPayload(allResult)
    #expect((allPayload.objectValue?["commands"]?.arrayValue?.count) == (2))
  }

  @Test
  func testCLIStatusRejectsUnknownID() {
    let registry = GatewayToolRegistry(configuration: .fixture())

    expectThrows(
      try registry.callTool(
        name: "cli.status",
        arguments: .object(["id": .string("missing")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown CLI command id"))
    }
  }

  @Test
  func testCLIHelpReturnsRawHelpAndExecContext() throws {
    let runner = FakeCommandRunner()
    let config = GatewayConfiguration.fixture(
      cli: CLISectionConfig(commands: [
        CLICommandConfig(
          id: "echo",
          executable: "/bin/echo",
          interface: CLIInterfaceConfig(formatFlag: "--format", defaultFormat: "json")
        )
      ])
    )
    let registry = GatewayToolRegistry(configuration: config, commandRunner: runner)

    let result = try registry.callTool(
      name: "cli.help",
      arguments: .object([
        "id": .string("echo"),
        "path": .array([.string("sub")]),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.arguments) == (["sub", "--help"]))
    #expect((payload.objectValue?["path"]) == (.array([.string("sub")])))
    #expect((payload.objectValue?["help_argv"]) == (.array([.string("sub"), .string("--help")])))
    #expect((payload.objectValue?["exec_context"]?.objectValue?["tool"]) == (.string("cli.exec")))
    #expect(
      (payload.objectValue?["exec_context"]?.objectValue?["argv_prefix"])
        == (.array([.string("sub")])))
    #expect(
      (payload.objectValue?["interface"]?.objectValue?["format_flag"]) == (.string("--format")))
    #expect((payload.objectValue?["stdout"]) == (.string("ok")))
    #expect((payload.objectValue?["stderr"]) == (.string("")))
    #expect((payload.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testCLIExecUsesRegisteredExecutable() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(configuration: .fixture(), commandRunner: runner)

    let result = try registry.callTool(
      name: "cli.exec",
      arguments: .object([
        "id": .string("echo"),
        "argv": .array([.string("hello")]),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect((runner.calls.first?.arguments) == (["hello"]))
    #expect((payload.objectValue?["stdout"]) == (.string("ok")))
  }

  @Test
  func testCLIExecSchemaRequiresArgv() throws {
    let registry = GatewayToolRegistry(configuration: .fixture())
    let tools = try registry.listTools()

    let cliExec = try #require(tools.first { $0.name == "cli.exec" })

    #expect(
      (cliExec.inputSchema.objectValue?["required"]) == (.array([.string("id"), .string("argv")])))
  }

  @Test
  func testCLIExecRejectsMissingArgv() {
    let registry = GatewayToolRegistry(configuration: .fixture())

    expectThrows(
      try registry.callTool(
        name: "cli.exec",
        arguments: .object(["id": .string("echo")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Missing required array argument: argv"))
    }
  }

  @Test
  func testSkillsToolsExposeOnlyWhenEnabled() throws {
    let disabledRegistry = GatewayToolRegistry(configuration: .fixture())
    let disabledNames = try disabledRegistry.listTools().map(\.name)

    #expect(!(disabledNames.contains("skills.list")))
    expectThrows(
      try disabledRegistry.callTool(name: "skills.list", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("skills tools are disabled"))
    }

    let root = try temporaryDirectory()
    let enabledRegistry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path, description: "Local skills")]
        ))
    )
    let enabledTools = try enabledRegistry.listTools()
    let enabledNames = enabledTools.map(\.name)

    #expect(enabledNames.contains("skills.roots"))
    #expect(enabledNames.contains("skills.list"))
    #expect(enabledNames.contains("skills.describe"))
    #expect(enabledNames.contains("skills.validate"))
    #expect(enabledNames.contains("skills.frontmatter"))
    #expect(enabledNames.contains("skills.read"))
    #expect(enabledNames.contains("skills.files"))
    #expect(enabledNames.contains("skills.read_file"))
    #expect(enabledNames.contains("skills.read_files"))
    #expect(enabledNames.contains("skills.read_package"))
    #expect(enabledNames.contains("skills.outline"))
    #expect(enabledNames.contains("skills.section"))
    #expect(enabledNames.contains("skills.tables"))
    #expect(enabledNames.contains("skills.links"))
    #expect(enabledNames.contains("skills.link_check"))
    #expect(enabledNames.contains("skills.search"))
    #expect(enabledNames.contains("skills.search_files"))
    #expect(
      enabledTools.first { $0.name == "skills.roots" }?.description.contains(
        "main MCP gateway") == true)
    #expect(
      enabledTools.first { $0.name == "skills.list" }?.description.contains(
        "separate local or coding-provider execution path") == true)
    #expect(
      enabledTools.first { $0.name == "skills.read" }?.description.contains(
        "same gateway") == true)
    #expect(
      enabledTools.first { $0.name == "skills.read_package" }?.description.contains(
        "any authorized MCP client") == true)
    #expect(
      (enabledTools.first { $0.name == "skills.read" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.read_file" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name"), .string("path")])))
    #expect(
      (enabledTools.first { $0.name == "skills.read_files" }?.inputSchema.objectValue?[
        "required"]) == (.array([.string("name"), .string("paths")])))
    #expect(
      (enabledTools.first { $0.name == "skills.read_package" }?.inputSchema.objectValue?[
        "required"]) == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.outline" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.section" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name"), .string("heading")])))
    #expect(
      (enabledTools.first { $0.name == "skills.tables" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.links" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.link_check" }?.inputSchema.objectValue?[
        "required"]) == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.validate" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.frontmatter" }?.inputSchema.objectValue?[
        "required"]) == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.search_files" }?.inputSchema.objectValue?[
        "required"]) == (.array([.string("name"), .string("query")])))
  }

  @Test
  func testSkillsListReadAndSearchConfiguredRoots() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "alpha",
      content:
        """
        ---
        name: alpha-skill
        description: >-
          Alpha helper
          skill.
        ---
        # Alpha

        Use cli.exec for alpha work.
        """
    )
    try writeSkill(
      root: root,
      directory: "beta",
      content:
        """
        ---
        name: beta-skill
        description: Beta helper skill.
        ---
        # Beta
        """
    )

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path, description: "Local skills")]
        ))
    )

    let rootsResult = try registry.callTool(name: "skills.roots", arguments: .object([:]))
    let rootsPayload = try decodeTextPayload(rootsResult)
    let rootPayload = try #require(rootsPayload.objectValue?["roots"]?.arrayValue?.first)
      .objectValue
    #expect((rootPayload?["id"]) == (.string("local")))
    #expect((rootPayload?["exists"]) == (.bool(true)))
    #expect((rootPayload?["is_readable"]) == (.bool(true)))

    let listResult = try registry.callTool(
      name: "skills.list",
      arguments: .object(["root_id": .string("local")])
    )
    let listPayload = try decodeTextPayload(listResult)
    let skills = try #require(listPayload.objectValue?["skills"]?.arrayValue)

    #expect((listPayload.objectValue?["skill_count"]) == (.number(2)))
    #expect(
      (skills.map { $0.objectValue?["name"] }) == ([.string("alpha-skill"), .string("beta-skill")]))
    #expect((skills.first?.objectValue?["description"]) == (.string("Alpha helper skill.")))
    #expect(
      (skills.first?.objectValue?["read_context"]?.objectValue?["tool"]) == (.string("skills.read"))
    )
    #expect(
      (skills.first?.objectValue?["files_context"]?.objectValue?["tool"])
        == (.string("skills.files")))

    let readResult = try registry.callTool(
      name: "skills.read",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("alpha-skill"),
      ])
    )
    let readPayload = try decodeTextPayload(readResult)

    #expect((readPayload.objectValue?["name"]) == (.string("alpha-skill")))
    #expect((readPayload.objectValue?["valid_utf8"]) == (.bool(true)))
    #expect((readPayload.objectValue?["content_truncated"]) == (.bool(false)))
    #expect(readPayload.objectValue?["content"]?.stringValue?.contains("Use cli.exec") == true)

    let metadataSearch = try registry.callTool(
      name: "skills.search",
      arguments: .object([
        "root_id": .string("local"),
        "query": .string("alpha"),
      ])
    )
    let metadataPayload = try decodeTextPayload(metadataSearch)
    let metadataMatch = try #require(metadataPayload.objectValue?["matches"]?.arrayValue?.first)
      .objectValue

    #expect((metadataPayload.objectValue?["match_count"]) == (.number(1)))
    #expect((metadataMatch?["name"]) == (.string("alpha-skill")))
    #expect((metadataMatch?["matched_fields"]?.arrayValue?.contains(.string("name"))) == (true))

    let contentSearch = try registry.callTool(
      name: "skills.search",
      arguments: .object([
        "root_id": .string("local"),
        "query": .string("cli.exec"),
        "search_content": .bool(true),
      ])
    )
    let contentPayload = try decodeTextPayload(contentSearch)
    let contentMatch = try #require(contentPayload.objectValue?["matches"]?.arrayValue?.first)
      .objectValue

    #expect((contentPayload.objectValue?["match_count"]) == (.number(1)))
    #expect((contentMatch?["content_searched"]) == (.bool(true)))
    #expect((contentMatch?["content_match_count"]) == (.number(1)))
  }

  @Test
  func testSkillsFilesAndReadFileExposeWholeSkillFolderReadOnly() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "skill-creator-lite",
      content:
        """
        ---
        name: skill-creator-lite
        description: >-
          Test skill
          folder.
        ---
        # Skill Creator Lite
        """
    )
    let skillDirectory = root.appendingPathComponent("skill-creator-lite", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("agents", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("scripts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("assets", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("eval-viewer", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "display_name: Skill Creator Lite\n".write(
      to: skillDirectory.appendingPathComponent("agents/openai.yaml"),
      atomically: true,
      encoding: .utf8
    )
    try """
    ---
    title: Guide
    audience: agents
    ---
    Use skills.read_file for references.

    | Phase | Owner |
    | --- | --- |
    | Read | Agent |
    """.write(
      to: skillDirectory.appendingPathComponent("references/guide.md"),
      atomically: true,
      encoding: .utf8
    )
    try "print('do not execute')\n".write(
      to: skillDirectory.appendingPathComponent("scripts/check.py"),
      atomically: true,
      encoding: .utf8
    )
    try Data([0, 1, 2, 255]).write(to: skillDirectory.appendingPathComponent("assets/blob.bin"))
    try "print('review')\n".write(
      to: skillDirectory.appendingPathComponent("eval-viewer/generate_review.py"),
      atomically: true,
      encoding: .utf8
    )
    try "Example license.\n".write(
      to: skillDirectory.appendingPathComponent("license.txt"),
      atomically: true,
      encoding: .utf8
    )

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)]
        ))
    )

    let describeResult = try registry.callTool(
      name: "skills.describe",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "max_depth": .number(3),
      ])
    )
    let describePayload = try decodeTextPayload(describeResult)
    let resourcePayloads = try #require(describePayload.objectValue?["resources"]?.arrayValue)
    func resource(_ kind: String) -> [String: JSONValue]? {
      resourcePayloads.first { $0.objectValue?["kind"] == .string(kind) }?.objectValue
    }

    #expect((describePayload.objectValue?["operation"]) == (.string("skills.describe")))
    #expect((describePayload.objectValue?["name"]) == (.string("skill-creator-lite")))
    #expect((describePayload.objectValue?["description"]) == (.string("Test skill folder.")))
    #expect(
      (describePayload.objectValue?["entrypoint"]?.objectValue?["path"]) == (.string("SKILL.md")))
    #expect(
      (describePayload.objectValue?["entrypoint"]?.objectValue?["read_context"]?.objectValue?[
        "tool"]) == (.string("skills.read")))
    #expect((describePayload.objectValue?["content"]) == nil)
    #expect((resource("agents")?["exists"]) == (.bool(true)))
    #expect((resource("agents")?["file_count"]) == (.number(1)))
    #expect((resource("references")?["exists"]) == (.bool(true)))
    #expect((resource("references")?["file_count"]) == (.number(1)))
    #expect((resource("scripts")?["exists"]) == (.bool(true)))
    #expect((resource("scripts")?["file_count"]) == (.number(1)))
    #expect((resource("assets")?["exists"]) == (.bool(true)))
    #expect((resource("assets")?["file_count"]) == (.number(1)))
    #expect((resource("other")?["file_count"]) == (.number(2)))
    #expect((resource("other")?["directory_count"]) == (.number(1)))
    #expect(
      (resource("references")?["list_context"]?.objectValue?["tool"]) == (.string("skills.files")))

    let validateResult = try registry.callTool(
      name: "skills.validate",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
      ])
    )
    let validatePayload = try decodeTextPayload(validateResult)
    #expect((validatePayload.objectValue?["operation"]) == (.string("skills.validate")))
    #expect((validatePayload.objectValue?["valid"]) == (.bool(true)))
    #expect((validatePayload.objectValue?["error_count"]) == (.number(0)))
    #expect(
      (validatePayload.objectValue?["frontmatter"]?.objectValue?["name"])
        == (.string("skill-creator-lite")))
    #expect(
      (validatePayload.objectValue?["frontmatter"]?.objectValue?["description"])
        == (.string("Test skill folder.")))
    #expect(
      (validatePayload.objectValue?["describe_context"]?.objectValue?["tool"])
        == (.string("skills.describe")))

    let pathSearchResult = try registry.callTool(
      name: "skills.search_files",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "query": .string("blob"),
      ])
    )
    let pathSearchPayload = try decodeTextPayload(pathSearchResult)
    let pathMatch = try #require(pathSearchPayload.objectValue?["matches"]?.arrayValue?.first)
      .objectValue
    #expect((pathSearchPayload.objectValue?["operation"]) == (.string("skills.search_files")))
    #expect((pathSearchPayload.objectValue?["match_count"]) == (.number(1)))
    #expect((pathMatch?["path"]) == (.string("assets/blob.bin")))
    #expect((pathMatch?["matched_fields"]) == (.array([.string("path")])))
    #expect((pathMatch?["content_searched"]) == (.bool(false)))
    #expect((pathMatch?["read_context"]?.objectValue?["tool"]) == (.string("skills.read_file")))

    let contentSearchResult = try registry.callTool(
      name: "skills.search_files",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "query": .string("references"),
        "search_content": .bool(true),
      ])
    )
    let contentSearchPayload = try decodeTextPayload(contentSearchResult)
    let contentMatches = try #require(contentSearchPayload.objectValue?["matches"]?.arrayValue)
    let guideMatch = try #require(
      contentMatches.first { $0.objectValue?["path"] == .string("references/guide.md") }
    )
    #expect((guideMatch.objectValue?["content_searched"]) == (.bool(true)))
    #expect((guideMatch.objectValue?["content_match_count"]) == (.number(1)))
    #expect((guideMatch.objectValue?["valid_utf8"]) == (.bool(true)))

    let filesResult = try registry.callTool(
      name: "skills.files",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "max_depth": .number(3),
      ])
    )
    let filesPayload = try decodeTextPayload(filesResult)
    let files = try #require(filesPayload.objectValue?["files"]?.arrayValue)
    let paths = files.compactMap { $0.objectValue?["path"]?.stringValue }

    #expect(paths.contains("SKILL.md"))
    #expect(paths.contains("references"))
    #expect(paths.contains("references/guide.md"))
    #expect(paths.contains("scripts/check.py"))
    #expect(paths.contains("assets/blob.bin"))
    #expect(paths.contains("eval-viewer/generate_review.py"))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references") }?
        .objectValue?["list_context"]?.objectValue?["tool"]) == (.string("skills.files")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["read_context"]?.objectValue?["tool"]) == (.string("skills.read_file")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("SKILL.md") }?
        .objectValue?["outline_context"]?.objectValue?["tool"]) == (.string("skills.outline")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["outline_language"]) == (.string("markdown")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["outline_context"]?.objectValue?["arguments"]?.objectValue?["path"])
        == (.string("references/guide.md")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["frontmatter_context"]?.objectValue?["tool"])
        == (.string("skills.frontmatter")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["frontmatter_context"]?.objectValue?["arguments"]?.objectValue?["path"])
        == (.string("references/guide.md")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["section_context"]?.objectValue?["tool"]) == (.string("skills.section")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["section_context"]?.objectValue?["required_arguments"])
        == (.array([.string("heading")])))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["tables_context"]?.objectValue?["tool"]) == (.string("skills.tables")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["tables_context"]?.objectValue?["arguments"]?.objectValue?["path"])
        == (.string("references/guide.md")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["links_context"]?.objectValue?["tool"]) == (.string("skills.links")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["links_context"]?.objectValue?["arguments"]?.objectValue?["path"])
        == (.string("references/guide.md")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("SKILL.md") }?
        .objectValue?["link_check_context"]?.objectValue?["tool"]) == (.string("skills.link_check"))
    )
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["link_check_context"]?.objectValue?["arguments"]?.objectValue?["path"])
        == (.string("references/guide.md")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("assets/blob.bin") }?
        .objectValue?["link_check_context"]) == (.null))

    let rootFilesResult = try registry.callTool(
      name: "skills.files",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "path": .string(""),
        "max_depth": .number(1),
      ])
    )
    let rootFilesPayload = try decodeTextPayload(rootFilesResult)
    #expect((rootFilesPayload.objectValue?["path"]) == (.string(".")))

    let referenceResult = try registry.callTool(
      name: "skills.read_file",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "path": .string("references/guide.md"),
      ])
    )
    let referencePayload = try decodeTextPayload(referenceResult)
    #expect((referencePayload.objectValue?["encoding"]) == (.string("utf8")))
    #expect(
      referencePayload.objectValue?["content"]?.stringValue?.contains("Use skills.read_file")
        == true)

    let binaryResult = try registry.callTool(
      name: "skills.read_file",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "path": .string("assets/blob.bin"),
        "encoding": .string("base64"),
      ])
    )
    let binaryPayload = try decodeTextPayload(binaryResult)
    #expect((binaryPayload.objectValue?["encoding"]) == (.string("base64")))
    #expect(
      (binaryPayload.objectValue?["content"])
        == (.string(Data([0, 1, 2, 255]).base64EncodedString())))
    #expect((binaryPayload.objectValue?["valid_utf8"]) == (.bool(false)))

    let autoBinaryResult = try registry.callTool(
      name: "skills.read_file",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "path": .string("assets/blob.bin"),
        "encoding": .string("auto"),
      ])
    )
    let autoBinaryPayload = try decodeTextPayload(autoBinaryResult)
    #expect((autoBinaryPayload.objectValue?["encoding"]) == (.string("base64")))
    #expect(
      (autoBinaryPayload.objectValue?["content"])
        == (.string(Data([0, 1, 2, 255]).base64EncodedString())))

    let batchResult = try registry.callTool(
      name: "skills.read_files",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "paths": .array([
          .string("agents/openai.yaml"),
          .string("references/guide.md"),
        ]),
        "max_bytes_per_file": .number(1024),
      ])
    )
    let batchPayload = try decodeTextPayload(batchResult)
    let batchFiles = try #require(batchPayload.objectValue?["files"]?.arrayValue)
    #expect((batchPayload.objectValue?["operation"]) == (.string("skills.read_files")))
    #expect((batchPayload.objectValue?["file_count"]) == (.number(2)))
    #expect((batchPayload.objectValue?["truncated_file_count"]) == (.number(0)))
    #expect(
      (batchFiles.map { $0.objectValue?["path"] })
        == ([
          .string("agents/openai.yaml"),
          .string("references/guide.md"),
        ]))
    #expect(batchFiles[0].objectValue?["content"]?.stringValue?.contains("display_name") == true)
    #expect(
      batchFiles[1].objectValue?["content"]?.stringValue?.contains("skills.read_file") == true)

    let autoBatchResult = try registry.callTool(
      name: "skills.read_files",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "paths": .array([
          .string("agents/openai.yaml"),
          .string("assets/blob.bin"),
        ]),
        "encoding": .string("auto"),
      ])
    )
    let autoBatchPayload = try decodeTextPayload(autoBatchResult)
    let autoBatchFiles = try #require(autoBatchPayload.objectValue?["files"]?.arrayValue)
    #expect((autoBatchPayload.objectValue?["encoding"]) == (.string("auto")))
    #expect((autoBatchFiles[0].objectValue?["encoding"]) == (.string("utf8")))
    #expect((autoBatchFiles[1].objectValue?["encoding"]) == (.string("base64")))

    let packageResult = try registry.callTool(
      name: "skills.read_package",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "encoding": .string("auto"),
        "max_depth": .number(3),
        "max_files": .number(10),
        "max_total_bytes": .number(4096),
      ])
    )
    let packagePayload = try decodeTextPayload(packageResult)
    let packageFiles = try #require(packagePayload.objectValue?["files"]?.arrayValue)
    let packageSkipped = try #require(packagePayload.objectValue?["skipped"]?.arrayValue)
    let packageByPath = Dictionary(
      uniqueKeysWithValues: packageFiles.compactMap { file -> (String, [String: JSONValue])? in
        guard let object = file.objectValue, let path = object["path"]?.stringValue else {
          return nil
        }
        return (path, object)
      })

    #expect((packagePayload.objectValue?["operation"]) == (.string("skills.read_package")))
    #expect((packagePayload.objectValue?["file_count"]) == (.number(7)))
    #expect((packagePayload.objectValue?["truncated"]) == (.bool(false)))
    #expect(packageSkipped.contains { $0.objectValue?["reason"] == .string("not_file") })
    #expect(packageByPath.keys.contains("SKILL.md"))
    #expect(packageByPath.keys.contains("eval-viewer/generate_review.py"))
    #expect(
      packageByPath["agents/openai.yaml"]?["content"]?.stringValue?.contains("display_name")
        == true)
    #expect(
      packageByPath["references/guide.md"]?["content"]?.stringValue?.contains(
        "skills.read_file")
        == true)
    #expect((packageByPath["assets/blob.bin"]?["encoding"]) == (.string("base64")))
    #expect(
      (packageByPath["assets/blob.bin"]?["content"])
        == (.string(Data([0, 1, 2, 255]).base64EncodedString())))
    #expect(
      (packagePayload.objectValue?["files_context"]?.objectValue?["tool"])
        == (.string("skills.files")))

    let rootPackageResult = try registry.callTool(
      name: "skills.read_package",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "path": .string(""),
        "encoding": .string("auto"),
        "max_depth": .number(1),
        "max_files": .number(2),
      ])
    )
    let rootPackagePayload = try decodeTextPayload(rootPackageResult)
    #expect((rootPackagePayload.objectValue?["path"]) == (.string(".")))

    let smallPackageResult = try registry.callTool(
      name: "skills.read_package",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-creator-lite"),
        "encoding": .string("utf8"),
        "max_depth": .number(3),
        "max_files": .number(10),
        "max_bytes_per_file": .number(30),
        "max_total_bytes": .number(30),
      ])
    )
    let smallPackagePayload = try decodeTextPayload(smallPackageResult)
    let smallPackageFiles = try #require(smallPackagePayload.objectValue?["files"]?.arrayValue)
    #expect((smallPackagePayload.objectValue?["file_count"]) == (.number(1)))
    #expect((smallPackageFiles.first?.objectValue?["path"]) == (.string("SKILL.md")))
    #expect((smallPackageFiles.first?.objectValue?["content_truncated"]) == (.bool(true)))

    expectThrows(
      try registry.callTool(
        name: "skills.read_file",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "path": .string("../outside.md"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }
  }

  @Test
  func testSkillsFrontmatterReadsSkillPackageMarkdownMetadata() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "skill-frontmatter",
      content:
        """
        ---
        name: skill-frontmatter
        description: Read metadata.
        tags:
          - gateway
        ---
        # Body
        """
    )
    let skillDirectory = root.appendingPathComponent("skill-frontmatter", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    +++
    title = "Reference"
    weight = 3
    +++
    # Reference
    """.write(
      to: skillDirectory.appendingPathComponent("references/page.md"), atomically: true,
      encoding: .utf8)
    try "# Plain\n".write(
      to: skillDirectory.appendingPathComponent("references/plain.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    ---
    title: [unterminated
    ---
    # Bad
    """.write(
      to: skillDirectory.appendingPathComponent("references/bad.md"), atomically: true,
      encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)]
        ))
    )

    let skillResult = try registry.callTool(
      name: "skills.frontmatter",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-frontmatter"),
      ])
    )
    let skillPayload = try decodeTextPayload(skillResult)
    let skillValue = try #require(skillPayload.objectValue?["value"]?.objectValue)

    #expect((skillPayload.objectValue?["operation"]) == (.string("skills.frontmatter")))
    #expect((skillPayload.objectValue?["root_id"]) == (.string("local")))
    #expect((skillPayload.objectValue?["name"]) == (.string("skill-frontmatter")))
    #expect((skillPayload.objectValue?["path"]) == (.string("SKILL.md")))
    #expect((skillPayload.objectValue?["found"]) == (.bool(true)))
    #expect((skillPayload.objectValue?["format"]) == (.string("yaml")))
    #expect((skillPayload.objectValue?["parsed"]) == (.bool(true)))
    #expect((skillPayload.objectValue?["raw_start_line"]) == (.number(2)))
    #expect((skillPayload.objectValue?["raw_end_line"]) == (.number(5)))
    #expect((skillPayload.objectValue?["closing_line"]) == (.number(6)))
    #expect((skillPayload.objectValue?["body_start_line"]) == (.number(7)))
    #expect((skillValue["name"]) == (.string("skill-frontmatter")))
    #expect((skillValue["description"]) == (.string("Read metadata.")))
    #expect((skillValue["tags"]) == (.array([.string("gateway")])))
    #expect(
      (skillPayload.objectValue?["read_file_context"]?.objectValue?["tool"])
        == (.string("skills.read_file")))

    let tomlResult = try registry.callTool(
      name: "skills.frontmatter",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-frontmatter"),
        "path": .string("references/page.md"),
        "format": .string("toml"),
      ])
    )
    let tomlPayload = try decodeTextPayload(tomlResult)
    let tomlValue = try #require(tomlPayload.objectValue?["value"]?.objectValue)
    #expect((tomlPayload.objectValue?["path"]) == (.string("references/page.md")))
    #expect((tomlPayload.objectValue?["format"]) == (.string("toml")))
    #expect((tomlPayload.objectValue?["found"]) == (.bool(true)))
    #expect((tomlValue["title"]) == (.string("Reference")))
    #expect((tomlValue["weight"]) == (.number(3)))

    let missingResult = try registry.callTool(
      name: "skills.frontmatter",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-frontmatter"),
        "path": .string("references/plain.md"),
      ])
    )
    let missingPayload = try decodeTextPayload(missingResult)
    #expect((missingPayload.objectValue?["found"]) == (.bool(false)))
    #expect(
      (missingPayload.objectValue?["failure"]?.objectValue?["reason"])
        == (.string("missing_frontmatter")))

    let badResult = try registry.callTool(
      name: "skills.frontmatter",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("skill-frontmatter"),
        "path": .string("references/bad.md"),
      ])
    )
    let badPayload = try decodeTextPayload(badResult)
    #expect((badPayload.objectValue?["found"]) == (.bool(true)))
    #expect((badPayload.objectValue?["parsed"]) == (.bool(false)))
    #expect((badPayload.objectValue?["parse_error"]?.stringValue) != nil)
    #expect((badPayload.objectValue?["value"]) == (.null))
  }

  @Test
  func testSkillsFrontmatterRejectsBadInputs() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "skill-frontmatter",
      content:
        """
        ---
        name: skill-frontmatter
        description: Read metadata.
        ---
        # Body
        """
    )
    let skillDirectory = root.appendingPathComponent("skill-frontmatter", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: skillDirectory.appendingPathComponent("bad.md"))
    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)]
        ))
    )

    expectThrows(
      try registry.callTool(
        name: "skills.frontmatter",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-frontmatter"),
          "path": .string("../outside.md"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.frontmatter",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-frontmatter"),
          "path": .string("references"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.frontmatter",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-frontmatter"),
          "path": .string("bad.md"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.frontmatter",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-frontmatter"),
          "format": .string("json"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("format"))
    }
  }

  @Test
  func testSkillsTablesExtractsSkillPackageMarkdownTables() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "table-skill",
      content:
        """
        ---
        name: table-skill
        description: Table skill.
        ---
        # Table Skill
        """
    )
    let skillDirectory = root.appendingPathComponent("table-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    # Reference

    | Name | Count | Note |
    | :--- | ---: | :---: |
    | Alpha | 1 | ok |
    | Short | 3 |

    ```md
    | Hidden | Value |
    | --- | --- |
    | X | Y |
    ```
    """.write(
      to: skillDirectory.appendingPathComponent("references/table.md"),
      atomically: true,
      encoding: .utf8
    )

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)]
        ))
    )

    let result = try registry.callTool(
      name: "skills.tables",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("table-skill"),
        "path": .string("references/table.md"),
        "max_tables": .number(10),
        "max_rows_per_table": .number(10),
      ])
    )
    let payload = try decodeTextPayload(result)
    let tables = try #require(payload.objectValue?["tables"]?.arrayValue)
    let first = try #require(tables.first?.objectValue)
    let firstRows = try #require(first["rows"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("skills.tables")))
    #expect((payload.objectValue?["root_id"]) == (.string("local")))
    #expect((payload.objectValue?["name"]) == (.string("table-skill")))
    #expect((payload.objectValue?["path"]) == (.string("references/table.md")))
    #expect((payload.objectValue?["include_code_blocks"]) == (.bool(false)))
    #expect((payload.objectValue?["table_count"]) == (.number(1)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((first["start_line"]) == (.number(3)))
    #expect((first["headers"]) == (.array([.string("Name"), .string("Count"), .string("Note")])))
    #expect(
      (first["alignments"]) == (.array([.string("left"), .string("right"), .string("center")])))
    #expect((first["row_count"]) == (.number(2)))
    #expect(
      (firstRows[0].objectValue?["cells"])
        == (.array([.string("Alpha"), .string("1"), .string("ok")])))
    #expect((firstRows[1].objectValue?["missing_cell_count"]) == (.number(1)))
    #expect(
      (firstRows[1].objectValue?["cells"])
        == (.array([.string("Short"), .string("3"), .string("")])))
    #expect(
      (payload.objectValue?["read_file_context"]?.objectValue?["tool"])
        == (.string("skills.read_file")))
    #expect(
      (payload.objectValue?["link_check_context"]?.objectValue?["tool"])
        == (.string("skills.link_check")))

    let codeBlockResult = try registry.callTool(
      name: "skills.tables",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("table-skill"),
        "path": .string("references/table.md"),
        "include_code_blocks": .bool(true),
      ])
    )
    let codeBlockPayload = try decodeTextPayload(codeBlockResult)
    #expect((codeBlockPayload.objectValue?["table_count"]) == (.number(2)))

    let truncatedResult = try registry.callTool(
      name: "skills.tables",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("table-skill"),
        "path": .string("references/table.md"),
        "max_rows_per_table": .number(1),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedTable = try #require(
      truncatedPayload.objectValue?["tables"]?.arrayValue?.first
    ).objectValue
    #expect((truncatedPayload.objectValue?["row_truncated_table_count"]) == (.number(1)))
    #expect((truncatedTable?["row_result_truncated"]) == (.bool(true)))
    #expect((truncatedTable?["returned_row_count"]) == (.number(1)))
  }

  @Test
  func testSkillsTablesRejectsBadInputs() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "table-bad-skill",
      content:
        """
        ---
        name: table-bad-skill
        description: Bad table skill.
        ---
        # Table Bad Skill
        """
    )
    let skillDirectory = root.appendingPathComponent("table-bad-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(
      to: skillDirectory.appendingPathComponent("references/binary.md")
    )

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)],
          maxBytesPerSkill: 128
        ))
    )

    expectThrows(
      try registry.callTool(
        name: "skills.tables",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("table-bad-skill"),
          "path": .string("../outside.md"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.tables",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("table-bad-skill"),
          "path": .string("references"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.tables",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("table-bad-skill"),
          "path": .string("references/binary.md"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("valid UTF-8"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.tables",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("table-bad-skill"),
          "max_tables": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_tables"))
    }
  }

  @Test
  func testSkillsLinksReturnsBoundedMechanicalSkillLinks() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "link-skill",
      content:
        """
        ---
        name: link-skill
        description: Link skill.
        ---
        # Link Skill

        See [Guide](references/guide.md#usage "Guide docs") and ![Asset](assets/icon.png).
        Use [API][api-ref] and [MissingRef][missing-ref].
        Visit <https://example.com/docs>.

        [api-ref]: references/guide.md#custom "Guide Reference"

        ```md
        [Ignored](secret.md)
        ```
        """
    )
    let skillDirectory = root.appendingPathComponent("link-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("assets", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "# Usage\n\n<a id=\"custom\"></a>\n".write(
      to: skillDirectory.appendingPathComponent("references/guide.md"),
      atomically: true,
      encoding: .utf8
    )
    try Data([137, 80, 78, 71]).write(to: skillDirectory.appendingPathComponent("assets/icon.png"))

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)]
        ))
    )

    let result = try registry.callTool(
      name: "skills.links",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("link-skill"),
        "max_links": .number(10),
      ])
    )
    let payload = try decodeTextPayload(result)
    let links = try #require(payload.objectValue?["links"]?.arrayValue)
    func link(label: String) -> [String: JSONValue]? {
      links.first { $0.objectValue?["label"] == .string(label) }?.objectValue
    }
    let guide = try #require(link(label: "Guide"))
    let asset = try #require(link(label: "Asset"))
    let api = try #require(link(label: "API"))
    let missingRef = try #require(link(label: "MissingRef"))
    let definition = try #require(
      links.first { $0.objectValue?["kind"] == .string("reference_definition") }?.objectValue)
    let autolink = try #require(
      links.first { $0.objectValue?["kind"] == .string("autolink") }?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("skills.links")))
    #expect((payload.objectValue?["root_id"]) == (.string("local")))
    #expect((payload.objectValue?["name"]) == (.string("link-skill")))
    #expect((payload.objectValue?["path"]) == (.string("SKILL.md")))
    #expect((payload.objectValue?["link_count"]) == (.number(6)))
    #expect((payload.objectValue?["returned_count"]) == (.number(6)))
    #expect((payload.objectValue?["local_count"]) == (.number(4)))
    #expect((payload.objectValue?["external_count"]) == (.number(1)))
    #expect((payload.objectValue?["image_count"]) == (.number(1)))
    #expect((payload.objectValue?["reference_definition_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((guide["destination"]) == (.string("references/guide.md#usage")))
    #expect((guide["resolved_destination"]) == (.string("references/guide.md#usage")))
    #expect(
      (guide["target"]?.objectValue?["target_skill_relative_path"])
        == (.string("references/guide.md")))
    #expect((guide["target"]?.objectValue?["fragment"]) == (.string("usage")))
    #expect(
      (guide["target_context"]?.objectValue?["read_context"]?.objectValue?["arguments"]?
        .objectValue?["path"]) == (.string("references/guide.md")))
    #expect((asset["is_image"]) == (.bool(true)))
    #expect(
      (asset["target"]?.objectValue?["target_skill_relative_path"]) == (.string("assets/icon.png")))
    #expect((api["destination"]) == (.null))
    #expect((api["resolved_destination"]) == (.string("references/guide.md#custom")))
    #expect((api["resolved_via_reference_definition"]) == (.bool(true)))
    #expect((api["reference_definition_line"]) == (.number(11)))
    #expect((api["target"]?.objectValue?["fragment"]) == (.string("custom")))
    #expect((missingRef["resolved_destination"]) == (.null))
    #expect((missingRef["target"]) == (.null))
    #expect((definition["destination"]) == (.string("references/guide.md#custom")))
    #expect((definition["title"]) == (.string("Guide Reference")))
    #expect((autolink["target"]?.objectValue?["kind"]) == (.string("url")))
    #expect((autolink["target"]?.objectValue?["scheme"]) == (.string("https")))
    #expect(
      (payload.objectValue?["link_check_context"]?.objectValue?["tool"])
        == (.string("skills.link_check")))

    let truncatedResult = try registry.callTool(
      name: "skills.links",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("link-skill"),
        "include_images": .bool(false),
        "max_links": .number(1),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["include_images"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["link_count"]) == (.number(5)))
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let codeBlockResult = try registry.callTool(
      name: "skills.links",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("link-skill"),
        "include_code_blocks": .bool(true),
        "max_links": .number(10),
      ])
    )
    let codeBlockPayload = try decodeTextPayload(codeBlockResult)
    #expect((codeBlockPayload.objectValue?["link_count"]) == (.number(7)))
  }

  @Test
  func testSkillsLinksRejectsBadInputs() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "link-bad-skill",
      content:
        """
        ---
        name: link-bad-skill
        description: Bad link inventory skill.
        ---
        # Bad Link Skill
        """
    )
    let skillDirectory = root.appendingPathComponent("link-bad-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(
      to: skillDirectory.appendingPathComponent("references/binary.md")
    )

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)],
          maxBytesPerSkill: 128
        ))
    )

    expectThrows(
      try registry.callTool(
        name: "skills.links",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("link-bad-skill"),
          "path": .string("../outside.md"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.links",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("link-bad-skill"),
          "path": .string("references"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.links",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("link-bad-skill"),
          "path": .string("references/binary.md"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("valid UTF-8"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.links",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("link-bad-skill"),
          "max_links": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_links"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.links",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("link-bad-skill"),
          "max_bytes": .number(1024),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("skills.max_bytes_per_skill"))
    }
  }

  @Test
  func testSkillsLinkCheckReportsSkillLocalBrokenAndUncheckedLinks() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "doc-skill",
      content:
        """
        ---
        name: doc-skill
        description: Documentation skill.
        ---
        # Doc Skill

        [Guide](references/guide.md#usage)
        [Missing](references/missing.md)
        [Outside](../outside.md)
        [External](https://example.com)
        [Ref][guide-ref]
        [NoRef][missing-ref]
        ![Asset](assets/icon.png)
        [Bad Fragment](references/guide.md#missing)
        [Script](scripts/check.py)
        [Empty]()

        [guide-ref]: references/guide.md#custom
        """
    )
    let skillDirectory = root.appendingPathComponent("doc-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("assets", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("scripts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    # Usage

    <a id="custom"></a>
    """.write(
      to: skillDirectory.appendingPathComponent("references/guide.md"),
      atomically: true,
      encoding: .utf8
    )
    try Data([137, 80, 78, 71]).write(to: skillDirectory.appendingPathComponent("assets/icon.png"))
    try "print('noop')\n".write(
      to: skillDirectory.appendingPathComponent("scripts/check.py"),
      atomically: true,
      encoding: .utf8
    )

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)]
        ))
    )

    let result = try registry.callTool(
      name: "skills.link_check",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("doc-skill"),
        "max_target_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)
    let checks = try #require(payload.objectValue?["checks"]?.arrayValue)
    let byLabel = Dictionary(
      uniqueKeysWithValues: checks.compactMap { check -> (String, [String: JSONValue])? in
        guard let object = check.objectValue,
          let label = object["label"]?.stringValue
        else {
          return nil
        }
        return (label, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("skills.link_check")))
    #expect((payload.objectValue?["path"]) == (.string("SKILL.md")))
    #expect((payload.objectValue?["check_count"]) == (.number(11)))
    #expect((payload.objectValue?["ok_count"]) == (.number(5)))
    #expect((payload.objectValue?["broken_count"]) == (.number(5)))
    #expect((payload.objectValue?["unchecked_count"]) == (.number(1)))
    #expect((payload.objectValue?["reference_definition_count"]) == (.number(1)))
    #expect((byLabel["Guide"]?["status"]) == (.string("ok")))
    #expect(
      (byLabel["Guide"]?["target"]?.objectValue?["target_skill_relative_path"])
        == (.string("references/guide.md")))
    #expect((byLabel["Guide"]?["target"]?.objectValue?["fragment_found"]) == (.bool(true)))
    #expect((byLabel["Missing"]?["status"]) == (.string("missing_target")))
    #expect((byLabel["Outside"]?["status"]) == (.string("outside_skill")))
    #expect((byLabel["Outside"]?["target"]?.objectValue?["target_inside_skill"]) == (.bool(false)))
    #expect((byLabel["External"]?["status"]) == (.string("external_unchecked")))
    #expect((byLabel["Ref"]?["status"]) == (.string("ok")))
    #expect((byLabel["Ref"]?["resolved_via_reference_definition"]) == (.bool(true)))
    #expect((byLabel["NoRef"]?["status"]) == (.string("missing_reference_definition")))
    #expect((byLabel["Asset"]?["status"]) == (.string("ok")))
    #expect((byLabel["Bad Fragment"]?["status"]) == (.string("missing_fragment")))
    #expect((byLabel["Script"]?["status"]) == (.string("ok")))
    #expect((byLabel["Empty"]?["status"]) == (.string("empty_destination")))

    let withoutDefinitionsResult = try registry.callTool(
      name: "skills.link_check",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("doc-skill"),
        "include_reference_definitions": .bool(false),
      ])
    )
    let withoutDefinitionsPayload = try decodeTextPayload(withoutDefinitionsResult)
    #expect((withoutDefinitionsPayload.objectValue?["check_count"]) == (.number(10)))
    #expect((withoutDefinitionsPayload.objectValue?["ok_count"]) == (.number(4)))
  }

  @Test
  func testSkillsOutlineReturnsBoundedMechanicalSkillFileMarkers() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "outline-skill",
      content:
        """
        ---
        name: outline-skill
        description: Outline skill.
        ---
        # Outline Skill

        ## Setup

        ```markdown
        # Not a heading
        ```

        ### Details
        """
    )
    let skillDirectory = root.appendingPathComponent("outline-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("scripts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    import Foundation

    public struct Runner {
      func run() {}
    }
    """.write(
      to: skillDirectory.appendingPathComponent("scripts/runner.swift"),
      atomically: true,
      encoding: .utf8
    )

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)]
        ))
    )

    let markdownResult = try registry.callTool(
      name: "skills.outline",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("outline-skill"),
        "max_results": .number(2),
      ])
    )
    let markdownPayload = try decodeTextPayload(markdownResult)
    let markdownItems = try #require(markdownPayload.objectValue?["items"]?.arrayValue)

    #expect((markdownPayload.objectValue?["operation"]) == (.string("skills.outline")))
    #expect((markdownPayload.objectValue?["path"]) == (.string("SKILL.md")))
    #expect((markdownPayload.objectValue?["language"]) == (.string("markdown")))
    #expect((markdownPayload.objectValue?["outline_count"]) == (.number(3)))
    #expect((markdownPayload.objectValue?["returned_count"]) == (.number(2)))
    #expect((markdownPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((markdownItems[0].objectValue?["kind"]) == (.string("heading")))
    #expect((markdownItems[0].objectValue?["name"]) == (.string("Outline Skill")))
    #expect((markdownItems[1].objectValue?["level"]) == (.number(2)))
    #expect(
      (markdownPayload.objectValue?["read_file_context"]?.objectValue?["tool"])
        == (.string("skills.read_file")))
    #expect(
      (markdownPayload.objectValue?["link_check_context"]?.objectValue?["tool"])
        == (.string("skills.link_check")))

    let sourceResult = try registry.callTool(
      name: "skills.outline",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("outline-skill"),
        "path": .string("scripts/runner.swift"),
        "include_imports": .bool(true),
      ])
    )
    let sourcePayload = try decodeTextPayload(sourceResult)
    let sourceItems = try #require(sourcePayload.objectValue?["items"]?.arrayValue)

    #expect((sourcePayload.objectValue?["language"]) == (.string("swift")))
    #expect((sourcePayload.objectValue?["link_check_context"]) == (.null))
    #expect((sourceItems[0].objectValue?["kind"]) == (.string("import")))
    #expect((sourceItems[0].objectValue?["name"]) == (.string("Foundation")))
    #expect((sourceItems[1].objectValue?["kind"]) == (.string("struct")))
    #expect((sourceItems[1].objectValue?["name"]) == (.string("Runner")))
    #expect((sourceItems[2].objectValue?["kind"]) == (.string("function")))
    #expect((sourceItems[2].objectValue?["name"]) == (.string("run")))
  }

  @Test
  func testSkillsOutlineRejectsBadInputs() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "outline-bad-skill",
      content:
        """
        ---
        name: outline-bad-skill
        description: Outline bad skill.
        ---
        # Outline Bad Skill
        """
    )
    let skillDirectory = root.appendingPathComponent("outline-bad-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0, 1, 2, 255]).write(
      to: skillDirectory.appendingPathComponent("references/binary.md"))

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)],
          maxBytesPerSkill: 128
        ))
    )

    expectThrows(
      try registry.callTool(
        name: "skills.outline",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("outline-bad-skill"),
          "path": .string("../outside.md"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.outline",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("outline-bad-skill"),
          "path": .string("references"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.outline",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("outline-bad-skill"),
          "path": .string("references/binary.md"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("valid UTF-8"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.outline",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("outline-bad-skill"),
          "max_bytes": .number(1024),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("skills.max_bytes_per_skill"))
    }
  }

  @Test
  func testSkillsSectionExtractsExactHeadingSection() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "section-skill",
      content:
        """
        ---
        name: section-skill
        description: Section skill.
        ---
        # Section Skill

        ## Install
        First
        ### Details
        Deep
        ```md
        ## Ignored
        ```
        ## Usage
        Use it

        ## Install
        Second
        """
    )

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)]
        ))
    )

    let result = try registry.callTool(
      name: "skills.section",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("section-skill"),
        "heading": .string("Install"),
        "level": .number(2),
      ])
    )
    let payload = try decodeTextPayload(result)
    let section = try #require(payload.objectValue?["section"]?.objectValue)
    let followingHeading = try #require(payload.objectValue?["following_heading"]?.objectValue)
    let content = try #require(section["content"]?.stringValue)

    #expect((payload.objectValue?["operation"]) == (.string("skills.section")))
    #expect((payload.objectValue?["root_id"]) == (.string("local")))
    #expect((payload.objectValue?["name"]) == (.string("section-skill")))
    #expect((payload.objectValue?["path"]) == (.string("SKILL.md")))
    #expect((payload.objectValue?["matched"]) == (.bool(true)))
    #expect((payload.objectValue?["match_count"]) == (.number(2)))
    #expect((payload.objectValue?["matched_heading"]?.objectValue?["line"]) == (.number(7)))
    #expect((followingHeading["name"]) == (.string("Usage")))
    #expect((followingHeading["line"]) == (.number(14)))
    #expect((section["start_line"]) == (.number(7)))
    #expect((section["end_line"]) == (.number(13)))
    #expect((section["line_count"]) == (.number(7)))
    #expect(content.contains("## Install"))
    #expect(content.contains("## Ignored"))
    #expect(!(content.contains("## Usage")))
    #expect((section["section_may_be_truncated"]) == (.bool(false)))
    #expect(
      (payload.objectValue?["read_file_context"]?.objectValue?["tool"])
        == (.string("skills.read_file")))
    #expect(
      (payload.objectValue?["outline_context"]?.objectValue?["tool"]) == (.string("skills.outline"))
    )

    let secondResult = try registry.callTool(
      name: "skills.section",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("section-skill"),
        "heading": .string("Install"),
        "level": .number(2),
        "occurrence": .number(2),
        "include_heading": .bool(false),
      ])
    )
    let secondPayload = try decodeTextPayload(secondResult)
    let secondSection = try #require(secondPayload.objectValue?["section"]?.objectValue)
    #expect((secondPayload.objectValue?["matched"]) == (.bool(true)))
    #expect((secondPayload.objectValue?["following_heading"]) == (.null))
    #expect((secondSection["start_line"]) == (.number(18)))
    #expect((secondSection["end_line"]) == (.number(18)))
    #expect((secondSection["content"]) == (.string("Second")))

    let truncatedResult = try registry.callTool(
      name: "skills.section",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("section-skill"),
        "heading": .string("Install"),
        "max_section_bytes": .number(8),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedSection = try #require(truncatedPayload.objectValue?["section"]?.objectValue)
    #expect((truncatedSection["content_truncated"]) == (.bool(true)))

    let missingResult = try registry.callTool(
      name: "skills.section",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("section-skill"),
        "heading": .string("Missing"),
      ])
    )
    let missingPayload = try decodeTextPayload(missingResult)
    #expect((missingPayload.objectValue?["matched"]) == (.bool(false)))
    #expect((missingPayload.objectValue?["section"]) == (.null))
    #expect(
      (missingPayload.objectValue?["failure"]?.objectValue?["reason"])
        == (.string("missing_heading")))
  }

  @Test
  func testSkillsSectionRejectsBadInputs() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "section-bad-skill",
      content:
        """
        ---
        name: section-bad-skill
        description: Bad section skill.
        ---
        # Section Bad Skill
        """
    )
    let skillDirectory = root.appendingPathComponent("section-bad-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(
      to: skillDirectory.appendingPathComponent("references/binary.md")
    )

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)],
          maxBytesPerSkill: 128
        ))
    )

    expectThrows(
      try registry.callTool(
        name: "skills.section",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("section-bad-skill"),
          "path": .string("../outside.md"),
          "heading": .string("Intro"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.section",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("section-bad-skill"),
          "path": .string("references"),
          "heading": .string("Intro"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.section",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("section-bad-skill"),
          "path": .string("references/binary.md"),
          "heading": .string("Intro"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("valid UTF-8"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.section",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("section-bad-skill"),
          "heading": .string("Intro"),
          "level": .number(7),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("level"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.section",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("section-bad-skill"),
          "heading": .string("Intro"),
          "occurrence": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("occurrence"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.section",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("section-bad-skill"),
          "heading": .string("Intro"),
          "max_section_bytes": .number(1024),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("skills.max_bytes_per_skill"))
    }
  }

  @Test
  func testSkillsLinkCheckRejectsBadInputs() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "bad-link-skill",
      content:
        """
        ---
        name: bad-link-skill
        description: Bad link skill.
        ---
        # Bad Link Skill
        """
    )
    let skillDirectory = root.appendingPathComponent("bad-link-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0, 1, 2, 255]).write(
      to: skillDirectory.appendingPathComponent("references/binary.md"))

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)],
          maxBytesPerSkill: 128
        ))
    )

    expectThrows(
      try registry.callTool(
        name: "skills.link_check",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("bad-link-skill"),
          "path": .string("../outside.md"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.link_check",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("bad-link-skill"),
          "path": .string("references"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.link_check",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("bad-link-skill"),
          "path": .string("references/binary.md"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("valid UTF-8"))
    }

    expectThrows(
      try registry.callTool(
        name: "skills.link_check",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("bad-link-skill"),
          "max_bytes": .number(1024),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("skills.max_bytes_per_skill"))
    }
  }

  @Test
  func testSkillsValidateReportsPackageIssues() throws {
    let root = try temporaryDirectory()
    let badSkill = root.appendingPathComponent("bad-skill", isDirectory: true)
    try FileManager.default.createDirectory(at: badSkill, withIntermediateDirectories: true)
    try """
    ---
    name: Bad_Skill
    ---
    # Bad Skill
    """.write(
      to: badSkill.appendingPathComponent("SKILL.md"),
      atomically: true,
      encoding: .utf8
    )
    let outside = root.appendingPathComponent("outside.txt")
    try "outside\n".write(to: outside, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: badSkill.appendingPathComponent("outside-link"),
      withDestinationURL: outside
    )

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)]
        ))
    )

    let result = try registry.callTool(
      name: "skills.validate",
      arguments: .object([
        "root_id": .string("local"),
        "name": .string("bad-skill"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let issues = try #require(payload.objectValue?["issues"]?.arrayValue)
    let codes = issues.compactMap { $0.objectValue?["code"]?.stringValue }

    #expect((payload.objectValue?["valid"]) == (.bool(false)))
    #expect(codes.contains("missing_description"))
    #expect(codes.contains("noncanonical_name"))
    #expect(codes.contains("directory_name_mismatch"))
    #expect(codes.contains("symlink_escape"))
    #expect((payload.objectValue?["error_count"]) == (.number(2)))
    #expect(
      (payload.objectValue?["frontmatter"]?.objectValue?["has_opening_delimiter"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["frontmatter"]?.objectValue?["has_closing_delimiter"]) == (.bool(true)))
  }

  @Test
  func testSkillsReadRejectsAmbiguousOrUnknownSkill() throws {
    let firstRoot = try temporaryDirectory()
    let secondRoot = try temporaryDirectory()
    try writeSkill(root: firstRoot, directory: "shared", content: "---\nname: shared\n---\n# One\n")
    try writeSkill(
      root: secondRoot, directory: "shared", content: "---\nname: shared\n---\n# Two\n")

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [
            SkillRootConfig(id: "one", path: firstRoot.path),
            SkillRootConfig(id: "two", path: secondRoot.path),
          ]
        ))
    )

    expectThrows(
      try registry.callTool(
        name: "skills.read",
        arguments: .object(["name": .string("shared")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("ambiguous"))
    }

    let result = try registry.callTool(
      name: "skills.read",
      arguments: .object([
        "root_id": .string("two"),
        "name": .string("shared"),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["root_id"]) == (.string("two")))
    #expect(payload.objectValue?["content"]?.stringValue?.contains("# Two") == true)

    expectThrows(
      try registry.callTool(
        name: "skills.read",
        arguments: .object(["name": .string("missing")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown skill"))
    }
  }

  @Test
  func testSkillsReadRespectsByteLimitAndRejectsSymlinkEscapes() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "long",
      content: "---\nname: long-skill\n---\n" + String(repeating: "x", count: 80)
    )

    let outside = try temporaryDirectory()
    try writeSkill(
      root: outside,
      directory: "escaped",
      content: "---\nname: escaped-skill\n---\n# Escape\n"
    )
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escaped-link"),
      withDestinationURL: outside.appendingPathComponent("escaped")
    )

    let registry = GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "local", path: root.path)],
          maxBytesPerSkill: 32
        ))
    )

    let readResult = try registry.callTool(
      name: "skills.read",
      arguments: .object(["name": .string("long-skill")])
    )
    let readPayload = try decodeTextPayload(readResult)

    #expect((readPayload.objectValue?["max_bytes"]) == (.number(32)))
    #expect((readPayload.objectValue?["content_truncated"]) == (.bool(true)))
    #expect((readPayload.objectValue?["valid_utf8"]) == (.bool(true)))

    let listResult = try registry.callTool(name: "skills.list", arguments: .object([:]))
    let listPayload = try decodeTextPayload(listResult)
    let names = listPayload.objectValue?["skills"]?.arrayValue?.map { $0.objectValue?["name"] }

    #expect((names) == ([.string("long-skill")]))

    expectThrows(
      try registry.callTool(
        name: "skills.read",
        arguments: .object([
          "name": .string("long-skill"),
          "max_bytes": .number(33),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("skills.max_bytes_per_skill"))
    }
  }

  @Test
  func testProcessListReturnsGatewayManagedSessions() throws {
    let processManager = FakeProcessManager()
    processManager.snapshots = [
      ManagedProcessSnapshot(
        processID: "proc-1",
        isRunning: true,
        exitCode: nil,
        stdout: "ready\n",
        stderr: "",
        stdoutTruncated: false,
        stderrTruncated: false
      )
    ]
    let registry = GatewayToolRegistry(
      configuration: .fixture(),
      processManager: processManager
    )

    let result = try registry.callTool(name: "process.list", arguments: .object([:]))
    let payload = try decodeTextPayload(result)
    let process = try #require(payload.objectValue?["processes"]?.arrayValue?.first?.objectValue)

    #expect((process["process_id"]) == (.string("proc-1")))
    #expect((process["is_running"]) == (.bool(true)))
    #expect((process["stdout"]) == (.string("ready\n")))
  }

  @Test
  func testCLIExecRejectsUnknownID() {
    let registry = GatewayToolRegistry(configuration: .fixture())

    expectThrows(
      try registry.callTool(
        name: "cli.exec",
        arguments: .object([
          "id": .string("missing"),
          "argv": .array([.string("--version")]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown CLI command id"))
    }
  }

  @Test
  func testCLIExecRejectsCommandThatDisallowsArbitraryArgs() {
    let registry = GatewayToolRegistry(
      configuration: .fixture(
        cli: CLISectionConfig(commands: [
          CLICommandConfig(id: "echo", executable: "/bin/echo", allowAnyArgs: false)
        ])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "cli.exec",
        arguments: .object([
          "id": .string("echo"),
          "argv": .array([.string("hello")]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("does not allow arbitrary args"))
    }
  }

  @Test
  func testProcessSpawnRejectsCommandThatDisallowsArbitraryArgs() {
    let registry = GatewayToolRegistry(
      configuration: .fixture(
        cli: CLISectionConfig(commands: [
          CLICommandConfig(id: "echo", executable: "/bin/echo", allowAnyArgs: false)
        ])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "process.spawn",
        arguments: .object([
          "id": .string("echo"),
          "argv": .array([.string("hello")]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("does not allow arbitrary args"))
    }
  }

  @Test
  func testConfiguredMCPBackedToolProxiesDownstreamCall() throws {
    let mcp = FakeDownstreamMCPClient()
    let config = GatewayConfiguration.fixture(
      tools: [
        ToolConfig(
          name: "fake.sample_typed",
          description: "Call sample directly.",
          adapter: .mcp,
          source: "fake",
          tool: "sample",
          inputSchema:
            #"{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}"#
        )
      ]
    )
    let registry = GatewayToolRegistry(configuration: config, mcpClient: mcp)

    let names = try registry.listTools().map(\.name)
    #expect(names.contains("fake.sample_typed"))
    let configuredTool = try #require(
      try registry.listTools().first { $0.name == "fake.sample_typed" })
    #expect((configuredTool.outputSchema) == nil)

    let result = try registry.callTool(
      name: "fake.sample_typed",
      arguments: .object(["value": .string("typed")])
    )

    #expect((result.objectValue?["isError"]) == (.bool(false)))
    #expect((mcp.calls.first?.tool) == ("sample"))
    #expect((mcp.calls.first?.arguments) == (.object(["value": .string("typed")])))
  }

  @Test
  func testShellRunIsDisabledByDefault() {
    let registry = GatewayToolRegistry(configuration: .fixture())

    expectThrows(
      try registry.callTool(
        name: "shell.run",
        arguments: .object(["command": .string("echo nope")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("disabled"))
    }
  }

  @Test
  func testDisabledBuiltinRejectsDirectToolCall() {
    let registry = GatewayToolRegistry(configuration: .fixture())

    expectThrows(
      try registry.callTool(
        name: "file.write",
        arguments: .object([
          "path": .string("blocked.txt"),
          "content": .string("blocked"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("disabled"))
    }
  }

  @Test
  func testUnregisteredMCPServerRejectsDirectToolCalls() {
    let registry = GatewayToolRegistry(configuration: .fixture())

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.list",
        arguments: .object(["server": .string("figma")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.call",
        arguments: .object([
          "server": .string("figma"),
          "tool": .string("get_screenshot"),
          "arguments": .object([:]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.describe",
        arguments: .object([
          "server": .string("figma"),
          "tool": .string("get_screenshot"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.resources.list",
        arguments: .object(["server": .string("figma")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.resources.read",
        arguments: .object([
          "server": .string("figma"),
          "uri": .string("file:///missing"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.prompts.list",
        arguments: .object(["server": .string("figma")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.prompts.get",
        arguments: .object([
          "server": .string("figma"),
          "name": .string("review"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }
  }

  @Test
  func testUnexposedTopLevelToolNameRejectsDirectToolCall() {
    let registry = GatewayToolRegistry(configuration: .fixture())

    expectThrows(
      try registry.callTool(
        name: "figma.get_screenshot",
        arguments: .object([:])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown tool"))
    }
  }

  @Test
  func testReexportPassesArgumentsMatchingTheAdvertisedDownstreamSchema() throws {
    let mcp = FakeDownstreamMCPClient()
    let configuration = GatewayConfiguration.fixture(
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "fake",
          transport: .stdio,
          command: "/bin/cat",
          exposure: .reexport,
          prefix: "fake",
          allowedTools: ["sample"]
        )
      ])
    )
    let registry = GatewayToolRegistry(configuration: configuration, mcpClient: mcp)

    _ = try registry.callTool(
      name: "fake.sample",
      arguments: .object(["value": .string("direct")])
    )

    #expect((mcp.calls.first?.tool) == ("sample"))
    #expect((mcp.calls.first?.arguments) == (.object(["value": .string("direct")])))
  }

  @Test
  func testMCPToolsListAndCallUseDownstreamClient() throws {
    let mcp = FakeDownstreamMCPClient()
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let listResult = try registry.callTool(
      name: "mcp.tools.list",
      arguments: .object(["server": .string("fake")])
    )
    let listPayload = try decodeTextPayload(listResult)

    #expect((listPayload.arrayValue?.first?.objectValue?["name"]) == (.string("sample")))

    let callResult = try registry.callTool(
      name: "mcp.tools.call",
      arguments: .object([
        "server": .string("fake"),
        "tool": .string("sample"),
        "request_id": .string("request-1"),
        "arguments": .object(["value": .string("x")]),
      ])
    )
    let callPayload = try decodeTextPayload(callResult)

    #expect(
      (callPayload.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"])
        == (.string("called")))
    #expect((mcp.calls.first?.tool) == ("sample"))
    #expect((mcp.calls.first?.requestID) == ("request-1"))
  }

  @Test
  func testMCPToolCallCanStartWithoutWaitingForResult() throws {
    let mcp = FakeDownstreamMCPClient()
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let result = try registry.callTool(
      name: "mcp.tools.call",
      arguments: .object([
        "server": .string("fake"),
        "tool": .string("sample"),
        "request_id": .string("request-started"),
        "wait_for_result": .bool(false),
        "arguments": .object(["value": .string("x")]),
      ])
    )

    #expect((try decodeTextPayload(result).objectValue?["state"]) == (.string("running")))
    #expect((mcp.startedCalls.first?.tool) == ("sample"))
    #expect((mcp.startedCalls.first?.requestID) == ("request-started"))
  }

  @Test
  func testMCPToolCallRequiresRequestIDWhenStartingWithoutWaiting() {
    let registry = GatewayToolRegistry(
      configuration: .fixture(),
      mcpClient: FakeDownstreamMCPClient()
    )

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.call",
        arguments: .object([
          "server": .string("fake"),
          "tool": .string("sample"),
          "wait_for_result": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("request_id is required"))
    }
  }

  @Test
  func testMCPToolDiscoveryAndCallsAreLimitedToReviewedTools() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.tools = [
      MCPTool(
        name: "reviewed",
        description: "Reviewed tool.",
        inputSchema: .object(["type": .string("object")])
      ),
      MCPTool(
        name: "shell",
        description: "Unreviewed shell tool.",
        inputSchema: .object(["type": .string("object")])
      ),
    ]
    let configuration = GatewayConfiguration.fixture(
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "fake",
          transport: .stdio,
          command: "/bin/cat",
          allowedTools: ["reviewed"]
        )
      ])
    )
    let registry = GatewayToolRegistry(configuration: configuration, mcpClient: mcp)

    let listed = try decodeTextPayload(
      registry.callTool(
        name: "mcp.tools.list",
        arguments: .object(["server": .string("fake")])
      )
    )
    #expect(
      (listed.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }) == (["reviewed"]))

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.call",
        arguments: .object([
          "server": .string("fake"),
          "tool": .string("shell"),
          "arguments": .object([:]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not approved"))
    }
    #expect(mcp.calls.isEmpty)
  }

  @Test
  func testMCPEventsRequestsAndCancellationUseDownstreamClient() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.events = .object([
      "server": .string("fake"),
      "next_cursor": .number(8),
      "events": .array([
        .object([
          "cursor": .number(8),
          "kind": .string("notifications/tools/list_changed"),
        ])
      ]),
    ])
    mcp.activeRequestPayload = .object([
      "server": .string("fake"),
      "requests": .array([
        .object(["request_id": .string("request-1")])
      ]),
    ])
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let eventsResult = try registry.callTool(
      name: "mcp.events.read",
      arguments: .object([
        "server": .string("fake"),
        "after_cursor": .number(3),
        "max_results": .number(25),
      ])
    )
    #expect((try decodeTextPayload(eventsResult).objectValue?["next_cursor"]) == (.number(8)))
    #expect((mcp.eventReads) == ([.init(afterCursor: 3, maxResults: 25)]))

    let requestsResult = try registry.callTool(
      name: "mcp.requests.list",
      arguments: .object(["server": .string("fake")])
    )
    #expect(
      (try decodeTextPayload(requestsResult).objectValue?["requests"]?.arrayValue?.count) == (1))

    let cancelResult = try registry.callTool(
      name: "mcp.requests.cancel",
      arguments: .object([
        "server": .string("fake"),
        "request_id": .string("request-1"),
        "reason": .string("test"),
      ])
    )
    #expect((try decodeTextPayload(cancelResult).objectValue?["cancelled"]) == (.bool(true)))
    #expect((mcp.cancellations) == ([.init(requestID: "request-1", reason: "test")]))
  }

  @Test
  func testMCPToolsDescribeReturnsExactDownstreamToolDefinition() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.tools = [
      MCPTool(
        name: "sample",
        description: "Sample downstream tool.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object(["value": .object(["type": .string("string")])]),
        ])
      ),
      MCPTool(
        name: "other",
        description: "Other downstream tool.",
        inputSchema: .object(["type": .string("object")])
      ),
    ]
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let result = try registry.callTool(
      name: "mcp.tools.describe",
      arguments: .object([
        "server": .string("fake"),
        "tool": .string("sample"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let definition = try #require(payload.objectValue?["definition"]?.objectValue)
    let callContext = try #require(payload.objectValue?["call_context"]?.objectValue)
    let callArguments = try #require(callContext["arguments"]?.objectValue)

    #expect((payload.objectValue?["server"]) == (.string("fake")))
    #expect((payload.objectValue?["tool"]) == (.string("sample")))
    #expect((payload.objectValue?["tool_count"]) == (.number(2)))
    #expect((definition["name"]) == (.string("sample")))
    #expect((definition["description"]) == (.string("Sample downstream tool.")))
    #expect(
      (definition["inputSchema"]?.objectValue?["properties"]?.objectValue?["value"]?.objectValue?[
        "type"]) == (.string("string")))
    #expect((callContext["tool"]) == (.string("mcp.tools.call")))
    #expect((callArguments["server"]) == (.string("fake")))
    #expect((callArguments["tool"]) == (.string("sample")))
    #expect((callArguments["arguments"]) == (.object([:])))
  }

  @Test
  func testMCPToolsDescribeRejectsUnknownDownstreamTool() {
    let registry = GatewayToolRegistry(
      configuration: .fixture(), mcpClient: FakeDownstreamMCPClient())

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.describe",
        arguments: .object([
          "server": .string("fake"),
          "tool": .string("missing"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown downstream MCP tool"))
    }
  }

  @Test
  func testMCPResourcesListTemplatesAndReadUseDownstreamClient() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.resources = [
      .object([
        "name": .string("Readme"),
        "uri": .string("file:///workspace/README.md"),
        "mimeType": .string("text/markdown"),
      ])
    ]
    mcp.resourceTemplates = [
      .object([
        "name": .string("File by path"),
        "uriTemplate": .string("file:///workspace/{path}"),
        "mimeType": .string("text/plain"),
      ])
    ]
    mcp.resourceContents = [
      "file:///workspace/README.md": [
        .object([
          "uri": .string("file:///workspace/README.md"),
          "mimeType": .string("text/markdown"),
          "text": .string("# README"),
        ])
      ]
    ]
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let listResult = try registry.callTool(
      name: "mcp.resources.list",
      arguments: .object([
        "server": .string("fake"),
        "cursor": .string("page-1"),
      ])
    )
    let listPayload = try decodeTextPayload(listResult)
    let resources = try #require(listPayload.objectValue?["resources"]?.arrayValue)
    let resource = try #require(resources.first?.objectValue)
    let readContext = try #require(resource["read_context"]?.objectValue)

    #expect((listPayload.objectValue?["server"]) == (.string("fake")))
    #expect((listPayload.objectValue?["cursor"]) == (.string("page-1")))
    #expect((listPayload.objectValue?["resource_count"]) == (.number(1)))
    #expect((resource["uri"]) == (.string("file:///workspace/README.md")))
    #expect((readContext["tool"]) == (.string("mcp.resources.read")))
    #expect(
      (readContext["arguments"]?.objectValue?["uri"]) == (.string("file:///workspace/README.md")))
    #expect((mcp.resourceListCursors) == (["page-1"]))

    let templatesResult = try registry.callTool(
      name: "mcp.resources.templates.list",
      arguments: .object(["server": .string("fake")])
    )
    let templatesPayload = try decodeTextPayload(templatesResult)
    let templates = try #require(templatesPayload.objectValue?["resource_templates"]?.arrayValue)

    #expect((templatesPayload.objectValue?["template_count"]) == (.number(1)))
    #expect((templates.first?.objectValue?["uriTemplate"]) == (.string("file:///workspace/{path}")))

    let readResult = try registry.callTool(
      name: "mcp.resources.read",
      arguments: .object([
        "server": .string("fake"),
        "uri": .string("file:///workspace/README.md"),
      ])
    )
    let readPayload = try decodeTextPayload(readResult)
    let contents = try #require(readPayload.objectValue?["contents"]?.arrayValue)

    #expect((readPayload.objectValue?["server"]) == (.string("fake")))
    #expect((readPayload.objectValue?["uri"]) == (.string("file:///workspace/README.md")))
    #expect((readPayload.objectValue?["content_count"]) == (.number(1)))
    #expect((contents.first?.objectValue?["text"]) == (.string("# README")))
    #expect((mcp.resourceReadURIs) == (["file:///workspace/README.md"]))
  }

  @Test
  func testMCPPromptsListAndGetUseDownstreamClient() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.prompts = [
      .object([
        "name": .string("review"),
        "description": .string("Review selected code."),
        "arguments": .array([
          .object([
            "name": .string("path"),
            "description": .string("Workspace path."),
            "required": .bool(true),
          ])
        ]),
      ])
    ]
    mcp.promptResults = [
      "review": .object([
        "description": .string("Review prompt."),
        "messages": .array([
          .object([
            "role": .string("user"),
            "content": .object([
              "type": .string("text"),
              "text": .string("Review Sources/ComputerMCP/GatewayToolRegistry.swift"),
            ]),
          ])
        ]),
      ])
    ]
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let listResult = try registry.callTool(
      name: "mcp.prompts.list",
      arguments: .object([
        "server": .string("fake"),
        "cursor": .string("page-1"),
      ])
    )
    let listPayload = try decodeTextPayload(listResult)
    let prompts = try #require(listPayload.objectValue?["prompts"]?.arrayValue)
    let prompt = try #require(prompts.first?.objectValue)
    let getContext = try #require(prompt["get_context"]?.objectValue)

    #expect((listPayload.objectValue?["server"]) == (.string("fake")))
    #expect((listPayload.objectValue?["cursor"]) == (.string("page-1")))
    #expect((listPayload.objectValue?["prompt_count"]) == (.number(1)))
    #expect((prompt["name"]) == (.string("review")))
    #expect((getContext["tool"]) == (.string("mcp.prompts.get")))
    #expect((getContext["arguments"]?.objectValue?["name"]) == (.string("review")))
    #expect((mcp.promptListCursors) == (["page-1"]))

    let getResult = try registry.callTool(
      name: "mcp.prompts.get",
      arguments: .object([
        "server": .string("fake"),
        "name": .string("review"),
        "arguments": .object(["path": .string("Sources")]),
      ])
    )
    let getPayload = try decodeTextPayload(getResult)
    let messages = try #require(getPayload.objectValue?["messages"]?.arrayValue)

    #expect((getPayload.objectValue?["server"]) == (.string("fake")))
    #expect((getPayload.objectValue?["name"]) == (.string("review")))
    #expect((getPayload.objectValue?["arguments"]?.objectValue?["path"]) == (.string("Sources")))
    #expect((getPayload.objectValue?["description"]) == (.string("Review prompt.")))
    #expect((getPayload.objectValue?["message_count"]) == (.number(1)))
    #expect(
      (messages.first?.objectValue?["content"]?.objectValue?["text"])
        == (.string("Review Sources/ComputerMCP/GatewayToolRegistry.swift")))
    #expect(
      (mcp.promptGetCalls)
        == ([
          FakeDownstreamMCPClient.PromptGetCall(
            name: "review", arguments: ["path": "Sources"])
        ]))
  }

  @Test
  func testMCPPromptsGetRejectsNonStringArguments() {
    let registry = GatewayToolRegistry(
      configuration: .fixture(), mcpClient: FakeDownstreamMCPClient())

    expectThrows(
      try registry.callTool(
        name: "mcp.prompts.get",
        arguments: .object([
          "server": .string("fake"),
          "name": .string("review"),
          "arguments": .object(["path": .number(1)]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("arguments.path must be a string"))
    }
  }

  @Test
  func testMCPToolsFindFiltersDownstreamToolsDeterministically() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.tools = [
      MCPTool(
        name: "video_read",
        description: "Read video metadata.",
        inputSchema: .object(["type": .string("object")])
      ),
      MCPTool(
        name: "video_comments",
        description: "List comments.",
        inputSchema: .object(["type": .string("object")])
      ),
      MCPTool(
        name: "auth_status",
        description: "Report authenticated account.",
        inputSchema: .object(["type": .string("object")])
      ),
    ]
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let result = try registry.callTool(
      name: "mcp.tools.find",
      arguments: .object([
        "server": .string("fake"),
        "query": .string("video_"),
        "match": .string("prefix"),
        "field": .string("name"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let tools = try #require(payload.objectValue?["tools"]?.arrayValue)

    #expect((payload.objectValue?["tool_count"]) == (.number(3)))
    #expect((payload.objectValue?["result_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect(
      (tools.map { $0.objectValue?["name"] })
        == ([.string("video_read"), .string("video_comments")]))
  }

  @Test
  func testMCPToolsFindCanMatchDescriptionAndReportTruncation() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.tools = [
      MCPTool(name: "one", description: "Export media.", inputSchema: .object([:])),
      MCPTool(name: "two", description: "Export subtitles.", inputSchema: .object([:])),
    ]
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let result = try registry.callTool(
      name: "mcp.tools.find",
      arguments: .object([
        "server": .string("fake"),
        "query": .string("export"),
        "field": .string("description"),
        "max_results": .number(1),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["result_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testMCPToolsFindRejectsBadModes() {
    let registry = GatewayToolRegistry(
      configuration: .fixture(), mcpClient: FakeDownstreamMCPClient())

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.find",
        arguments: .object([
          "server": .string("fake"),
          "query": .string("video"),
          "field": .string("schema"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("field"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.find",
        arguments: .object([
          "server": .string("fake"),
          "query": .string("video"),
          "match": .string("regex"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("match"))
    }
  }

  @Test
  func testMCPServersStatusReportsProviderReadinessWithoutLeakingEnvValues() throws {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent("mcp-server")
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let config = GatewayConfiguration.fixture(
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "local",
          transport: .stdio,
          command: executable.path,
          args: ["--stdio"],
          env: ["LOCAL_MCP_TOKEN": "super-secret-local"],
          cwd: "workspace"
        ),
        MCPServerConfig(
          id: "remote",
          transport: .streamableHTTP,
          url: "https://mcp.example.com/mcp",
          env: ["REMOTE_MCP_TOKEN": "super-secret-remote"],
          exposure: .reexport,
          prefix: "remote",
          allowedTools: ["sample"]
        ),
      ])
    )
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(name: "mcp.servers.status", arguments: .object([:]))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let servers = try #require(payload.objectValue?["servers"]?.arrayValue)
    let local = try #require(servers.first { $0.objectValue?["id"] == .string("local") })
      .objectValue
    let remote = try #require(servers.first { $0.objectValue?["id"] == .string("remote") })
      .objectValue

    #expect(!(text.contains("super-secret-local")))
    #expect(!(text.contains("super-secret-remote")))
    #expect((local?["ready"]) == (.bool(true)))
    #expect((local?["command"]) == (.string(executable.path)))
    #expect(
      (local?["command_resolution"]?.objectValue?["resolved_path"]) == (.string(executable.path)))
    #expect((local?["env"]?.arrayValue?.first?.objectValue?["key"]) == (.string("LOCAL_MCP_TOKEN")))
    #expect((local?["env"]?.arrayValue?.first?.objectValue?["value_redacted"]) == (.bool(true)))

    #expect((remote?["ready"]) == (.bool(true)))
    #expect((remote?["url_status"]?.objectValue?["scheme"]) == (.string("https")))
    #expect((remote?["url_status"]?.objectValue?["host"]) == (.string("mcp.example.com")))
    #expect((remote?["prefix"]) == (.string("remote")))
  }

  @Test
  func testMCPServersStatusCanFilterAndRejectsUnknownServer() throws {
    let config = GatewayConfiguration.fixture(
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "missing",
          transport: .stdio,
          command: "definitely-missing-mcp-server-for-computer-mcp-tests"
        )
      ])
    )
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(
      name: "mcp.servers.status",
      arguments: .object(["server": .string("missing")])
    )
    let payload = try decodeTextPayload(result)
    let server = try #require(payload.objectValue?["servers"]?.arrayValue?.first?.objectValue)

    #expect((server["id"]) == (.string("missing")))
    #expect((server["ready"]) == (.bool(false)))
    #expect((server["command_resolution"]?.objectValue?["exists"]) == (.bool(false)))

    expectThrows(
      try registry.callTool(
        name: "mcp.servers.status",
        arguments: .object(["server": .string("unknown")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }
  }

  @Test
  func testReexportPrefixesDownstreamTools() throws {
    let mcp = FakeDownstreamMCPClient()
    let config = GatewayConfiguration.fixture(
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "fake",
          transport: .stdio,
          command: "/bin/cat",
          exposure: .reexport,
          prefix: "fake",
          allowedTools: ["sample"]
        )
      ])
    )
    let registry = GatewayToolRegistry(configuration: config, mcpClient: mcp)

    let names = try registry.listTools().map(\.name)
    #expect(names.contains("fake.sample"))

    let result = try registry.callTool(
      name: "fake.sample",
      arguments: .object(["arguments": .object(["value": .string("x")])])
    )

    #expect((result.objectValue?["isError"]) == (.bool(false)))
    #expect((mcp.calls.first?.tool) == ("sample"))
  }

  @Test
  func testEnabledFileBuiltinsReadWriteWorkspaceFiles() throws {
    let directory = try temporaryDirectory()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.read", "file.read_files", "file.write"]),
        workspaceDirectory: directory
      )
    )

    let names = try registry.listTools().map(\.name)
    #expect(names.contains("file.read"))
    #expect(names.contains("file.read_files"))
    #expect(names.contains("file.write"))

    let writeResult = try registry.callTool(
      name: "file.write",
      arguments: .object([
        "path": .string("notes/debug.txt"),
        "content": .string("codex ready"),
        "create_directories": .bool(true),
      ])
    )
    let writePayload = try decodeTextPayload(writeResult)
    #expect((writePayload.objectValue?["bytes_written"]) == (.number(11)))

    let readResult = try registry.callTool(
      name: "file.read",
      arguments: .object(["path": .string("notes/debug.txt")])
    )
    let readPayload = try decodeTextPayload(readResult)
    #expect((readPayload.objectValue?["content"]) == (.string("codex ready")))
    #expect((readPayload.objectValue?["truncated"]) == (.bool(false)))

    try "follow-up".write(
      to: directory.appendingPathComponent("notes/todo.md"),
      atomically: true,
      encoding: .utf8
    )
    let batchResult = try registry.callTool(
      name: "file.read_files",
      arguments: .object([
        "paths": .array([.string("notes/debug.txt"), .string("notes/todo.md")]),
        "max_bytes_per_file": .number(64),
      ])
    )
    let batchPayload = try decodeTextPayload(batchResult)
    let files = try #require(batchPayload.objectValue?["files"]?.arrayValue)
    #expect((batchPayload.objectValue?["operation"]) == (.string("file.read_files")))
    #expect((batchPayload.objectValue?["file_count"]) == (.number(2)))
    #expect((batchPayload.objectValue?["truncated_file_count"]) == (.number(0)))
    #expect((files[0].objectValue?["workspace_relative_path"]) == (.string("notes/debug.txt")))
    #expect((files[0].objectValue?["content"]) == (.string("codex ready")))
    #expect((files[1].objectValue?["workspace_relative_path"]) == (.string("notes/todo.md")))
    #expect((files[1].objectValue?["content"]) == (.string("follow-up")))
  }

  @Test
  func testFileReadFilesSupportsBase64AndTruncation() throws {
    let directory = try temporaryDirectory()
    let binaryURL = directory.appendingPathComponent("blob.bin")
    try Data([0xff, 0xfe, 0xfd, 0xfc]).write(to: binaryURL)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.read_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.read_files",
      arguments: .object([
        "paths": .array([.string("blob.bin")]),
        "encoding": .string("base64"),
        "max_bytes_per_file": .number(3),
      ])
    )
    let payload = try decodeTextPayload(result)
    let file = try #require(payload.objectValue?["files"]?.arrayValue?.first?.objectValue)
    #expect((payload.objectValue?["encoding"]) == (.string("base64")))
    #expect((payload.objectValue?["total_bytes_read"]) == (.number(3)))
    #expect((payload.objectValue?["truncated_file_count"]) == (.number(1)))
    #expect((file["content"]) == (.string("//79")))
    #expect((file["bytes_read"]) == (.number(3)))
    #expect((file["truncated"]) == (.bool(true)))
    #expect((file["valid_utf8"]) == (.bool(false)))

    expectThrows(
      try registry.callTool(
        name: "file.read_files",
        arguments: .object([
          "paths": .array([.string(".")])
        ])
      )
    )
  }

  @Test
  func testFileWriteDryRunDoesNotCreateDirectoriesOrWriteFile() throws {
    let directory = try temporaryDirectory()
    let target = directory.appendingPathComponent("notes/debug.txt")
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.write"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.write",
      arguments: .object([
        "path": .string("notes/debug.txt"),
        "content": .string("codex ready"),
        "create_directories": .bool(true),
        "dry_run": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue

    #expect(!(FileManager.default.fileExists(atPath: target.path)))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["written"]) == (.bool(false)))
    #expect((payload.objectValue?["would_create"]) == (.bool(true)))
    #expect((payload.objectValue?["would_create_parent_directories"]) == (.bool(true)))
    #expect((payload.objectValue?["bytes_to_write"]) == (.number(11)))
    #expect((payload.objectValue?["bytes_written"]) == (.number(0)))
    #expect((preview?["content"]) == (.string("codex ready")))
    #expect((preview?["content_truncated"]) == (.bool(false)))
  }

  @Test
  func testFileWriteFilesDryRunAndConfirmedWrite() throws {
    let directory = try temporaryDirectory()
    let first = directory.appendingPathComponent("notes/one.txt")
    let second = directory.appendingPathComponent("notes/two.txt")
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.write_files"]),
        workspaceDirectory: directory
      )
    )

    let dryRunResult = try registry.callTool(
      name: "file.write_files",
      arguments: .object([
        "files": .array([
          .object(["path": .string("notes/one.txt"), "content": .string("hello world")]),
          .object(["path": .string("notes/two.txt"), "content": .string("")]),
        ]),
        "create_directories": .bool(true),
        "preview_max_bytes": .number(5),
      ])
    )
    let dryRunPayload = try decodeTextPayload(dryRunResult)
    let dryRunFiles = try #require(dryRunPayload.objectValue?["files"]?.arrayValue)
    #expect((dryRunPayload.objectValue?["operation"]) == (.string("file.write_files")))
    #expect((dryRunPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((dryRunPayload.objectValue?["total_bytes_to_write"]) == (.number(11)))
    #expect((dryRunPayload.objectValue?["total_bytes_written"]) == (.number(0)))
    #expect((dryRunFiles[0].objectValue?["workspace_relative_path"]) == (.string("notes/one.txt")))
    #expect((dryRunFiles[0].objectValue?["would_create"]) == (.bool(true)))
    #expect((dryRunFiles[0].objectValue?["would_create_parent_directories"]) == (.bool(true)))
    #expect((dryRunFiles[0].objectValue?["preview"]?.objectValue?["content"]) == (.string("hello")))
    #expect(
      (dryRunFiles[0].objectValue?["preview"]?.objectValue?["content_truncated"]) == (.bool(true)))
    #expect(!(FileManager.default.fileExists(atPath: first.path)))
    #expect(!(FileManager.default.fileExists(atPath: second.path)))

    expectThrows(
      try registry.callTool(
        name: "file.write_files",
        arguments: .object([
          "files": .array([
            .object(["path": .string("notes/one.txt"), "content": .string("hello")])
          ]),
          "create_directories": .bool(true),
          "dry_run": .bool(false),
        ])
      )
    )

    let writeResult = try registry.callTool(
      name: "file.write_files",
      arguments: .object([
        "files": .array([
          .object(["path": .string("notes/one.txt"), "content": .string("hello world")]),
          .object(["path": .string("notes/two.txt"), "content": .string("")]),
        ]),
        "create_directories": .bool(true),
        "dry_run": .bool(false),
        "confirm_write": .bool(true),
      ])
    )
    let writePayload = try decodeTextPayload(writeResult)
    #expect((writePayload.objectValue?["written"]) == (.bool(true)))
    #expect((writePayload.objectValue?["total_bytes_written"]) == (.number(11)))
    #expect((try String(contentsOf: first, encoding: .utf8)) == ("hello world"))
    #expect((try String(contentsOf: second, encoding: .utf8)) == (""))

    expectThrows(
      try registry.callTool(
        name: "file.write_files",
        arguments: .object([
          "files": .array([
            .object(["path": .string("notes/one.txt"), "content": .string("again")])
          ])
        ])
      )
    )
    expectThrows(
      try registry.callTool(
        name: "file.write_files",
        arguments: .object([
          "files": .array([
            .object(["path": .string("notes/three.txt"), "content": .string("a")]),
            .object(["path": .string("notes/three.txt"), "content": .string("b")]),
          ]),
          "create_directories": .bool(true),
        ])
      )
    )
  }

  @Test
  func testFileExistsReturnsPresenceWithoutStatError() throws {
    let directory = try temporaryDirectory()
    try "hello".write(
      to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("logs"),
      withIntermediateDirectories: true
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.exists"]),
        workspaceDirectory: directory
      )
    )

    let fileResult = try registry.callTool(
      name: "file.exists",
      arguments: .object(["path": .string("notes.txt")])
    )
    let filePayload = try decodeTextPayload(fileResult)
    #expect((filePayload.objectValue?["exists"]) == (.bool(true)))
    #expect((filePayload.objectValue?["is_file"]) == (.bool(true)))
    #expect((filePayload.objectValue?["is_directory"]) == (.bool(false)))

    let directoryResult = try registry.callTool(
      name: "file.exists",
      arguments: .object(["path": .string("logs")])
    )
    let directoryPayload = try decodeTextPayload(directoryResult)
    #expect((directoryPayload.objectValue?["exists"]) == (.bool(true)))
    #expect((directoryPayload.objectValue?["is_directory"]) == (.bool(true)))

    let missingResult = try registry.callTool(
      name: "file.exists",
      arguments: .object(["path": .string("missing.txt")])
    )
    let missingPayload = try decodeTextPayload(missingResult)
    #expect((missingPayload.objectValue?["exists"]) == (.bool(false)))
    #expect((missingPayload.objectValue?["is_file"]) == (.null))
    #expect((missingPayload.objectValue?["workspace_relative_path"]) == (.string("missing.txt")))
  }

  @Test
  func testFileExistsRejectsWorkspaceEscape() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.exists"]),
        workspaceDirectory: try temporaryDirectory()
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.exists",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }
  }

  @Test
  func testFileAppendAddsContentWithoutOverwriting() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "first".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.append"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.append",
      arguments: .object([
        "path": .string("notes.txt"),
        "content": .string(" second"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("first second"))
    #expect((payload.objectValue?["created"]) == (.bool(false)))
    #expect((payload.objectValue?["bytes_appended"]) == (.number(7)))
    #expect((payload.objectValue?["size_before_bytes"]) == (.number(5)))
    #expect((payload.objectValue?["size_after_bytes"]) == (.number(12)))
  }

  @Test
  func testFileAppendCanCreateMissingFileWithNewline() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("logs/session.txt")
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.append"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.append",
      arguments: .object([
        "path": .string("logs/session.txt"),
        "content": .string("created"),
        "create_directories": .bool(true),
        "append_newline": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("created\n"))
    #expect((payload.objectValue?["created"]) == (.bool(true)))
    #expect((payload.objectValue?["append_newline"]) == (.bool(true)))
    #expect((payload.objectValue?["bytes_appended"]) == (.number(8)))
  }

  @Test
  func testFileAppendDryRunDoesNotCreateOrAppend() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("logs/session.txt")
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.append"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.append",
      arguments: .object([
        "path": .string("logs/session.txt"),
        "content": .string("created"),
        "create_directories": .bool(true),
        "append_newline": .bool(true),
        "dry_run": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue

    #expect(!(FileManager.default.fileExists(atPath: file.path)))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["created"]) == (.bool(false)))
    #expect((payload.objectValue?["would_create"]) == (.bool(true)))
    #expect((payload.objectValue?["would_create_parent_directories"]) == (.bool(true)))
    #expect((payload.objectValue?["bytes_to_append"]) == (.number(8)))
    #expect((payload.objectValue?["bytes_appended"]) == (.number(0)))
    #expect((payload.objectValue?["size_before_bytes"]) == (.number(0)))
    #expect((payload.objectValue?["size_after_bytes"]) == (.number(8)))
    #expect((preview?["content"]) == (.string("created\n")))
    #expect((preview?["content_truncated"]) == (.bool(false)))
  }

  @Test
  func testFileAppendRejectsDirectoryEscapeAndOversizedContent() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("logs"),
      withIntermediateDirectories: true
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        policy: PolicyConfig(maxOutputBytes: 3),
        builtin: BuiltinConfig(enabled: ["file.append"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.append",
        arguments: .object(["path": .string("logs"), "content": .string("x")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.append",
        arguments: .object(["path": .string("../outside"), "content": .string("x")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.append",
        arguments: .object(["path": .string("notes.txt"), "content": .string("long")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testFileReplaceTextReplacesFirstMatchByDefault() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "alpha beta beta".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.replace_text"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.replace_text",
      arguments: .object([
        "path": .string("notes.txt"),
        "search": .string("beta"),
        "replacement": .string("gamma"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("alpha gamma beta"))
    #expect((payload.objectValue?["total_matches"]) == (.number(2)))
    #expect((payload.objectValue?["replacements"]) == (.number(1)))
    #expect((payload.objectValue?["changed"]) == (.bool(true)))
  }

  @Test
  func testFileReplaceTextCanReplaceAllWithExpectedCountAndEmptyReplacement() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one two two two".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.replace_text"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.replace_text",
      arguments: .object([
        "path": .string("notes.txt"),
        "search": .string("two"),
        "replacement": .string(""),
        "replace_all": .bool(true),
        "expected_replacements": .number(3),
      ])
    )
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one   "))
    #expect((payload.objectValue?["replace_all"]) == (.bool(true)))
    #expect((payload.objectValue?["total_matches"]) == (.number(3)))
    #expect((payload.objectValue?["replacements"]) == (.number(3)))
  }

  @Test
  func testFileReplaceTextDryRunReturnsCountsAndPreviewWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one two two".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.replace_text"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.replace_text",
      arguments: .object([
        "path": .string("notes.txt"),
        "search": .string("two"),
        "replacement": .string("three"),
        "replace_all": .bool(true),
        "expected_replacements": .number(2),
        "dry_run": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one two two"))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["total_matches"]) == (.number(2)))
    #expect((payload.objectValue?["replacements"]) == (.number(2)))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(false)))
    #expect((preview?["search"]) == (.string("two")))
    #expect((preview?["search_truncated"]) == (.bool(false)))
    #expect((preview?["replacement"]) == (.string("three")))
    #expect((preview?["replacement_truncated"]) == (.bool(false)))
  }

  @Test
  func testFileReplaceTextPreviewCanBeRequestedAndTruncated() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "abcdef abcdef".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.replace_text"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.replace_text",
      arguments: .object([
        "path": .string("notes.txt"),
        "search": .string("abcdef"),
        "replacement": .string("uvwxyz"),
        "include_preview": .bool(true),
        "preview_max_bytes": .number(3),
      ])
    )
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("uvwxyz abcdef"))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(true)))
    #expect((preview?["search"]) == (.string("abc")))
    #expect((preview?["search_truncated"]) == (.bool(true)))
    #expect((preview?["replacement"]) == (.string("uvw")))
    #expect((preview?["replacement_truncated"]) == (.bool(true)))
  }

  @Test
  func testFileReplaceTextExpectedMismatchDoesNotWrite() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one two two".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.replace_text"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.replace_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "search": .string("two"),
          "replacement": .string("three"),
          "replace_all": .bool(true),
          "expected_replacements": .number(1),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Expected 1 replacements"))
    }

    #expect((try String(contentsOf: file, encoding: .utf8)) == ("one two two"))
  }

  @Test
  func testFileReplaceTextRejectsDirectoryEscapeAndOversizedFile() throws {
    let directory = try temporaryDirectory()
    try "abcdef".write(
      to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.replace_text"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.replace_text",
        arguments: .object([
          "path": .string("../outside"),
          "search": .string("a"),
          "replacement": .string("b"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.replace_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "search": .string("a"),
          "replacement": .string("b"),
          "max_bytes": .number(3),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_bytes"))
    }
  }

  @Test
  func testFileInsertTextInsertsBeforeLineWithExpectedLine() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.insert_text"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.insert_text",
      arguments: .object([
        "path": .string("notes.txt"),
        "line": .number(2),
        "content": .string("inserted"),
        "expected_line": .string("two"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one\ninserted\ntwo\nthree\n"))
    #expect((payload.objectValue?["line"]) == (.number(2)))
    #expect((payload.objectValue?["position"]) == (.string("before")))
    #expect((payload.objectValue?["line_count_before"]) == (.number(3)))
    #expect((payload.objectValue?["changed"]) == (.bool(true)))
  }

  @Test
  func testFileInsertTextCanInsertAfterLastLineWithoutTrailingNewline() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.insert_text"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.insert_text",
      arguments: .object([
        "path": .string("notes.txt"),
        "line": .number(2),
        "position": .string("after"),
        "content": .string("three"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one\ntwo\nthree\n"))
    #expect((payload.objectValue?["position"]) == (.string("after")))
    #expect((payload.objectValue?["bytes_inserted"]) == (.number(7)))
  }

  @Test
  func testFileInsertTextMatchesLastLineWithoutTrailingNewlineText() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.insert_text"]),
        workspaceDirectory: directory
      )
    )

    _ = try registry.callTool(
      name: "file.insert_text",
      arguments: .object([
        "path": .string("notes.txt"),
        "line": .number(2),
        "position": .string("after"),
        "content": .string("three"),
        "expected_line": .string("two"),
      ])
    )

    let content = try String(contentsOf: file, encoding: .utf8)
    #expect((content) == ("one\ntwo\nthree\n"))
  }

  @Test
  func testFileInsertTextDryRunReturnsPreviewWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.insert_text"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.insert_text",
      arguments: .object([
        "path": .string("notes.txt"),
        "line": .number(2),
        "content": .string("inserted"),
        "expected_line": .string("two"),
        "dry_run": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one\ntwo\nthree\n"))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(false)))
    #expect((preview?["target_line"]) == (.string("two")))
    #expect((preview?["target_line_truncated"]) == (.bool(false)))
    #expect((preview?["inserted_content"]) == (.string("inserted\n")))
    #expect((preview?["inserted_content_truncated"]) == (.bool(false)))
  }

  @Test
  func testFileInsertTextPreviewCanBeRequestedAndTruncated() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "abcdef\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.insert_text"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.insert_text",
      arguments: .object([
        "path": .string("notes.txt"),
        "line": .number(1),
        "content": .string("uvwxyz"),
        "append_newline": .bool(false),
        "include_preview": .bool(true),
        "preview_max_bytes": .number(3),
      ])
    )
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("uvwxyzabcdef\n"))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(true)))
    #expect((preview?["target_line"]) == (.string("abc")))
    #expect((preview?["target_line_truncated"]) == (.bool(true)))
    #expect((preview?["inserted_content"]) == (.string("uvw")))
    #expect((preview?["inserted_content_truncated"]) == (.bool(true)))
  }

  @Test
  func testFileInsertTextExpectedLineMismatchDoesNotWrite() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.insert_text"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.insert_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(2),
          "content": .string("inserted"),
          "expected_line": .string("wrong"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("expected_line"))
    }

    #expect((try String(contentsOf: file, encoding: .utf8)) == ("one\ntwo\n"))
  }

  @Test
  func testFileInsertTextRejectsBadPositionLineEscapeAndOversizedFile() throws {
    let directory = try temporaryDirectory()
    try "one\ntwo\n".write(
      to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.insert_text"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.insert_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(1),
          "position": .string("middle"),
          "content": .string("x"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("position"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.insert_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(3),
          "content": .string("x"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("line must be between"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.insert_text",
        arguments: .object([
          "path": .string("../outside"),
          "line": .number(1),
          "content": .string("x"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.insert_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(1),
          "content": .string("x"),
          "max_bytes": .number(3),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_bytes"))
    }
  }

  @Test
  func testFileReplaceLinesReplacesRangeWithExpectedContent() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.replace_lines"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.replace_lines",
      arguments: .object([
        "path": .string("notes.txt"),
        "start_line": .number(2),
        "end_line": .number(3),
        "content": .string("middle"),
        "expected_content": .string("two\nthree\n"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one\nmiddle\nfour\n"))
    #expect((payload.objectValue?["start_line"]) == (.number(2)))
    #expect((payload.objectValue?["end_line"]) == (.number(3)))
    #expect((payload.objectValue?["line_count_before"]) == (.number(4)))
    #expect((payload.objectValue?["deleted_line_count"]) == (.number(2)))
    #expect((payload.objectValue?["inserted_line_count"]) == (.number(1)))
    #expect((payload.objectValue?["changed"]) == (.bool(true)))
  }

  @Test
  func testFileReplaceLinesCanDeleteLastLineWithoutTrailingNewline() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.replace_lines"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.replace_lines",
      arguments: .object([
        "path": .string("notes.txt"),
        "start_line": .number(3),
        "end_line": .number(3),
        "content": .string(""),
        "expected_content": .string("three"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one\ntwo\n"))
    #expect((payload.objectValue?["deleted_line_count"]) == (.number(1)))
    #expect((payload.objectValue?["inserted_line_count"]) == (.number(0)))
    #expect((payload.objectValue?["bytes_inserted"]) == (.number(0)))
  }

  @Test
  func testFileReplaceLinesDryRunReturnsPreviewWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.replace_lines"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.replace_lines",
      arguments: .object([
        "path": .string("notes.txt"),
        "start_line": .number(2),
        "end_line": .number(2),
        "content": .string("updated"),
        "dry_run": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one\ntwo\nthree\n"))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(false)))
    #expect((preview?["selected_content"]) == (.string("two\n")))
    #expect((preview?["selected_truncated"]) == (.bool(false)))
    #expect((preview?["replacement_content"]) == (.string("updated\n")))
    #expect((preview?["replacement_truncated"]) == (.bool(false)))
  }

  @Test
  func testFileReplaceLinesPreviewCanBeRequestedAndTruncated() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "abcdef\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.replace_lines"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.replace_lines",
      arguments: .object([
        "path": .string("notes.txt"),
        "start_line": .number(1),
        "end_line": .number(1),
        "content": .string("uvwxyz"),
        "append_newline": .bool(false),
        "include_preview": .bool(true),
        "preview_max_bytes": .number(3),
      ])
    )
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("uvwxyz"))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(true)))
    #expect((preview?["selected_content"]) == (.string("abc")))
    #expect((preview?["selected_truncated"]) == (.bool(true)))
    #expect((preview?["replacement_content"]) == (.string("uvw")))
    #expect((preview?["replacement_truncated"]) == (.bool(true)))
  }

  @Test
  func testFileReplaceLinesRejectsMismatchRangeEscapeAndOversizedFile() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.replace_lines"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.replace_lines",
        arguments: .object([
          "path": .string("notes.txt"),
          "start_line": .number(2),
          "end_line": .number(2),
          "content": .string("updated"),
          "expected_content": .string("wrong\n"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("expected_content"))
    }

    #expect((try String(contentsOf: file, encoding: .utf8)) == ("one\ntwo\nthree\n"))

    expectThrows(
      try registry.callTool(
        name: "file.replace_lines",
        arguments: .object([
          "path": .string("notes.txt"),
          "start_line": .number(3),
          "end_line": .number(2),
          "content": .string("x"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("end_line"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.replace_lines",
        arguments: .object([
          "path": .string("../outside"),
          "start_line": .number(1),
          "end_line": .number(1),
          "content": .string("x"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.replace_lines",
        arguments: .object([
          "path": .string("notes.txt"),
          "start_line": .number(1),
          "end_line": .number(1),
          "content": .string("x"),
          "max_bytes": .number(3),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_bytes"))
    }
  }

  @Test
  func testFileReadLinesReturnsBoundedLineRange() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.read_lines"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.read_lines",
      arguments: .object([
        "path": .string("notes.txt"),
        "start_line": .number(2),
        "max_lines": .number(2),
      ])
    )
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["line_count"]) == (.number(2)))
    #expect((lines[0].objectValue?["line"]) == (.number(2)))
    #expect((lines[0].objectValue?["text"]) == (.string("two")))
    #expect((lines[1].objectValue?["line"]) == (.number(3)))
    #expect((lines[1].objectValue?["text"]) == (.string("three")))
  }

  @Test
  func testFileReadContextReturnsTargetLineNeighborhood() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\nfour\nfive\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.read_context"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.read_context",
      arguments: .object([
        "path": .string("notes.txt"),
        "line": .number(3),
        "before": .number(1),
        "after": .number(1),
      ])
    )
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("file.read_context")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["start_line"]) == (.number(2)))
    #expect((payload.objectValue?["end_line"]) == (.number(4)))
    #expect((payload.objectValue?["start_clamped"]) == (.bool(false)))
    #expect((payload.objectValue?["target_line_returned"]) == (.bool(true)))
    #expect((payload.objectValue?["range_may_be_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["line_count"]) == (.number(3)))
    #expect((lines[0].objectValue?["line"]) == (.number(2)))
    #expect((lines[0].objectValue?["relative_line"]) == (.number(-1)))
    #expect((lines[0].objectValue?["is_target"]) == (.bool(false)))
    #expect((lines[0].objectValue?["text"]) == (.string("two")))
    #expect((lines[1].objectValue?["line"]) == (.number(3)))
    #expect((lines[1].objectValue?["relative_line"]) == (.number(0)))
    #expect((lines[1].objectValue?["is_target"]) == (.bool(true)))
    #expect((lines[1].objectValue?["text"]) == (.string("three")))

    let clampedResult = try registry.callTool(
      name: "file.read_context",
      arguments: .object([
        "path": .string("notes.txt"),
        "line": .number(1),
        "before": .number(5),
        "after": .number(1),
      ])
    )
    let clampedPayload = try decodeTextPayload(clampedResult)
    #expect((clampedPayload.objectValue?["start_line"]) == (.number(1)))
    #expect((clampedPayload.objectValue?["start_clamped"]) == (.bool(true)))
    #expect((clampedPayload.objectValue?["line_count"]) == (.number(2)))
  }

  @Test
  func testFileReadContextReportsTruncatedRangeAndRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.read_context"]),
        workspaceDirectory: directory
      )
    )

    let truncatedResult = try registry.callTool(
      name: "file.read_context",
      arguments: .object([
        "path": .string("notes.txt"),
        "line": .number(3),
        "before": .number(0),
        "after": .number(0),
        "max_bytes": .number(4),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["file_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["range_may_be_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["target_line_returned"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["line_count"]) == (.number(0)))

    expectThrows(
      try registry.callTool(
        name: "file.read_context",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("line"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.read_context",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(1),
          "before": .number(-1),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("before"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.read_context",
        arguments: .object([
          "path": .string("."),
          "line": .number(1),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }
  }

  @Test
  func testFileReadWindowReturnsOffsetTextWindow() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "zero\none\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.read_window"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.read_window",
      arguments: .object([
        "path": .string("notes.txt"),
        "offset_bytes": .number(5),
        "max_bytes": .number(3),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("file.read_window")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["offset_bytes"]) == (.number(5)))
    #expect((payload.objectValue?["max_bytes"]) == (.number(3)))
    #expect((payload.objectValue?["bytes_read"]) == (.number(3)))
    #expect((payload.objectValue?["next_offset_bytes"]) == (.number(8)))
    #expect((payload.objectValue?["eof"]) == (.bool(false)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["valid_utf8"]) == (.bool(true)))
    #expect((payload.objectValue?["content"]) == (.string("one")))

    let eofResult = try registry.callTool(
      name: "file.read_window",
      arguments: .object([
        "path": .string("notes.txt"),
        "offset_bytes": .number(10_000),
        "max_bytes": .number(10),
      ])
    )
    let eofPayload = try decodeTextPayload(eofResult)
    #expect((eofPayload.objectValue?["bytes_read"]) == (.number(0)))
    #expect((eofPayload.objectValue?["eof"]) == (.bool(true)))
    #expect((eofPayload.objectValue?["content"]) == (.string("")))

    expectThrows(
      try registry.callTool(
        name: "file.read_window",
        arguments: .object(["path": .string(".")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }
  }

  @Test
  func testFileReadWindowReportsInvalidUTF8Window() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("unicode.txt")
    try Data("aé\n".utf8).write(to: file)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.read_window"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.read_window",
      arguments: .object([
        "path": .string("unicode.txt"),
        "offset_bytes": .number(2),
        "max_bytes": .number(2),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["bytes_read"]) == (.number(2)))
    #expect((payload.objectValue?["valid_utf8"]) == (.bool(false)))
  }

  @Test
  func testFileReadLinesReportsTruncatedScan() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "1234567890\nnext\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.read_lines"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.read_lines",
      arguments: .object([
        "path": .string("notes.txt"),
        "max_bytes": .number(5),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["bytes_scanned"]) == (.number(5)))
    #expect((payload.objectValue?["file_truncated"]) == (.bool(true)))
  }

  @Test
  func testFileHeadReturnsFirstLinesWithBoundedByteWindow() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.head"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.head",
      arguments: .object([
        "path": .string("notes.txt"),
        "max_lines": .number(2),
      ])
    )
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["line_count"]) == (.number(2)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["file_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["last_line_truncated"]) == (.bool(false)))
    #expect((lines[0].objectValue?["line"]) == (.number(1)))
    #expect((lines[0].objectValue?["head_index"]) == (.number(1)))
    #expect((lines[0].objectValue?["text"]) == (.string("one")))
    #expect((lines[0].objectValue?["line_truncated"]) == (.bool(false)))
    #expect((lines[1].objectValue?["line"]) == (.number(2)))
    #expect((lines[1].objectValue?["text"]) == (.string("two")))
  }

  @Test
  func testFileHeadReportsTruncatedLastLine() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "1234567890\nnext\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.head"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.head",
      arguments: .object([
        "path": .string("notes.txt"),
        "max_lines": .number(5),
        "max_bytes": .number(5),
      ])
    )
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["bytes_read"]) == (.number(5)))
    #expect((payload.objectValue?["file_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["last_line_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((lines[0].objectValue?["text"]) == (.string("12345")))
    #expect((lines[0].objectValue?["line_truncated"]) == (.bool(true)))

    expectThrows(
      try registry.callTool(
        name: "file.head",
        arguments: .object(["path": .string(".")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }
  }

  @Test
  func testFileOutlineReturnsBoundedMechanicalMarkdownAndSourceMarkers() throws {
    let directory = try temporaryDirectory()
    let readme = directory.appendingPathComponent("README.md")
    let source = directory.appendingPathComponent("App.swift")
    let script = directory.appendingPathComponent("tool.js")
    try "# Computer MCP\n\nIntro\n\n## Install\n```toml\n# Not a heading\n```\n### Verify\n"
      .write(to: readme, atomically: true, encoding: .utf8)
    try """
    import Foundation

    public struct Gateway {
      func serve() {}
    }

    private enum Mode {
    }
    """.write(to: source, atomically: true, encoding: .utf8)
    try """
    export function run() {}
    const value = 1
    """.write(to: script, atomically: true, encoding: .utf8)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.outline"]),
        workspaceDirectory: directory
      )
    )

    let markdownResult = try registry.callTool(
      name: "file.outline",
      arguments: .object([
        "path": .string("README.md"),
        "max_results": .number(2),
      ])
    )
    let markdownPayload = try decodeTextPayload(markdownResult)
    let markdownItems = try #require(markdownPayload.objectValue?["items"]?.arrayValue)

    #expect((markdownPayload.objectValue?["operation"]) == (.string("file.outline")))
    #expect((markdownPayload.objectValue?["workspace_relative_path"]) == (.string("README.md")))
    #expect((markdownPayload.objectValue?["language"]) == (.string("markdown")))
    #expect((markdownPayload.objectValue?["outline_count"]) == (.number(3)))
    #expect((markdownPayload.objectValue?["returned_count"]) == (.number(2)))
    #expect((markdownPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((markdownItems[0].objectValue?["kind"]) == (.string("heading")))
    #expect((markdownItems[0].objectValue?["level"]) == (.number(1)))
    #expect((markdownItems[0].objectValue?["name"]) == (.string("Computer MCP")))
    #expect((markdownItems[1].objectValue?["line"]) == (.number(5)))

    let sourceResult = try registry.callTool(
      name: "file.outline",
      arguments: .object([
        "path": .string("App.swift"),
        "include_imports": .bool(true),
      ])
    )
    let sourcePayload = try decodeTextPayload(sourceResult)
    let sourceItems = try #require(sourcePayload.objectValue?["items"]?.arrayValue)

    #expect((sourcePayload.objectValue?["language"]) == (.string("swift")))
    #expect((sourceItems[0].objectValue?["kind"]) == (.string("import")))
    #expect((sourceItems[0].objectValue?["name"]) == (.string("Foundation")))
    #expect((sourceItems[1].objectValue?["kind"]) == (.string("struct")))
    #expect((sourceItems[1].objectValue?["name"]) == (.string("Gateway")))
    #expect((sourceItems[2].objectValue?["kind"]) == (.string("function")))
    #expect((sourceItems[2].objectValue?["name"]) == (.string("serve")))
    #expect((sourceItems[3].objectValue?["kind"]) == (.string("enum")))
    #expect((sourceItems[3].objectValue?["name"]) == (.string("Mode")))

    let scriptResult = try registry.callTool(
      name: "file.outline",
      arguments: .object([
        "path": .string("tool.js")
      ])
    )
    let scriptPayload = try decodeTextPayload(scriptResult)
    let scriptItems = try #require(scriptPayload.objectValue?["items"]?.arrayValue)

    #expect((scriptPayload.objectValue?["language"]) == (.string("javascript")))
    #expect((scriptItems[0].objectValue?["kind"]) == (.string("function")))
    #expect((scriptItems[0].objectValue?["name"]) == (.string("run")))
    #expect((scriptItems[1].objectValue?["kind"]) == (.string("variable")))
    #expect((scriptItems[1].objectValue?["name"]) == (.string("value")))
  }

  @Test
  func testMarkdownLinksReturnsBoundedMechanicalLinks() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("docs/images"),
      withIntermediateDirectories: true
    )
    let readme = directory.appendingPathComponent("docs/README.md")
    try """
    # Guide

    See [Install](install.md#setup "Install docs") and ![Logo](images/logo.png).
    Use [API][api-ref] and <https://example.com/docs>.

    [api-ref]: ../API.md "API Reference"

    ```md
    [ignored](secret.md)
    ```
    """.write(to: readme, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["markdown.links"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "markdown.links",
      arguments: .object([
        "path": .string("docs/README.md")
      ])
    )
    let payload = try decodeTextPayload(result)
    let links = try #require(payload.objectValue?["links"]?.arrayValue)
    let byKind = Dictionary(
      uniqueKeysWithValues: links.map {
        ($0.objectValue?["kind"]?.stringValue ?? "", $0.objectValue ?? [:])
      })

    #expect((payload.objectValue?["operation"]) == (.string("markdown.links")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("docs/README.md")))
    #expect((payload.objectValue?["link_count"]) == (.number(5)))
    #expect((payload.objectValue?["returned_count"]) == (.number(5)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((byKind["inline_link"]?["label"]) == (.string("Install")))
    #expect((byKind["inline_link"]?["destination"]) == (.string("install.md#setup")))
    #expect((byKind["inline_link"]?["title"]) == (.string("Install docs")))
    #expect(
      (byKind["inline_link"]?["target"]?.objectValue?["target_workspace_relative_path"])
        == (.string("docs/install.md")))
    #expect((byKind["inline_link"]?["target"]?.objectValue?["fragment"]) == (.string("setup")))
    #expect((byKind["inline_image"]?["is_image"]) == (.bool(true)))
    #expect(
      (byKind["inline_image"]?["target"]?.objectValue?["target_workspace_relative_path"])
        == (.string("docs/images/logo.png")))
    #expect((byKind["reference_link"]?["reference_label"]) == (.string("api-ref")))
    #expect((byKind["reference_link"]?["destination"]) == (.null))
    #expect((byKind["reference_definition"]?["destination"]) == (.string("../API.md")))
    #expect(
      (byKind["reference_definition"]?["target"]?.objectValue?["target_workspace_relative_path"])
        == (.string("API.md")))
    #expect((byKind["autolink"]?["target"]?.objectValue?["kind"]) == (.string("url")))
    #expect((byKind["autolink"]?["target"]?.objectValue?["scheme"]) == (.string("https")))
  }

  @Test
  func testMarkdownLinksOptionsAndTruncation() throws {
    let directory = try temporaryDirectory()
    let readme = directory.appendingPathComponent("README.md")
    try """
    ![Skip](image.png)
    [One](one.md)
    [Two](two.md)
    ```md
    [Inside](inside.md)
    ```
    """.write(to: readme, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["markdown.links"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "markdown.links",
      arguments: .object([
        "path": .string("README.md"),
        "include_images": .bool(false),
        "max_links": .number(1),
      ])
    )
    let payload = try decodeTextPayload(result)
    let links = try #require(payload.objectValue?["links"]?.arrayValue)

    #expect((payload.objectValue?["include_images"]) == (.bool(false)))
    #expect((payload.objectValue?["include_code_blocks"]) == (.bool(false)))
    #expect((payload.objectValue?["link_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((links.first?.objectValue?["destination"]) == (.string("one.md")))

    let codeBlockResult = try registry.callTool(
      name: "markdown.links",
      arguments: .object([
        "path": .string("README.md"),
        "include_code_blocks": .bool(true),
        "max_links": .number(10),
      ])
    )
    let codeBlockPayload = try decodeTextPayload(codeBlockResult)
    #expect((codeBlockPayload.objectValue?["link_count"]) == (.number(4)))
  }

  @Test
  func testMarkdownTablesExtractsBoundedPipeTables() throws {
    let directory = try temporaryDirectory()
    let readme = directory.appendingPathComponent("README.md")
    try """
    # Data

    | Name | Count | Note |
    | :--- | ---: | :---: |
    | Alpha | 1 | ok |
    | Beta \\| escaped | 2 | centered |
    | Short | 3 |
    Text

    ```md
    | Hidden | Value |
    | --- | --- |
    | X | Y |
    ```

    Key | Value
    --- | ---
    A | B
    """.write(to: readme, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["markdown.tables"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "markdown.tables",
      arguments: .object([
        "path": .string("README.md"),
        "max_tables": .number(10),
        "max_rows_per_table": .number(10),
      ])
    )
    let payload = try decodeTextPayload(result)
    let tables = try #require(payload.objectValue?["tables"]?.arrayValue)
    let first = try #require(tables.first?.objectValue)
    let firstRows = try #require(first["rows"]?.arrayValue)
    let second = try #require(tables.last?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("markdown.tables")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("README.md")))
    #expect((payload.objectValue?["include_code_blocks"]) == (.bool(false)))
    #expect((payload.objectValue?["table_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((first["start_line"]) == (.number(3)))
    #expect((first["end_line"]) == (.number(7)))
    #expect((first["header_line"]) == (.number(3)))
    #expect((first["delimiter_line"]) == (.number(4)))
    #expect((first["column_count"]) == (.number(3)))
    #expect((first["headers"]) == (.array([.string("Name"), .string("Count"), .string("Note")])))
    #expect(
      (first["alignments"]) == (.array([.string("left"), .string("right"), .string("center")])))
    #expect((first["row_count"]) == (.number(3)))
    #expect((firstRows[1].objectValue?["cells"]?.arrayValue?[0]) == (.string("Beta | escaped")))
    #expect((firstRows[2].objectValue?["missing_cell_count"]) == (.number(1)))
    #expect(
      (firstRows[2].objectValue?["cells"])
        == (.array([.string("Short"), .string("3"), .string("")])))
    #expect((second["start_line"]) == (.number(16)))
    #expect((second["headers"]) == (.array([.string("Key"), .string("Value")])))

    let truncatedResult = try registry.callTool(
      name: "markdown.tables",
      arguments: .object([
        "path": .string("README.md"),
        "max_tables": .number(1),
        "max_rows_per_table": .number(2),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedTable = try #require(truncatedPayload.objectValue?["tables"]?.arrayValue?.first)
      .objectValue
    #expect((truncatedPayload.objectValue?["table_count"]) == (.number(2)))
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["row_truncated_table_count"]) == (.number(1)))
    #expect((truncatedTable?["row_result_truncated"]) == (.bool(true)))
    #expect((truncatedTable?["returned_row_count"]) == (.number(2)))

    let codeBlockResult = try registry.callTool(
      name: "markdown.tables",
      arguments: .object([
        "path": .string("README.md"),
        "include_code_blocks": .bool(true),
      ])
    )
    let codeBlockPayload = try decodeTextPayload(codeBlockResult)
    #expect((codeBlockPayload.objectValue?["table_count"]) == (.number(3)))
  }

  @Test
  func testMarkdownTablesRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("bad.md"))
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["markdown.tables"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "markdown.tables",
        arguments: .object(["path": .string("../outside.md")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.tables",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.tables",
        arguments: .object(["path": .string("bad.md")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.tables",
        arguments: .object([
          "path": .string("bad.md"),
          "max_tables": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_tables"))
    }
  }

  @Test
  func testMarkdownSectionExtractsExactHeadingSection() throws {
    let directory = try temporaryDirectory()
    let readme = directory.appendingPathComponent("README.md")
    try """
    # Guide

    Intro

    ## Install
    First
    ### Details
    Deep
    ```md
    ## Ignored
    ```
    ## Usage
    Use it

    ## Install
    Second
    """.write(to: readme, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["markdown.section"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "markdown.section",
      arguments: .object([
        "path": .string("README.md"),
        "heading": .string("Install"),
        "level": .number(2),
      ])
    )
    let payload = try decodeTextPayload(result)
    let section = try #require(payload.objectValue?["section"]?.objectValue)
    let followingHeading = try #require(payload.objectValue?["following_heading"]?.objectValue)
    let content = try #require(section["content"]?.stringValue)

    #expect((payload.objectValue?["operation"]) == (.string("markdown.section")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("README.md")))
    #expect((payload.objectValue?["matched"]) == (.bool(true)))
    #expect((payload.objectValue?["match_count"]) == (.number(2)))
    #expect((payload.objectValue?["matched_heading"]?.objectValue?["line"]) == (.number(5)))
    #expect((followingHeading["name"]) == (.string("Usage")))
    #expect((followingHeading["line"]) == (.number(12)))
    #expect((section["start_line"]) == (.number(5)))
    #expect((section["end_line"]) == (.number(11)))
    #expect((section["line_count"]) == (.number(7)))
    #expect(content.contains("## Install"))
    #expect(content.contains("## Ignored"))
    #expect(!(content.contains("## Usage")))
    #expect((section["section_may_be_truncated"]) == (.bool(false)))
    #expect(
      (payload.objectValue?["outline_context"]?.objectValue?["tool"]) == (.string("file.outline")))

    let secondResult = try registry.callTool(
      name: "markdown.section",
      arguments: .object([
        "path": .string("README.md"),
        "heading": .string("Install"),
        "level": .number(2),
        "occurrence": .number(2),
        "include_heading": .bool(false),
      ])
    )
    let secondPayload = try decodeTextPayload(secondResult)
    let secondSection = try #require(secondPayload.objectValue?["section"]?.objectValue)
    #expect((secondPayload.objectValue?["matched"]) == (.bool(true)))
    #expect((secondPayload.objectValue?["following_heading"]) == (.null))
    #expect((secondSection["start_line"]) == (.number(16)))
    #expect((secondSection["end_line"]) == (.number(16)))
    #expect((secondSection["content"]) == (.string("Second")))

    let truncatedResult = try registry.callTool(
      name: "markdown.section",
      arguments: .object([
        "path": .string("README.md"),
        "heading": .string("Install"),
        "max_section_bytes": .number(8),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedSection = try #require(truncatedPayload.objectValue?["section"]?.objectValue)
    #expect((truncatedSection["content_truncated"]) == (.bool(true)))

    let missingResult = try registry.callTool(
      name: "markdown.section",
      arguments: .object([
        "path": .string("README.md"),
        "heading": .string("Missing"),
      ])
    )
    let missingPayload = try decodeTextPayload(missingResult)
    #expect((missingPayload.objectValue?["matched"]) == (.bool(false)))
    #expect((missingPayload.objectValue?["section"]) == (.null))
    #expect(
      (missingPayload.objectValue?["failure"]?.objectValue?["reason"])
        == (.string("missing_heading")))
  }

  @Test
  func testMarkdownSectionRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("bad.md"))
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["markdown.section"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "markdown.section",
        arguments: .object([
          "path": .string("../outside.md"),
          "heading": .string("Intro"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.section",
        arguments: .object([
          "path": .string("folder"),
          "heading": .string("Intro"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.section",
        arguments: .object([
          "path": .string("bad.md"),
          "heading": .string("Intro"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.section",
        arguments: .object([
          "path": .string("bad.md"),
          "heading": .string("Intro"),
          "level": .number(7),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("level"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.section",
        arguments: .object([
          "path": .string("bad.md"),
          "heading": .string("Intro"),
          "occurrence": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("occurrence"))
    }
  }

  @Test
  func testMarkdownFrontmatterReadsYAMLAndTOML() throws {
    let directory = try temporaryDirectory()
    try """
    ---
    title: Guide
    tags:
      - mcp
      - gateway
    draft: false
    ---
    # Body
    """.write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try """
    +++
    title = "Doc"
    weight = 2
    +++
    # Body
    """.write(to: directory.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["markdown.frontmatter"]),
        workspaceDirectory: directory
      )
    )

    let yamlResult = try registry.callTool(
      name: "markdown.frontmatter",
      arguments: .object(["path": .string("README.md")])
    )
    let yamlPayload = try decodeTextPayload(yamlResult)
    let yamlValue = try #require(yamlPayload.objectValue?["value"]?.objectValue)

    #expect((yamlPayload.objectValue?["operation"]) == (.string("markdown.frontmatter")))
    #expect((yamlPayload.objectValue?["workspace_relative_path"]) == (.string("README.md")))
    #expect((yamlPayload.objectValue?["found"]) == (.bool(true)))
    #expect((yamlPayload.objectValue?["format"]) == (.string("yaml")))
    #expect((yamlPayload.objectValue?["has_opening_delimiter"]) == (.bool(true)))
    #expect((yamlPayload.objectValue?["has_closing_delimiter"]) == (.bool(true)))
    #expect((yamlPayload.objectValue?["raw_start_line"]) == (.number(2)))
    #expect((yamlPayload.objectValue?["raw_end_line"]) == (.number(6)))
    #expect((yamlPayload.objectValue?["closing_line"]) == (.number(7)))
    #expect((yamlPayload.objectValue?["body_start_line"]) == (.number(8)))
    #expect((yamlPayload.objectValue?["parsed"]) == (.bool(true)))
    #expect((yamlPayload.objectValue?["parse_error"]) == (.null))
    #expect((yamlValue["title"]) == (.string("Guide")))
    #expect((yamlValue["tags"]) == (.array([.string("mcp"), .string("gateway")])))
    #expect((yamlValue["draft"]) == (.bool(false)))

    let tomlResult = try registry.callTool(
      name: "markdown.frontmatter",
      arguments: .object([
        "path": .string("page.md"),
        "format": .string("toml"),
      ])
    )
    let tomlPayload = try decodeTextPayload(tomlResult)
    let tomlValue = try #require(tomlPayload.objectValue?["value"]?.objectValue)

    #expect((tomlPayload.objectValue?["found"]) == (.bool(true)))
    #expect((tomlPayload.objectValue?["format"]) == (.string("toml")))
    #expect((tomlPayload.objectValue?["parsed"]) == (.bool(true)))
    #expect((tomlValue["title"]) == (.string("Doc")))
    #expect((tomlValue["weight"]) == (.number(2)))
  }

  @Test
  func testMarkdownFrontmatterReportsMissingAndMalformed() throws {
    let directory = try temporaryDirectory()
    try "# Body\n".write(
      to: directory.appendingPathComponent("plain.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    ---
    title: Missing
    # Body
    """.write(
      to: directory.appendingPathComponent("unterminated.md"), atomically: true, encoding: .utf8)
    try """
    ---
    title: [unterminated
    ---
    # Body
    """.write(to: directory.appendingPathComponent("bad.md"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["markdown.frontmatter"]),
        workspaceDirectory: directory
      )
    )

    let plainResult = try registry.callTool(
      name: "markdown.frontmatter",
      arguments: .object(["path": .string("plain.md")])
    )
    let plainPayload = try decodeTextPayload(plainResult)
    #expect((plainPayload.objectValue?["found"]) == (.bool(false)))
    #expect(
      (plainPayload.objectValue?["failure"]?.objectValue?["reason"])
        == (.string("missing_frontmatter")))
    #expect((plainPayload.objectValue?["value"]) == (.null))

    let unterminatedResult = try registry.callTool(
      name: "markdown.frontmatter",
      arguments: .object(["path": .string("unterminated.md")])
    )
    let unterminatedPayload = try decodeTextPayload(unterminatedResult)
    #expect((unterminatedPayload.objectValue?["found"]) == (.bool(false)))
    #expect((unterminatedPayload.objectValue?["has_opening_delimiter"]) == (.bool(true)))
    #expect((unterminatedPayload.objectValue?["has_closing_delimiter"]) == (.bool(false)))
    #expect(
      (unterminatedPayload.objectValue?["failure"]?.objectValue?["reason"])
        == (.string("unterminated_frontmatter")))

    let badResult = try registry.callTool(
      name: "markdown.frontmatter",
      arguments: .object(["path": .string("bad.md")])
    )
    let badPayload = try decodeTextPayload(badResult)
    #expect((badPayload.objectValue?["found"]) == (.bool(true)))
    #expect((badPayload.objectValue?["parsed"]) == (.bool(false)))
    #expect((badPayload.objectValue?["parse_error"]?.stringValue) != nil)
    #expect((badPayload.objectValue?["value"]) == (.null))
  }

  @Test
  func testMarkdownFrontmatterRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("bad.md"))
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["markdown.frontmatter"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "markdown.frontmatter",
        arguments: .object(["path": .string("../outside.md")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.frontmatter",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.frontmatter",
        arguments: .object(["path": .string("bad.md")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.frontmatter",
        arguments: .object([
          "path": .string("bad.md"),
          "format": .string("json"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("format"))
    }
  }

  @Test
  func testMarkdownLinksRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("bad.md"))
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["markdown.links"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "markdown.links",
        arguments: .object(["path": .string("../outside.md")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.links",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.links",
        arguments: .object([
          "path": .string("bad.md"),
          "max_bytes": .number(2),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.links",
        arguments: .object([
          "path": .string("bad.md"),
          "max_links": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_links"))
    }
  }

  @Test
  func testMarkdownLinkCheckReportsLocalBrokenAndUncheckedLinks() throws {
    let directory = try temporaryDirectory()
    let docs = directory.appendingPathComponent("docs")
    let images = docs.appendingPathComponent("images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    try Data([0, 1, 2]).write(to: docs.appendingPathComponent("asset.bin"))
    try Data([0xff]).write(to: images.appendingPathComponent("logo.png"))
    try """
    # Setup
    <a id="custom"></a>
    """.write(to: docs.appendingPathComponent("install.md"), atomically: true, encoding: .utf8)
    try """
    # API
    """.write(to: directory.appendingPathComponent("API.md"), atomically: true, encoding: .utf8)
    try """
    # Docs
    [Install](install.md#setup)
    [Missing](missing.md)
    [Bad Fragment](install.md#missing)
    [External](https://example.com/docs)
    [Ref][guide]
    [NoRef][missing-ref]
    ![Logo](images/logo.png)
    [Empty]()
    [Custom](install.md#custom)
    [Binary Fragment](asset.bin#bytes)
    [Guide Definition][guide]

    [guide]: ../API.md#api
    """.write(to: docs.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["markdown.link_check"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "markdown.link_check",
      arguments: .object([
        "path": .string("docs/README.md"),
        "max_links": .number(50),
      ])
    )
    let payload = try decodeTextPayload(result)
    let checks = try #require(payload.objectValue?["checks"]?.arrayValue)
    let byLabel = Dictionary(
      uniqueKeysWithValues: checks.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let label = object["label"]?.stringValue
        else {
          return nil
        }
        return (label, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("markdown.link_check")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("docs/README.md")))
    #expect((payload.objectValue?["check_count"]) == (.number(12)))
    #expect((payload.objectValue?["ok_count"]) == (.number(6)))
    #expect((payload.objectValue?["broken_count"]) == (.number(4)))
    #expect((payload.objectValue?["unchecked_count"]) == (.number(2)))
    #expect((payload.objectValue?["reference_definition_count"]) == (.number(1)))
    #expect((byLabel["Install"]?["status"]) == (.string("ok")))
    #expect((byLabel["Install"]?["target"]?.objectValue?["fragment_found"]) == (.bool(true)))
    #expect((byLabel["Missing"]?["status"]) == (.string("missing_target")))
    #expect((byLabel["Bad Fragment"]?["status"]) == (.string("missing_fragment")))
    #expect((byLabel["External"]?["status"]) == (.string("external_unchecked")))
    #expect((byLabel["Ref"]?["status"]) == (.string("ok")))
    #expect((byLabel["Ref"]?["resolved_via_reference_definition"]) == (.bool(true)))
    #expect((byLabel["Ref"]?["reference_definition_line"]) == (.number(14)))
    #expect((byLabel["NoRef"]?["status"]) == (.string("missing_reference_definition")))
    #expect((byLabel["Logo"]?["status"]) == (.string("ok")))
    #expect((byLabel["Empty"]?["status"]) == (.string("empty_destination")))
    #expect((byLabel["Custom"]?["status"]) == (.string("ok")))
    #expect((byLabel["Binary Fragment"]?["status"]) == (.string("fragment_unchecked")))
    #expect((byLabel["guide"]?["kind"]) == (.string("reference_definition")))
    #expect((byLabel["guide"]?["status"]) == (.string("ok")))

    let noDefinitionsResult = try registry.callTool(
      name: "markdown.link_check",
      arguments: .object([
        "path": .string("docs/README.md"),
        "include_reference_definitions": .bool(false),
        "max_links": .number(50),
      ])
    )
    let noDefinitionsPayload = try decodeTextPayload(noDefinitionsResult)
    #expect((noDefinitionsPayload.objectValue?["check_count"]) == (.number(11)))
    #expect((noDefinitionsPayload.objectValue?["ok_count"]) == (.number(5)))
  }

  @Test
  func testMarkdownLinkCheckRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("bad.md"))
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["markdown.link_check"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "markdown.link_check",
        arguments: .object(["path": .string("../outside.md")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.link_check",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "markdown.link_check",
        arguments: .object([
          "path": .string("bad.md"),
          "max_bytes": .number(2),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }
  }

  @Test
  func testFileTailReturnsLastLines() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.tail"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.tail",
      arguments: .object([
        "path": .string("notes.txt"),
        "max_lines": .number(2),
      ])
    )
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["line_numbers_known"]) == (.bool(true)))
    #expect((payload.objectValue?["file_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["line_count"]) == (.number(2)))
    #expect((lines[0].objectValue?["line"]) == (.number(3)))
    #expect((lines[0].objectValue?["tail_index"]) == (.number(1)))
    #expect((lines[0].objectValue?["text"]) == (.string("three")))
    #expect((lines[1].objectValue?["line"]) == (.number(4)))
    #expect((lines[1].objectValue?["text"]) == (.string("four")))
  }

  @Test
  func testFileTailReportsTruncatedWindowAndDropsPartialFirstLine() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.tail"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.tail",
      arguments: .object([
        "path": .string("notes.txt"),
        "max_lines": .number(3),
        "max_bytes": .number(9),
      ])
    )
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["bytes_read"]) == (.number(9)))
    #expect((payload.objectValue?["file_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["dropped_partial_first_line"]) == (.bool(true)))
    #expect((payload.objectValue?["line_numbers_known"]) == (.bool(false)))
    #expect((payload.objectValue?["line_count"]) == (.number(1)))
    #expect((lines[0].objectValue?["line"]) == (.null))
    #expect((lines[0].objectValue?["text"]) == (.string("four")))
  }

  @Test
  func testFileHexdumpReturnsBoundedHexAndASCIIWindow() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("blob.bin")
    let bytes = Data([
      0x00, 0x41, 0x7f, 0x80, 0x20, 0x7e, 0x0a, 0xff, 0x42, 0x43, 0x44, 0x45, 0x46,
      0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d,
    ])
    try bytes.write(to: file)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.hexdump"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.hexdump",
      arguments: .object([
        "path": .string("blob.bin"),
        "offset_bytes": .number(1),
        "max_bytes": .number(18),
      ])
    )
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("blob.bin")))
    #expect((payload.objectValue?["offset_bytes"]) == (.number(1)))
    #expect((payload.objectValue?["max_bytes"]) == (.number(18)))
    #expect((payload.objectValue?["file_size_bytes"]) == (.number(20)))
    #expect((payload.objectValue?["bytes_read"]) == (.number(18)))
    #expect((payload.objectValue?["next_offset_bytes"]) == (.number(19)))
    #expect((payload.objectValue?["eof"]) == (.bool(false)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((lines.count) == (2))
    #expect((lines[0].objectValue?["offset_bytes"]) == (.number(1)))
    #expect(
      (lines[0].objectValue?["hex"]) == (.string("41 7f 80 20 7e 0a ff 42 43 44 45 46 47 48 49 4a"))
    )
    #expect((lines[0].objectValue?["ascii"]) == (.string("A.. ~..BCDEFGHIJ")))
    #expect((lines[1].objectValue?["offset_bytes"]) == (.number(17)))
    #expect((lines[1].objectValue?["hex"]) == (.string("4b 4c")))
    #expect((lines[1].objectValue?["ascii"]) == (.string("KL")))
  }

  @Test
  func testFileHexdumpCanReadEmptyWindowAtEOF() throws {
    let directory = try temporaryDirectory()
    try Data([0x01, 0x02]).write(to: directory.appendingPathComponent("blob.bin"))
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.hexdump"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.hexdump",
      arguments: .object([
        "path": .string("blob.bin"),
        "offset_bytes": .number(10),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["bytes_read"]) == (.number(0)))
    #expect((payload.objectValue?["next_offset_bytes"]) == (.number(10)))
    #expect((payload.objectValue?["eof"]) == (.bool(true)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["lines"]) == (.array([])))
  }

  @Test
  func testFileHexdumpRejectsWorkspaceEscapeNonFileAndBadBounds() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.hexdump"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.hexdump",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.hexdump",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.hexdump",
        arguments: .object([
          "path": .string("folder"),
          "max_bytes": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_bytes"))
    }
  }

  @Test
  func testFileXattrsListsNamesAndOptionalBoundedValues() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("download.txt")
    try "download".write(to: file, atomically: true, encoding: .utf8)
    try setTestExtendedAttribute(
      file,
      name: "com.showxu.alpha",
      value: Data("hello-world".utf8)
    )
    try setTestExtendedAttribute(
      file,
      name: "com.showxu.empty",
      value: Data()
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.xattrs"]),
        workspaceDirectory: directory
      )
    )

    let listResult = try registry.callTool(
      name: "file.xattrs",
      arguments: .object(["path": .string("download.txt")])
    )
    let listPayload = try decodeTextPayload(listResult)
    let listedAttributes = try #require(listPayload.objectValue?["attributes"]?.arrayValue)
    let listedAlpha = try #require(
      listedAttributes.first { $0.objectValue?["name"] == .string("com.showxu.alpha") }
    )

    #expect((listPayload.objectValue?["workspace_relative_path"]) == (.string("download.txt")))
    #expect((listPayload.objectValue?["include_values"]) == (.bool(false)))
    #expect((listedAlpha.objectValue?["size_bytes"]) == (.number(11)))
    #expect((listedAlpha.objectValue?["value_base64"]) == nil)

    let valueResult = try registry.callTool(
      name: "file.xattrs",
      arguments: .object([
        "path": .string("download.txt"),
        "include_values": .bool(true),
        "max_value_bytes": .number(16),
      ])
    )
    let valuePayload = try decodeTextPayload(valueResult)
    let valueAttributes = try #require(valuePayload.objectValue?["attributes"]?.arrayValue)
    let alpha = try #require(
      valueAttributes.first { $0.objectValue?["name"] == .string("com.showxu.alpha") }
    )
    let empty = try #require(
      valueAttributes.first { $0.objectValue?["name"] == .string("com.showxu.empty") }
    )

    #expect((valuePayload.objectValue?["include_values"]) == (.bool(true)))
    #expect((alpha.objectValue?["value_bytes_read"]) == (.number(11)))
    #expect((alpha.objectValue?["value_truncated"]) == (.bool(false)))
    #expect(
      (alpha.objectValue?["value_base64"])
        == (.string(Data("hello-world".utf8).base64EncodedString())))
    #expect((alpha.objectValue?["value_utf8"]) == (.string("hello-world")))
    #expect((empty.objectValue?["size_bytes"]) == (.number(0)))
    #expect((empty.objectValue?["value_bytes_read"]) == (.number(0)))
    #expect((empty.objectValue?["value_truncated"]) == (.bool(false)))
    #expect((empty.objectValue?["value_base64"]) == (.string("")))
    #expect((empty.objectValue?["value_utf8"]) == (.string("")))

    let limitedResult = try registry.callTool(
      name: "file.xattrs",
      arguments: .object([
        "path": .string("download.txt"),
        "include_values": .bool(true),
        "max_value_bytes": .number(5),
      ])
    )
    let limitedPayload = try decodeTextPayload(limitedResult)
    let limitedAttributes = try #require(limitedPayload.objectValue?["attributes"]?.arrayValue)
    let limitedAlpha = try #require(
      limitedAttributes.first { $0.objectValue?["name"] == .string("com.showxu.alpha") }
    )

    #expect((limitedAlpha.objectValue?["value_bytes_read"]) == (.number(0)))
    #expect((limitedAlpha.objectValue?["value_truncated"]) == (.bool(true)))
    #expect((limitedAlpha.objectValue?["value_base64"]) == (.null))
    #expect((limitedAlpha.objectValue?["value_utf8"]) == (.null))
    #expect(
      (limitedAlpha.objectValue?["value_omitted_reason"])
        == (.string("attribute exceeds max_value_bytes")))
  }

  @Test
  func testFileXattrsRejectsWorkspaceEscapeMissingPathAndBadBounds() throws {
    let directory = try temporaryDirectory()
    try "download".write(
      to: directory.appendingPathComponent("download.txt"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.xattrs"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.xattrs",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.xattrs",
        arguments: .object(["path": .string("missing.txt")])
      )
    ) { error in
      #expect(!(error.localizedDescription.isEmpty))
    }

    expectThrows(
      try registry.callTool(
        name: "file.xattrs",
        arguments: .object([
          "path": .string("download.txt"),
          "max_value_bytes": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_value_bytes"))
    }
  }

  @Test
  func testFileRemoveXattrRemovesNamedAttribute() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("download.txt")
    try "download".write(to: file, atomically: true, encoding: .utf8)
    try setTestExtendedAttribute(
      file,
      name: "com.showxu.keep",
      value: Data("keep".utf8)
    )
    try setTestExtendedAttribute(
      file,
      name: "com.showxu.metadata:test",
      value: Data("remove".utf8)
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.remove_xattr", "file.xattrs"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.remove_xattr",
      arguments: .object([
        "path": .string("download.txt"),
        "name": .string("com.showxu.metadata:test"),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("file.remove_xattr")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("download.txt")))
    #expect((payload.objectValue?["name"]) == (.string("com.showxu.metadata:test")))
    #expect((payload.objectValue?["removed"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["attributes_before"]?.arrayValue?.contains(
        .string("com.showxu.metadata:test"))) == (true))
    #expect(
      (payload.objectValue?["attributes_after"]?.arrayValue?.contains(
        .string("com.showxu.metadata:test"))) == (false))

    let readback = try registry.callTool(
      name: "file.xattrs",
      arguments: .object(["path": .string("download.txt")])
    )
    let readbackPayload = try decodeTextPayload(readback)
    let attributes = try #require(readbackPayload.objectValue?["attributes"]?.arrayValue)
    #expect(
      (attributes.first { $0.objectValue?["name"] == .string("com.showxu.metadata:test") }) == nil)
    #expect((attributes.first { $0.objectValue?["name"] == .string("com.showxu.keep") }) != nil)
  }

  @Test
  func testFileRemoveXattrDryRunDoesNotRemoveAttribute() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("download.txt")
    try "download".write(to: file, atomically: true, encoding: .utf8)
    try setTestExtendedAttribute(
      file,
      name: "com.showxu.metadata:test",
      value: Data("keep".utf8)
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.remove_xattr", "file.xattrs"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.remove_xattr",
      arguments: .object([
        "path": .string("download.txt"),
        "name": .string("com.showxu.metadata:test"),
        "dry_run": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["removed"]) == (.bool(false)))
    #expect((payload.objectValue?["would_remove"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["attributes_after"]?.arrayValue?.contains(
        .string("com.showxu.metadata:test"))) == (true))
    #expect(
      (payload.objectValue?["would_attributes_after"]?.arrayValue?.contains(
        .string("com.showxu.metadata:test"))) == (false))

    let readback = try registry.callTool(
      name: "file.xattrs",
      arguments: .object(["path": .string("download.txt")])
    )
    let readbackPayload = try decodeTextPayload(readback)
    let attributes = try #require(readbackPayload.objectValue?["attributes"]?.arrayValue)
    #expect(
      (attributes.first { $0.objectValue?["name"] == .string("com.showxu.metadata:test") }) != nil)
  }

  @Test
  func testFileRemoveXattrRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("download.txt")
    try "download".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.remove_xattr"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.remove_xattr",
        arguments: .object([
          "path": .string("download.txt"),
          "name": .string("com.showxu.missing"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.remove_xattr",
        arguments: .object([
          "path": .string("download.txt"),
          "name": .string("bad\nname"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("control"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.remove_xattr",
        arguments: .object([
          "path": .string("../outside.txt"),
          "name": .string("com.showxu.alpha"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }
  }

  @Test
  func testFileMetadataUsesFixedMDLSArgvAndParsesPlist() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("document.txt")
    try "document".write(to: file, atomically: true, encoding: .utf8)
    let runner = FakeCommandRunner()
    runner.stdout = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>kMDItemDisplayName</key>
        <string>document.txt</string>
        <key>kMDItemFSSize</key>
        <integer>8</integer>
        <key>kMDItemWhereFroms</key>
        <array>
          <string>https://example.com/document.txt</string>
        </array>
        <key>kMDItemIsUbiquitous</key>
        <false/>
      </dict>
      </plist>
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.metadata"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "file.metadata",
      arguments: .object([
        "path": .string("document.txt"),
        "attributes": .array([
          .string("kMDItemDisplayName"),
          .string("kMDItemFSSize"),
        ]),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)
    let metadata = try #require(payload.objectValue?["metadata"]?.objectValue)

    #expect((runner.calls.first?.executable) == ("/usr/bin/mdls"))
    #expect((runner.calls.first?.arguments) == (["-plist", "-", file.path]))
    #expect((payload.objectValue?["operation"]) == (.string("file.metadata")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("document.txt")))
    #expect(
      (payload.objectValue?["requested_attributes"])
        == (.array([.string("kMDItemDisplayName"), .string("kMDItemFSSize")])))
    #expect((metadata["kMDItemDisplayName"]) == (.string("document.txt")))
    #expect((metadata["kMDItemFSSize"]) == (.number(8)))
    #expect((metadata.count) == (2))
    #expect((metadata["kMDItemWhereFroms"]) == nil)
    #expect((metadata["kMDItemIsUbiquitous"]) == nil)
    #expect((payload.objectValue?["metadata_parse_error"]) == (.null))
    #expect((payload.objectValue?["metadata_omitted_reason"]) == (.null))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testFileMetadataRejectsBadInputsAndReportsTruncation() throws {
    let directory = try temporaryDirectory()
    try "document".write(
      to: directory.appendingPathComponent("document.txt"),
      atomically: true,
      encoding: .utf8
    )
    let runner = FakeCommandRunner()
    runner.stdout = "<plist version=\"1.0\"><dict></dict></plist>"
    runner.stdoutTruncated = true
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.metadata"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "file.metadata",
      arguments: .object(["path": .string("document.txt")])
    )
    let payload = try decodeTextPayload(result)
    #expect((payload.objectValue?["metadata"]) == (.null))
    #expect((payload.objectValue?["metadata_omitted_reason"]) == (.string("stdout truncated")))

    expectThrows(
      try registry.callTool(
        name: "file.metadata",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.metadata",
        arguments: .object([
          "path": .string("document.txt"),
          "attributes": .array([.string("-bad")]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("attribute must not be an option"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.metadata",
        arguments: .object([
          "path": .string("document.txt"),
          "attributes": .array([.string("bad attribute")]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("attribute may contain only"))
    }
  }

  @Test
  func testFileReadlinkReturnsRawDestinationWithoutFollowingFinalSymlink() throws {
    let directory = try temporaryDirectory()
    let target = directory.appendingPathComponent("target.txt")
    let link = directory.appendingPathComponent("target-link")
    let outsideLink = directory.appendingPathComponent("outside-link")
    try "target".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")
    try FileManager.default.createSymbolicLink(
      atPath: outsideLink.path,
      withDestinationPath: "/tmp/computer-mcp-outside-target"
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.readlink"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.readlink",
      arguments: .object(["path": .string("target-link")])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("file.readlink")))
    #expect((payload.objectValue?["path"]) == (.string(link.path)))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("target-link")))
    #expect((payload.objectValue?["destination"]) == (.string("target.txt")))
    #expect((payload.objectValue?["destination_is_absolute"]) == (.bool(false)))
    #expect((payload.objectValue?["destination_workspace_contained"]) == (.bool(true)))
    #expect((payload.objectValue?["destination_exists"]) == (.bool(true)))
    #expect((payload.objectValue?["resolved_destination_path"]) == (.string(target.path)))
    #expect(
      (payload.objectValue?["destination_workspace_relative_path"]) == (.string("target.txt")))

    let outside = try registry.callTool(
      name: "file.readlink",
      arguments: .object(["path": .string("outside-link")])
    )
    let outsidePayload = try decodeTextPayload(outside)
    #expect((outsidePayload.objectValue?["destination_is_absolute"]) == (.bool(true)))
    #expect((outsidePayload.objectValue?["destination_workspace_contained"]) == (.bool(false)))
    #expect((outsidePayload.objectValue?["destination_workspace_relative_path"]) == (.null))
  }

  @Test
  func testFileReadlinkRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try "target".write(
      to: directory.appendingPathComponent("regular.txt"),
      atomically: true,
      encoding: .utf8
    )
    let outsideDirectory = try temporaryDirectory()
    let parentLink = directory.appendingPathComponent("outside-parent")
    try FileManager.default.createSymbolicLink(
      atPath: parentLink.path,
      withDestinationPath: outsideDirectory.path
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.readlink"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.readlink",
        arguments: .object(["path": .string("regular.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not a symbolic link"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.readlink",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.readlink",
        arguments: .object(["path": .string("outside-parent/link")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("parent symlink"))
    }
  }

  @Test
  func testFileResolveReportsLexicalAndResolvedWorkspacePaths() throws {
    let directory = try temporaryDirectory()
    let target = directory.appendingPathComponent("target.txt")
    let link = directory.appendingPathComponent("target-link")
    try "target".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.resolve"]),
        workspaceDirectory: directory
      )
    )

    let fileResult = try registry.callTool(
      name: "file.resolve",
      arguments: .object(["path": .string("./target.txt")])
    )
    let filePayload = try decodeTextPayload(fileResult)
    #expect((filePayload.objectValue?["operation"]) == (.string("file.resolve")))
    #expect((filePayload.objectValue?["input_path"]) == (.string("./target.txt")))
    #expect((filePayload.objectValue?["path"]) == (.string(target.path)))
    #expect((filePayload.objectValue?["workspace_relative_path"]) == (.string("target.txt")))
    #expect((filePayload.objectValue?["exists"]) == (.bool(true)))
    #expect((filePayload.objectValue?["is_symlink"]) == (.bool(false)))
    #expect((filePayload.objectValue?["resolved_path"]) == (.string(target.path)))
    #expect((filePayload.objectValue?["resolved_workspace_contained"]) == (.bool(true)))
    #expect(
      (filePayload.objectValue?["resolved_workspace_relative_path"]) == (.string("target.txt")))

    let linkResult = try registry.callTool(
      name: "file.resolve",
      arguments: .object(["path": .string("target-link")])
    )
    let linkPayload = try decodeTextPayload(linkResult)
    #expect((linkPayload.objectValue?["path"]) == (.string(link.path)))
    #expect((linkPayload.objectValue?["workspace_relative_path"]) == (.string("target-link")))
    #expect((linkPayload.objectValue?["exists"]) == (.bool(true)))
    #expect((linkPayload.objectValue?["is_symlink"]) == (.bool(true)))
    #expect((linkPayload.objectValue?["symlink_destination"]) == (.string("target.txt")))
    #expect((linkPayload.objectValue?["resolved_path"]) == (.string(target.path)))
    #expect(
      (linkPayload.objectValue?["resolved_workspace_relative_path"]) == (.string("target.txt")))

    let missingResult = try registry.callTool(
      name: "file.resolve",
      arguments: .object(["path": .string("missing/new.txt")])
    )
    let missingPayload = try decodeTextPayload(missingResult)
    #expect((missingPayload.objectValue?["exists"]) == (.bool(false)))
    #expect(
      (missingPayload.objectValue?["workspace_relative_path"]) == (.string("missing/new.txt")))
    #expect((missingPayload.objectValue?["resolved_workspace_contained"]) == (.bool(true)))
  }

  @Test
  func testFileResolveRejectsWorkspaceEscapeThroughParentSymlink() throws {
    let directory = try temporaryDirectory()
    let outsideDirectory = try temporaryDirectory()
    let parentLink = directory.appendingPathComponent("outside-parent")
    try FileManager.default.createSymbolicLink(
      atPath: parentLink.path,
      withDestinationPath: outsideDirectory.path
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.resolve"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.resolve",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.resolve",
        arguments: .object(["path": .string("outside-parent/file")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("parent symlink"))
    }
  }

  @Test
  func testJSONReadParsesWorkspaceJSONIntoValue() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("config.json")
    try """
    {
      "name": "computer-mcp",
      "enabled": true,
      "retry_count": 3,
      "tags": ["gateway", "json"],
      "nested": {
        "threshold": 0.75
      }
    }
    """.write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["json.read"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "json.read",
      arguments: .object(["path": .string("config.json")])
    )
    let payload = try decodeTextPayload(result)
    let value = try #require(payload.objectValue?["value"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("json.read")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("config.json")))
    #expect((try #require(payload.objectValue?["bytes_read"]?.numberValue)) > (0))
    #expect((value["name"]) == (.string("computer-mcp")))
    #expect((value["enabled"]) == (.bool(true)))
    #expect((value["retry_count"]) == (.number(3)))
    #expect((value["tags"]) == (.array([.string("gateway"), .string("json")])))
    #expect((value["nested"]?.objectValue?["threshold"]) == (.number(0.75)))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testJSONReadRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "{bad".write(
      to: directory.appendingPathComponent("bad.json"),
      atomically: true,
      encoding: .utf8
    )
    try "[1,2,3]".write(
      to: directory.appendingPathComponent("large.json"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["json.read"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "json.read",
        arguments: .object(["path": .string("../outside.json")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "json.read",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "json.read",
        arguments: .object([
          "path": .string("large.json"),
          "max_bytes": .number(3),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("File exceeds max_bytes"))
    }

    expectThrows(
      try registry.callTool(
        name: "json.read",
        arguments: .object(["path": .string("bad.json")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse JSON"))
    }
  }

  @Test
  func testJSONLinesReadParsesBoundedRecordsAndErrors() throws {
    let directory = try temporaryDirectory()
    try """
    {"event":"ready","count":1}

    [1,2]
    not json
    {"event":"done"}
    """.write(
      to: directory.appendingPathComponent("events.jsonl"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["jsonl.read"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "jsonl.read",
      arguments: .object([
        "path": .string("events.jsonl"),
        "max_records": .number(2),
        "max_errors": .number(1),
      ])
    )
    let payload = try decodeTextPayload(result)
    let records = try #require(payload.objectValue?["records"]?.arrayValue)
    let errors = try #require(payload.objectValue?["errors"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("jsonl.read")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("events.jsonl")))
    #expect((payload.objectValue?["record_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_record_count"]) == (.number(2)))
    #expect((payload.objectValue?["record_count_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["error_count"]) == (.number(1)))
    #expect((payload.objectValue?["returned_error_count"]) == (.number(1)))
    #expect((payload.objectValue?["skipped_blank_line_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((records[0].objectValue?["line"]) == (.number(1)))
    #expect((records[0].objectValue?["value"]?.objectValue?["event"]) == (.string("ready")))
    #expect((records[0].objectValue?["value"]?.objectValue?["count"]) == (.number(1)))
    #expect((records[1].objectValue?["line"]) == (.number(3)))
    #expect((records[1].objectValue?["value"]) == (.array([.number(1), .number(2)])))
    #expect((errors.first?.objectValue?["line"]) == (.number(4)))
    #expect((errors.first?.objectValue?["raw_preview"]) == (.string("not json")))
  }

  @Test
  func testJSONLinesReadHandlesStartLineAndPartialWindow() throws {
    let directory = try temporaryDirectory()
    try """
    {"a":1}
    {"b":2}
    {"c":3}
    """.write(
      to: directory.appendingPathComponent("events.ndjson"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["jsonl.read"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "jsonl.read",
      arguments: .object([
        "path": .string("events.ndjson"),
        "start_line": .number(2),
        "max_bytes": .number(18),
      ])
    )
    let payload = try decodeTextPayload(result)
    let records = try #require(payload.objectValue?["records"]?.arrayValue)

    #expect((payload.objectValue?["content_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["last_line_may_be_partial"]) == (.bool(true)))
    #expect((payload.objectValue?["partial_line_dropped"]) == (.bool(true)))
    #expect((payload.objectValue?["record_count"]) == (.number(1)))
    #expect((payload.objectValue?["parse_incomplete"]) == (.bool(true)))
    #expect((records.first?.objectValue?["line"]) == (.number(2)))
    #expect((records.first?.objectValue?["value"]?.objectValue?["b"]) == (.number(2)))

    let partialResult = try registry.callTool(
      name: "jsonl.read",
      arguments: .object([
        "path": .string("events.ndjson"),
        "max_bytes": .number(10),
        "include_partial_line": .bool(true),
      ])
    )
    let partialPayload = try decodeTextPayload(partialResult)
    #expect((partialPayload.objectValue?["partial_line_dropped"]) == (.bool(false)))
    #expect((partialPayload.objectValue?["error_count"]) == (.number(1)))
  }

  @Test
  func testJSONLinesReadRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("bad.jsonl"))
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["jsonl.read"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "jsonl.read",
        arguments: .object(["path": .string("../outside.jsonl")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "jsonl.read",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "jsonl.read",
        arguments: .object(["path": .string("bad.jsonl")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    expectThrows(
      try registry.callTool(
        name: "jsonl.read",
        arguments: .object([
          "path": .string("bad.jsonl"),
          "max_records": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_records"))
    }
  }

  @Test
  func testJSONWriteDryRunAndConfirmedWrite() throws {
    let directory = try temporaryDirectory()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["json.write", "json.read"]),
        workspaceDirectory: directory
      )
    )

    let dryRunResult = try registry.callTool(
      name: "json.write",
      arguments: .object([
        "path": .string("config/out.json"),
        "create_directories": .bool(true),
        "preview_max_bytes": .number(128),
        "value": .object([
          "z": .number(1),
          "a": .array([.string("x")]),
        ]),
      ])
    )
    let dryRunPayload = try decodeTextPayload(dryRunResult)
    let preview = try #require(
      dryRunPayload.objectValue?["preview"]?.objectValue?["content"]?
        .stringValue)

    #expect((dryRunPayload.objectValue?["operation"]) == (.string("json.write")))
    #expect((dryRunPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((dryRunPayload.objectValue?["written"]) == (.bool(false)))
    #expect((dryRunPayload.objectValue?["would_create"]) == (.bool(true)))
    let aKeyRange = try #require(preview.range(of: "\"a\""))
    let zKeyRange = try #require(preview.range(of: "\"z\""))
    #expect(aKeyRange.lowerBound < zKeyRange.lowerBound)
    #expect(
      !(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("config/out.json").path)))

    expectThrows(
      try registry.callTool(
        name: "json.write",
        arguments: .object([
          "path": .string("config/out.json"),
          "create_directories": .bool(true),
          "dry_run": .bool(false),
          "value": .object(["ok": .bool(true)]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_write=true"))
    }

    let writeResult = try registry.callTool(
      name: "json.write",
      arguments: .object([
        "path": .string("config/out.json"),
        "create_directories": .bool(true),
        "dry_run": .bool(false),
        "confirm_write": .bool(true),
        "value": .object([
          "z": .number(1),
          "a": .array([.string("x")]),
        ]),
      ])
    )
    let writePayload = try decodeTextPayload(writeResult)

    #expect((writePayload.objectValue?["written"]) == (.bool(true)))
    #expect((try #require(writePayload.objectValue?["bytes_written"]?.numberValue)) > (0))
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("config/out.json").path))

    let readResult = try registry.callTool(
      name: "json.read",
      arguments: .object(["path": .string("config/out.json")])
    )
    let readPayload = try decodeTextPayload(readResult)
    let value = try #require(readPayload.objectValue?["value"]?.objectValue)
    #expect((value["z"]) == (.number(1)))
    #expect((value["a"]) == (.array([.string("x")])))
  }

  @Test
  func testJSONWriteRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "{}".write(
      to: directory.appendingPathComponent("existing.json"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["json.write"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "json.write",
        arguments: .object([
          "path": .string("../outside.json"),
          "value": .object(["ok": .bool(true)]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "json.write",
        arguments: .object([
          "path": .string("missing/out.json"),
          "value": .object(["ok": .bool(true)]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Parent directory does not exist"))
    }

    expectThrows(
      try registry.callTool(
        name: "json.write",
        arguments: .object([
          "path": .string("folder"),
          "value": .object(["ok": .bool(true)]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is a directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "json.write",
        arguments: .object([
          "path": .string("existing.json"),
          "value": .object(["ok": .bool(true)]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Refusing to overwrite"))
    }

    expectThrows(
      try registry.callTool(
        name: "json.write",
        arguments: .object([
          "path": .string("too-large.json"),
          "max_bytes": .number(4),
          "value": .object(["large": .string("value")]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Encoded JSON exceeds max_bytes"))
    }
  }

  @Test
  func testTOMLReadParsesWorkspaceTOMLIntoValue() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("config.toml")
    try """
    name = "computer-mcp"
    enabled = true
    retry_count = 3
    threshold = 0.75
    tags = ["gateway", "toml"]
    release_date = 2026-07-07
    start_time = 09:30:15

    [nested]
    mode = "safe"
    """.write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["toml.read"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "toml.read",
      arguments: .object(["path": .string("config.toml")])
    )
    let payload = try decodeTextPayload(result)
    let value = try #require(payload.objectValue?["value"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("toml.read")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("config.toml")))
    #expect((try #require(payload.objectValue?["bytes_read"]?.numberValue)) > (0))
    #expect((value["name"]) == (.string("computer-mcp")))
    #expect((value["enabled"]) == (.bool(true)))
    #expect((value["retry_count"]) == (.number(3)))
    #expect((value["threshold"]) == (.number(0.75)))
    #expect((value["tags"]) == (.array([.string("gateway"), .string("toml")])))
    #expect((value["nested"]?.objectValue?["mode"]) == (.string("safe")))
    #expect((value["release_date"]?.objectValue?["type"]) == (.string("local_date")))
    #expect((value["release_date"]?.objectValue?["value"]) == (.string("2026-07-07")))
    #expect((value["start_time"]?.objectValue?["type"]) == (.string("local_time")))
    #expect((value["start_time"]?.objectValue?["value"]) == (.string("09:30:15")))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testTOMLReadRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "name = ".write(
      to: directory.appendingPathComponent("bad.toml"),
      atomically: true,
      encoding: .utf8
    )
    try "name = \"abcd\"".write(
      to: directory.appendingPathComponent("large.toml"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["toml.read"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "toml.read",
        arguments: .object(["path": .string("../outside.toml")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "toml.read",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "toml.read",
        arguments: .object([
          "path": .string("large.toml"),
          "max_bytes": .number(3),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("File exceeds max_bytes"))
    }

    expectThrows(
      try registry.callTool(
        name: "toml.read",
        arguments: .object(["path": .string("bad.toml")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse TOML"))
    }
  }

  @Test
  func testYAMLReadParsesWorkspaceYAMLIntoDocuments() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("config.yaml")
    try """
    name: computer-mcp
    enabled: true
    retry_count: 3
    threshold: 0.75
    created_at: 2026-07-09T01:02:03Z
    tags:
      - gateway
      - yaml
    nested:
      mode: safe
    not_a_number: .nan
    ---
    items:
      - id: 1
        label: first
    """.write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["yaml.read"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "yaml.read",
      arguments: .object([
        "path": .string("config.yaml"),
        "max_documents": .number(10),
      ])
    )
    let payload = try decodeTextPayload(result)
    let documents = try #require(payload.objectValue?["documents"]?.arrayValue)
    let first = try #require(documents.first?.objectValue?["value"]?.objectValue)
    let second = try #require(documents.last?.objectValue?["value"]?.objectValue)
    let topLevel = try #require(payload.objectValue?["value"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("yaml.read")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("config.yaml")))
    #expect((try #require(payload.objectValue?["bytes_read"]?.numberValue)) > (0))
    #expect((payload.objectValue?["document_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_document_count"]) == (.number(2)))
    #expect((payload.objectValue?["document_count_truncated"]) == (.bool(false)))
    #expect((topLevel.count) == (2))
    #expect((first["name"]) == (.string("computer-mcp")))
    #expect((first["enabled"]) == (.bool(true)))
    #expect((first["retry_count"]) == (.number(3)))
    #expect((first["threshold"]) == (.number(0.75)))
    #expect((first["tags"]) == (.array([.string("gateway"), .string("yaml")])))
    #expect((first["nested"]?.objectValue?["mode"]) == (.string("safe")))
    #expect((first["created_at"]?.objectValue?["type"]) == (.string("date")))
    #expect((first["not_a_number"]?.objectValue?["type"]) == (.string("non_finite_number")))
    #expect((second["items"]?.arrayValue?.first?.objectValue?["label"]) == (.string("first")))
    #expect((payload.objectValue?["conversion"]?.objectValue?["date_count"]) == (.number(1)))
    #expect(
      (payload.objectValue?["conversion"]?.objectValue?["non_finite_number_count"]) == (.number(1)))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testYAMLReadRejectsBadInputsAndTruncatesDocuments() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "name: [unterminated".write(
      to: directory.appendingPathComponent("bad.yaml"),
      atomically: true,
      encoding: .utf8
    )
    try "name: abcd".write(
      to: directory.appendingPathComponent("large.yaml"),
      atomically: true,
      encoding: .utf8
    )
    try "first: true\n---\nsecond: true\n".write(
      to: directory.appendingPathComponent("multi.yaml"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["yaml.read"]),
        workspaceDirectory: directory
      )
    )

    let truncatedResult = try registry.callTool(
      name: "yaml.read",
      arguments: .object([
        "path": .string("multi.yaml"),
        "max_documents": .number(1),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["document_count"]) == (.number(2)))
    #expect((truncatedPayload.objectValue?["returned_document_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["document_count_truncated"]) == (.bool(true)))

    expectThrows(
      try registry.callTool(
        name: "yaml.read",
        arguments: .object(["path": .string("../outside.yaml")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "yaml.read",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "yaml.read",
        arguments: .object([
          "path": .string("large.yaml"),
          "max_bytes": .number(3),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("File exceeds max_bytes"))
    }

    expectThrows(
      try registry.callTool(
        name: "yaml.read",
        arguments: .object(["path": .string("bad.yaml")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse YAML"))
    }
  }

  @Test
  func testXMLReadParsesWorkspaceXMLIntoElementTree() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("config.xml")
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <root enabled="true">
      <item id="1">First</item>
      <item id="2"><name>Second</name><![CDATA[raw <cdata>]]></item>
    </root>
    """.write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["xml.read"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "xml.read",
      arguments: .object(["path": .string("config.xml")])
    )
    let payload = try decodeTextPayload(result)
    let root = try #require(payload.objectValue?["root"]?.objectValue)
    let children = try #require(root["children"]?.arrayValue)
    let firstItem = try #require(children.first?.objectValue)
    let secondItem = try #require(children.last?.objectValue)
    let nameNode = try #require(secondItem["children"]?.arrayValue?.first?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("xml.read")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("config.xml")))
    #expect((try #require(payload.objectValue?["bytes_read"]?.numberValue)) > (0))
    #expect((payload.objectValue?["element_count"]) == (.number(4)))
    #expect((payload.objectValue?["returned_element_count"]) == (.number(4)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((root["name"]) == (.string("root")))
    #expect((root["attributes"]?.objectValue?["enabled"]) == (.string("true")))
    #expect((root["child_count"]) == (.number(2)))
    #expect((root["returned_child_count"]) == (.number(2)))
    #expect((firstItem["name"]) == (.string("item")))
    #expect((firstItem["attributes"]?.objectValue?["id"]) == (.string("1")))
    #expect((firstItem["text"]) == (.string("First")))
    #expect((secondItem["text"]) == (.string("raw <cdata>")))
    #expect((nameNode["name"]) == (.string("name")))
    #expect((nameNode["text"]) == (.string("Second")))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testXMLReadRejectsBadInputsAndTruncatesTree() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "<root>".write(
      to: directory.appendingPathComponent("bad.xml"), atomically: true, encoding: .utf8)
    try "<root>abcd</root>".write(
      to: directory.appendingPathComponent("large.xml"), atomically: true, encoding: .utf8)
    try "<root><a/><b/></root>".write(
      to: directory.appendingPathComponent("many.xml"), atomically: true, encoding: .utf8)
    try "<root>abcdef</root>".write(
      to: directory.appendingPathComponent("text.xml"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["xml.read"]),
        workspaceDirectory: directory
      )
    )

    let truncatedResult = try registry.callTool(
      name: "xml.read",
      arguments: .object([
        "path": .string("many.xml"),
        "max_nodes": .number(2),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedRoot = try #require(truncatedPayload.objectValue?["root"]?.objectValue)
    #expect((truncatedPayload.objectValue?["element_count"]) == (.number(3)))
    #expect((truncatedPayload.objectValue?["returned_element_count"]) == (.number(2)))
    #expect((truncatedPayload.objectValue?["node_count_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((truncatedRoot["child_count"]) == (.number(2)))
    #expect((truncatedRoot["returned_child_count"]) == (.number(1)))

    let textResult = try registry.callTool(
      name: "xml.read",
      arguments: .object([
        "path": .string("text.xml"),
        "max_text_bytes": .number(3),
      ])
    )
    let textPayload = try decodeTextPayload(textResult)
    let textRoot = try #require(textPayload.objectValue?["root"]?.objectValue)
    #expect((textRoot["text"]) == (.string("abc")))
    #expect((textRoot["text_truncated"]) == (.bool(true)))
    #expect((textPayload.objectValue?["text_truncated"]) == (.bool(true)))

    expectThrows(
      try registry.callTool(
        name: "xml.read",
        arguments: .object(["path": .string("../outside.xml")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "xml.read",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "xml.read",
        arguments: .object([
          "path": .string("large.xml"),
          "max_bytes": .number(3),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("File exceeds max_bytes"))
    }

    expectThrows(
      try registry.callTool(
        name: "xml.read",
        arguments: .object(["path": .string("bad.xml")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse XML"))
    }
  }

  @Test
  func testPlistReadParsesWorkspacePropertyListIntoJSON() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("Info.plist")
    let plist: [String: Any] = [
      "CFBundleIdentifier": "com.example.tool",
      "Enabled": true,
      "RetryCount": 3,
      "Tags": ["alpha", "beta"],
      "Payload": Data([0xde, 0xad, 0xbe, 0xef]),
      "CreatedAt": Date(timeIntervalSince1970: 1_700_000_000),
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try data.write(to: file)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["plist.read"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "plist.read",
      arguments: .object(["path": .string("Info.plist")])
    )
    let payload = try decodeTextPayload(result)
    let value = try #require(payload.objectValue?["value"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("plist.read")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("Info.plist")))
    #expect((payload.objectValue?["format"]) == (.string("xml")))
    #expect((try #require(payload.objectValue?["bytes_read"]?.numberValue)) > (0))
    #expect((value["CFBundleIdentifier"]) == (.string("com.example.tool")))
    #expect((value["Enabled"]) == (.bool(true)))
    #expect((value["RetryCount"]) == (.number(3)))
    #expect((value["Tags"]) == (.array([.string("alpha"), .string("beta")])))
    #expect((value["Payload"]?.objectValue?["type"]) == (.string("data")))
    #expect((value["Payload"]?.objectValue?["base64"]) == (.string("3q2+7w==")))
    #expect((value["CreatedAt"]?.objectValue?["type"]) == (.string("date")))
    #expect((value["CreatedAt"]?.objectValue?["iso8601"]?.stringValue) != nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testPlistReadRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "not plist".write(
      to: directory.appendingPathComponent("bad.plist"),
      atomically: true,
      encoding: .utf8
    )
    try "abcd".write(
      to: directory.appendingPathComponent("large.plist"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["plist.read"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "plist.read",
        arguments: .object(["path": .string("../outside.plist")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "plist.read",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "plist.read",
        arguments: .object([
          "path": .string("large.plist"),
          "max_bytes": .number(3),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("File exceeds max_bytes"))
    }

    expectThrows(
      try registry.callTool(
        name: "plist.read",
        arguments: .object(["path": .string("bad.plist")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse property list"))
    }
  }

  @Test
  func testStructuredGetReadsExactPathsAcrossFormats() throws {
    let directory = try temporaryDirectory()
    let configDirectory = directory.appendingPathComponent("config")
    try FileManager.default.createDirectory(
      at: configDirectory,
      withIntermediateDirectories: true
    )
    try """
    {
      "scripts": {
        "test": "swift test",
        "matrix": [
          {"name": "unit"},
          {"name": "integration"}
        ]
      },
      "enabled": true
    }
    """.write(
      to: configDirectory.appendingPathComponent("package.json"),
      atomically: true,
      encoding: .utf8
    )
    try """
    ---
    jobs:
      build:
        steps:
          - name: Checkout
          - name: Test
    ---
    jobs:
      deploy:
        steps:
          - name: Ship
    """.write(
      to: configDirectory.appendingPathComponent("workflow.yaml"),
      atomically: true,
      encoding: .utf8
    )
    try """
    [server]
    name = "computer-mcp"
    ports = [8080, 9090]
    """.write(
      to: configDirectory.appendingPathComponent("settings.toml"),
      atomically: true,
      encoding: .utf8
    )
    let plist: [String: Any] = [
      "CFBundleIdentifier": "com.example.app",
      "Nested": [
        "Items": ["first", "second"]
      ],
    ]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try plistData.write(to: configDirectory.appendingPathComponent("Info.plist"))
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["structured.get"]),
        workspaceDirectory: directory
      )
    )

    let jsonResult = try registry.callTool(
      name: "structured.get",
      arguments: .object([
        "path": .string("config/package.json"),
        "query_path": .array([
          .string("scripts"),
          .string("matrix"),
          .number(1),
          .string("name"),
        ]),
      ])
    )
    let jsonPayload = try decodeTextPayload(jsonResult)
    #expect((jsonPayload.objectValue?["operation"]) == (.string("structured.get")))
    #expect((jsonPayload.objectValue?["format"]) == (.string("json")))
    #expect((jsonPayload.objectValue?["query_pointer"]) == (.string("/scripts/matrix/1/name")))
    #expect((jsonPayload.objectValue?["matched"]) == (.bool(true)))
    #expect((jsonPayload.objectValue?["value_kind"]) == (.string("string")))
    #expect((jsonPayload.objectValue?["value"]) == (.string("integration")))
    #expect((jsonPayload.objectValue?["failure"]?.objectValue) == nil)

    let yamlResult = try registry.callTool(
      name: "structured.get",
      arguments: .object([
        "path": .string("config/workflow.yaml"),
        "query_path": .array([
          .number(1),
          .string("jobs"),
          .string("deploy"),
          .string("steps"),
          .number(0),
          .string("name"),
        ]),
      ])
    )
    let yamlPayload = try decodeTextPayload(yamlResult)
    let yamlMetadata = try #require(yamlPayload.objectValue?["document_metadata"]?.objectValue)
    #expect((yamlPayload.objectValue?["format"]) == (.string("yaml")))
    #expect((yamlPayload.objectValue?["value"]) == (.string("Ship")))
    #expect((yamlMetadata["kind"]) == (.string("yaml")))
    #expect((yamlMetadata["document_count"]) == (.number(2)))

    let tomlResult = try registry.callTool(
      name: "structured.get",
      arguments: .object([
        "path": .string("config/settings.toml"),
        "query_path": .array([
          .string("server"),
          .string("ports"),
          .number(0),
        ]),
      ])
    )
    let tomlPayload = try decodeTextPayload(tomlResult)
    #expect((tomlPayload.objectValue?["format"]) == (.string("toml")))
    #expect((tomlPayload.objectValue?["value"]) == (.number(8080)))

    let plistResult = try registry.callTool(
      name: "structured.get",
      arguments: .object([
        "path": .string("config/Info.plist"),
        "query_path": .array([
          .string("Nested"),
          .string("Items"),
          .number(1),
        ]),
      ])
    )
    let plistPayload = try decodeTextPayload(plistResult)
    #expect((plistPayload.objectValue?["format"]) == (.string("plist")))
    #expect((plistPayload.objectValue?["value"]) == (.string("second")))

    let missingResult = try registry.callTool(
      name: "structured.get",
      arguments: .object([
        "path": .string("config/package.json"),
        "query_path": .array([
          .string("scripts"),
          .string("missing"),
        ]),
      ])
    )
    let missingPayload = try decodeTextPayload(missingResult)
    let failure = try #require(missingPayload.objectValue?["failure"]?.objectValue)
    #expect((missingPayload.objectValue?["matched"]) == (.bool(false)))
    #expect((missingPayload.objectValue?["value"]) == (.null))
    #expect((failure["reason"]) == (.string("missing_key")))
    #expect((failure["index"]) == (.number(1)))
    #expect((failure["actual_kind"]) == (.string("object")))
  }

  @Test
  func testStructuredGetRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try #"{"items":[1]}"#.write(
      to: directory.appendingPathComponent("data.json"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["structured.get"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "structured.get",
        arguments: .object([
          "path": .string("../data.json"),
          "query_path": .array([]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "structured.get",
        arguments: .object([
          "path": .string("folder"),
          "query_path": .array([]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "structured.get",
        arguments: .object([
          "path": .string("data.json"),
          "query_path": .string("items"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("query_path must be an array"))
    }

    expectThrows(
      try registry.callTool(
        name: "structured.get",
        arguments: .object([
          "path": .string("data.json"),
          "query_path": .array([.number(-1)]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("zero or greater"))
    }

    expectThrows(
      try registry.callTool(
        name: "structured.get",
        arguments: .object([
          "path": .string("data.json"),
          "format": .string("jsonpath"),
          "query_path": .array([]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("format must be one of"))
    }

    expectThrows(
      try registry.callTool(
        name: "structured.get",
        arguments: .object([
          "path": .string("data.json"),
          "query_path": .array([]),
          "max_bytes": .number(3),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("File exceeds max_bytes"))
    }
  }

  @Test
  func testPlistWriteDryRunAndConfirmedWrite() throws {
    let directory = try temporaryDirectory()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["plist.write", "plist.read"]),
        workspaceDirectory: directory
      )
    )

    let value: JSONValue = .object([
      "CFBundleIdentifier": .string("com.example.tool"),
      "Enabled": .bool(true),
      "RetryCount": .number(3),
      "Tags": .array([.string("alpha"), .string("beta")]),
      "Payload": .object([
        "type": .string("data"),
        "base64": .string("3q2+7w=="),
      ]),
      "CreatedAt": .object([
        "type": .string("date"),
        "iso8601": .string("2023-11-14T22:13:20Z"),
      ]),
    ])

    let dryRunResult = try registry.callTool(
      name: "plist.write",
      arguments: .object([
        "path": .string("generated/Info.plist"),
        "create_directories": .bool(true),
        "preview_max_bytes": .number(512),
        "value": value,
      ])
    )
    let dryRunPayload = try decodeTextPayload(dryRunResult)
    let preview = try #require(dryRunPayload.objectValue?["preview"]?.objectValue)

    #expect((dryRunPayload.objectValue?["operation"]) == (.string("plist.write")))
    #expect((dryRunPayload.objectValue?["format"]) == (.string("xml")))
    #expect((dryRunPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((dryRunPayload.objectValue?["written"]) == (.bool(false)))
    #expect((dryRunPayload.objectValue?["would_create"]) == (.bool(true)))
    #expect((preview["encoding"]) == (.string("utf8")))
    #expect(preview["content"]?.stringValue?.contains("CFBundleIdentifier") == true)
    #expect(
      !(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("generated/Info.plist").path)))

    expectThrows(
      try registry.callTool(
        name: "plist.write",
        arguments: .object([
          "path": .string("generated/Info.plist"),
          "create_directories": .bool(true),
          "dry_run": .bool(false),
          "value": value,
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_write=true"))
    }

    let writeResult = try registry.callTool(
      name: "plist.write",
      arguments: .object([
        "path": .string("generated/Info.plist"),
        "create_directories": .bool(true),
        "dry_run": .bool(false),
        "confirm_write": .bool(true),
        "value": value,
      ])
    )
    let writePayload = try decodeTextPayload(writeResult)

    #expect((writePayload.objectValue?["written"]) == (.bool(true)))
    #expect((try #require(writePayload.objectValue?["bytes_written"]?.numberValue)) > (0))
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("generated/Info.plist").path))

    let readResult = try registry.callTool(
      name: "plist.read",
      arguments: .object(["path": .string("generated/Info.plist")])
    )
    let readPayload = try decodeTextPayload(readResult)
    let readValue = try #require(readPayload.objectValue?["value"]?.objectValue)
    #expect((readValue["CFBundleIdentifier"]) == (.string("com.example.tool")))
    #expect((readValue["Enabled"]) == (.bool(true)))
    #expect((readValue["RetryCount"]) == (.number(3)))
    #expect((readValue["Payload"]?.objectValue?["type"]) == (.string("data")))
    #expect((readValue["Payload"]?.objectValue?["base64"]) == (.string("3q2+7w==")))
    #expect((readValue["CreatedAt"]?.objectValue?["type"]) == (.string("date")))
    #expect((readValue["CreatedAt"]?.objectValue?["iso8601"]?.stringValue) != nil)
  }

  @Test
  func testPlistWriteRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "old".write(
      to: directory.appendingPathComponent("existing.plist"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["plist.write"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "plist.write",
        arguments: .object([
          "path": .string("../outside.plist"),
          "value": .object(["ok": .bool(true)]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "plist.write",
        arguments: .object([
          "path": .string("missing/out.plist"),
          "value": .object(["ok": .bool(true)]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Parent directory does not exist"))
    }

    expectThrows(
      try registry.callTool(
        name: "plist.write",
        arguments: .object([
          "path": .string("folder"),
          "value": .object(["ok": .bool(true)]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is a directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "plist.write",
        arguments: .object([
          "path": .string("existing.plist"),
          "value": .object(["ok": .bool(true)]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Refusing to overwrite"))
    }

    expectThrows(
      try registry.callTool(
        name: "plist.write",
        arguments: .object([
          "path": .string("bad.plist"),
          "format": .string("openstep"),
          "value": .object(["ok": .bool(true)]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("format must be xml or binary"))
    }

    expectThrows(
      try registry.callTool(
        name: "plist.write",
        arguments: .object([
          "path": .string("null.plist"),
          "value": .object(["bad": .null]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("do not support null"))
    }

    expectThrows(
      try registry.callTool(
        name: "plist.write",
        arguments: .object([
          "path": .string("bad-date.plist"),
          "value": .object([
            "CreatedAt": .object([
              "type": .string("date"),
              "iso8601": .string("not-a-date"),
            ])
          ]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Invalid property list date"))
    }

    expectThrows(
      try registry.callTool(
        name: "plist.write",
        arguments: .object([
          "path": .string("too-large.plist"),
          "max_bytes": .number(8),
          "value": .object(["large": .string("value")]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Encoded property list exceeds max_bytes"))
    }
  }

  @Test
  func testCSVReadParsesDelimitedPreview() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("data.csv")
    try """
    name,note,count,extra
    Alpha,"hello, world",1,a
    Beta,"two
    lines",2,b
    Gamma,done,3,c
    """.write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["csv.read"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "csv.read",
      arguments: .object([
        "path": .string("data.csv"),
        "max_rows": .number(2),
        "max_columns": .number(3),
      ])
    )
    let payload = try decodeTextPayload(result)
    let headers = try #require(payload.objectValue?["headers"]?.arrayValue)
    let rows = try #require(payload.objectValue?["rows"]?.arrayValue)
    let firstCells = try #require(rows.first?.objectValue?["cells"]?.arrayValue)
    let secondCells = try #require(rows.last?.objectValue?["cells"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("csv.read")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("data.csv")))
    #expect((payload.objectValue?["delimiter"]) == (.string("comma")))
    #expect((payload.objectValue?["delimiter_source"]) == (.string("auto")))
    #expect((payload.objectValue?["has_header"]) == (.bool(true)))
    #expect((headers) == ([.string("name"), .string("note"), .string("count")]))
    #expect((payload.objectValue?["header_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_row_count"]) == (.number(2)))
    #expect((rows.first?.objectValue?["record_number"]) == (.number(2)))
    #expect((firstCells) == ([.string("Alpha"), .string("hello, world"), .string("1")]))
    #expect((secondCells) == ([.string("Beta"), .string("two\nlines"), .string("2")]))
    #expect((payload.objectValue?["row_count_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["column_count_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["parse_incomplete"]) == (.bool(false)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testCSVReadSupportsTSVAndHeaderlessRows() throws {
    let directory = try temporaryDirectory()
    try "a\tb\n1\t2\n".write(
      to: directory.appendingPathComponent("data.tsv"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["csv.read"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "csv.read",
      arguments: .object([
        "path": .string("data.tsv"),
        "delimiter": .string("tab"),
        "has_header": .bool(false),
      ])
    )
    let payload = try decodeTextPayload(result)
    let rows = try #require(payload.objectValue?["rows"]?.arrayValue)

    #expect((payload.objectValue?["delimiter"]) == (.string("tab")))
    #expect((payload.objectValue?["delimiter_character"]) == (.string("\t")))
    #expect((payload.objectValue?["delimiter_source"]) == (.string("configured")))
    #expect((payload.objectValue?["headers"]) == (.array([])))
    #expect((payload.objectValue?["returned_row_count"]) == (.number(2)))
    #expect((rows.first?.objectValue?["record_number"]) == (.number(1)))
    #expect((rows.first?.objectValue?["cells"]?.arrayValue) == ([.string("a"), .string("b")]))
  }

  @Test
  func testCSVReadRejectsBadInputsAndReportsIncompleteWindows() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("invalid.csv"))
    try "a,\"unterminated".write(
      to: directory.appendingPathComponent("partial.csv"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["csv.read"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "csv.read",
        arguments: .object(["path": .string("../outside.csv")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "csv.read",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "csv.read",
        arguments: .object([
          "path": .string("partial.csv"),
          "delimiter": .string("\n"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("delimiter must be"))
    }

    expectThrows(
      try registry.callTool(
        name: "csv.read",
        arguments: .object([
          "path": .string("partial.csv"),
          "max_rows": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_rows"))
    }

    expectThrows(
      try registry.callTool(
        name: "csv.read",
        arguments: .object([
          "path": .string("partial.csv"),
          "max_columns": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_columns"))
    }

    expectThrows(
      try registry.callTool(
        name: "csv.read",
        arguments: .object(["path": .string("invalid.csv")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    let truncatedResult = try registry.callTool(
      name: "csv.read",
      arguments: .object([
        "path": .string("partial.csv"),
        "max_bytes": .number(6),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)

    #expect((truncatedPayload.objectValue?["content_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["parse_incomplete"]) == (.bool(true)))
  }

  @Test
  func testSQLiteSchemaUsesReadonlyJSONCLIAndParsesEntries() throws {
    let directory = try temporaryDirectory()
    let database = directory.appendingPathComponent("app.db")
    try "not actually read by fake runner".write(to: database, atomically: true, encoding: .utf8)
    let runner = FakeCommandRunner()
    let schemaJSON = """
      [
        {
          "type": "table",
          "name": "items",
          "tbl_name": "items",
          "sql": "CREATE TABLE items(id INTEGER, name TEXT)"
        },
        {
          "type": "index",
          "name": "idx_items_name",
          "tbl_name": "items",
          "sql": "CREATE INDEX idx_items_name ON items(name)"
        }
      ]
      """
    runner.outputs = [
      FakeCommandRunner.Output(stdout: schemaJSON),
      FakeCommandRunner.Output(
        stdout: """
          [
            {"type":"table","name":"items","tbl_name":"items","sql":null},
            {"type":"table","name":"more","tbl_name":"more","sql":null}
          ]
          """),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["sqlite.schema"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "sqlite.schema",
      arguments: .object([
        "path": .string("app.db"),
        "max_entries": .number(10),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)
    let firstCall = try #require(runner.calls.first)
    let firstSQL = try #require(firstCall.arguments.last)

    #expect((firstCall.executable) == ("/usr/bin/sqlite3"))
    #expect(
      (Array(firstCall.arguments.prefix(4))) == (["-batch", "-readonly", "-json", database.path]))
    #expect(firstSQL.contains("FROM sqlite_schema"))
    #expect(firstSQL.contains("type IN ('table', 'view', 'index', 'trigger')"))
    #expect(firstSQL.contains("name NOT LIKE 'sqlite_%'"))
    #expect(firstSQL.contains("LIMIT 11"))
    #expect((payload.objectValue?["operation"]) == (.string("sqlite.schema")))
    #expect(
      (payload.objectValue?["database"]?.objectValue?["workspace_relative_path"])
        == (.string("app.db")))
    #expect((payload.objectValue?["include_views"]) == (.bool(true)))
    #expect((payload.objectValue?["include_indexes"]) == (.bool(true)))
    #expect((payload.objectValue?["include_triggers"]) == (.bool(true)))
    #expect((payload.objectValue?["include_internal"]) == (.bool(false)))
    #expect((payload.objectValue?["include_sql"]) == (.bool(true)))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((entries.first?.objectValue?["name"]) == (.string("items")))
    #expect((entries.first?.objectValue?["type"]) == (.string("table")))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["stdout_bytes"])
        == (.number(Double(schemaJSON.utf8.count))))

    let truncatedResult = try registry.callTool(
      name: "sqlite.schema",
      arguments: .object([
        "path": .string("app.db"),
        "include_views": .bool(false),
        "include_indexes": .bool(false),
        "include_triggers": .bool(false),
        "include_sql": .bool(false),
        "max_entries": .number(1),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedEntries = try #require(truncatedPayload.objectValue?["entries"]?.arrayValue)
    let secondSQL = try #require(runner.calls.last?.arguments.last)

    #expect(secondSQL.contains("type IN ('table')"))
    #expect(secondSQL.contains("NULL AS sql"))
    #expect(secondSQL.contains("LIMIT 2"))
    #expect((truncatedPayload.objectValue?["include_views"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["include_indexes"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["include_triggers"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["include_sql"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((truncatedEntries.count) == (1))
    #expect((truncatedEntries.first?.objectValue?["sql"]) == (.null))
  }

  @Test
  func testSQLiteSchemaRejectsBadInputsAndCommandFailures() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "fake".write(
      to: directory.appendingPathComponent("app.db"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["sqlite.schema"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "sqlite.schema",
        arguments: .object(["path": .string("../outside.db")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "sqlite.schema",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "sqlite.schema",
        arguments: .object([
          "path": .string("app.db"),
          "max_entries": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_entries"))
    }

    let failingRunner = FakeCommandRunner()
    failingRunner.exitCode = 1
    failingRunner.stderr = "file is not a database"
    let failingRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["sqlite.schema"]),
        workspaceDirectory: directory
      ),
      commandRunner: failingRunner
    )
    expectThrows(
      try failingRegistry.callTool(
        name: "sqlite.schema",
        arguments: .object(["path": .string("app.db")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("sqlite.schema failed"))
      #expect(error.localizedDescription.contains("file is not a database"))
    }

    let truncatedRunner = FakeCommandRunner()
    truncatedRunner.stdout = "[]"
    truncatedRunner.stdoutTruncated = true
    let truncatedRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["sqlite.schema"]),
        workspaceDirectory: directory
      ),
      commandRunner: truncatedRunner
    )
    expectThrows(
      try truncatedRegistry.callTool(
        name: "sqlite.schema",
        arguments: .object(["path": .string("app.db")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("exceeded max_output_bytes"))
    }

    let badJSONRunner = FakeCommandRunner()
    badJSONRunner.stdout = "{bad"
    let badJSONRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["sqlite.schema"]),
        workspaceDirectory: directory
      ),
      commandRunner: badJSONRunner
    )
    expectThrows(
      try badJSONRegistry.callTool(
        name: "sqlite.schema",
        arguments: .object(["path": .string("app.db")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse sqlite schema JSON"))
    }
  }

  @Test
  func testSQLiteQueryUsesReadonlyJSONCLIAndBoundsRows() throws {
    let directory = try temporaryDirectory()
    let database = directory.appendingPathComponent("app.db")
    try "not actually read by fake runner".write(to: database, atomically: true, encoding: .utf8)
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(
        stdout: """
          [
            {"id":1,"name":"alpha"},
            {"id":2,"name":"beta"},
            {"id":3,"name":"gamma"}
          ]
          """),
      FakeCommandRunner.Output(stdout: #"[{"cid":0,"name":"id","type":"INTEGER"}]"#),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["sqlite.query"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "sqlite.query",
      arguments: .object([
        "path": .string("app.db"),
        "query": .string("SELECT id, name FROM items ORDER BY id;"),
        "max_rows": .number(2),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)
    let rows = try #require(payload.objectValue?["rows"]?.arrayValue)
    let firstCall = try #require(runner.calls.first)
    let firstSQL = try #require(firstCall.arguments.last)

    #expect((firstCall.executable) == ("/usr/bin/sqlite3"))
    #expect(
      (Array(firstCall.arguments.prefix(4))) == (["-batch", "-readonly", "-json", database.path]))
    #expect(firstSQL.contains("FROM ("))
    #expect(firstSQL.contains("SELECT id, name FROM items ORDER BY id"))
    #expect(firstSQL.contains("LIMIT 3"))
    #expect((payload.objectValue?["operation"]) == (.string("sqlite.query")))
    #expect((payload.objectValue?["query_kind"]) == (.string("select")))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((rows.count) == (2))
    #expect((rows.first?.objectValue?["name"]) == (.string("alpha")))

    let pragmaResult = try registry.callTool(
      name: "sqlite.query",
      arguments: .object([
        "path": .string("app.db"),
        "query": .string("PRAGMA table_info(items);"),
        "max_rows": .number(10),
      ])
    )
    let pragmaPayload = try decodeTextPayload(pragmaResult)
    let secondSQL = try #require(runner.calls.last?.arguments.last)

    #expect((secondSQL) == ("PRAGMA table_info(items)"))
    #expect((pragmaPayload.objectValue?["query_kind"]) == (.string("pragma")))
    #expect((pragmaPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((pragmaPayload.objectValue?["truncated"]) == (.bool(false)))
  }

  @Test
  func testSQLiteQueryRejectsUnsafeInputsAndCommandFailures() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "fake".write(
      to: directory.appendingPathComponent("app.db"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["sqlite.query"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "sqlite.query",
        arguments: .object([
          "path": .string("../outside.db"),
          "query": .string("SELECT 1"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "sqlite.query",
        arguments: .object([
          "path": .string("folder"),
          "query": .string("SELECT 1"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "sqlite.query",
        arguments: .object([
          "path": .string("app.db"),
          "query": .string("UPDATE items SET name = 'x'"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("read-only"))
    }

    expectThrows(
      try registry.callTool(
        name: "sqlite.query",
        arguments: .object([
          "path": .string("app.db"),
          "query": .string("SELECT 1; SELECT 2"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("one SQL statement"))
    }

    expectThrows(
      try registry.callTool(
        name: "sqlite.query",
        arguments: .object([
          "path": .string("app.db"),
          "query": .string("PRAGMA user_version = 1"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("without assignment"))
    }

    let literalRunner = FakeCommandRunner()
    literalRunner.stdout = #"[{"text":"drop table users"}]"#
    let literalRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["sqlite.query"]),
        workspaceDirectory: directory
      ),
      commandRunner: literalRunner
    )
    _ = try literalRegistry.callTool(
      name: "sqlite.query",
      arguments: .object([
        "path": .string("app.db"),
        "query": .string("SELECT 'drop table users' AS text"),
      ])
    )

    let failingRunner = FakeCommandRunner()
    failingRunner.exitCode = 1
    failingRunner.stderr = "file is not a database"
    let failingRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["sqlite.query"]),
        workspaceDirectory: directory
      ),
      commandRunner: failingRunner
    )
    expectThrows(
      try failingRegistry.callTool(
        name: "sqlite.query",
        arguments: .object([
          "path": .string("app.db"),
          "query": .string("SELECT 1"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("sqlite.query failed"))
      #expect(error.localizedDescription.contains("file is not a database"))
    }

    let truncatedRunner = FakeCommandRunner()
    truncatedRunner.stdout = "[]"
    truncatedRunner.stdoutTruncated = true
    let truncatedRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["sqlite.query"]),
        workspaceDirectory: directory
      ),
      commandRunner: truncatedRunner
    )
    expectThrows(
      try truncatedRegistry.callTool(
        name: "sqlite.query",
        arguments: .object([
          "path": .string("app.db"),
          "query": .string("SELECT 1"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("exceeded max_output_bytes"))
    }

    let badJSONRunner = FakeCommandRunner()
    badJSONRunner.stdout = "{bad"
    let badJSONRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["sqlite.query"]),
        workspaceDirectory: directory
      ),
      commandRunner: badJSONRunner
    )
    expectThrows(
      try badJSONRegistry.callTool(
        name: "sqlite.query",
        arguments: .object([
          "path": .string("app.db"),
          "query": .string("SELECT 1"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse sqlite query JSON"))
    }
  }

  @Test
  func testFileHashReturnsSHA256Digest() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "abc".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.hash"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.hash",
      arguments: .object(["path": .string("notes.txt")])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["algorithm"]) == (.string("sha256")))
    #expect(
      (payload.objectValue?["hex"])
        == (.string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")))
    #expect((payload.objectValue?["bytes_read"]) == (.number(3)))
  }

  @Test
  func testFileHashRejectsUnsupportedAlgorithm() throws {
    let directory = try temporaryDirectory()
    try "abc".write(
      to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.hash"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.hash",
        arguments: .object([
          "path": .string("notes.txt"),
          "algorithm": .string("md5"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("sha256"))
    }
  }

  @Test
  func testFileTypeUsesFileMimeWithWorkspaceFile() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "hello".write(to: file, atomically: true, encoding: .utf8)
    let runner = FakeCommandRunner()
    runner.stdout = "text/plain; charset=us-ascii\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.type"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "file.type",
      arguments: .object([
        "path": .string("notes.txt"),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/file"))
    #expect((runner.calls.first?.arguments) == (["-b", "--mime", file.path]))
    #expect((payload.objectValue?["operation"]) == (.string("file.type")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["mime_type"]) == (.string("text/plain")))
    #expect((payload.objectValue?["charset"]) == (.string("us-ascii")))
    #expect((payload.objectValue?["raw"]) == (.string("text/plain; charset=us-ascii")))
  }

  @Test
  func testImageInfoReadsMechanicalImageMetadata() throws {
    let directory = try temporaryDirectory()
    let images = directory.appendingPathComponent("Images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    let imageURL = images.appendingPathComponent("tile.png")
    let representation = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 2,
        pixelsHigh: 3,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ))
    let imageData = try #require(representation.representation(using: .png, properties: [:]))
    try imageData.write(to: imageURL)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["image.info"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "image.info",
      arguments: .object([
        "path": .string("Images/tile.png"),
        "include_properties": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("image.info")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("Images/tile.png")))
    #expect((payload.objectValue?["mime_type"]) == (.string("image/png")))
    #expect((payload.objectValue?["frame_count"]) == (.number(1)))
    #expect((payload.objectValue?["pixel_width"]) == (.number(2)))
    #expect((payload.objectValue?["pixel_height"]) == (.number(3)))
    #expect((payload.objectValue?["has_alpha"]) == (.bool(true)))
    #expect((payload.objectValue?["properties_included"]) == (.bool(true)))
    #expect((payload.objectValue?["properties"]?.objectValue) != nil)
  }

  @Test
  func testImageInfoRejectsInvalidTargets() throws {
    let directory = try temporaryDirectory()
    try "not an image".write(
      to: directory.appendingPathComponent("notes.txt"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["image.info"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "image.info",
        arguments: .object(["path": .string("notes.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unable to read image metadata"))
    }

    expectThrows(
      try registry.callTool(
        name: "image.info",
        arguments: .object(["path": .string(".")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }
  }

  @Test
  func testPDFInfoReadsMechanicalDocumentMetadata() throws {
    let directory = try temporaryDirectory()
    let docs = directory.appendingPathComponent("Docs")
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    let pdfURL = docs.appendingPathComponent("report.pdf")
    let document = PDFDocument()
    document.insert(PDFPage(), at: 0)
    document.insert(PDFPage(), at: 1)
    document.documentAttributes = [
      PDFDocumentAttribute.titleAttribute: "Demo Report",
      PDFDocumentAttribute.authorAttribute: "Codex",
    ]
    #expect(document.write(to: pdfURL))

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["pdf.info"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "pdf.info",
      arguments: .object([
        "path": .string("Docs/report.pdf"),
        "max_pages": .number(1),
        "include_attributes": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)
    let page = try #require(payload.objectValue?["pages"]?.arrayValue?.first?.objectValue)
    let boxes = try #require(page["boxes"]?.objectValue)
    let media = try #require(boxes["media"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("pdf.info")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("Docs/report.pdf")))
    #expect((payload.objectValue?["page_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_page_count"]) == (.number(1)))
    #expect((payload.objectValue?["pages_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["is_encrypted"]) == (.bool(false)))
    #expect((payload.objectValue?["allows_copying"]) == (.bool(true)))
    #expect((payload.objectValue?["attributes_included"]) == (.bool(true)))
    #expect((payload.objectValue?["attributes"]?.objectValue?["Title"]) == (.string("Demo Report")))
    #expect((page["number"]) == (.number(1)))
    #expect((media["width"]) == (.number(612)))
    #expect((media["height"]) == (.number(792)))
  }

  @Test
  func testPDFInfoRejectsInvalidTargets() throws {
    let directory = try temporaryDirectory()
    try "not a pdf".write(
      to: directory.appendingPathComponent("notes.txt"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["pdf.info"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "pdf.info",
        arguments: .object(["path": .string("notes.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unable to read PDF metadata"))
    }

    expectThrows(
      try registry.callTool(
        name: "pdf.info",
        arguments: .object(["path": .string(".")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }
  }

  @Test
  func testPDFTextExtractsSearchableTextWithBounds() throws {
    let directory = try temporaryDirectory()
    let docs = directory.appendingPathComponent("Docs")
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    let pdfURL = docs.appendingPathComponent("report.pdf")
    try writeTextPDF(
      pages: [
        "Alpha PDF page one. This page has searchable text.",
        "Beta PDF page two. More searchable text lives here.",
      ],
      to: pdfURL
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["pdf.text"]),
        workspaceDirectory: directory
      )
    )

    let firstPageResult = try registry.callTool(
      name: "pdf.text",
      arguments: .object([
        "path": .string("Docs/report.pdf"),
        "max_pages": .number(1),
        "max_characters": .number(1_000),
      ])
    )
    let firstPagePayload = try decodeTextPayload(firstPageResult)
    let firstPage = try #require(firstPagePayload.objectValue?["pages"]?.arrayValue?.first)
      .objectValue

    #expect((firstPagePayload.objectValue?["operation"]) == (.string("pdf.text")))
    #expect(
      (firstPagePayload.objectValue?["workspace_relative_path"]) == (.string("Docs/report.pdf")))
    #expect((firstPagePayload.objectValue?["page_count"]) == (.number(2)))
    #expect((firstPagePayload.objectValue?["returned_page_count"]) == (.number(1)))
    #expect((firstPagePayload.objectValue?["page_range_truncated"]) == (.bool(true)))
    #expect((firstPagePayload.objectValue?["text_truncated"]) == (.bool(false)))
    #expect((firstPagePayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((firstPage?["number"]) == (.number(1)))
    #expect(firstPage?["text"]?.stringValue?.contains("Alpha PDF page one") == true)
    #expect((firstPage?["text_truncated"]) == (.bool(false)))

    let truncatedResult = try registry.callTool(
      name: "pdf.text",
      arguments: .object([
        "path": .string("Docs/report.pdf"),
        "start_page": .number(2),
        "max_pages": .number(1),
        "max_characters": .number(8),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedPage = try #require(truncatedPayload.objectValue?["pages"]?.arrayValue?.first)
      .objectValue

    #expect((truncatedPayload.objectValue?["start_page"]) == (.number(2)))
    #expect((truncatedPayload.objectValue?["returned_page_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["page_range_truncated"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["text_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["total_extracted_character_count"]) == (.number(8)))
    #expect((truncatedPage?["number"]) == (.number(2)))
    #expect((truncatedPage?["extracted_character_count"]) == (.number(8)))
    #expect((truncatedPage?["text_truncated"]) == (.bool(true)))
  }

  @Test
  func testPDFTextRejectsInvalidTargetsAndBounds() throws {
    let directory = try temporaryDirectory()
    try "not a pdf".write(
      to: directory.appendingPathComponent("notes.txt"),
      atomically: true,
      encoding: .utf8
    )
    let pdfURL = directory.appendingPathComponent("blank.pdf")
    try writeTextPDF(pages: ["Only page"], to: pdfURL)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["pdf.text"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "pdf.text",
        arguments: .object(["path": .string("notes.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unable to read PDF text"))
    }

    expectThrows(
      try registry.callTool(
        name: "pdf.text",
        arguments: .object(["path": .string(".")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "pdf.text",
        arguments: .object([
          "path": .string("blank.pdf"),
          "start_page": .number(2),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("start_page exceeds PDF page_count"))
    }

    expectThrows(
      try registry.callTool(
        name: "pdf.text",
        arguments: .object([
          "path": .string("blank.pdf"),
          "max_characters": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_characters"))
    }
  }

  @Test
  func testMediaInfoReadsMechanicalAudioMetadata() throws {
    let directory = try temporaryDirectory()
    let media = directory.appendingPathComponent("Media")
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    let audioURL = media.appendingPathComponent("tone.wav")
    try testWAVData(sampleRate: 8_000, sampleCount: 4_000).write(to: audioURL)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["media.info"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "media.info",
      arguments: .object([
        "path": .string("Media/tone.wav"),
        "max_tracks": .number(5),
      ])
    )
    let payload = try decodeTextPayload(result)
    let track = try #require(payload.objectValue?["tracks"]?.arrayValue?.first?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("media.info")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("Media/tone.wav")))
    #expect((payload.objectValue?["extension"]) == (.string("wav")))
    #expect((payload.objectValue?["track_count"]) == (.number(1)))
    #expect((payload.objectValue?["returned_track_count"]) == (.number(1)))
    #expect((payload.objectValue?["tracks_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["media_types"]) == (.array([.string("audio")])))
    #expect((payload.objectValue?["is_playable"]) == (.bool(true)))
    #expect((payload.objectValue?["has_protected_content"]) == (.bool(false)))
    #expect((track["media_type"]) == (.string("audio")))
    #expect((track["codec_types"]?.arrayValue?.first) == (.string("lpcm")))
    #expect((try #require(payload.objectValue?["duration_seconds"]?.numberValue)) > (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testMediaInfoRejectsInvalidTargets() throws {
    let directory = try temporaryDirectory()
    try "not media".write(
      to: directory.appendingPathComponent("notes.txt"),
      atomically: true,
      encoding: .utf8
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["media.info"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "media.info",
        arguments: .object(["path": .string("notes.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unable to read media metadata"))
    }

    expectThrows(
      try registry.callTool(
        name: "media.info",
        arguments: .object(["path": .string(".")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }
  }

  @Test
  func testFileCountUsesWCWithWorkspaceFile() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one two\nthree\n".write(to: file, atomically: true, encoding: .utf8)
    let runner = FakeCommandRunner()
    runner.stdout = "       2       3      14 \(file.path)\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.count"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "file.count",
      arguments: .object(["path": .string("notes.txt")])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/wc"))
    #expect((runner.calls.first?.arguments) == (["-l", "-w", "-c", file.path]))
    #expect((payload.objectValue?["operation"]) == (.string("file.count")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["line_count"]) == (.number(2)))
    #expect((payload.objectValue?["word_count"]) == (.number(3)))
    #expect((payload.objectValue?["byte_count"]) == (.number(14)))
  }

  @Test
  func testFileDiskUsageUsesDUForWorkspacePath() throws {
    let directory = try temporaryDirectory()
    let nested = directory.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "hello".write(
      to: nested.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let runner = FakeCommandRunner()
    runner.stdout = "8\t\(nested.path)\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.disk_usage"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "file.disk_usage",
      arguments: .object(["path": .string("nested")])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/du"))
    #expect((runner.calls.first?.arguments) == (["-sk", nested.path]))
    #expect((payload.objectValue?["operation"]) == (.string("file.disk_usage")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("nested")))
    #expect((payload.objectValue?["type"]) == (.string("directory")))
    #expect((payload.objectValue?["disk_usage_kib"]) == (.number(8)))
    #expect((payload.objectValue?["disk_usage_bytes"]) == (.number(8192)))
    #expect((payload.objectValue?["apparent_size_bytes"]) != nil)
  }

  @Test
  func testFileVolumeInfoReturnsPathVolumeMetadataWithoutCommandRunner() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "hello".write(to: file, atomically: true, encoding: .utf8)
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.volume_info"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "file.volume_info",
      arguments: .object(["path": .string("notes.txt")])
    )
    let payload = try decodeTextPayload(result)
    let volume = try #require(payload.objectValue?["volume"]?.objectValue)

    #expect(runner.calls.isEmpty)
    #expect((payload.objectValue?["operation"]) == (.string("file.volume_info")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["type"]) == (.string("file")))
    #expect((volume["path"]?.stringValue) != nil)
    #expect((volume["name"]?.stringValue) != nil)
    #expect((volume["available_capacity_bytes"]) != nil)
    #expect((volume["is_read_only"]) != nil)
    #expect((volume["supports_case_sensitive_names"]) != nil)
  }

  @Test
  func testFileVolumeInfoRejectsWorkspaceEscapeAndMissingPath() throws {
    let directory = try temporaryDirectory()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.volume_info"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.volume_info",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.volume_info",
        arguments: .object(["path": .string("missing")])
      )
    )
  }

  @Test
  func testFileTypeAndCountRejectWorkspaceEscapeNonFileAndBadBounds() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.type", "file.count"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.type",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.count",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.count",
        arguments: .object([
          "path": .string("folder"),
          "timeout_ms": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }
  }

  @Test
  func testFileDiskUsageRejectsWorkspaceEscapeMissingPathAndBadBounds() throws {
    let directory = try temporaryDirectory()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.disk_usage"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.disk_usage",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.disk_usage",
        arguments: .object(["path": .string("missing")])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.disk_usage",
        arguments: .object([
          "path": .string("."),
          "timeout_ms": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }
  }

  @Test
  func testFileDiffUsesDiffWithWorkspaceFiles() throws {
    let directory = try temporaryDirectory()
    try "one\ntwo\n".write(
      to: directory.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
    try "one\nthree\n".write(
      to: directory.appendingPathComponent("after.txt"), atomically: true, encoding: .utf8)
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.diff"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "file.diff",
      arguments: .object([
        "source": .string("before.txt"),
        "target": .string("after.txt"),
        "context_lines": .number(1),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/diff"))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "-U", "1", directory.appendingPathComponent("before.txt").path,
          directory.appendingPathComponent("after.txt").path,
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("file.diff")))
    #expect(
      (payload.objectValue?["source"]?.objectValue?["workspace_relative_path"])
        == (.string("before.txt")))
    #expect(
      (payload.objectValue?["target"]?.objectValue?["workspace_relative_path"])
        == (.string("after.txt")))
    #expect((payload.objectValue?["context_lines"]) == (.number(1)))
    #expect((payload.objectValue?["max_output_bytes"]) == (.number(4096)))
  }

  @Test
  func testFileDiffRejectsWorkspaceEscapeNonFileAndBadBounds() throws {
    let directory = try temporaryDirectory()
    try "one".write(
      to: directory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.diff"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.diff",
        arguments: .object([
          "source": .string("../outside"),
          "target": .string("one.txt"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.diff",
        arguments: .object([
          "source": .string("folder"),
          "target": .string("one.txt"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Source is not a file"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.diff",
        arguments: .object([
          "source": .string("one.txt"),
          "target": .string("one.txt"),
          "context_lines": .number(-1),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("context_lines"))
    }
  }

  @Test
  func testFileCompareTreesReturnsBoundedMetadataDifferences() throws {
    let directory = try temporaryDirectory()
    let left = directory.appendingPathComponent("left", isDirectory: true)
    let right = directory.appendingPathComponent("right", isDirectory: true)
    try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    try "same".write(
      to: left.appendingPathComponent("common.txt"), atomically: true, encoding: .utf8)
    try "same".write(
      to: right.appendingPathComponent("common.txt"), atomically: true, encoding: .utf8)
    try "left".write(to: left.appendingPathComponent("left.txt"), atomically: true, encoding: .utf8)
    try "right".write(
      to: right.appendingPathComponent("right.txt"), atomically: true, encoding: .utf8)
    try "small".write(
      to: left.appendingPathComponent("size.txt"), atomically: true, encoding: .utf8)
    try "larger".write(
      to: right.appendingPathComponent("size.txt"), atomically: true, encoding: .utf8)
    try "file".write(to: left.appendingPathComponent("kind"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: right.appendingPathComponent("kind"),
      withIntermediateDirectories: true
    )
    try "ignored".write(
      to: left.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: left.appendingPathComponent("link").path,
      withDestinationPath: "left-target"
    )
    try FileManager.default.createSymbolicLink(
      atPath: right.appendingPathComponent("link").path,
      withDestinationPath: "right-target"
    )
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.compare_trees"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "file.compare_trees",
      arguments: .object([
        "left": .string("left"),
        "right": .string("right"),
        "max_depth": .number(3),
        "max_results": .number(20),
      ])
    )
    let payload = try decodeTextPayload(result)
    let counts = try #require(payload.objectValue?["difference_counts"]?.objectValue)

    #expect(runner.calls.isEmpty)
    #expect((payload.objectValue?["operation"]) == (.string("file.compare_trees")))
    #expect(
      (payload.objectValue?["left"]?.objectValue?["workspace_relative_path"]) == (.string("left")))
    #expect(
      (payload.objectValue?["right"]?.objectValue?["workspace_relative_path"]) == (.string("right"))
    )
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["difference_count"]) == (.number(5)))
    #expect((payload.objectValue?["metadata_match_count"]) == (.number(1)))
    #expect((counts["left_only"]) == (.number(1)))
    #expect((counts["right_only"]) == (.number(1)))
    #expect((counts["size_mismatch"]) == (.number(1)))
    #expect((counts["type_mismatch"]) == (.number(1)))
    #expect((counts["symlink_mismatch"]) == (.number(1)))

    let differences = try #require(payload.objectValue?["differences"]?.arrayValue)
    #expect((differences.count) == (5))
    #expect(
      !(differences.contains { difference in
        difference.objectValue?["relative_path"] == .string(".hidden")
      }))
  }

  @Test
  func testFileCompareTreesCanHashSameSizeFiles() throws {
    let directory = try temporaryDirectory()
    let left = directory.appendingPathComponent("left", isDirectory: true)
    let right = directory.appendingPathComponent("right", isDirectory: true)
    try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    try "ab".write(
      to: left.appendingPathComponent("same-size.txt"), atomically: true, encoding: .utf8)
    try "cd".write(
      to: right.appendingPathComponent("same-size.txt"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.compare_trees"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.compare_trees",
      arguments: .object([
        "left": .string("left"),
        "right": .string("right"),
        "compare_hashes": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)
    let counts = try #require(payload.objectValue?["difference_counts"]?.objectValue)
    let differences = try #require(payload.objectValue?["differences"]?.arrayValue)
    let firstDifference = try #require(differences.first?.objectValue)

    #expect((counts["hash_mismatch"]) == (.number(1)))
    #expect((payload.objectValue?["hash_files_compared"]) == (.number(2)))
    #expect((payload.objectValue?["hash_bytes_read"]) == (.number(4)))
    #expect((firstDifference["kind"]) == (.string("hash_mismatch")))
    #expect((firstDifference["left"]?.objectValue?["sha256"]?.stringValue) != nil)
    #expect((firstDifference["right"]?.objectValue?["sha256"]?.stringValue) != nil)
  }

  @Test
  func testFileCompareTreesRejectsWorkspaceEscapeNonDirectoryAndBadBounds() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("left"),
      withIntermediateDirectories: true
    )
    try "file".write(
      to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.compare_trees"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.compare_trees",
        arguments: .object([
          "left": .string("../outside"),
          "right": .string("left"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.compare_trees",
        arguments: .object([
          "left": .string("file.txt"),
          "right": .string("left"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.compare_trees",
        arguments: .object([
          "left": .string("left"),
          "right": .string("left"),
          "max_depth": .number(-1),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_depth"))
    }
  }

  @Test
  func testFileDuplicatesReturnsHashConfirmedGroups() throws {
    let directory = try temporaryDirectory()
    let nested = directory.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "same".write(
      to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "same".write(
      to: nested.appendingPathComponent("a-copy.txt"), atomically: true, encoding: .utf8)
    try "abcd".write(
      to: directory.appendingPathComponent("same-size-1.txt"), atomically: true, encoding: .utf8)
    try "wxyz".write(
      to: directory.appendingPathComponent("same-size-2.txt"), atomically: true, encoding: .utf8)
    try "".write(
      to: directory.appendingPathComponent("empty-1.txt"), atomically: true, encoding: .utf8)
    try "".write(
      to: directory.appendingPathComponent("empty-2.txt"), atomically: true, encoding: .utf8)
    try "same".write(
      to: directory.appendingPathComponent(".hidden-copy.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: directory.appendingPathComponent("link-to-a").path,
      withDestinationPath: "a.txt"
    )
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.duplicates"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "file.duplicates",
      arguments: .object([
        "path": .string("."),
        "max_depth": .number(3),
        "max_groups": .number(10),
        "max_files_per_group": .number(10),
      ])
    )
    let payload = try decodeTextPayload(result)
    let groups = try #require(payload.objectValue?["groups"]?.arrayValue)
    let firstGroup = try #require(groups.first?.objectValue)
    let files = try #require(firstGroup["files"]?.arrayValue)
    let returnedPaths = files.compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }

    #expect(runner.calls.isEmpty)
    #expect((payload.objectValue?["operation"]) == (.string("file.duplicates")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string(".")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["candidate_file_count"]) == (.number(4)))
    #expect((payload.objectValue?["candidate_size_bucket_count"]) == (.number(1)))
    #expect((payload.objectValue?["skipped_small_file_count"]) == (.number(2)))
    #expect((payload.objectValue?["hashed_file_count"]) == (.number(4)))
    #expect((payload.objectValue?["duplicate_group_count"]) == (.number(1)))
    #expect((payload.objectValue?["duplicate_file_count"]) == (.number(2)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(false)))
    #expect((firstGroup["file_count"]) == (.number(2)))
    #expect((firstGroup["returned_file_count"]) == (.number(2)))
    #expect((firstGroup["size_bytes"]) == (.number(4)))
    #expect((firstGroup["sha256"]?.stringValue) != nil)
    #expect((returnedPaths) == (["a.txt", "nested/a-copy.txt"]))
    #expect((files.first?.objectValue?["read_context"]?.objectValue) != nil)
    #expect(!(returnedPaths.contains(".hidden-copy.txt")))
  }

  @Test
  func testFileDuplicatesHonorsHashLimits() throws {
    let directory = try temporaryDirectory()
    try "same".write(
      to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "same".write(
      to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.duplicates"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.duplicates",
      arguments: .object([
        "max_hash_files": .number(1)
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["candidate_file_count"]) == (.number(2)))
    #expect((payload.objectValue?["hashed_file_count"]) == (.number(0)))
    #expect((payload.objectValue?["hash_skipped_file_count"]) == (.number(2)))
    #expect((payload.objectValue?["hash_skipped_size_bucket_count"]) == (.number(1)))
    #expect((payload.objectValue?["duplicate_group_count"]) == (.number(0)))
  }

  @Test
  func testFileDuplicatesRejectsWorkspaceEscapeNonDirectoryAndBadBounds() throws {
    let directory = try temporaryDirectory()
    try "file".write(
      to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.duplicates"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.duplicates",
        arguments: .object([
          "path": .string("../outside")
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.duplicates",
        arguments: .object([
          "path": .string("file.txt")
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.duplicates",
        arguments: .object([
          "max_depth": .number(-1)
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_depth"))
    }
  }

  @Test
  func testArchiveListUsesFixedZipInfoArgvAndReturnsBoundedEntries() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    try Data([0x50, 0x4b]).write(to: archive)
    let runner = FakeCommandRunner()
    runner.stdout = "dir/\ndir/file.txt\nimage.png\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.list"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "archive.list",
      arguments: .object([
        "path": .string("bundle.zip"),
        "max_entries": .number(2),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect((runner.calls.first?.executable) == ("/usr/bin/zipinfo"))
    #expect((runner.calls.first?.arguments) == (["-1", archive.path]))
    #expect((payload.objectValue?["operation"]) == (.string("archive.list")))
    #expect((payload.objectValue?["archive"]?.objectValue?["format"]) == (.string("zip")))
    #expect(
      (payload.objectValue?["archive"]?.objectValue?["workspace_relative_path"])
        == (.string("bundle.zip")))
    #expect((payload.objectValue?["entry_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((entries[0].objectValue?["path"]) == (.string("dir/")))
    #expect((entries[0].objectValue?["is_directory"]) == (.bool(true)))
    #expect((entries[1].objectValue?["path"]) == (.string("dir/file.txt")))
    #expect((entries[1].objectValue?["is_directory"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testArchiveListUsesTarArgvAndRejectsUnsupportedInputs() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.tar.gz")
    try Data("tar".utf8).write(to: archive)
    try Data("text".utf8).write(to: directory.appendingPathComponent("notes.txt"))
    let runner = FakeCommandRunner()
    runner.stdout = "src/\nsrc/main.swift\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.list"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "archive.list",
      arguments: .object(["path": .string("bundle.tar.gz")])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/tar"))
    #expect((runner.calls.first?.arguments) == (["-tf", archive.path]))
    #expect((payload.objectValue?["archive"]?.objectValue?["format"]) == (.string("tar")))

    expectThrows(
      try registry.callTool(
        name: "archive.list",
        arguments: .object(["path": .string("notes.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unsupported archive format"))
    }

    expectThrows(
      try registry.callTool(
        name: "archive.list",
        arguments: .object(["path": .string("../outside.zip")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "archive.list",
        arguments: .object([
          "path": .string("bundle.tar.gz"),
          "max_entries": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_entries"))
    }
  }

  @Test
  func testArchiveReadFileUsesFixedZipArgvAndReturnsText() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    try Data([0x50, 0x4b]).write(to: archive)
    let runner = FakeCommandRunner()
    runner.outputs = [
      .init(stdout: "hello from archive\n", stdoutTruncated: true)
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.read_file"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "archive.read_file",
      arguments: .object([
        "path": .string("bundle.zip"),
        "entry": .string("dir/file.txt"),
        "max_bytes": .number(32),
        "timeout_ms": .number(1234),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/unzip"))
    #expect((runner.calls.first?.arguments) == (["-p", archive.path, "dir/file.txt"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (32))
    #expect((payload.objectValue?["operation"]) == (.string("archive.read_file")))
    #expect((payload.objectValue?["archive"]?.objectValue?["format"]) == (.string("zip")))
    #expect(
      (payload.objectValue?["archive"]?.objectValue?["workspace_relative_path"])
        == (.string("bundle.zip")))
    #expect(
      (payload.objectValue?["entry"]?.objectValue?["requested_path"]) == (.string("dir/file.txt")))
    #expect(
      (payload.objectValue?["entry"]?.objectValue?["normalized_path"]) == (.string("dir/file.txt")))
    #expect((payload.objectValue?["content"]) == (.string("hello from archive\n")))
    #expect((payload.objectValue?["requested_encoding"]) == (.string("utf8")))
    #expect((payload.objectValue?["encoding"]) == (.string("utf8")))
    #expect((payload.objectValue?["valid_utf8"]) == (.bool(true)))
    #expect((payload.objectValue?["content_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout_truncated"]) == (.bool(true)))
  }

  @Test
  func testArchiveReadFileCanReturnBinaryMemberAsBase64() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    try Data([0x50, 0x4b]).write(to: archive)
    let runner = FakeCommandRunner()
    runner.outputs = [
      .init(stdout: "", stdoutData: Data([0x00, 0xff, 0x41, 0x42]))
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.read_file"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "archive.read_file",
      arguments: .object([
        "path": .string("bundle.zip"),
        "entry": .string("image.bin"),
        "encoding": .string("auto"),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.arguments) == (["-p", archive.path, "image.bin"]))
    #expect((payload.objectValue?["requested_encoding"]) == (.string("auto")))
    #expect((payload.objectValue?["encoding"]) == (.string("base64")))
    #expect((payload.objectValue?["valid_utf8"]) == (.bool(false)))
    #expect(
      (payload.objectValue?["content"])
        == (.string(Data([0x00, 0xff, 0x41, 0x42]).base64EncodedString())))
    #expect((payload.objectValue?["bytes_read"]) == (.number(4)))

    let forcedBase64Result = try registry.callTool(
      name: "archive.read_file",
      arguments: .object([
        "path": .string("bundle.zip"),
        "entry": .string("image.bin"),
        "encoding": .string("base64"),
      ])
    )
    let forcedPayload = try decodeTextPayload(forcedBase64Result)
    #expect((forcedPayload.objectValue?["encoding"]) == (.string("base64")))
  }

  @Test
  func testArchiveReadFileRejectsInvalidUTF8WhenUTF8Requested() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    try Data([0x50, 0x4b]).write(to: archive)
    let runner = FakeCommandRunner()
    runner.outputs = [
      .init(stdout: "", stdoutData: Data([0xff, 0xfe]))
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.read_file"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    expectThrows(
      try registry.callTool(
        name: "archive.read_file",
        arguments: .object([
          "path": .string("bundle.zip"),
          "entry": .string("image.bin"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
      #expect((runner.calls.count) == (1))
    }
  }

  @Test
  func testArchiveReadFileUsesTarArgvAndNormalizesEntry() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.tar.gz")
    try Data("tar".utf8).write(to: archive)
    let runner = FakeCommandRunner()
    runner.stdout = "main\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.read_file"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "archive.read_file",
      arguments: .object([
        "path": .string("bundle.tar.gz"),
        "entry": .string("./src/main.swift"),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/tar"))
    #expect((runner.calls.first?.arguments) == (["-xOf", archive.path, "src/main.swift"]))
    #expect((payload.objectValue?["archive"]?.objectValue?["format"]) == (.string("tar")))
    #expect(
      (payload.objectValue?["entry"]?.objectValue?["normalized_path"])
        == (.string("src/main.swift")))
    #expect((payload.objectValue?["content"]) == (.string("main\n")))
  }

  @Test
  func testArchiveReadFileRejectsUnsafeInputsAndCommandFailure() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    let notes = directory.appendingPathComponent("notes.txt")
    try Data([0x50, 0x4b]).write(to: archive)
    try Data("text".utf8).write(to: notes)
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.read_file"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    for entry in ["../outside.txt", "/absolute.txt", "dir/", "-option", "*.txt"] {
      expectThrows(
        try registry.callTool(
          name: "archive.read_file",
          arguments: .object([
            "path": .string("bundle.zip"),
            "entry": .string(entry),
          ])
        )
      )
    }
    #expect(runner.calls.isEmpty)

    expectThrows(
      try registry.callTool(
        name: "archive.read_file",
        arguments: .object([
          "path": .string("notes.txt"),
          "entry": .string("README.md"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unsupported archive format"))
    }

    expectThrows(
      try registry.callTool(
        name: "archive.read_file",
        arguments: .object([
          "path": .string("bundle.zip"),
          "entry": .string("README.md"),
          "max_bytes": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_bytes"))
    }

    let failureRunner = FakeCommandRunner()
    failureRunner.exitCode = 11
    let failureRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.read_file"]),
        workspaceDirectory: directory
      ),
      commandRunner: failureRunner
    )
    expectThrows(
      try failureRegistry.callTool(
        name: "archive.read_file",
        arguments: .object([
          "path": .string("bundle.zip"),
          "entry": .string("missing.txt"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("failed with exit code 11"))
      #expect((failureRunner.calls.count) == (1))
    }
  }

  @Test
  func testArchiveExtractDryRunValidatesZipEntriesWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    try Data([0x50, 0x4b]).write(to: archive)
    let destination = directory.appendingPathComponent("out")
    let runner = FakeCommandRunner()
    runner.outputs = [
      .init(stdout: "dir/\ndir/file.txt\nimage.png\n"),
      .init(
        stdout: """
          Archive:  bundle.zip
          drwxr-xr-x  3.0 unx        0 bx        0 stor 26-Jul-08 23:11 dir/
          -rw-r--r--  3.0 unx        1 tx        1 stor 26-Jul-08 23:11 dir/file.txt
          -rw-r--r--  3.0 unx        1 tx        1 stor 26-Jul-08 23:11 image.png
          3 files, 2 bytes uncompressed, 2 bytes compressed:  0.0%
          """
      ),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.extract"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "archive.extract",
      arguments: .object([
        "path": .string("bundle.zip"),
        "destination": .string("out"),
        "create_directories": .bool(true),
        "max_preview_entries": .number(2),
      ])
    )
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect((runner.calls.map(\.executable)) == (["/usr/bin/zipinfo", "/usr/bin/zipinfo"]))
    #expect((runner.calls[0].arguments) == (["-1", archive.path]))
    #expect((runner.calls[1].arguments) == (["-l", archive.path]))
    #expect(!(FileManager.default.fileExists(atPath: destination.path)))
    #expect((payload.objectValue?["operation"]) == (.string("archive.extract")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_extract"]) == (.bool(false)))
    #expect((payload.objectValue?["entry_count"]) == (.number(3)))
    #expect((payload.objectValue?["entries_truncated"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["destination"]?.objectValue?["workspace_relative_path"])
        == (.string("out")))
    #expect((payload.objectValue?["destination"]?.objectValue?["would_create"]) == (.bool(true)))
    #expect((entries[0].objectValue?["path"]) == (.string("dir/")))
    #expect((entries[0].objectValue?["normalized_path"]) == (.string("dir")))
    #expect((entries[0].objectValue?["is_directory"]) == (.bool(true)))
    #expect((entries[1].objectValue?["normalized_path"]) == (.string("dir/file.txt")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("-q"),
          .string("-n"),
          .string(archive.path),
          .string("-d"),
          .string(destination.path),
        ])))
    #expect((payload.objectValue?["result"]) == (.null))
  }

  @Test
  func testArchiveExtractRunsTarAfterConfirmation() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.tar.gz")
    let destination = directory.appendingPathComponent("out")
    try Data("tar".utf8).write(to: archive)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let runner = FakeCommandRunner()
    runner.outputs = [
      .init(stdout: "src/\nsrc/main.swift\n"),
      .init(
        stdout: """
          drwxr-xr-x  0 user staff       0 Jul  8 23:11 src/
          -rw-r--r--  0 user staff       1 Jul  8 23:11 src/main.swift
          """
      ),
      .init(stdout: "extracted\n"),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.extract"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "archive.extract",
      arguments: .object([
        "path": .string("bundle.tar.gz"),
        "destination": .string("out"),
        "dry_run": .bool(false),
        "confirm_extract": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.map(\.executable)) == (["/usr/bin/tar", "/usr/bin/tar", "/usr/bin/tar"]))
    #expect((runner.calls[0].arguments) == (["-tf", archive.path]))
    #expect((runner.calls[1].arguments) == (["-tvf", archive.path]))
    #expect((runner.calls[2].arguments) == (["-xkf", archive.path, "-C", destination.path]))
    #expect((payload.objectValue?["operation"]) == (.string("archive.extract")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_extract"]) == (.bool(true)))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testArchiveExtractRejectsUnsafeInputs() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    let destination = directory.appendingPathComponent("out")
    try Data([0x50, 0x4b]).write(to: archive)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("existing".utf8).write(to: destination.appendingPathComponent("existing.txt"))

    let missingConfirmRunner = FakeCommandRunner()
    let missingConfirmRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.extract"]),
        workspaceDirectory: directory
      ),
      commandRunner: missingConfirmRunner
    )
    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "archive.extract",
        arguments: .object([
          "path": .string("bundle.zip"),
          "destination": .string("out"),
          "dry_run": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_extract"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let traversalRunner = FakeCommandRunner()
    traversalRunner.outputs = [
      .init(stdout: "../outside.txt\n"),
      .init(
        stdout: "-rw-r--r--  3.0 unx        1 tx        1 stor 26-Jul-08 23:11 ../outside.txt\n"),
    ]
    let traversalRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.extract"]),
        workspaceDirectory: directory
      ),
      commandRunner: traversalRunner
    )
    expectThrows(
      try traversalRegistry.callTool(
        name: "archive.extract",
        arguments: .object([
          "path": .string("bundle.zip"),
          "destination": .string("out"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes destination"))
    }

    let linkRunner = FakeCommandRunner()
    linkRunner.outputs = [
      .init(stdout: "link\n"),
      .init(stdout: "lrwxr-xr-x  3.0 unx        4 bx        4 stor 26-Jul-08 23:11 link\n"),
    ]
    let linkRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.extract"]),
        workspaceDirectory: directory
      ),
      commandRunner: linkRunner
    )
    expectThrows(
      try linkRegistry.callTool(
        name: "archive.extract",
        arguments: .object([
          "path": .string("bundle.zip"),
          "destination": .string("out"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("link entries"))
    }

    let overwriteRunner = FakeCommandRunner()
    overwriteRunner.outputs = [
      .init(stdout: "existing.txt\n"),
      .init(stdout: "-rw-r--r--  3.0 unx        1 tx        1 stor 26-Jul-08 23:11 existing.txt\n"),
    ]
    let overwriteRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.extract"]),
        workspaceDirectory: directory
      ),
      commandRunner: overwriteRunner
    )
    expectThrows(
      try overwriteRegistry.callTool(
        name: "archive.extract",
        arguments: .object([
          "path": .string("bundle.zip"),
          "destination": .string("out"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("overwrite existing path"))
    }
  }

  @Test
  func testArchiveCreateDryRunBuildsZipArgvWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let sourceDirectory = directory.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try "main".write(
      to: sourceDirectory.appendingPathComponent("main.swift"),
      atomically: true,
      encoding: .utf8
    )
    try "readme".write(
      to: directory.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    let archive = directory.appendingPathComponent("dist/bundle.zip")
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.create"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "archive.create",
      arguments: .object([
        "path": .string("dist/bundle.zip"),
        "sources": .array([.string("src"), .string("README.md")]),
        "create_directories": .bool(true),
        "max_preview_entries": .number(2),
      ])
    )
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect(runner.calls.isEmpty)
    #expect(!(FileManager.default.fileExists(atPath: archive.deletingLastPathComponent().path)))
    #expect((payload.objectValue?["operation"]) == (.string("archive.create")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_create"]) == (.bool(false)))
    #expect((payload.objectValue?["entry_count"]) == (.number(3)))
    #expect((payload.objectValue?["entries_truncated"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["archive"]?.objectValue?["workspace_relative_path"])
        == (.string("dist/bundle.zip")))
    #expect(
      (payload.objectValue?["archive"]?.objectValue?["would_create_parent_directories"])
        == (.bool(true)))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("-qry"),
          .string(archive.path),
          .string("src"),
          .string("README.md"),
        ])))
    #expect((entries[0].objectValue?["workspace_relative_path"]) == (.string("src")))
    #expect((entries[0].objectValue?["type"]) == (.string("directory")))
    #expect((entries[1].objectValue?["workspace_relative_path"]) == (.string("src/main.swift")))
    #expect((payload.objectValue?["result"]) == (.null))
  }

  @Test
  func testArchiveCreateRunsTarAfterConfirmation() throws {
    let directory = try temporaryDirectory()
    let sourceDirectory = directory.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try "main".write(
      to: sourceDirectory.appendingPathComponent("main.swift"),
      atomically: true,
      encoding: .utf8
    )
    let archive = directory.appendingPathComponent("out/bundle.tar.gz")
    let runner = FakeCommandRunner()
    runner.stdout = "created\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.create"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "archive.create",
      arguments: .object([
        "path": .string("out/bundle.tar.gz"),
        "sources": .array([.string("src")]),
        "create_directories": .bool(true),
        "dry_run": .bool(false),
        "confirm_create": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.map(\.executable)) == (["/usr/bin/tar"]))
    #expect((runner.calls.first?.arguments) == (["-czf", archive.path, "src"]))
    #expect(FileManager.default.fileExists(atPath: archive.deletingLastPathComponent().path))
    #expect((payload.objectValue?["operation"]) == (.string("archive.create")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_create"]) == (.bool(true)))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testArchiveCreateRejectsUnsafeInputs() throws {
    let directory = try temporaryDirectory()
    let sourceDirectory = directory.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let sourceFile = sourceDirectory.appendingPathComponent("main.swift")
    try "main".write(to: sourceFile, atomically: true, encoding: .utf8)

    let missingConfirmRunner = FakeCommandRunner()
    let missingConfirmRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.create"]),
        workspaceDirectory: directory
      ),
      commandRunner: missingConfirmRunner
    )
    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "archive.create",
        arguments: .object([
          "path": .string("bundle.zip"),
          "sources": .array([.string("src")]),
          "dry_run": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_create"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let existingArchive = directory.appendingPathComponent("bundle.zip")
    try Data("old".utf8).write(to: existingArchive)
    let existingRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.create"]),
        workspaceDirectory: directory
      )
    )
    expectThrows(
      try existingRegistry.callTool(
        name: "archive.create",
        arguments: .object([
          "path": .string("bundle.zip"),
          "sources": .array([.string("src")]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("already exists"))
    }

    let insideSourceRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.create"]),
        workspaceDirectory: directory
      )
    )
    expectThrows(
      try insideSourceRegistry.callTool(
        name: "archive.create",
        arguments: .object([
          "path": .string("src/bundle.zip"),
          "sources": .array([.string("src")]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("inside a source path"))
    }

    let symlink = sourceDirectory.appendingPathComponent("link.swift")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sourceFile)
    let symlinkRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["archive.create"]),
        workspaceDirectory: directory
      )
    )
    expectThrows(
      try symlinkRegistry.callTool(
        name: "archive.create",
        arguments: .object([
          "path": .string("new-bundle.zip"),
          "sources": .array([.string("src")]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("symbolic link entries"))
    }

    expectThrows(
      try symlinkRegistry.callTool(
        name: "archive.create",
        arguments: .object([
          "path": .string("new-bundle.zip"),
          "sources": .array([]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("sources must not be empty"))
    }
  }

  @Test
  func testFileOrganizationBuiltinsCreateCopyAndMoveWorkspacePaths() throws {
    let directory = try temporaryDirectory()
    try "source".write(
      to: directory.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.mkdir", "file.copy", "file.move"]),
        workspaceDirectory: directory
      )
    )

    let mkdirResult = try registry.callTool(
      name: "file.mkdir",
      arguments: .object(["path": .string("notes/nested")])
    )
    let mkdirPayload = try decodeTextPayload(mkdirResult)
    #expect((mkdirPayload.objectValue?["workspace_relative_path"]) == (.string("notes/nested")))
    #expect((mkdirPayload.objectValue?["created"]) == (.bool(true)))

    let existingResult = try registry.callTool(
      name: "file.mkdir",
      arguments: .object(["path": .string("notes/nested")])
    )
    let existingPayload = try decodeTextPayload(existingResult)
    #expect((existingPayload.objectValue?["created"]) == (.bool(false)))

    let copyResult = try registry.callTool(
      name: "file.copy",
      arguments: .object([
        "source": .string("source.txt"),
        "destination": .string("notes/nested/copy.txt"),
      ])
    )
    let copyPayload = try decodeTextPayload(copyResult)
    #expect((copyPayload.objectValue?["operation"]) == (.string("file.copy")))
    #expect(
      (try String(contentsOf: directory.appendingPathComponent("notes/nested/copy.txt")))
        == ("source"))

    let moveResult = try registry.callTool(
      name: "file.move",
      arguments: .object([
        "source": .string("notes/nested/copy.txt"),
        "destination": .string("moved/copy.txt"),
        "create_directories": .bool(true),
      ])
    )
    let movePayload = try decodeTextPayload(moveResult)
    #expect((movePayload.objectValue?["operation"]) == (.string("file.move")))
    #expect(
      !(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("notes/nested/copy.txt").path)))
    #expect(
      (try String(contentsOf: directory.appendingPathComponent("moved/copy.txt"))) == ("source"))
  }

  @Test
  func testFileOrganizationRejectsOverwriteUnlessRequested() throws {
    let directory = try temporaryDirectory()
    try "source".write(
      to: directory.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    try "old".write(
      to: directory.appendingPathComponent("target.txt"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.copy"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.copy",
        arguments: .object([
          "source": .string("source.txt"),
          "destination": .string("target.txt"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Destination already exists"))
    }

    _ = try registry.callTool(
      name: "file.copy",
      arguments: .object([
        "source": .string("source.txt"),
        "destination": .string("target.txt"),
        "overwrite": .bool(true),
      ])
    )

    #expect((try String(contentsOf: directory.appendingPathComponent("target.txt"))) == ("source"))
  }

  @Test
  func testFileOrganizationRejectsWorkspaceEscape() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.mkdir", "file.copy", "file.move"]),
        workspaceDirectory: try temporaryDirectory()
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.mkdir",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.copy",
        arguments: .object([
          "source": .string("missing.txt"),
          "destination": .string("../outside"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }
  }

  @Test
  func testFileOrganizationDryRunsDoNotMutateWorkspace() throws {
    let directory = try temporaryDirectory()
    let source = directory.appendingPathComponent("source.txt")
    let target = directory.appendingPathComponent("target.txt")
    let obsolete = directory.appendingPathComponent("obsolete.txt")
    try "source".write(to: source, atomically: true, encoding: .utf8)
    try "target".write(to: target, atomically: true, encoding: .utf8)
    try "obsolete".write(to: obsolete, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(
          enabled: [
            "file.touch", "file.mkdir", "file.copy", "file.move", "file.symlink",
            "file.trash",
          ]),
        workspaceDirectory: directory
      )
    )

    let mkdirResult = try registry.callTool(
      name: "file.mkdir",
      arguments: .object([
        "path": .string("notes/nested"),
        "dry_run": .bool(true),
      ])
    )
    let mkdirPayload = try decodeTextPayload(mkdirResult)
    #expect((mkdirPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((mkdirPayload.objectValue?["created"]) == (.bool(false)))
    #expect((mkdirPayload.objectValue?["would_create"]) == (.bool(true)))
    #expect(
      !(FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes").path)))

    let touchResult = try registry.callTool(
      name: "file.touch",
      arguments: .object([
        "path": .string("logs/session.txt"),
        "create_directories": .bool(true),
        "dry_run": .bool(true),
      ])
    )
    let touchPayload = try decodeTextPayload(touchResult)
    #expect((touchPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((touchPayload.objectValue?["created"]) == (.bool(false)))
    #expect((touchPayload.objectValue?["would_create"]) == (.bool(true)))
    #expect(
      !(FileManager.default.fileExists(atPath: directory.appendingPathComponent("logs").path)))

    let copyResult = try registry.callTool(
      name: "file.copy",
      arguments: .object([
        "source": .string("source.txt"),
        "destination": .string("target.txt"),
        "overwrite": .bool(true),
        "dry_run": .bool(true),
      ])
    )
    let copyPayload = try decodeTextPayload(copyResult)
    #expect((copyPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((copyPayload.objectValue?["copied"]) == (.bool(false)))
    #expect((copyPayload.objectValue?["would_copy"]) == (.bool(true)))
    #expect((copyPayload.objectValue?["would_overwrite"]) == (.bool(true)))
    #expect((try String(contentsOf: target)) == ("target"))

    let moveResult = try registry.callTool(
      name: "file.move",
      arguments: .object([
        "source": .string("source.txt"),
        "destination": .string("moved/source.txt"),
        "create_directories": .bool(true),
        "dry_run": .bool(true),
      ])
    )
    let movePayload = try decodeTextPayload(moveResult)
    #expect((movePayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((movePayload.objectValue?["moved"]) == (.bool(false)))
    #expect((movePayload.objectValue?["would_move"]) == (.bool(true)))
    #expect((movePayload.objectValue?["source_removed"]) == (.bool(false)))
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(
      !(FileManager.default.fileExists(atPath: directory.appendingPathComponent("moved").path)))

    let symlinkResult = try registry.callTool(
      name: "file.symlink",
      arguments: .object([
        "path": .string("links/current"),
        "destination": .string("../source.txt"),
        "create_directories": .bool(true),
        "dry_run": .bool(true),
      ])
    )
    let symlinkPayload = try decodeTextPayload(symlinkResult)
    #expect((symlinkPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((symlinkPayload.objectValue?["created"]) == (.bool(false)))
    #expect((symlinkPayload.objectValue?["would_create"]) == (.bool(true)))
    #expect((symlinkPayload.objectValue?["destination_exists"]) == (.bool(true)))
    #expect(
      !(FileManager.default.fileExists(atPath: directory.appendingPathComponent("links").path)))

    let trashResult = try registry.callTool(
      name: "file.trash",
      arguments: .object([
        "path": .string("obsolete.txt"),
        "dry_run": .bool(true),
      ])
    )
    let trashPayload = try decodeTextPayload(trashResult)
    #expect((trashPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((trashPayload.objectValue?["trashed"]) == (.bool(false)))
    #expect((trashPayload.objectValue?["would_trash"]) == (.bool(true)))
    #expect((trashPayload.objectValue?["trashed_path"]) == (.null))
    #expect(FileManager.default.fileExists(atPath: obsolete.path))
  }

  @Test
  func testFileTouchCreatesAndUpdatesWorkspaceFile() throws {
    let directory = try temporaryDirectory()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.touch"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.touch",
      arguments: .object([
        "path": .string("notes/touched.txt"),
        "create_directories": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)
    let file = directory.appendingPathComponent("notes/touched.txt")

    #expect((payload.objectValue?["operation"]) == (.string("file.touch")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("notes/touched.txt")))
    #expect((payload.objectValue?["created"]) == (.bool(true)))
    #expect((payload.objectValue?["modified"]) == (.bool(true)))
    #expect((payload.objectValue?["result"]?.objectValue?["type"]) == (.string("file")))
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect((try Data(contentsOf: file).count) == (0))

    let oldDate = Date(timeIntervalSince1970: 1)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
    let updateResult = try registry.callTool(
      name: "file.touch",
      arguments: .object([
        "path": .string("notes/touched.txt"),
        "create_if_missing": .bool(false),
      ])
    )
    let updatePayload = try decodeTextPayload(updateResult)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let modifiedDate = try #require(attributes[.modificationDate] as? Date)

    #expect((updatePayload.objectValue?["created"]) == (.bool(false)))
    #expect((updatePayload.objectValue?["modified"]) == (.bool(true)))
    #expect((modifiedDate.timeIntervalSince1970) > (oldDate.timeIntervalSince1970))
  }

  @Test
  func testFileTouchRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.touch"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.touch",
        arguments: .object([
          "path": .string("missing.txt"),
          "create_if_missing": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.touch",
        arguments: .object(["path": .string("nested/missing.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Parent directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.touch",
        arguments: .object(["path": .string("folder")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.touch",
        arguments: .object(["path": .string("../outside.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }
  }

  @Test
  func testFileSymlinkCreatesWorkspaceLinkWithContainedDestinationByDefault() throws {
    let directory = try temporaryDirectory()
    let target = directory.appendingPathComponent("target.txt")
    try "target".write(to: target, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.symlink"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.symlink",
      arguments: .object([
        "path": .string("links/current"),
        "destination": .string("../target.txt"),
        "create_directories": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)
    let link = directory.appendingPathComponent("links/current")

    #expect((payload.objectValue?["operation"]) == (.string("file.symlink")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("links/current")))
    #expect((payload.objectValue?["destination"]) == (.string("../target.txt")))
    #expect((payload.objectValue?["destination_workspace_contained"]) == (.bool(true)))
    #expect((payload.objectValue?["destination_exists"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["destination_workspace_relative_path"]) == (.string("target.txt")))
    #expect(
      (try FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == ("../target.txt"))
  }

  @Test
  func testFileSymlinkRejectsExternalDestinationUnlessAllowedAndCanOverwrite() throws {
    let directory = try temporaryDirectory()
    let link = directory.appendingPathComponent("external-link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.symlink"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.symlink",
        arguments: .object([
          "path": .string("external-link"),
          "destination": .string("/tmp/computer-mcp-external-target"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("outside workspace"))
    }

    let result = try registry.callTool(
      name: "file.symlink",
      arguments: .object([
        "path": .string("external-link"),
        "destination": .string("/tmp/computer-mcp-external-target"),
        "allow_external_destination": .bool(true),
        "overwrite": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["destination_workspace_contained"]) == (.bool(false)))
    #expect((payload.objectValue?["allow_external_destination"]) == (.bool(true)))
    #expect((payload.objectValue?["overwritten"]) == (.bool(true)))
    #expect(
      (try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        == ("/tmp/computer-mcp-external-target"))
  }

  @Test
  func testFileSymlinkRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    let outsideDirectory = try temporaryDirectory()
    try FileManager.default.createSymbolicLink(
      atPath: directory.appendingPathComponent("outside-parent").path,
      withDestinationPath: outsideDirectory.path
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.symlink"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.symlink",
        arguments: .object([
          "path": .string("../outside-link"),
          "destination": .string("target"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.symlink",
        arguments: .object([
          "path": .string("outside-parent/link"),
          "destination": .string("target"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("parent symlink"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.symlink",
        arguments: .object([
          "path": .string("empty-link"),
          "destination": .string(""),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("destination"))
    }
  }

  @Test
  func testFileTrashMovesWorkspacePathToMacOSTrash() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("obsolete.txt")
    try "obsolete".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.trash"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.trash",
      arguments: .object(["path": .string("obsolete.txt")])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("file.trash")))
    #expect((payload.objectValue?["source_workspace_relative_path"]) == (.string("obsolete.txt")))
    #expect(!(FileManager.default.fileExists(atPath: file.path)))
    #expect((payload.objectValue?["trashed_path"]) != (.null))
  }

  @Test
  func testFileTrashRejectsWorkspaceEscape() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.trash"]),
        workspaceDirectory: try temporaryDirectory()
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.trash",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }
  }

  @Test
  func testWorkspaceInfoReturnsNonSecretGatewaySummary() throws {
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
      cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/usr/bin/git")]),
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(id: "fake", transport: .stdio, command: "/bin/cat")
      ]),
      tools: [
        ToolConfig(name: "fake.sample", adapter: .mcp, source: "fake", tool: "sample")
      ],
      builtin: BuiltinConfig(enabled: ["workspace.info"]),
      workspaceDirectory: directory
    )
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(name: "workspace.info", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["server"]?.objectValue?["name"]) == (.string("test-computer")))
    #expect(
      (payload.objectValue?["server"]?.objectValue?["http"]?.objectValue?["auth"])
        == (.string("bearer")))
    #expect(
      (payload.objectValue?["server"]?.objectValue?["http"]?.objectValue?["access_token_env"])
        == (.string("COMPUTER_MCP_TOKEN")))
    #expect(
      (payload.objectValue?["workspace"]?.objectValue?["root"])
        == (.string(directory.standardizedFileURL.path)))
    #expect((payload.objectValue?["cli"]?.objectValue?["ids"]) == (.array([.string("git")])))
    #expect(
      (payload.objectValue?["mcp"]?.objectValue?["server_ids"]) == (.array([.string("fake")])))
    #expect(
      (payload.objectValue?["builtin"]?.objectValue?["enabled"])
        == (.array([.string("workspace.info")])))
  }

  @Test
  func testWorkspaceStatusReturnsBoundedTopLevelState() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.status"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.status",
      arguments: .object([:])
    )
    let payload = try decodeTextPayload(result)
    let workspace = try #require(payload.objectValue?["workspace"]?.objectValue)
    let topLevel = try #require(payload.objectValue?["top_level"]?.objectValue)
    let vcs = try #require(payload.objectValue?["vcs"]?.objectValue)
    let gitMetadata = try #require(vcs["git_metadata_at_root"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("workspace.status")))
    #expect((workspace["root"]) == (.string(directory.standardizedFileURL.path)))
    #expect((workspace["exists"]) == (.bool(true)))
    #expect((workspace["is_directory"]) == (.bool(true)))
    #expect((topLevel["include_hidden"]) == (.bool(false)))
    #expect((topLevel["scanned_entry_count"]) == (.number(3)))
    #expect((topLevel["file_count"]) == (.number(1)))
    #expect((topLevel["directory_count"]) == (.number(1)))
    #expect((topLevel["symlink_count"]) == (.number(1)))
    #expect((topLevel["truncated"]) == (.bool(false)))
    #expect((gitMetadata["exists"]) == (.bool(true)))
    #expect((gitMetadata["type"]) == (.string("directory")))

    let truncatedResult = try registry.callTool(
      name: "workspace.status",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_entries": .number(1),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedTopLevel = try #require(truncatedPayload.objectValue?["top_level"]?.objectValue)

    #expect((truncatedTopLevel["include_hidden"]) == (.bool(true)))
    #expect((truncatedTopLevel["scanned_entry_count"]) == (.number(1)))
    #expect((truncatedTopLevel["truncated"]) == (.bool(true)))
  }

  @Test
  func testWorkspaceManifestsReturnsFixedCatalogPresence() throws {
    let directory = try temporaryDirectory()
    try "{}".write(
      to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "// swift-tools-version: 6.0".write(
      to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent(".github/workflows"),
      withIntermediateDirectories: true
    )

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.manifests"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.manifests",
      arguments: .object([:])
    )
    let payload = try decodeTextPayload(result)
    let workspace = try #require(payload.objectValue?["workspace"]?.objectValue)
    let manifests = try #require(payload.objectValue?["manifests"]?.arrayValue)
    let paths = manifests.compactMap { $0.objectValue?["path"]?.stringValue }

    #expect((payload.objectValue?["operation"]) == (.string("workspace.manifests")))
    #expect((workspace["root"]) == (.string(directory.standardizedFileURL.path)))
    #expect((payload.objectValue?["include_missing"]) == (.bool(false)))
    #expect((paths) == (["Package.swift", "package.json", ".github/workflows"]))
    #expect((payload.objectValue?["included_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_count"]) == (.number(3)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((manifests[0].objectValue?["kind"]) == (.string("file")))
    #expect((manifests[2].objectValue?["kind"]) == (.string("directory")))

    let missingResult = try registry.callTool(
      name: "workspace.manifests",
      arguments: .object([
        "include_missing": .bool(true),
        "max_results": .number(2),
      ])
    )
    let missingPayload = try decodeTextPayload(missingResult)
    let missingManifests = try #require(missingPayload.objectValue?["manifests"]?.arrayValue)

    #expect((missingPayload.objectValue?["include_missing"]) == (.bool(true)))
    #expect((missingPayload.objectValue?["included_count"]) == (.number(49)))
    #expect((missingPayload.objectValue?["returned_count"]) == (.number(2)))
    #expect((missingPayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((missingManifests[1].objectValue?["kind"]) == (.string("missing")))
  }

  @Test
  func testWorkspaceRecentFilesReturnsBoundedMetadataOnlyOrder() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.recent_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.recent_files",
      arguments: .object([:])
    )
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let paths = files.compactMap { $0.objectValue?["workspace_relative_path"]?.stringValue }

    #expect((payload.objectValue?["operation"]) == (.string("workspace.recent_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["matched_file_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((paths) == (["nested/new.txt", "old.txt"]))
    #expect((files[0].objectValue?["modified_at"]) != nil)

    let hiddenResult = try registry.callTool(
      name: "workspace.recent_files",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_results": .number(1),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenFiles = try #require(hiddenPayload.objectValue?["files"]?.arrayValue)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["matched_file_count"]) == (.number(3)))
    #expect((hiddenPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((hiddenFiles[0].objectValue?["workspace_relative_path"]) == (.string(".hidden.txt")))
  }

  @Test
  func testWorkspaceDirectoryStatsReturnsGroupedMetadataOnlyCounts() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.directory_stats"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.directory_stats",
      arguments: .object(["max_depth": .number(4)])
    )
    let payload = try decodeTextPayload(result)
    let groups = try #require(payload.objectValue?["groups"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: groups.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.directory_stats")))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.directory_stats",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_results": .number(1),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["group_count"]?.numberValue ?? 0) > (1))
  }

  @Test
  func testWorkspaceArtifactDirectoriesReturnsMetadataOnlyCandidates() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.artifact_directories"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.artifact_directories",
      arguments: .object(["max_depth": .number(4)])
    )
    let payload = try decodeTextPayload(result)
    let directories = try #require(payload.objectValue?["directories"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: directories.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.artifact_directories")))
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
        == (.string("workspace.directory_stats")))
    #expect(!(String(describing: payload).contains("build-secret")))
    #expect(!(String(describing: payload).contains("dependency-secret")))
    #expect(!(String(describing: payload).contains("generated-secret")))

    let visibleOnlyResult = try registry.callTool(
      name: "workspace.artifact_directories",
      arguments: .object([
        "include_hidden": .bool(false),
        "max_depth": .number(4),
      ])
    )
    let visibleOnlyPayload = try decodeTextPayload(visibleOnlyResult)
    let visibleOnlyDirectories = try #require(
      visibleOnlyPayload.objectValue?["directories"]?.arrayValue)
    let visibleOnlyPaths = visibleOnlyDirectories.compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }
    #expect(!(visibleOnlyPaths.contains(".build")))
    #expect(!(visibleOnlyPaths.contains(".hidden/.cache")))
    #expect(visibleOnlyPaths.contains("node_modules"))

    let truncatedResult = try registry.callTool(
      name: "workspace.artifact_directories",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    expectThrows(
      try registry.callTool(
        name: "workspace.artifact_directories",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "workspace.artifact_directories",
        arguments: .object(["path": .string("Docs/guide.md")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a directory"))
    }
  }

  @Test
  func testWorkspaceEmptyDirectoriesReturnsActualEmptyDirectoryMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.empty_directories"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.empty_directories",
      arguments: .object(["max_depth": .number(4)])
    )
    let payload = try decodeTextPayload(result)
    let directories = try #require(payload.objectValue?["directories"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: directories.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.empty_directories")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["empty_directory_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(false)))
    #expect((byPath["empty"]?["child_count"]) == (.number(0)))
    #expect((byPath["empty"]?["depth"]) == (.number(1)))
    #expect((byPath["empty"]?["is_root"]) == (.bool(false)))
    #expect(
      (byPath["empty"]?["workspace.reveal"]?.objectValue?["arguments"]?.objectValue?["path"])
        == (.string("empty")))
    #expect((byPath["nested/child"]?["child_count"]) == (.number(0)))
    #expect((byPath["non-empty"]) == nil)
    #expect((byPath["only-hidden-file"]) == nil)
    #expect((byPath[".hidden-empty"]) == nil)
    #expect((byPath["empty-link"]) == nil)

    let hiddenResult = try registry.callTool(
      name: "workspace.empty_directories",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_results": .number(1),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenDirectories = try #require(hiddenPayload.objectValue?["directories"]?.arrayValue)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["empty_directory_count"]) == (.number(3)))
    #expect((hiddenPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect(
      (hiddenDirectories.first?.objectValue?["workspace_relative_path"])
        == (.string(".hidden-empty")))

    let scopedResult = try registry.callTool(
      name: "workspace.empty_directories",
      arguments: .object(["path": .string("empty")])
    )
    let scopedPayload = try decodeTextPayload(scopedResult)
    let scopedDirectory = try #require(
      scopedPayload.objectValue?["directories"]?.arrayValue?.first)
    #expect((scopedPayload.objectValue?["empty_directory_count"]) == (.number(1)))
    #expect((scopedDirectory.objectValue?["workspace_relative_path"]) == (.string("empty")))
    #expect((scopedDirectory.objectValue?["depth"]) == (.number(0)))
    #expect((scopedDirectory.objectValue?["is_root"]) == (.bool(true)))

    expectThrows(
      try registry.callTool(
        name: "workspace.empty_directories",
        arguments: .object(["path": .string("non-empty/file.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a directory"))
    }
  }

  @Test
  func testWorkspaceGitChangesParsesPorcelainStatusFromRegisteredGitProvider() throws {
    let runner = FakeCommandRunner()
    runner.stdout =
      " M README.md\0A  Sources/App.swift\0R  Sources/New.swift\0Sources/Old.swift\0?? notes.txt\0"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["workspace.git_changes"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "workspace.git_changes",
      arguments: .object([
        "paths": .array([.string("Sources")]),
        "max_results": .number(3),
      ])
    )
    let payload = try decodeTextPayload(result)
    let changes = try #require(payload.objectValue?["changes"]?.arrayValue)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "Sources"]))
    #expect((payload.objectValue?["operation"]) == (.string("workspace.git_changes")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["change_count"]) == (.number(4)))
    #expect((payload.objectValue?["returned_count"]) == (.number(3)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["status_counts"]?.objectValue?[" M"]) == (.number(1)))
    #expect((payload.objectValue?["status_counts"]?.objectValue?["R "]) == (.number(1)))
    #expect((changes[0].objectValue?["workspace_relative_path"]) == (.string("README.md")))
    #expect((changes[0].objectValue?["index_status"]) == (.string(" ")))
    #expect((changes[0].objectValue?["worktree_status"]) == (.string("M")))
    #expect((changes[2].objectValue?["workspace_relative_path"]) == (.string("Sources/New.swift")))
    #expect((changes[2].objectValue?["original_path"]) == (.string("Sources/Old.swift")))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["stdout_bytes"])
        == (.number(Double(runner.stdout.utf8.count))))
  }

  @Test
  func testWorkspaceFileTypesReturnsMetadataOnlyExtensionHistogram() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.file_types"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.file_types",
      arguments: .object([:])
    )
    let payload = try decodeTextPayload(result)
    let groups = try #require(payload.objectValue?["file_types"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("workspace.file_types")))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.file_types",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_groups": .number(1),
      ])
    )
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
  func testWorkspaceLargeFilesReturnsBoundedMetadataOnlyOrder() throws {
    let directory = try temporaryDirectory()
    let nested = directory.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let smallFile = directory.appendingPathComponent("small.txt")
    let largeFile = nested.appendingPathComponent("large.bin")
    let hiddenFile = directory.appendingPathComponent(".hidden.bin")
    try "1".write(to: smallFile, atomically: true, encoding: .utf8)
    try String(repeating: "2", count: 20).write(to: largeFile, atomically: true, encoding: .utf8)
    try String(repeating: "3", count: 30).write(to: hiddenFile, atomically: true, encoding: .utf8)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.large_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.large_files",
      arguments: .object([:])
    )
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let paths = files.compactMap { $0.objectValue?["workspace_relative_path"]?.stringValue }

    #expect((payload.objectValue?["operation"]) == (.string("workspace.large_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["regular_file_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((paths) == (["nested/large.bin", "small.txt"]))
    #expect((files[0].objectValue?["size_bytes"]) == (.number(20)))

    let hiddenResult = try registry.callTool(
      name: "workspace.large_files",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_results": .number(1),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenFiles = try #require(hiddenPayload.objectValue?["files"]?.arrayValue)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["regular_file_count"]) == (.number(3)))
    #expect((hiddenPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((hiddenFiles[0].objectValue?["workspace_relative_path"]) == (.string(".hidden.bin")))
    #expect((hiddenFiles[0].objectValue?["size_bytes"]) == (.number(30)))
  }

  @Test
  func testWorkspaceSymlinksReturnsRawDestinationsAndContainment() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.symlinks"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.symlinks",
      arguments: .object([:])
    )
    let payload = try decodeTextPayload(result)
    let symlinks = try #require(payload.objectValue?["symlinks"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: symlinks.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.symlinks")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["symlink_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((byPath["nested/inside.link"]?["destination"]) == (.string("../target.txt")))
    #expect((byPath["nested/inside.link"]?["target_workspace_contained"]) == (.bool(true)))
    #expect((byPath["outside.link"]?["target_exists"]) == (.bool(true)))
    #expect((byPath["outside.link"]?["target_workspace_contained"]) == (.bool(false)))

    let hiddenResult = try registry.callTool(
      name: "workspace.symlinks",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_results": .number(1),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenSymlinks = try #require(hiddenPayload.objectValue?["symlinks"]?.arrayValue)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["symlink_count"]) == (.number(3)))
    #expect((hiddenPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect(
      (hiddenSymlinks[0].objectValue?["workspace_relative_path"]) == (.string(".hidden.link")))
  }

  @Test
  func testWorkspaceExecutableFilesReturnsMetadataOnlyExecutableFiles() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.executable_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.executable_files",
      arguments: .object([:])
    )
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("workspace.executable_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["executable_file_count"]) == (.number(1)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((files[0].objectValue?["workspace_relative_path"]) == (.string("scripts/run.sh")))
    #expect((files[0].objectValue?["is_executable"]) == (.bool(true)))
    #expect((files[0].objectValue?["type"]) == (.string("file")))

    let hiddenResult = try registry.callTool(
      name: "workspace.executable_files",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_results": .number(1),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenFiles = try #require(hiddenPayload.objectValue?["files"]?.arrayValue)

    #expect((hiddenPayload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((hiddenPayload.objectValue?["executable_file_count"]) == (.number(2)))
    #expect((hiddenPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((hiddenPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((hiddenFiles[0].objectValue?["workspace_relative_path"]) == (.string(".secret-tool")))
  }

  @Test
  func testWorkspaceTodosReturnsBoundedMarkerMatches() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.todos"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.todos",
      arguments: .object([
        "max_matches": .number(2)
      ])
    )
    let payload = try decodeTextPayload(result)
    let matches = try #require(payload.objectValue?["matches"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("workspace.todos")))
    #expect(
      (payload.objectValue?["markers"])
        == (.array([.string("TODO"), .string("FIXME"), .string("HACK"), .string("XXX")])))
    #expect((payload.objectValue?["case_sensitive"]) == (.bool(false)))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["match_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((matches[0].objectValue?["marker"]) == (.string("TODO")))
    #expect((matches[0].objectValue?["workspace_relative_path"]) == (.string("Sources/App.swift")))
    #expect((matches[0].objectValue?["line"]) == (.number(1)))
    #expect((matches[0].objectValue?["column"]) == (.number(1)))
    #expect((matches[1].objectValue?["marker"]) == (.string("FIXME")))
    #expect((matches[1].objectValue?["line"]) == (.number(2)))
    #expect((matches[1].objectValue?["preview"]) == (.string("fixme lower")))

    let hiddenResult = try registry.callTool(
      name: "workspace.todos",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_matches": .number(10),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenMatches = try #require(hiddenPayload.objectValue?["matches"]?.arrayValue)
    let hiddenPaths = hiddenMatches.compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }

    #expect(hiddenPaths.contains(".hidden.md"))
    #expect((hiddenPayload.objectValue?["match_count"]) == (.number(4)))

    let customResult = try registry.callTool(
      name: "workspace.todos",
      arguments: .object([
        "path": .string("Sources"),
        "markers": .array([.string("NOTE")]),
      ])
    )
    let customPayload = try decodeTextPayload(customResult)
    let customMatch = try #require(
      customPayload.objectValue?["matches"]?.arrayValue?.first?.objectValue)

    #expect((customPayload.objectValue?["markers"]) == (.array([.string("NOTE")])))
    #expect((customPayload.objectValue?["match_count"]) == (.number(1)))
    #expect((customMatch["marker"]) == (.string("NOTE")))
    #expect((customMatch["line"]) == (.number(5)))

    expectThrows(
      try registry.callTool(
        name: "workspace.todos",
        arguments: .object(["markers": .array([.string("")])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("markers must not contain empty strings"))
    }
  }

  @Test
  func testWorkspaceEnvFilesReturnsKeyMetadataWithoutValues() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.env_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.env_files",
      arguments: .object([:])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let envFiles = try #require(payload.objectValue?["env_files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: envFiles.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.env_files")))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.env_files",
      arguments: .object(["include_hidden_directories": .bool(true)])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenFiles = try #require(hiddenPayload.objectValue?["env_files"]?.arrayValue)
    let hiddenPaths = hiddenFiles.compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/.env"))

    let truncatedResult = try registry.callTool(
      name: "workspace.env_files",
      arguments: .object([
        "path": .string(".env"),
        "max_keys_per_file": .number(1),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedFile = try #require(truncatedPayload.objectValue?["env_files"]?.arrayValue?.first)
      .objectValue
    #expect((truncatedFile?["key_count"]) == (.number(1)))
    #expect((truncatedFile?["keys_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testWorkspaceDependencyFilesReturnsManifestAndLockMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.dependency_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.dependency_files",
      arguments: .object(["max_depth": .number(1)])
    )
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.dependency_files")))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.dependency_files",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_depth": .number(1),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/Cargo.toml"))

    let truncatedResult = try registry.callTool(
      name: "workspace.dependency_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.dependency_files",
      arguments: .object(["path": .string("package.json")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["dependency_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["workspace_relative_path"]) == (.string("package.json")))
  }

  @Test
  func testWorkspaceProjectRootsGroupsDependencyMetadataByDirectory() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.project_roots"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.project_roots",
      arguments: .object(["max_depth": .number(3)])
    )
    let payload = try decodeTextPayload(result)
    let roots = try #require(payload.objectValue?["project_roots"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: roots.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.project_roots")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["project_root_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_count"]) == (.number(3)))
    #expect((payload.objectValue?["dependency_file_count"]) == (.number(5)))
    #expect((byPath["."]?["is_workspace_root"]) == (.bool(true)))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.project_roots",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_depth": .number(1),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenRoots = try #require(hiddenPayload.objectValue?["project_roots"]?.arrayValue)
      .compactMap {
        $0.objectValue?["workspace_relative_path"]?.stringValue
      }
    #expect(hiddenRoots.contains(".hidden"))

    let truncatedResult = try registry.callTool(
      name: "workspace.project_roots",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.project_roots",
      arguments: .object(["path": .string("package.json")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["project_root_count"]) == (.number(1)))
    let singleRoot = try #require(
      singleFilePayload.objectValue?["project_roots"]?.arrayValue?.first
    )
    #expect((singleRoot.objectValue?["workspace_relative_path"]) == (.string(".")))
  }

  @Test
  func testWorkspaceDocumentationFilesReturnsDocumentationMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.documentation_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.documentation_files",
      arguments: .object(["max_depth": .number(2)])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.documentation_files")))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.documentation_files",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_depth": .number(1),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/README.md"))

    let truncatedResult = try registry.callTool(
      name: "workspace.documentation_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.documentation_files",
      arguments: .object(["path": .string("AGENTS.md")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["documentation_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["workspace_relative_path"]) == (.string("AGENTS.md")))
    #expect((singleFile?["category"]) == (.string("agent_instructions")))
  }

  @Test
  func testWorkspaceAgentFilesReturnsInstructionEntryMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.agent_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(name: "workspace.agent_files", arguments: .object([:]))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.agent_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((payload.objectValue?["agent_file_count"]) == (.number(5)))
    #expect((byPath["AGENTS.md"]?["kind"]) == (.string("codex")))
    #expect((byPath["AGENTS.md"]?["scope_workspace_relative_path"]) == (.string(".")))
    #expect((byPath["AGENTS.md"]?["read_context"]?.objectValue?["tool"]) == (.string("file.read")))
    #expect((byPath["AGENTS.md"]?["read_context"]?.objectValue?["path"]) == (.string("AGENTS.md")))
    #expect((byPath["app/CLAUDE.md"]?["kind"]) == (.string("claude")))
    #expect((byPath["app/CLAUDE.md"]?["scope_workspace_relative_path"]) == (.string("app")))
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

    let visibleOnlyResult = try registry.callTool(
      name: "workspace.agent_files",
      arguments: .object(["include_hidden": .bool(false)])
    )
    let visibleOnlyPayload = try decodeTextPayload(visibleOnlyResult)
    let visibleOnlyFiles = try #require(
      visibleOnlyPayload.objectValue?["files"]?.arrayValue
    )
    let visibleOnlyPaths = visibleOnlyFiles.compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }
    #expect(visibleOnlyPaths.contains("AGENTS.md"))
    #expect(visibleOnlyPaths.contains("app/CLAUDE.md"))
    #expect(!(visibleOnlyPaths.contains(".github/copilot-instructions.md")))
    #expect(!(visibleOnlyPaths.contains(".cursor/rules/project.mdc")))

    let truncatedResult = try registry.callTool(
      name: "workspace.agent_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.agent_files",
      arguments: .object(["path": .string("AGENTS.md")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["agent_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["workspace_relative_path"]) == (.string("AGENTS.md")))
    #expect((singleFile?["kind"]) == (.string("codex")))
  }

  @Test
  func testWorkspaceInstructionsReturnsApplicableInstructionChain() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.instructions"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.instructions",
      arguments: .object(["path": .string("app/feature/Sources/Feature.swift")])
    )
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let paths = files.compactMap { $0.objectValue?["workspace_relative_path"]?.stringValue }

    #expect((payload.objectValue?["operation"]) == (.string("workspace.instructions")))
    #expect((payload.objectValue?["target_exists"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["scope_workspace_relative_path"]) == (.string("app/feature/Sources")))
    #expect(
      (paths)
        == ([
          "AGENTS.md",
          ".github/copilot-instructions.md",
          "app/CLAUDE.md",
          "app/feature/.cursor/rules/style.mdc",
        ]))
    #expect((files[0].objectValue?["scope_workspace_relative_path"]) == (.string(".")))
    #expect((files[0].objectValue?["apply_order"]) == (.number(0)))
    #expect((files[0].objectValue?["kind"]) == (.string("codex")))
    #expect((files[0].objectValue?["content"]) == (.string("root instructions")))
    #expect((files[0].objectValue?["content_truncated"]) == (.bool(false)))
    #expect((files[0].objectValue?["valid_utf8"]) == (.bool(true)))
    #expect((files[1].objectValue?["kind"]) == (.string("github_copilot")))
    #expect((files[2].objectValue?["scope_workspace_relative_path"]) == (.string("app")))
    #expect((files[3].objectValue?["kind"]) == (.string("cursor_rule")))
    #expect(!(paths.contains("docs/instructions.md")))

    let futureResult = try registry.callTool(
      name: "workspace.instructions",
      arguments: .object(["path": .string("app/feature/NewFile.swift")])
    )
    let futurePayload = try decodeTextPayload(futureResult)
    #expect((futurePayload.objectValue?["target_exists"]) == (.bool(false)))
    #expect(
      (futurePayload.objectValue?["scope_workspace_relative_path"]) == (.string("app/feature")))

    let metadataOnlyResult = try registry.callTool(
      name: "workspace.instructions",
      arguments: .object([
        "path": .string("app/feature/Sources/Feature.swift"),
        "include_content": .bool(false),
      ])
    )
    let metadataOnlyPayload = try decodeTextPayload(metadataOnlyResult)
    let metadataOnlyFile = try #require(
      metadataOnlyPayload.objectValue?["files"]?.arrayValue?.first?.objectValue)
    #expect((metadataOnlyFile["content_included"]) == (.bool(false)))
    #expect((metadataOnlyFile["content"]) == (.null))

    let truncatedContentResult = try registry.callTool(
      name: "workspace.instructions",
      arguments: .object([
        "path": .string("app/feature/Sources/Feature.swift"),
        "max_bytes_per_file": .number(4),
      ])
    )
    let truncatedContentPayload = try decodeTextPayload(truncatedContentResult)
    let truncatedFile = try #require(
      truncatedContentPayload.objectValue?["files"]?.arrayValue?.first?.objectValue)
    #expect((truncatedFile["content"]) == (.string("root")))
    #expect((truncatedFile["content_truncated"]) == (.bool(true)))

    let truncatedResult = try registry.callTool(
      name: "workspace.instructions",
      arguments: .object([
        "path": .string("app/feature/Sources/Feature.swift"),
        "max_results": .number(1),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    expectThrows(
      try registry.callTool(
        name: "workspace.instructions",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path escapes workspace"))
    }
  }

  @Test
  func testWorkspaceTestFilesReturnsTestFileMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.test_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.test_files",
      arguments: .object(["max_depth": .number(3)])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.test_files")))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.test_files",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_depth": .number(1),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/test_hidden.py"))

    let truncatedResult = try registry.callTool(
      name: "workspace.test_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.test_files",
      arguments: .object(["path": .string("Sources/App/user.spec.ts")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["test_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["workspace_relative_path"]) == (.string("Sources/App/user.spec.ts")))
    #expect((singleFile?["style"]) == (.string("dot_spec")))
  }

  @Test
  func testWorkspaceCIFilesReturnsPipelineMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.ci_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.ci_files",
      arguments: .object(["max_depth": .number(3)])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.ci_files")))
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

    let visibleOnlyResult = try registry.callTool(
      name: "workspace.ci_files",
      arguments: .object([
        "include_hidden": .bool(false),
        "max_depth": .number(3),
      ])
    )
    let visibleOnlyPayload = try decodeTextPayload(visibleOnlyResult)
    let visibleOnlyPaths = try #require(visibleOnlyPayload.objectValue?["files"]?.arrayValue)
      .compactMap {
        $0.objectValue?["workspace_relative_path"]?.stringValue
      }
    #expect(!(visibleOnlyPaths.contains(".github/workflows/build.yml")))
    #expect(!(visibleOnlyPaths.contains(".gitlab-ci.yml")))
    #expect(visibleOnlyPaths.contains("Jenkinsfile"))
    #expect(visibleOnlyPaths.contains("app/azure-pipelines.yaml"))

    let truncatedResult = try registry.callTool(
      name: "workspace.ci_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.ci_files",
      arguments: .object(["path": .string(".github/workflows/build.yml")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["ci_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["provider"]) == (.string("github_actions")))
  }

  @Test
  func testWorkspaceInfraFilesReturnsDeploymentMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.infra_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.infra_files",
      arguments: .object(["max_depth": .number(4)])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.infra_files")))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.infra_files",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_depth": .number(2),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/Dockerfile"))
    #expect(!(hiddenPaths.contains(".terraform/modules/main.tf")))

    let truncatedResult = try registry.callTool(
      name: "workspace.infra_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.infra_files",
      arguments: .object(["path": .string("wrangler.toml")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["infra_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["provider"]) == (.string("cloudflare")))
  }

  @Test
  func testWorkspaceConfigFilesReturnsToolingMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.config_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.config_files",
      arguments: .object(["max_depth": .number(3)])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.config_files")))
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

    let visibleOnlyResult = try registry.callTool(
      name: "workspace.config_files",
      arguments: .object([
        "include_hidden": .bool(false),
        "max_depth": .number(3),
      ])
    )
    let visibleOnlyPayload = try decodeTextPayload(visibleOnlyResult)
    let visibleOnlyPaths = try #require(visibleOnlyPayload.objectValue?["files"]?.arrayValue)
      .compactMap {
        $0.objectValue?["workspace_relative_path"]?.stringValue
      }
    #expect(!(visibleOnlyPaths.contains(".editorconfig")))
    #expect(!(visibleOnlyPaths.contains(".vscode/settings.json")))
    #expect(!(visibleOnlyPaths.contains(".npmrc")))
    #expect(visibleOnlyPaths.contains("eslint.config.js"))
    #expect(visibleOnlyPaths.contains("tsconfig.app.json"))
    #expect(visibleOnlyPaths.contains("src/ruff.toml"))

    let truncatedResult = try registry.callTool(
      name: "workspace.config_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.config_files",
      arguments: .object(["path": .string(".vscode/settings.json")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["config_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["tool"]) == (.string("vscode")))
  }

  @Test
  func testWorkspaceIgnoreFilesReturnsBoundaryMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.ignore_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.ignore_files",
      arguments: .object(["max_depth": .number(3)])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.ignore_files")))
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

    let visibleOnlyResult = try registry.callTool(
      name: "workspace.ignore_files",
      arguments: .object([
        "include_hidden": .bool(false),
        "max_depth": .number(3),
      ])
    )
    let visibleOnlyPayload = try decodeTextPayload(visibleOnlyResult)
    let visibleOnlyFiles = try #require(visibleOnlyPayload.objectValue?["files"]?.arrayValue)
    #expect(visibleOnlyFiles.isEmpty)

    let truncatedResult = try registry.callTool(
      name: "workspace.ignore_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.ignore_files",
      arguments: .object(["path": .string(".git/info/exclude")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["ignore_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["match_source"]) == (.string("git_info_exclude")))
  }

  @Test
  func testWorkspaceAssetFilesReturnsAssetMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.asset_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.asset_files",
      arguments: .object(["max_depth": .number(4)])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.asset_files")))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.asset_files",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_depth": .number(2),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/secret.png"))

    let truncatedResult = try registry.callTool(
      name: "workspace.asset_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.asset_files",
      arguments: .object(["path": .string("Resources/Fonts/Inter.woff2")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["asset_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["category"]) == (.string("font")))
  }

  @Test
  func testWorkspaceArchiveFilesReturnsArchiveMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.archive_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.archive_files",
      arguments: .object(["max_depth": .number(4)])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.archive_files")))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.archive_files",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_depth": .number(2),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/secret.zip"))

    let truncatedResult = try registry.callTool(
      name: "workspace.archive_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.archive_files",
      arguments: .object(["path": .string("Archives/source.tar.gz")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["archive_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["format"]) == (.string("tar_gzip")))
  }

  @Test
  func testWorkspaceLogFilesReturnsLogMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.log_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.log_files",
      arguments: .object(["max_depth": .number(4)])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.log_files")))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.log_files",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_depth": .number(2),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/debug.log"))

    let truncatedResult = try registry.callTool(
      name: "workspace.log_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.log_files",
      arguments: .object(["path": .string("logs/current")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["log_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["match_source"]) == (.string("logs_directory")))
  }

  @Test
  func testWorkspaceDataFilesReturnsDataMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.data_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.data_files",
      arguments: .object(["max_depth": .number(4)])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.data_files")))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.data_files",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_depth": .number(2),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/secret.csv"))

    let truncatedResult = try registry.callTool(
      name: "workspace.data_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.data_files",
      arguments: .object(["path": .string("app.sqlite")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["data_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["format"]) == (.string("sqlite")))
  }

  @Test
  func testWorkspaceSchemaFilesReturnsSchemaMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.schema_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.schema_files",
      arguments: .object(["max_depth": .number(4)])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.schema_files")))
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

    let hiddenResult = try registry.callTool(
      name: "workspace.schema_files",
      arguments: .object([
        "include_hidden": .bool(true),
        "max_depth": .number(2),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)
    let hiddenPaths = try #require(hiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
      $0.objectValue?["workspace_relative_path"]?.stringValue
    }
    #expect(hiddenPaths.contains(".hidden/hidden.proto"))

    let truncatedResult = try registry.callTool(
      name: "workspace.schema_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.schema_files",
      arguments: .object(["path": .string("api/openapi.yaml")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["schema_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["schema_kind"]) == (.string("openapi")))
  }

  @Test
  func testWorkspaceSourceFilesReturnsSourceMetadataOnly() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.source_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.source_files",
      arguments: .object(["max_depth": .number(4)])
    )
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.source_files")))
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

    let withTestsResult = try registry.callTool(
      name: "workspace.source_files",
      arguments: .object([
        "include_tests": .bool(true),
        "include_hidden": .bool(true),
        "max_depth": .number(4),
      ])
    )
    let withTestsPayload = try decodeTextPayload(withTestsResult)
    let withTestsPaths = try #require(withTestsPayload.objectValue?["files"]?.arrayValue)
      .compactMap {
        $0.objectValue?["workspace_relative_path"]?.stringValue
      }
    #expect(withTestsPaths.contains("Tests/AppTests/AppTests.swift"))
    #expect(withTestsPaths.contains(".hidden/hidden.py"))
    #expect(!(withTestsPaths.contains("build/generated.swift")))

    let truncatedResult = try registry.callTool(
      name: "workspace.source_files",
      arguments: .object(["max_results": .number(1)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.source_files",
      arguments: .object(["path": .string("Sources/App/view.tsx")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["source_file_count"]) == (.number(1)))
    let singleFile = try #require(singleFilePayload.objectValue?["files"]?.arrayValue?.first)
      .objectValue
    #expect((singleFile?["language"]) == (.string("typescript")))
  }

  @Test
  func testWorkspaceOutlineReturnsBoundedMechanicalMarkersAcrossFiles() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.outline"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.outline",
      arguments: .object(["max_depth": .number(4)])
    )
    let payload = try decodeTextPayload(result)
    let items = try #require(payload.objectValue?["items"]?.arrayValue)
    let names = items.compactMap { $0.objectValue?["name"]?.stringValue }

    #expect((payload.objectValue?["operation"]) == (.string("workspace.outline")))
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
        $0.objectValue?["workspace_relative_path"] == .string("Sources/App/App.swift")
      }?.objectValue
    )
    #expect((firstAppItem["language"]) == (.string("swift")))
    #expect((firstAppItem["read_context"]?.objectValue?["tool"]) == (.string("file.read_context")))
    #expect((firstAppItem["outline_context"]?.objectValue?["tool"]) == (.string("file.outline")))

    let expandedResult = try registry.callTool(
      name: "workspace.outline",
      arguments: .object([
        "include_hidden": .bool(true),
        "include_tests": .bool(true),
        "include_imports": .bool(true),
        "max_depth": .number(4),
      ])
    )
    let expandedPayload = try decodeTextPayload(expandedResult)
    let expandedNames = try #require(expandedPayload.objectValue?["items"]?.arrayValue)
      .compactMap {
        $0.objectValue?["name"]?.stringValue
      }
    #expect(expandedNames.contains("Foundation"))
    #expect(expandedNames.contains("AppTests"))
    #expect(expandedNames.contains("hidden_function"))

    let truncatedResult = try registry.callTool(
      name: "workspace.outline",
      arguments: .object([
        "max_depth": .number(4),
        "max_items": .number(3),
      ])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(3)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.outline",
      arguments: .object(["path": .string("Sources/App/App.swift")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["outline_file_count"]) == (.number(1)))

    expectThrows(
      try registry.callTool(
        name: "workspace.outline",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }
  }

  @Test
  func testWorkspaceCommandsReturnsManifestCommandEntrypoints() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        cli: CLISectionConfig(commands: [
          CLICommandConfig(id: "npm", executable: "npm"),
          CLICommandConfig(id: "make", executable: "make"),
          CLICommandConfig(id: "swift", executable: "swift"),
        ]),
        builtin: BuiltinConfig(enabled: ["workspace.commands"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.commands",
      arguments: .object(["max_depth": .number(4)])
    )
    let payload = try decodeTextPayload(result)
    let commands = try #require(payload.objectValue?["commands"]?.arrayValue)
    let byKey = Dictionary(
      uniqueKeysWithValues: commands.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let source = object["source_workspace_relative_path"]?.stringValue,
          let ecosystem = object["ecosystem"]?.stringValue,
          let name = object["name"]?.stringValue
        else {
          return nil
        }
        return ("\(source)|\(ecosystem)|\(name)", object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.commands")))
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
      (byKey["crates/app/Cargo.toml|rust|run"]?["cwd_workspace_relative_path"])
        == (.string("crates/app")))
    #expect((byKey[".hidden/package.json|node|hidden"]) == nil)
    #expect((byKey["node_modules/pkg/package.json|node|ignored"]) == nil)

    let parseErrors = try #require(payload.objectValue?["parse_errors"]?.arrayValue)
    #expect((parseErrors.count) == (1))
    #expect(
      (parseErrors.first?.objectValue?["source_workspace_relative_path"])
        == (.string("bad/package.json")))

    let truncatedResult = try registry.callTool(
      name: "workspace.commands",
      arguments: .object(["max_results": .number(2)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(2)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let singleFileResult = try registry.callTool(
      name: "workspace.commands",
      arguments: .object(["path": .string("Package.swift")])
    )
    let singleFilePayload = try decodeTextPayload(singleFileResult)
    #expect((singleFilePayload.objectValue?["manifest_count"]) == (.number(1)))
    #expect((singleFilePayload.objectValue?["command_count"]) == (.number(3)))
  }

  @Test
  func testWorkspaceGovernanceFilesReturnsGovernanceMetadataOnly() throws {
    let directory = try temporaryDirectory()
    let opsBin = directory.appendingPathComponent("_ops/bin")
    let referencesUpstream = directory.appendingPathComponent("references/upstreams/devspace")
    let referencesFork = directory.appendingPathComponent("references/forks/local")
    let codexWorkspaceSkill = directory.appendingPathComponent(".codex/skills/workspace")
    let githubDirectory = directory.appendingPathComponent(".github")
    let nodeModules = directory.appendingPathComponent("node_modules/pkg")
    let hiddenDirectory = directory.appendingPathComponent(".hidden")
    try FileManager.default.createDirectory(
      at: opsBin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: referencesUpstream, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: referencesFork, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: codexWorkspaceSkill, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: githubDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: nodeModules, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: hiddenDirectory, withIntermediateDirectories: true)

    let workspaceExecutable = opsBin.appendingPathComponent("workspace")
    try "#!/bin/sh\n".write(to: workspaceExecutable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: workspaceExecutable.path
    )
    try "refs:\n  - devspace\n".write(
      to: directory.appendingPathComponent("refs.yaml"), atomically: true, encoding: .utf8)
    try "lock: true\n".write(
      to: directory.appendingPathComponent("refs.lock.yaml"), atomically: true,
      encoding: .utf8)
    try "# workspace skill\n".write(
      to: codexWorkspaceSkill.appendingPathComponent("SKILL.md"), atomically: true,
      encoding: .utf8)
    try "* @owner\n".write(
      to: githubDirectory.appendingPathComponent("CODEOWNERS"), atomically: true,
      encoding: .utf8)
    try "ignored\n".write(
      to: nodeModules.appendingPathComponent("refs.yaml"), atomically: true, encoding: .utf8)
    try "hidden\n".write(
      to: hiddenDirectory.appendingPathComponent("refs.yaml"), atomically: true, encoding: .utf8)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.governance_files"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "workspace.governance_files",
      arguments: .object(["max_depth": .number(6)])
    )
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let byPath = Dictionary(
      uniqueKeysWithValues: files.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let path = object["workspace_relative_path"]?.stringValue
        else {
          return nil
        }
        return (path, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("workspace.governance_files")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(true)))
    #expect((payload.objectValue?["scan_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(false)))
    #expect((byPath["_ops"]) != nil)
    #expect((byPath["_ops/bin/workspace"]?["kind"]) == (.string("workspace_cli")))
    #expect((byPath["_ops/bin/workspace"]?["is_executable"]) == (.bool(true)))
    #expect((byPath["refs.yaml"]?["category"]) == (.string("workspace_refs")))
    #expect((byPath["refs.yaml"]?["yaml_readable"]) == (.bool(true)))
    #expect((byPath["refs.yaml"]?["yaml_context"]?.objectValue?["tool"]) == (.string("yaml.read")))
    #expect((byPath["refs.lock.yaml"]?["kind"]) == (.string("refs_lock")))
    #expect((byPath["references/upstreams"]?["kind"]) == (.string("upstream_refs_root")))
    #expect((byPath["references/upstreams/devspace"]?["kind"]) == (.string("upstream_reference")))
    #expect((byPath["references/forks/local"]?["kind"]) == (.string("fork_reference")))
    #expect((byPath[".codex/skills/workspace/SKILL.md"]?["kind"]) == (.string("workspace_skill")))
    #expect((byPath[".github/CODEOWNERS"]?["provider"]) == (.string("github")))
    #expect((byPath["node_modules/pkg/refs.yaml"]) == nil)
    #expect((byPath[".hidden/refs.yaml"]) != nil)
    #expect((byPath["refs.yaml"]?["value"]) == nil)
    #expect(
      (byPath["refs.yaml"]?["read_lines_context"]?.objectValue?["tool"])
        == (.string("file.read_lines")))
    #expect((byPath["refs.yaml"]?["stat_context"]?.objectValue?["tool"]) == (.string("file.stat")))

    let noHiddenResult = try registry.callTool(
      name: "workspace.governance_files",
      arguments: .object(["include_hidden": .bool(false), "max_depth": .number(6)])
    )
    let noHiddenPayload = try decodeTextPayload(noHiddenResult)
    let noHiddenPaths = Set(
      try #require(noHiddenPayload.objectValue?["files"]?.arrayValue).compactMap {
        $0.objectValue?["workspace_relative_path"]?.stringValue
      })
    #expect(!(noHiddenPaths.contains(".hidden/refs.yaml")))
    #expect(!(noHiddenPaths.contains(".codex/skills/workspace/SKILL.md")))

    let truncatedResult = try registry.callTool(
      name: "workspace.governance_files",
      arguments: .object(["max_results": .number(2)])
    )
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(2)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))
  }

  @Test
  func testSystemInfoReturnsReadOnlyMacOSSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.info"])
      )
    )

    let result = try registry.callTool(name: "system.info", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operating_system"]?.objectValue?["name"]) == (.string("macOS")))
    #expect((payload.objectValue?["hardware"]?.objectValue?["processor_count"]) != nil)
    #expect((payload.objectValue?["process"]?.objectValue?["id"]) != nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemKernelReturnsReadOnlyUnameSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.kernel"])
      )
    )

    let result = try registry.callTool(name: "system.kernel", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.kernel")))
    #expect((payload.objectValue?["source"]) == (.string("uname")))
    #expect((payload.objectValue?["operating_system"]?.objectValue?["name"]) == (.string("macOS")))
    #expect(
      !(try #require(payload.objectValue?["kernel"]?.objectValue?["name"]?.stringValue).isEmpty))
    #expect(
      !(try #require(payload.objectValue?["kernel"]?.objectValue?["release"]?.stringValue).isEmpty))
    #expect(
      !(try #require(payload.objectValue?["hardware"]?.objectValue?["machine"]?.stringValue)
        .isEmpty))
    #expect(
      (try #require(payload.objectValue?["hardware"]?.objectValue?["processor_count"]?.numberValue))
        > (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemSoftwareUsesSWVersFixedArgvAndParsesVersion() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      ProductName:\t\tmacOS
      ProductVersion:\t\t15.6
      BuildVersion:\t\t24G84
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.software"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "system.software",
      arguments: .object(["timeout_ms": .number(1234)])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/sw_vers"))
    #expect((runner.calls.first?.arguments) == ([]))
    #expect((payload.objectValue?["operation"]) == (.string("system.software")))
    #expect((payload.objectValue?["source"]) == (.string("/usr/bin/sw_vers")))
    #expect((payload.objectValue?["product"]?.objectValue?["name"]) == (.string("macOS")))
    #expect((payload.objectValue?["product"]?.objectValue?["version"]) == (.string("15.6")))
    #expect((payload.objectValue?["product"]?.objectValue?["build_version"]) == (.string("24G84")))
    #expect(
      (try #require(
        payload.objectValue?["process_info"]?.objectValue?["major_version"]?.numberValue)) >= (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemLocaleReturnsReadOnlyLocaleSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.locale"])
      )
    )

    let result = try registry.callTool(name: "system.locale", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.locale")))
    #expect((payload.objectValue?["source"]) == (.string("Foundation.Locale")))
    #expect(
      !(try #require(payload.objectValue?["locale"]?.objectValue?["identifier"]?.stringValue)
        .isEmpty))
    #expect((payload.objectValue?["preferred_languages"]?.arrayValue) != nil)
    #expect(
      !(try #require(payload.objectValue?["calendar"]?.objectValue?["identifier"]?.stringValue)
        .isEmpty))
    #expect(
      !(try #require(payload.objectValue?["time_zone"]?.objectValue?["identifier"]?.stringValue)
        .isEmpty))
    #expect((payload.objectValue?["time_zone"]?.objectValue?["seconds_from_gmt"]) != nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemMemoryReturnsReadOnlyVMStats() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.memory"])
      )
    )

    let result = try registry.callTool(name: "system.memory", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.memory")))
    #expect((payload.objectValue?["source"]) == (.string("host_statistics64")))
    #expect((try #require(payload.objectValue?["physical_memory_bytes"]?.numberValue)) > (0))
    #expect((try #require(payload.objectValue?["page_size_bytes"]?.numberValue)) > (0))
    #expect((try #require(payload.objectValue?["pages"]?.objectValue?["free"]?.numberValue)) >= (0))
    #expect(
      (try #require(payload.objectValue?["bytes"]?.objectValue?["wired"]?.numberValue)) >= (0))
    #expect(
      (try #require(payload.objectValue?["events"]?.objectValue?["faults"]?.numberValue)) >= (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemLoadReturnsReadOnlyLoadAverage() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.load"])
      )
    )

    let result = try registry.callTool(name: "system.load", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.load")))
    #expect((payload.objectValue?["source"]) == (.string("getloadavg")))
    #expect((try #require(payload.objectValue?["sample_count"]?.numberValue)) >= (1))
    #expect((try #require(payload.objectValue?["active_processor_count"]?.numberValue)) > (0))
    #expect(
      (try #require(payload.objectValue?["load_average"]?.objectValue?["one_minute"]?.numberValue))
        >= (0))
    #expect(
      (try #require(
        payload.objectValue?["load_per_active_processor"]?.objectValue?["one_minute"]?
          .numberValue)) >= (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemCPUReturnsReadOnlyProcessorSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.cpu"])
      )
    )

    let result = try registry.callTool(name: "system.cpu", arguments: .object([:]))
    let payload = try decodeTextPayload(result)
    let processInfo = try #require(payload.objectValue?["process_info"]?.objectValue)
    let hardware = try #require(payload.objectValue?["hardware"]?.objectValue)
    let machine = try #require(hardware["machine"]?.stringValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.cpu")))
    #expect(
      (payload.objectValue?["source"])
        == (.array([.string("ProcessInfo"), .string("sysctlbyname"), .string("uname")])))
    #expect((try #require(processInfo["processor_count"]?.numberValue)) > (0))
    #expect((try #require(processInfo["active_processor_count"]?.numberValue)) > (0))
    #expect(!(machine.isEmpty))
    #expect((hardware["model_identifier"]) != nil)
    #expect((hardware["brand_string"]) != nil)
    #expect((hardware["physical_cpu_count"]) != nil)
    #expect((hardware["logical_cpu_count"]) != nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemThermalReturnsReadOnlyConditionSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.thermal"])
      )
    )

    let result = try registry.callTool(name: "system.thermal", arguments: .object([:]))
    let payload = try decodeTextPayload(result)
    let thermalState = try #require(payload.objectValue?["thermal_state"]?.stringValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.thermal")))
    #expect((payload.objectValue?["source"]) == (.string("ProcessInfo")))
    #expect(["nominal", "fair", "serious", "critical", "unknown"].contains(thermalState))
    #expect((payload.objectValue?["thermal_state_rank"]?.numberValue) != nil)
    #expect((payload.objectValue?["low_power_mode_enabled"]?.boolValue) != nil)
    #expect((try #require(payload.objectValue?["processor_count"]?.numberValue)) > (0))
    #expect((try #require(payload.objectValue?["active_processor_count"]?.numberValue)) > (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemTimeReturnsLocalTimeSnapshot() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.time"])
      )
    )

    let result = try registry.callTool(name: "system.time", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["now"]?.objectValue?["iso8601"]?.stringValue) != nil)
    #expect((payload.objectValue?["now"]?.objectValue?["unix_time"]?.numberValue) != nil)
    #expect(
      !(try #require(payload.objectValue?["time_zone"]?.objectValue?["identifier"]?.stringValue)
        .isEmpty))
    #expect((payload.objectValue?["time_zone"]?.objectValue?["seconds_from_gmt"]) != nil)
    #expect(
      (try #require(payload.objectValue?["system"]?.objectValue?["uptime_seconds"]?.numberValue))
        > (0))
  }

  @Test
  func testSystemUptimeReturnsReadOnlyBootTimeSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.uptime"])
      )
    )

    let result = try registry.callTool(name: "system.uptime", arguments: .object([:]))
    let payload = try decodeTextPayload(result)
    let uptime = try #require(payload.objectValue?["uptime_seconds"]?.numberValue)
    let bootTime = try #require(payload.objectValue?["boot_time"]?.objectValue)
    let now = try #require(payload.objectValue?["now"]?.objectValue)
    let bootUnixTime = try #require(bootTime["unix_time"]?.numberValue)
    let nowUnixTime = try #require(now["unix_time"]?.numberValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.uptime")))
    #expect(
      (payload.objectValue?["source"])
        == (.array([.string("ProcessInfo.systemUptime"), .string("Date")])))
    #expect((uptime) > (0))
    #expect((bootTime["iso8601"]?.stringValue) != nil)
    #expect((now["iso8601"]?.stringValue) != nil)
    #expect((bootUnixTime) < (nowUnixTime))
    #expect((abs((nowUnixTime - bootUnixTime) - uptime)) < (1))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemUserReturnsCurrentPOSIXIdentity() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.user"])
      )
    )

    let result = try registry.callTool(name: "system.user", arguments: .object([:]))
    let payload = try decodeTextPayload(result)
    let ids = try #require(payload.objectValue?["ids"]?.objectValue)
    let user = try #require(payload.objectValue?["user"]?.objectValue)
    let effectiveUser = try #require(payload.objectValue?["effective_user"]?.objectValue)
    let group = try #require(payload.objectValue?["group"]?.objectValue)
    let effectiveGroup = try #require(payload.objectValue?["effective_group"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.user")))
    #expect(
      (payload.objectValue?["source"])
        == (.array([
          .string("getuid"),
          .string("geteuid"),
          .string("getgid"),
          .string("getegid"),
          .string("getpwuid"),
          .string("getgrgid"),
        ])))
    #expect((ids["uid"]) == (.number(Double(getuid()))))
    #expect((ids["effective_uid"]) == (.number(Double(geteuid()))))
    #expect((ids["gid"]) == (.number(Double(getgid()))))
    #expect((ids["effective_gid"]) == (.number(Double(getegid()))))
    #expect(!(try #require(user["name"]?.stringValue).isEmpty))
    #expect(!(try #require(effectiveUser["name"]?.stringValue).isEmpty))
    #expect(!(try #require(group["name"]?.stringValue).isEmpty))
    #expect(!(try #require(effectiveGroup["name"]?.stringValue).isEmpty))
    #expect((user["home_directory"]) != nil)
    #expect((user["shell"]) != nil)
    #expect((payload.objectValue?["users"]) == nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemGroupsReturnsCurrentSupplementaryGroups() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.groups"])
      )
    )

    let result = try registry.callTool(name: "system.groups", arguments: .object([:]))
    let payload = try decodeTextPayload(result)
    let groupCount = getgroups(0, nil)
    let groups = try #require(payload.objectValue?["supplementary_groups"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.groups")))
    #expect(
      (payload.objectValue?["source"])
        == (.array([
          .string("getgroups"),
          .string("getgid"),
          .string("getegid"),
          .string("getgrgid"),
        ])))
    #expect((payload.objectValue?["primary_gid"]) == (.number(Double(getgid()))))
    #expect((payload.objectValue?["effective_gid"]) == (.number(Double(getegid()))))
    #expect(
      (payload.objectValue?["supplementary_group_count"]) == (.number(Double(max(groupCount, 0)))))
    #expect((groups.count) == (max(Int(groupCount), 0)))
    if let first = groups.first?.objectValue {
      #expect((first["gid"]?.numberValue) != nil)
      #expect((first["group"]) != nil)
    }
    #expect((payload.objectValue?["users"]) == nil)
    #expect((payload.objectValue?["groups"]) == nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemPowerUsesPMSetWithoutShellInterpolation() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.power"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "system.power",
      arguments: .object(["timeout_ms": .number(1234)])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/pmset"))
    #expect((runner.calls.first?.arguments) == (["-g", "batt"]))
    #expect((payload.objectValue?["operation"]) == (.string("system.power")))
  }

  @Test
  func testSystemVolumesReturnsMountedVolumeSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.volumes"])
      )
    )

    let result = try registry.callTool(
      name: "system.volumes",
      arguments: .object(["include_hidden": .bool(false)])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["volume_count"]) != nil)
    #expect((payload.objectValue?["volumes"]?.arrayValue) != nil)
  }

  @Test
  func testSystemProcessesUsesPSFixedArgvAndParsesSnapshot() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
        123     1 root     Ss     0.0  0.1 01:02:03 /sbin/launchd
        456   123 exampleuser S      12.5 1.2 00:00:05 /Applications/Terminal.app/Terminal
      broken line
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.processes"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "system.processes",
      arguments: .object([
        "query": .string("terminal"),
        "max_results": .number(5),
        "timeout_ms": .number(1234),
      ])
    )
    let payload = try decodeTextPayload(result)
    let processes = try #require(payload.objectValue?["processes"]?.arrayValue)
    let first = try #require(processes.first?.objectValue)

    #expect((runner.calls.first?.executable) == ("/bin/ps"))
    #expect(
      (runner.calls.first?.arguments)
        == (["-axo", "pid=,ppid=,user=,stat=,pcpu=,pmem=,etime=,comm="]))
    #expect((payload.objectValue?["operation"]) == (.string("system.processes")))
    #expect((payload.objectValue?["query"]) == (.string("terminal")))
    #expect((payload.objectValue?["process_count"]) == (.number(1)))
    #expect((first["parsed"]) == (.bool(true)))
    #expect((first["pid"]) == (.number(456)))
    #expect((first["parent_pid"]) == (.number(123)))
    #expect((first["user"]) == (.string("exampleuser")))
    #expect((first["state"]) == (.string("S")))
    #expect((first["cpu_percent"]) == (.number(12.5)))
    #expect((first["memory_percent"]) == (.number(1.2)))
    #expect((first["elapsed"]) == (.string("00:00:05")))
    #expect((first["command"]) == (.string("/Applications/Terminal.app/Terminal")))
  }

  @Test
  func testSystemProcessesReportsTruncationAndRejectsBadBounds() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
        123     1 root     Ss     0.0  0.1 01:02:03 /sbin/launchd
        456   123 exampleuser S      12.5 1.2 00:00:05 /Applications/Terminal.app/Terminal
      """
    runner.stdoutTruncated = true
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.processes"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "system.processes",
      arguments: .object(["max_results": .number(1)])
    )
    let payload = try decodeTextPayload(result)
    let processes = try #require(payload.objectValue?["processes"]?.arrayValue)

    #expect((processes.count) == (1))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout_truncated"]) == (.bool(true)))

    expectThrows(
      try registry.callTool(
        name: "system.processes",
        arguments: .object(["max_results": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }
  }

  @Test
  func testSystemWhichResolvesExecutableFromPathWithoutRunningIt() throws {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent("sample-tool")
    try "#!/bin/sh\nexit 7\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.which"])
      ),
      environment: ["PATH": directory.path]
    )

    let result = try registry.callTool(
      name: "system.which",
      arguments: .object([
        "name": .string("sample-tool"),
        "all_matches": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.which")))
    #expect((payload.objectValue?["name"]) == (.string("sample-tool")))
    #expect((payload.objectValue?["found"]) == (.bool(true)))
    #expect((payload.objectValue?["resolved_path"]) == (.string(executable.path)))
    #expect((payload.objectValue?["paths"]) == (.array([.string(executable.path)])))
    #expect((payload.objectValue?["match_count"]) == (.number(1)))
    #expect((payload.objectValue?["all_matches"]) == (.bool(true)))
    #expect((payload.objectValue?["path_entry_count"]) == (.number(1)))
    #expect((payload.objectValue?["environment"]) == nil)

    let missing = try registry.callTool(
      name: "system.which",
      arguments: .object(["name": .string("missing-tool")])
    )
    let missingPayload = try decodeTextPayload(missing)
    #expect((missingPayload.objectValue?["found"]) == (.bool(false)))
    #expect((missingPayload.objectValue?["paths"]) == (.array([])))
  }

  @Test
  func testSystemWhichRejectsBadExecutableNames() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.which"])
      )
    )

    for name in ["", "-tool", "../tool", "bad tool", "."] {
      expectThrows(
        try registry.callTool(
          name: "system.which",
          arguments: .object(["name": .string(name)])
        )
      ) { error in
        #expect(error.localizedDescription.contains("name"))
      }
    }
  }

  @Test
  func testSystemPathReturnsStructuredEntriesWithoutEnvironmentDump() throws {
    let directory = try temporaryDirectory()
    let missing = directory.appendingPathComponent("missing")
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.path"])
      ),
      environment: ["PATH": "\(directory.path):\(missing.path):\(directory.path)"]
    )

    let result = try registry.callTool(
      name: "system.path",
      arguments: .object([
        "include_missing": .bool(true),
        "max_entries": .number(10),
      ])
    )
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.path")))
    #expect((payload.objectValue?["source"]) == (.string("process_environment")))
    #expect((payload.objectValue?["path_entry_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_count"]) == (.number(3)))
    #expect((payload.objectValue?["environment"]) == nil)
    #expect((entries[0].objectValue?["path"]) == (.string(directory.path)))
    #expect((entries[0].objectValue?["exists"]) == (.bool(true)))
    #expect((entries[0].objectValue?["is_directory"]) == (.bool(true)))
    #expect((entries[0].objectValue?["is_absolute"]) == (.bool(true)))
    #expect((entries[0].objectValue?["duplicate_of_index"]) == (.null))
    #expect((entries[1].objectValue?["path"]) == (.string(missing.path)))
    #expect((entries[1].objectValue?["exists"]) == (.bool(false)))
    #expect((entries[1].objectValue?["is_directory"]) == (.bool(false)))
    #expect((entries[2].objectValue?["duplicate_of_index"]) == (.number(0)))

    let existingOnly = try registry.callTool(
      name: "system.path",
      arguments: .object([
        "include_missing": .bool(false),
        "max_entries": .number(1),
      ])
    )
    let existingPayload = try decodeTextPayload(existingOnly)
    let existingEntries = try #require(existingPayload.objectValue?["entries"]?.arrayValue)
    #expect((existingPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((existingPayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((existingEntries.map { $0.objectValue?["path"] }) == ([.string(directory.path)]))
  }

  @Test
  func testSystemPathRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.path"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "system.path",
        arguments: .object(["max_entries": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_entries"))
    }
  }

  @Test
  func testLogsQueryUsesBoundedNDJSONArgvAndParsesEvents() throws {
    let runner = FakeCommandRunner()
    runner.stdout =
      """
      {"eventMessage":"first","processImagePath":"/usr/bin/example"}
      not-json
      {"eventMessage":"third"}
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["logs.query"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "logs.query",
      arguments: .object([
        "last_seconds": .number(300),
        "max_entries": .number(2),
        "predicate": .string("process == \"example\""),
        "include_info": .bool(true),
        "include_debug": .bool(true),
        "timeout_ms": .number(12_345),
        "max_output_bytes": .number(65_536),
      ])
    )
    let payload = try decodeTextPayload(result)
    let events = try #require(payload.objectValue?["events"]?.arrayValue)
    let unparsed = try #require(payload.objectValue?["unparsed_lines"]?.arrayValue)

    #expect((runner.calls.first?.executable) == ("/usr/bin/log"))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "show", "--style", "ndjson", "--color", "none", "--no-pager", "--last", "300s",
          "--info", "--debug", "--predicate", "process == \"example\"",
        ]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (12_345))
    #expect((runner.calls.first?.maxOutputBytes) == (65_536))
    #expect((payload.objectValue?["operation"]) == (.string("logs.query")))
    #expect((payload.objectValue?["source"]) == (.string("macos_unified_log")))
    #expect((payload.objectValue?["observed_line_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_line_count"]) == (.number(2)))
    #expect((payload.objectValue?["event_count"]) == (.number(1)))
    #expect((payload.objectValue?["unparsed_line_count"]) == (.number(1)))
    #expect((payload.objectValue?["omitted_line_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((events.first?.objectValue?["eventMessage"]) == (.string("first")))
    #expect((unparsed.first?.objectValue?["line"]) == (.string("not-json")))
    #expect((payload.objectValue?["execution"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testLogsQueryRequiresExplicitBoundsAndRejectsBadPredicate() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["logs.query"])
      )
    )

    expectThrows(
      try registry.callTool(name: "logs.query", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("last_seconds"))
    }
    expectThrows(
      try registry.callTool(
        name: "logs.query",
        arguments: .object([
          "last_seconds": .number(1),
          "max_entries": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_entries"))
    }
    expectThrows(
      try registry.callTool(
        name: "logs.query",
        arguments: .object([
          "last_seconds": .number(1),
          "max_entries": .number(1),
          "predicate": .string(""),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("predicate"))
    }
  }

  @Test
  func testServiceStatusUsesCurrentUIDAndRedactsUnsafeLaunchctlSections() throws {
    let runner = FakeCommandRunner()
    runner.stdout =
      """
      gui/501/com.example.worker = {
      \tactive count = 1
      \tpath = /Library/LaunchAgents/com.example.worker.plist
      \ttype = LaunchAgent
      \tstate = running
      \tenvironment = {
      \t\tSECRET_TOKEN => do-not-return
      \t}
      \tpid = 123
      \truns = 4
      }
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["service.status"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "service.status",
      arguments: .object([
        "domain": .string("gui"),
        "label": .string("com.example.worker"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let fields = try #require(payload.objectValue?["fields"]?.objectValue)
    let encoded = try JSONEncoder().encode(payload)
    let text = String(decoding: encoded, as: UTF8.self)

    #expect((runner.calls.first?.executable) == ("/bin/launchctl"))
    #expect((runner.calls.first?.arguments) == (["print", "gui/\(geteuid())/com.example.worker"]))
    #expect((payload.objectValue?["operation"]) == (.string("service.status")))
    #expect((payload.objectValue?["found"]) == (.bool(true)))
    #expect((payload.objectValue?["environment_returned"]) == (.bool(false)))
    #expect((payload.objectValue?["raw_output_returned"]) == (.bool(false)))
    #expect((fields["state"]) == (.string("running")))
    #expect((fields["pid"]) == (.number(123)))
    #expect((fields["runs"]) == (.number(4)))
    #expect((fields["environment"]) == nil)
    #expect(!(text.contains("SECRET_TOKEN")))
    #expect(!(text.contains("do-not-return")))
  }

  @Test
  func testServiceStatusReportsMissingAndRejectsUnsafeTargets() throws {
    let runner = FakeCommandRunner()
    runner.exitCode = 113
    runner.stdout = "environment = { SECRET_TOKEN => do-not-return }"
    runner.stderr = "Could not find service"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["service.status"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "service.status",
      arguments: .object([
        "domain": .string("system"),
        "label": .string("com.example.missing"),
      ])
    )
    let payload = try decodeTextPayload(result)
    #expect((runner.calls.first?.arguments) == (["print", "system/com.example.missing"]))
    #expect((payload.objectValue?["found"]) == (.bool(false)))
    #expect((payload.objectValue?["fields"]) == (.object([:])))
    #expect((payload.objectValue?["execution"]?.objectValue?["stdout"]) == nil)

    expectThrows(
      try registry.callTool(
        name: "service.status",
        arguments: .object([
          "domain": .string("login"),
          "label": .string("com.example.worker"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("domain"))
    }
    expectThrows(
      try registry.callTool(
        name: "service.status",
        arguments: .object([
          "domain": .string("gui"),
          "label": .string("../com.example.worker"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("label"))
    }
  }

  @Test
  func testNetworkInterfacesUsesIfconfigWithFixedArgv() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.interfaces"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.interfaces",
      arguments: .object(["interface": .string("lo0")])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/sbin/ifconfig"))
    #expect((runner.calls.first?.arguments) == (["lo0"]))
    #expect((payload.objectValue?["operation"]) == (.string("network.interfaces")))
    #expect((payload.objectValue?["interface"]) == (.string("lo0")))

    _ = try registry.callTool(name: "network.interfaces", arguments: .object([:]))
    #expect((runner.calls.last?.arguments) == (["-a"]))
  }

  @Test
  func testNetworkInterfacesRejectsOptionLikeInterfaceName() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.interfaces"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.interfaces",
        arguments: .object(["interface": .string("-a")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("option"))
    }
  }

  @Test
  func testNetworkDNSUsesSCUtilWithFixedArgv() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.dns"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(name: "network.dns", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/scutil"))
    #expect((runner.calls.first?.arguments) == (["--dns"]))
    #expect((payload.objectValue?["operation"]) == (.string("network.dns")))
  }

  @Test
  func testNetworkResolveUsesSystemResolverWithoutShell() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.resolve"])
      )
    )

    let result = try registry.callTool(
      name: "network.resolve",
      arguments: .object([
        "host": .string("localhost"),
        "family": .string("ipv4"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let addresses = try #require(payload.objectValue?["addresses"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("network.resolve")))
    #expect((payload.objectValue?["source"]) == (.string("getaddrinfo")))
    #expect((payload.objectValue?["host"]) == (.string("localhost")))
    #expect((payload.objectValue?["family"]) == (.string("ipv4")))
    #expect((payload.objectValue?["resolved"]) == (.bool(true)))
    #expect((addresses.count) >= (1))
    #expect(
      addresses.contains { address in
        address.objectValue?["family"] == .string("ipv4")
          && address.objectValue?["address"] == .string("127.0.0.1")
      })
    #expect((payload.objectValue?["result"]) == nil)
  }

  @Test
  func testNetworkResolveReportsUnresolvedHostAsResult() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.resolve"])
      )
    )

    let result = try registry.callTool(
      name: "network.resolve",
      arguments: .object([
        "host": .string("::1"),
        "family": .string("ipv4"),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("network.resolve")))
    #expect((payload.objectValue?["resolved"]) == (.bool(false)))
    #expect((payload.objectValue?["error_code"]?.numberValue) != nil)
    #expect(!(try #require(payload.objectValue?["error"]?.stringValue).isEmpty))
    #expect((payload.objectValue?["addresses"]) == (.array([])))
  }

  @Test
  func testNetworkResolveRejectsBadInputs() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.resolve"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.resolve",
        arguments: .object(["host": .string("https://example.com")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("URL"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.resolve",
        arguments: .object([
          "host": .string("localhost"),
          "family": .string("link"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("family"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.resolve",
        arguments: .object([
          "host": .string("localhost"),
          "max_results": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }
  }

  @Test
  func testNetworkProxyUsesSCUtilWithFixedArgv() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      <dictionary> {
        HTTPEnable : 0
        HTTPSEnable : 0
      }
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.proxy"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.proxy",
      arguments: .object(["timeout_ms": .number(1234)])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/scutil"))
    #expect((runner.calls.first?.arguments) == (["--proxy"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((payload.objectValue?["operation"]) == (.string("network.proxy")))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkProxyRejectsBadTimeout() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.proxy"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.proxy",
        arguments: .object(["timeout_ms": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }
  }

  @Test
  func testNetworkServicesUsesNetworkSetupWithFixedArgv() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      An asterisk (*) denotes that a network service is disabled.
      Wi-Fi
      Thunderbolt Bridge
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.services"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.services",
      arguments: .object([
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/networksetup"))
    #expect((runner.calls.first?.arguments) == (["-listallnetworkservices"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.services")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("-listallnetworkservices")])))
    #expect((payload.objectValue?["max_output_bytes"]) == (.number(4096)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkServicesRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.services"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.services",
        arguments: .object(["timeout_ms": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.services",
        arguments: .object(["max_output_bytes": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkHardwarePortsUsesNetworkSetupWithFixedArgv() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      Hardware Port: Wi-Fi
      Device: en0
      Ethernet Address: aa:bb:cc:dd:ee:ff
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.hardware_ports"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.hardware_ports",
      arguments: .object([
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/networksetup"))
    #expect((runner.calls.first?.arguments) == (["-listallhardwareports"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.hardware_ports")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("-listallhardwareports")])))
    #expect((payload.objectValue?["max_output_bytes"]) == (.number(4096)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkHardwarePortsRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.hardware_ports"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.hardware_ports",
        arguments: .object(["timeout_ms": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.hardware_ports",
        arguments: .object(["max_output_bytes": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkWiFiDiscoversDeviceAndUsesFixedNetworkSetupArgv() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(
        stdout: """
          Hardware Port: Thunderbolt Bridge
          Device: bridge0
          Ethernet Address: aa:bb:cc:dd:ee:00

          Hardware Port: Wi-Fi
          Device: en0
          Ethernet Address: aa:bb:cc:dd:ee:ff
          """),
      FakeCommandRunner.Output(stdout: "Wi-Fi Power (en0): On\n"),
      FakeCommandRunner.Output(stdout: "Current Wi-Fi Network: StudioNet\n"),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.wifi"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.wifi",
      arguments: .object([
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.count) == (3))
    #expect((runner.calls[0].executable) == ("/usr/sbin/networksetup"))
    #expect((runner.calls[0].arguments) == (["-listallhardwareports"]))
    #expect((runner.calls[1].arguments) == (["-getairportpower", "en0"]))
    #expect((runner.calls[2].arguments) == (["-getairportnetwork", "en0"]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((runner.calls[1].maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.wifi")))
    #expect((payload.objectValue?["available"]) == (.bool(true)))
    #expect((payload.objectValue?["device"]) == (.string("en0")))
    #expect((payload.objectValue?["hardware_port"]) == (.string("Wi-Fi")))
    #expect((payload.objectValue?["power"]) == (.string("on")))
    #expect((payload.objectValue?["associated"]) == (.bool(true)))
    #expect((payload.objectValue?["ssid"]) == (.string("StudioNet")))
    #expect(
      (payload.objectValue?["discovery_argv"]) == (.array([.string("-listallhardwareports")])))
    #expect((payload.objectValue?["discovery"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testNetworkWiFiReportsUnavailableWithoutRunningPowerQueries() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      Hardware Port: Thunderbolt Bridge
      Device: bridge0
      Ethernet Address: aa:bb:cc:dd:ee:00
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.wifi"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(name: "network.wifi", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.count) == (1))
    #expect((payload.objectValue?["operation"]) == (.string("network.wifi")))
    #expect((payload.objectValue?["available"]) == (.bool(false)))
    #expect((payload.objectValue?["device"]) == (.null))
    #expect((payload.objectValue?["associated"]) == (.bool(false)))
    #expect((payload.objectValue?["ssid"]) == (.null))
    #expect((payload.objectValue?["power_argv"]) == (.null))
    #expect((payload.objectValue?["network_argv"]) == (.null))
  }

  @Test
  func testNetworkWiFiRejectsBadInputs() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.wifi"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.wifi",
        arguments: .object(["device": .string("-bad")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("interface"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.wifi",
        arguments: .object(["timeout_ms": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.wifi",
        arguments: .object(["max_output_bytes": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkVPNUsesScutilNCListAndParsesServices() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      Available network connection services in the current set (*=enabled):
      * (Disconnected)   53F34FF6-F7ED-4085-8674-4EACFD48520A PPP --> LG Monitor Controls "LG Monitor Controls"            [PPP:Modem]
        (Connected)      11111111-2222-3333-4444-555555555555 IKEv2 --> Work VPN "Work VPN"            [VPN:IKEv2]
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.vpn"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.vpn",
      arguments: .object([
        "max_results": .number(1),
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)
    let services = try #require(payload.objectValue?["services"]?.arrayValue)
    let first = try #require(services.first?.objectValue)

    #expect((runner.calls.count) == (1))
    #expect((runner.calls[0].executable) == ("/usr/sbin/scutil"))
    #expect((runner.calls[0].arguments) == (["--nc", "list"]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((runner.calls[0].maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.vpn")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("--nc"), .string("list")])))
    #expect((payload.objectValue?["service_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((first["enabled"]) == (.bool(true)))
    #expect((first["status"]) == (.string("Disconnected")))
    #expect((first["connected"]) == (.bool(false)))
    #expect((first["id"]) == (.string("53F34FF6-F7ED-4085-8674-4EACFD48520A")))
    #expect((first["name"]) == (.string("LG Monitor Controls")))
    #expect((first["protocol"]) == (.string("PPP")))
    #expect((first["type"]) == (.string("PPP:Modem")))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testNetworkVPNRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.vpn"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.vpn",
        arguments: .object(["max_results": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.vpn",
        arguments: .object(["timeout_ms": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.vpn",
        arguments: .object(["max_output_bytes": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkLocationsUsesNetworkSetupWithFixedArgv() throws {
    let runner = FakeCommandRunner()
    runner.stdout = "Automatic\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.locations"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.locations",
      arguments: .object([
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.count) == (2))
    #expect((runner.calls[0].executable) == ("/usr/sbin/networksetup"))
    #expect((runner.calls[0].arguments) == (["-getcurrentlocation"]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((runner.calls[0].maxOutputBytes) == (4096))
    #expect((runner.calls[1].executable) == ("/usr/sbin/networksetup"))
    #expect((runner.calls[1].arguments) == (["-listlocations"]))
    #expect((runner.calls[1].timeoutMilliseconds) == (1234))
    #expect((runner.calls[1].maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.locations")))
    #expect((payload.objectValue?["current_argv"]) == (.array([.string("-getcurrentlocation")])))
    #expect((payload.objectValue?["list_argv"]) == (.array([.string("-listlocations")])))
    #expect((payload.objectValue?["max_output_bytes"]) == (.number(4096)))
    #expect((payload.objectValue?["current"]?.objectValue?["stdout"]) == (.string("Automatic\n")))
    #expect((payload.objectValue?["locations"]?.objectValue?["stdout"]) == (.string("Automatic\n")))
  }

  @Test
  func testNetworkLocationsRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.locations"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.locations",
        arguments: .object(["timeout_ms": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.locations",
        arguments: .object(["max_output_bytes": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkRoutesUsesNetstatWithFixedArgv() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      Routing tables

      Internet:
      Destination        Gateway            Flags        Netif Expire
      default            192.168.1.1        UGSc           en0
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.routes"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.routes",
      arguments: .object([
        "family": .string("inet"),
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/netstat"))
    #expect((runner.calls.first?.arguments) == (["-rn", "-f", "inet"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.routes")))
    #expect((payload.objectValue?["family"]) == (.string("inet")))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))

    _ = try registry.callTool(name: "network.routes", arguments: .object([:]))
    #expect((runner.calls.last?.arguments) == (["-rn"]))
  }

  @Test
  func testNetworkRoutesRejectsBadInputs() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.routes"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.routes",
        arguments: .object(["family": .string("link")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("family"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.routes",
        arguments: .object(["timeout_ms": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.routes",
        arguments: .object(["max_output_bytes": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkConnectionsUsesNetstatWithFixedArgv() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      Active Internet connections (including servers)
      Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
      tcp4       0      0  127.0.0.1.51712       127.0.0.1.3000         ESTABLISHED
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.connections"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.connections",
      arguments: .object([
        "family": .string("inet"),
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/netstat"))
    #expect((runner.calls.first?.arguments) == (["-an", "-f", "inet"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.connections")))
    #expect((payload.objectValue?["family"]) == (.string("inet")))
    #expect(
      (payload.objectValue?["argv"]) == (.array([.string("-an"), .string("-f"), .string("inet")])))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))

    _ = try registry.callTool(name: "network.connections", arguments: .object([:]))
    #expect((runner.calls.last?.arguments) == (["-an"]))
  }

  @Test
  func testNetworkConnectionsRejectsBadInputs() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.connections"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.connections",
        arguments: .object(["family": .string("link")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("family"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.connections",
        arguments: .object(["timeout_ms": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.connections",
        arguments: .object(["max_output_bytes": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkARPUsesARPWithFixedArgv() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      ? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.arp"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.arp",
      arguments: .object([
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/arp"))
    #expect((runner.calls.first?.arguments) == (["-an"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.arp")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("-an")])))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkARPRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.arp"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.arp",
        arguments: .object(["timeout_ms": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.arp",
        arguments: .object(["max_output_bytes": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkPingUsesPingWithFixedArgv() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      PING 127.0.0.1 (127.0.0.1): 56 data bytes
      64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.044 ms
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.ping"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.ping",
      arguments: .object([
        "host": .string("127.0.0.1"),
        "count": .number(2),
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/sbin/ping"))
    #expect((runner.calls.first?.arguments) == (["-c", "2", "127.0.0.1"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.ping")))
    #expect((payload.objectValue?["host"]) == (.string("127.0.0.1")))
    #expect((payload.objectValue?["count"]) == (.number(2)))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("-c"), .string("2"), .string("127.0.0.1")])))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkPingRejectsBadInputs() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.ping"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.ping",
        arguments: .object(["host": .string("-c")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("option"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.ping",
        arguments: .object(["host": .string("https://example.com")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("URL"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.ping",
        arguments: .object([
          "host": .string("localhost"),
          "count": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("count"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.ping",
        arguments: .object([
          "host": .string("localhost"),
          "max_output_bytes": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkTCPCheckUsesNCWithFixedArgv() throws {
    let runner = FakeCommandRunner()
    runner.stderr = "Connection to 127.0.0.1 port 443 [tcp/https] succeeded!\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.tcp_check"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.tcp_check",
      arguments: .object([
        "host": .string("127.0.0.1"),
        "port": .number(443),
        "connect_timeout_seconds": .number(2),
        "timeout_ms": .number(3456),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/nc"))
    #expect((runner.calls.first?.arguments) == (["-G", "2", "-zv", "127.0.0.1", "443"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (3456))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.tcp_check")))
    #expect((payload.objectValue?["host"]) == (.string("127.0.0.1")))
    #expect((payload.objectValue?["port"]) == (.number(443)))
    #expect((payload.objectValue?["connect_timeout_seconds"]) == (.number(2)))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("-G"), .string("2"), .string("-zv"), .string("127.0.0.1"), .string("443"),
        ])))
    #expect((payload.objectValue?["result"]?.objectValue?["stderr"]) == (.string(runner.stderr)))
  }

  @Test
  func testNetworkTCPCheckRejectsBadInputs() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.tcp_check"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.tcp_check",
        arguments: .object(["host": .string("localhost")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("port"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.tcp_check",
        arguments: .object([
          "host": .string("-example.com"),
          "port": .number(443),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("option"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.tcp_check",
        arguments: .object([
          "host": .string("https://example.com"),
          "port": .number(443),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("URL"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.tcp_check",
        arguments: .object([
          "host": .string("localhost"),
          "port": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("port"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.tcp_check",
        arguments: .object([
          "host": .string("localhost"),
          "port": .number(443),
          "connect_timeout_seconds": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("connect_timeout_seconds"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.tcp_check",
        arguments: .object([
          "host": .string("localhost"),
          "port": .number(443),
          "max_output_bytes": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkHTTPCheckUsesCurlWithFixedArgvAndParsesMetadata() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      hello
      __COMPUTER_MCP_HTTP_CHECK_META__
      http_code=200
      url_effective=https://example.com/health
      content_type=text/plain
      redirect_url=
      time_total=0.125000
      size_download=5
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.http_check"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.http_check",
      arguments: .object([
        "url": .string("https://example.com/health"),
        "method": .string("GET"),
        "include_body": .bool(true),
        "follow_redirects": .bool(true),
        "max_redirects": .number(3),
        "connect_timeout_seconds": .number(2),
        "timeout_ms": .number(3456),
        "max_body_bytes": .number(128),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/curl"))
    #expect((runner.calls.first?.timeoutMilliseconds) == (3456))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "--silent", "--show-error", "--max-time", "3", "--connect-timeout", "2",
          "--location", "--max-redirs", "3", "--request", "GET", "--range", "0-127",
          "--output", "-", "--write-out",
          "\n__COMPUTER_MCP_HTTP_CHECK_META__\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nredirect_url=%{redirect_url}\ntime_total=%{time_total}\nsize_download=%{size_download}\n",
          "https://example.com/health",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("network.http_check")))
    #expect((payload.objectValue?["method"]) == (.string("GET")))
    #expect((payload.objectValue?["include_body"]) == (.bool(true)))
    #expect((payload.objectValue?["follow_redirects"]) == (.bool(true)))
    #expect((payload.objectValue?["http_code"]) == (.number(200)))
    #expect((payload.objectValue?["url_effective"]) == (.string("https://example.com/health")))
    #expect((payload.objectValue?["content_type"]) == (.string("text/plain")))
    #expect((payload.objectValue?["redirect_url"]) == (.null))
    #expect((payload.objectValue?["time_total_seconds"]) == (.number(0.125)))
    #expect((payload.objectValue?["size_download_bytes"]) == (.number(5)))
    #expect((payload.objectValue?["body"]) == (.string("hello")))
    #expect((payload.objectValue?["body_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["meta_found"]) == (.bool(true)))
  }

  @Test
  func testNetworkHTTPCheckDefaultsToHeadAndRejectsBadInputs() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """

      __COMPUTER_MCP_HTTP_CHECK_META__
      http_code=404
      url_effective=http://127.0.0.1:8080/mcp
      content_type=
      redirect_url=
      time_total=0.010000
      size_download=0
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.http_check"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.http_check",
      arguments: .object(["url": .string("http://127.0.0.1:8080/mcp")])
    )
    let payload = try decodeTextPayload(result)

    #expect(runner.calls.first?.arguments.contains("--head") == true)
    #expect(runner.calls.first?.arguments.contains("/dev/null") == true)
    #expect((payload.objectValue?["method"]) == (.string("HEAD")))
    #expect((payload.objectValue?["include_body"]) == (.bool(false)))
    #expect((payload.objectValue?["http_code"]) == (.number(404)))
    #expect((payload.objectValue?["body"]) == (.null))

    expectThrows(
      try registry.callTool(
        name: "network.http_check",
        arguments: .object(["url": .string("ftp://example.com")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("http or https"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.http_check",
        arguments: .object(["url": .string("https://user:pass@example.com")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("userinfo"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.http_check",
        arguments: .object([
          "url": .string("https://example.com"),
          "method": .string("POST"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("HEAD or GET"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.http_check",
        arguments: .object([
          "url": .string("https://example.com"),
          "max_body_bytes": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_body_bytes"))
    }
  }

  @Test
  func testFileDownloadDryRunBuildsCurlArgvWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let destination = directory.appendingPathComponent("downloads/report.txt")
    let temp = directory.appendingPathComponent("downloads/.report.txt.computer-mcp-download.tmp")
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.download"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "file.download",
      arguments: .object([
        "url": .string("https://example.com/report.txt"),
        "path": .string("downloads/report.txt"),
        "create_directories": .bool(true),
        "follow_redirects": .bool(true),
        "max_redirects": .number(2),
        "connect_timeout_seconds": .number(3),
        "timeout_ms": .number(4_000),
        "max_download_bytes": .number(512),
        "max_output_bytes": .number(2_048),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(runner.calls.isEmpty)
    #expect(!(FileManager.default.fileExists(atPath: destination.path)))
    #expect((payload.objectValue?["operation"]) == (.string("file.download")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_download"]) == (.bool(false)))
    #expect((payload.objectValue?["downloaded"]) == (.bool(false)))
    #expect(
      (payload.objectValue?["destination"]?.objectValue?["workspace_relative_path"])
        == (.string("downloads/report.txt")))
    #expect(
      (payload.objectValue?["destination"]?.objectValue?["would_create_parent_directories"])
        == (.bool(true)))
    #expect(
      (payload.objectValue?["temporary_workspace_relative_path"])
        == (.string("downloads/.report.txt.computer-mcp-download.tmp")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("--fail"),
          .string("--silent"),
          .string("--show-error"),
          .string("--max-time"),
          .string("4"),
          .string("--connect-timeout"),
          .string("3"),
          .string("--max-filesize"),
          .string("512"),
          .string("--location"),
          .string("--max-redirs"),
          .string("2"),
          .string("--output"),
          .string(temp.path),
          .string("--write-out"),
          .string(
            "\n__COMPUTER_MCP_FILE_DOWNLOAD_META__\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nredirect_url=%{redirect_url}\ntime_total=%{time_total}\nsize_download=%{size_download}\n"
          ),
          .string("https://example.com/report.txt"),
        ])))
    #expect((payload.objectValue?["result"]) == (.null))
  }

  @Test
  func testFileDownloadRunsCurlAndMovesTempAfterConfirmation() throws {
    let directory = try temporaryDirectory()
    let destination = directory.appendingPathComponent("downloads/report.txt")
    let runner = FakeCommandRunner()
    runner.stdout = """

      __COMPUTER_MCP_FILE_DOWNLOAD_META__
      http_code=200
      url_effective=https://example.com/report.txt
      content_type=text/plain
      redirect_url=
      time_total=0.050000
      size_download=6
      """
    runner.onRun = { call in
      guard let outputIndex = call.arguments.firstIndex(of: "--output") else {
        return
      }
      let temp = URL(fileURLWithPath: call.arguments[outputIndex + 1])
      try FileManager.default.createDirectory(
        at: temp.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("report".utf8).write(to: temp)
    }
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.download"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "file.download",
      arguments: .object([
        "url": .string("https://example.com/report.txt"),
        "path": .string("downloads/report.txt"),
        "create_directories": .bool(true),
        "dry_run": .bool(false),
        "confirm_download": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/curl"))
    #expect((try String(contentsOf: destination, encoding: .utf8)) == ("report"))
    #expect(
      !(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(
          "downloads/.report.txt.computer-mcp-download.tmp"
        ).path
      )))
    #expect((payload.objectValue?["operation"]) == (.string("file.download")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_download"]) == (.bool(true)))
    #expect((payload.objectValue?["downloaded"]) == (.bool(true)))
    #expect((payload.objectValue?["http_code"]) == (.number(200)))
    #expect((payload.objectValue?["url_effective"]) == (.string("https://example.com/report.txt")))
    #expect((payload.objectValue?["content_type"]) == (.string("text/plain")))
    #expect((payload.objectValue?["downloaded_size_bytes"]) == (.number(6)))
    #expect(
      (payload.objectValue?["downloaded_file"]?.objectValue?["workspace_relative_path"])
        == (.string("downloads/report.txt")))
  }

  @Test
  func testFileDownloadRejectsUnsafeInputs() throws {
    let directory = try temporaryDirectory()
    let existing = directory.appendingPathComponent("downloads/report.txt")
    try FileManager.default.createDirectory(
      at: existing.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "existing".write(to: existing, atomically: true, encoding: .utf8)
    let temp = directory.appendingPathComponent("downloads/.temp.txt.computer-mcp-download.tmp")
    try "temp".write(to: temp, atomically: true, encoding: .utf8)

    let missingConfirmRunner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.download"]),
        workspaceDirectory: directory
      ),
      commandRunner: missingConfirmRunner
    )

    expectThrows(
      try registry.callTool(
        name: "file.download",
        arguments: .object([
          "url": .string("https://example.com/report.txt"),
          "path": .string("downloads/new.txt"),
          "dry_run": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_download"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try registry.callTool(
        name: "file.download",
        arguments: .object([
          "url": .string("https://user:pass@example.com/report.txt"),
          "path": .string("downloads/new.txt"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("userinfo"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.download",
        arguments: .object([
          "url": .string("ftp://example.com/report.txt"),
          "path": .string("downloads/new.txt"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("http or https"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.download",
        arguments: .object([
          "url": .string("https://example.com/report.txt"),
          "path": .string("downloads/report.txt"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("already exists"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.download",
        arguments: .object([
          "url": .string("https://example.com/temp.txt"),
          "path": .string("downloads/temp.txt"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Temporary download path already exists"))
    }
  }

  @Test
  func testNetworkListenersUsesLSOFWithFixedArgv() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
      node    12345 test   12u  IPv4 0x0000      0t0  TCP 127.0.0.1:3000 (LISTEN)
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.listeners"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.listeners",
      arguments: .object([
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/lsof"))
    #expect((runner.calls.first?.arguments) == (["-nP", "-iTCP", "-sTCP:LISTEN"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.listeners")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("-nP"), .string("-iTCP"), .string("-sTCP:LISTEN")])))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkListenersRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.listeners"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.listeners",
        arguments: .object(["timeout_ms": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.listeners",
        arguments: .object(["max_output_bytes": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testMacOSApplicationsReturnsBoundedApplicationSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["macos.applications"])
      )
    )

    let result = try registry.callTool(
      name: "macos.applications",
      arguments: .object([
        "include_system": .bool(true),
        "include_user": .bool(false),
        "max_results": .number(5),
        "max_depth": .number(2),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["include_system"]) == (.bool(true)))
    #expect((payload.objectValue?["include_user"]) == (.bool(false)))
    #expect((payload.objectValue?["max_depth"]) == (.number(2)))
    #expect((payload.objectValue?["application_count"]) != nil)
    #expect((payload.objectValue?["applications"]?.arrayValue) != nil)
  }

  @Test
  func testMacOSUserDirectoriesReturnsFixedDirectoryCatalog() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["macos.user_directories"])
      )
    )

    let result = try registry.callTool(
      name: "macos.user_directories",
      arguments: .object([
        "include_missing": .bool(true),
        "include_system": .bool(true),
        "include_temporary": .bool(true),
      ])
    )
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

    let filteredResult = try registry.callTool(
      name: "macos.user_directories",
      arguments: .object([
        "include_missing": .bool(false),
        "include_system": .bool(false),
        "include_temporary": .bool(false),
      ])
    )
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
    config.workspaceDirectory = directory
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(
      name: "macos.default_application",
      arguments: .object([
        "path": .string("note.txt"),
        "include_candidates": .bool(true),
        "max_candidates": .number(2),
      ])
    )
    let payload = try decodeTextPayload(result)
    let target = try #require(payload.objectValue?["target"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("macos.default_application")))
    #expect((target["type"]) == (.string("path")))
    #expect((target["workspace_relative_path"]) == (.string("note.txt")))
    #expect((payload.objectValue?["include_candidates"]) == (.bool(true)))
    #expect((payload.objectValue?["max_candidates"]) == (.number(2)))
    #expect((payload.objectValue?["default_application_available"]) != nil)
    #expect((payload.objectValue?["default_application"]) != nil)
    #expect((payload.objectValue?["candidate_applications"]?.arrayValue?.count ?? 0) <= (2))

    let urlResult = try registry.callTool(
      name: "macos.default_application",
      arguments: .object(["url": .string("https://example.com")])
    )
    let urlPayload = try decodeTextPayload(urlResult)
    let urlTarget = try #require(urlPayload.objectValue?["target"]?.objectValue)
    #expect((urlTarget["type"]) == (.string("url")))
    #expect((urlTarget["scheme"]) == (.string("https")))

    expectThrows(
      try registry.callTool(
        name: "macos.default_application",
        arguments: .object([
          "path": .string("note.txt"),
          "url": .string("https://example.com"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("exactly one"))
    }

    expectThrows(
      try registry.callTool(
        name: "macos.default_application",
        arguments: .object(["url": .string("file:///tmp/example.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("url scheme"))
    }
  }

  @Test
  func testMacOSScreensReturnsReadOnlyDisplaySummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["macos.screens"])
      )
    )

    let result = try registry.callTool(name: "macos.screens", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["screen_count"]) != nil)
    #expect((payload.objectValue?["screens"]?.arrayValue) != nil)
  }

  @Test
  func testMacOSSpotlightSearchUsesMDFindWithinWorkspace() throws {
    let directory = try temporaryDirectory()
    let notes = directory.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let file = notes.appendingPathComponent("alpha.txt")
    try "alpha".write(to: file, atomically: true, encoding: .utf8)

    let runner = FakeCommandRunner()
    runner.stdout =
      "\(file.path)\n/tmp/outside.txt\n\(notes.appendingPathComponent("missing.txt").path)\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["macos.spotlight_search"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "macos.spotlight_search",
      arguments: .object([
        "path": .string("notes"),
        "query": .string("alpha"),
        "max_results": .number(5),
        "max_output_bytes": .number(4096),
      ])
    )
    let payload = try decodeTextPayload(result)
    let results = try #require(payload.objectValue?["results"]?.arrayValue)

    #expect((runner.calls.first?.executable) == ("/usr/bin/mdfind"))
    #expect((runner.calls.first?.arguments) == (["-onlyin", notes.path, "alpha"]))
    #expect((payload.objectValue?["operation"]) == (.string("macos.spotlight_search")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("notes")))
    #expect((payload.objectValue?["returned_path_count"]) == (.number(3)))
    #expect((payload.objectValue?["result_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["skipped_escaped_results"]) == (.number(1)))
    #expect((payload.objectValue?["skipped_missing_results"]) == (.number(1)))
    #expect(
      (results.first?.objectValue?["workspace_relative_path"]) == (.string("notes/alpha.txt")))
  }

  @Test
  func testMacOSSpotlightSearchRejectsWorkspaceEscapeAndBadBounds() throws {
    let directory = try temporaryDirectory()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["macos.spotlight_search"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "macos.spotlight_search",
        arguments: .object([
          "path": .string("../outside"),
          "query": .string("alpha"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "macos.spotlight_search",
        arguments: .object([
          "query": .string("alpha"),
          "max_results": .number(0),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }
  }

  @Test
  func testMacOSRunningApplicationsReturnsBoundedSessionSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["macos.running_applications"])
      )
    )

    let result = try registry.callTool(
      name: "macos.running_applications",
      arguments: .object([
        "include_background": .bool(true),
        "max_results": .number(1),
      ])
    )
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
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["macos.frontmost_application"])
      )
    )

    let result = try registry.callTool(name: "macos.frontmost_application", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["available"]) != nil)
    #expect((payload.objectValue?["application"]) != nil)
  }

  @Test
  func testEnvironmentDescribeReportsOnlyConfiguredEnvNamesAndRedactsValues() throws {
    let config = GatewayConfiguration.fixture(
      server: ServerConfig(
        http: HTTPServerConfig(
          publicBaseURL: "https://gateway.example.com",
          accessTokenEnv: "COMPUTER_MCP_TOKEN"
        )
      ),
      cli: CLISectionConfig(commands: [
        CLICommandConfig(
          id: "secret-cli",
          executable: "/bin/echo",
          env: ["SECRET_CLI_TOKEN": "super-secret-cli-value"]
        )
      ]),
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "secret-mcp",
          transport: .stdio,
          command: "/bin/cat",
          env: ["SECRET_MCP_TOKEN": "super-secret-mcp-value"]
        )
      ]),
      builtin: BuiltinConfig(enabled: ["env.describe"])
    )
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(name: "env.describe", arguments: .object([:]))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))

    #expect(!(text.contains("super-secret-cli-value")))
    #expect(!(text.contains("super-secret-mcp-value")))
    #expect((payload.objectValue?["summary"]?.objectValue?["values_redacted"]) == (.bool(true)))
    #expect((payload.objectValue?["summary"]?.objectValue?["declared_key_count"]) == (.number(3)))
    let serverKeys = payload.objectValue?["server"]?.arrayValue?
      .compactMap { $0.objectValue?["key"] }
    #expect((serverKeys) == ([.string("COMPUTER_MCP_TOKEN")]))
    #expect(
      (payload.objectValue?["cli"]?.arrayValue?.first?.objectValue?["env"]?.arrayValue?.first?
        .objectValue?["key"]) == (.string("SECRET_CLI_TOKEN")))
    #expect(
      (payload.objectValue?["mcp"]?.arrayValue?.first?.objectValue?["env"]?.arrayValue?.first?
        .objectValue?["value_origin"]) == (.string("configured_provider_env")))
  }

  @Test
  func testFileListReturnsBoundedDirectoryEntries() throws {
    let directory = try temporaryDirectory()
    try "alpha".write(
      to: directory.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
    try "hidden".write(
      to: directory.appendingPathComponent(".hidden.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("notes"),
      withIntermediateDirectories: true
    )
    try "nested".write(
      to: directory.appendingPathComponent("notes/nested.txt"), atomically: true, encoding: .utf8)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.list"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.list",
      arguments: .object(["path": .string(".")])
    )
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect((payload.objectValue?["workspace_relative_path"]) == (.string(".")))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect(
      (entries.map { $0.objectValue?["workspace_relative_path"] })
        == ([.string("alpha.txt"), .string("notes")]))

    let emptyPathResult = try registry.callTool(
      name: "file.list",
      arguments: .object(["path": .string("")])
    )
    let emptyPathPayload = try decodeTextPayload(emptyPathResult)
    #expect((emptyPathPayload.objectValue?["workspace_relative_path"]) == (.string(".")))
    #expect((emptyPathPayload.objectValue?["entries"]) == (payload.objectValue?["entries"]))

    let recursiveResult = try registry.callTool(
      name: "file.list",
      arguments: .object([
        "path": .string("."),
        "include_hidden": .bool(true),
        "recursive_depth": .number(1),
        "max_entries": .number(2),
      ])
    )
    let recursivePayload = try decodeTextPayload(recursiveResult)

    #expect((recursivePayload.objectValue?["entry_count"]) == (.number(2)))
    #expect((recursivePayload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testFileTreeReturnsBoundedHierarchy() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("Sources/App"),
      withIntermediateDirectories: true
    )
    try "main".write(
      to: directory.appendingPathComponent("Sources/App/main.swift"),
      atomically: true,
      encoding: .utf8
    )
    try "readme".write(
      to: directory.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    try "hidden".write(
      to: directory.appendingPathComponent(".hidden"),
      atomically: true,
      encoding: .utf8
    )

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.tree"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.tree",
      arguments: .object([
        "path": .string("."),
        "max_depth": .number(2),
        "max_entries": .number(10),
      ])
    )
    let payload = try decodeTextPayload(result)
    let tree = try #require(payload.objectValue?["tree"]?.objectValue)
    let children = try #require(tree["children"]?.arrayValue)

    #expect((payload.objectValue?["workspace_relative_path"]) == (.string(".")))
    #expect((payload.objectValue?["entry_count"]) == (.number(4)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect(
      (children.map { $0.objectValue?["workspace_relative_path"] })
        == ([.string("README.md"), .string("Sources")]))

    let sources = try #require(children[1].objectValue?["children"]?.arrayValue)
    #expect((sources.first?.objectValue?["workspace_relative_path"]) == (.string("Sources/App")))
  }

  @Test
  func testFileTreeCanReturnDirectoriesOnlyAndTruncate() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("a/b"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("c"),
      withIntermediateDirectories: true
    )
    try "file".write(
      to: directory.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.tree"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.tree",
      arguments: .object([
        "path": .string("."),
        "directories_only": .bool(true),
        "max_depth": .number(2),
        "max_entries": .number(2),
      ])
    )
    let payload = try decodeTextPayload(result)
    let tree = try #require(payload.objectValue?["tree"]?.objectValue)
    let children = try #require(tree["children"]?.arrayValue)

    #expect((payload.objectValue?["directories_only"]) == (.bool(true)))
    #expect((payload.objectValue?["entry_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((children.map { $0.objectValue?["type"] }) == ([.string("directory")]))
  }

  @Test
  func testFileTreeRejectsWorkspaceEscapeAndNonDirectory() throws {
    let directory = try temporaryDirectory()
    try "file".write(
      to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.tree"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.tree",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.tree",
        arguments: .object(["path": .string("file.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not a directory"))
    }
  }

  @Test
  func testFileStatReturnsMetadataWithoutReadingContent() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("Package.swift")
    try "swift".write(to: file, atomically: true, encoding: .utf8)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.stat"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.stat",
      arguments: .object(["path": .string("Package.swift")])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("Package.swift")))
    #expect((payload.objectValue?["type"]) == (.string("file")))
    #expect((payload.objectValue?["size_bytes"]) == (.number(5)))
    #expect((payload.objectValue?["is_readable"]) == (.bool(true)))
    #expect((payload.objectValue?["content"]) == nil)
  }

  @Test
  func testFilePermissionsReturnsPOSIXModeOwnerAndFlags() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("script.sh")
    try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o754],
      ofItemAtPath: file.path
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.permissions"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.permissions",
      arguments: .object(["path": .string("script.sh")])
    )
    let payload = try decodeTextPayload(result)
    let permissions = try #require(payload.objectValue?["permissions"]?.objectValue)
    let user = try #require(permissions["user"]?.objectValue)
    let group = try #require(permissions["group"]?.objectValue)
    let other = try #require(permissions["other"]?.objectValue)
    let access = try #require(payload.objectValue?["current_process_access"]?.objectValue)
    let flags = try #require(payload.objectValue?["flags"]?.objectValue)

    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("script.sh")))
    #expect((payload.objectValue?["type"]) == (.string("file")))
    #expect((payload.objectValue?["mode"]) == (.number(Double(0o754))))
    #expect((payload.objectValue?["mode_octal"]) == (.string("0754")))
    #expect((payload.objectValue?["owner_account_id"]) != nil)
    #expect((payload.objectValue?["group_owner_account_id"]) != nil)
    #expect((user["read"]) == (.bool(true)))
    #expect((user["write"]) == (.bool(true)))
    #expect((user["execute"]) == (.bool(true)))
    #expect((group["read"]) == (.bool(true)))
    #expect((group["write"]) == (.bool(false)))
    #expect((group["execute"]) == (.bool(true)))
    #expect((other["read"]) == (.bool(true)))
    #expect((other["write"]) == (.bool(false)))
    #expect((other["execute"]) == (.bool(false)))
    #expect((permissions["setuid"]) == (.bool(false)))
    #expect((permissions["setgid"]) == (.bool(false)))
    #expect((permissions["sticky"]) == (.bool(false)))
    #expect((access["readable"]) == (.bool(true)))
    #expect((access["executable"]) == (.bool(true)))
    #expect((flags["immutable"]) != nil)
    #expect((flags["append_only"]) != nil)
    #expect((flags["extension_hidden"]) != nil)
  }

  @Test
  func testFilePermissionsRejectsWorkspaceEscapeAndMissingPath() throws {
    let directory = try temporaryDirectory()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.permissions"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.permissions",
        arguments: .object(["path": .string("../outside")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.permissions",
        arguments: .object(["path": .string("missing.txt")])
      )
    ) { error in
      #expect(!(error.localizedDescription.isEmpty))
    }
  }

  @Test
  func testFileChmodSetsPOSIXModeWithExpectedCurrentMode() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("script.sh")
    try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: file.path
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.chmod"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.chmod",
      arguments: .object([
        "path": .string("script.sh"),
        "mode": .string("0755"),
        "expected_current_mode": .string("0644"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let mode = try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o7777

    #expect((payload.objectValue?["operation"]) == (.string("file.chmod")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("script.sh")))
    #expect((payload.objectValue?["mode_before_octal"]) == (.string("0644")))
    #expect((payload.objectValue?["mode_after_octal"]) == (.string("0755")))
    #expect((payload.objectValue?["result"]?.objectValue?["type"]) == (.string("file")))
    #expect((mode) == (0o755))

    expectThrows(
      try registry.callTool(
        name: "file.chmod",
        arguments: .object([
          "path": .string("script.sh"),
          "mode": .string("0644"),
          "expected_current_mode": .string("0600"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("expected_current_mode"))
    }
  }

  @Test
  func testFileChmodDryRunDoesNotChangeMode() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("script.sh")
    try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: file.path
    )
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.chmod"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.chmod",
      arguments: .object([
        "path": .string("script.sh"),
        "mode": .string("0755"),
        "expected_current_mode": .string("0644"),
        "dry_run": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let mode = try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o7777

    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["mode_before_octal"]) == (.string("0644")))
    #expect((payload.objectValue?["mode_after_octal"]) == (.string("0644")))
    #expect((payload.objectValue?["requested_mode_octal"]) == (.string("0755")))
    #expect((payload.objectValue?["would_mode_after_octal"]) == (.string("0755")))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect((mode) == (0o644))
  }

  @Test
  func testFileChmodRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("script.sh")
    try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.chmod"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.chmod",
        arguments: .object([
          "path": .string("script.sh"),
          "mode": .string("888"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("octal"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.chmod",
        arguments: .object([
          "path": .string("missing.sh"),
          "mode": .string("0644"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.chmod",
        arguments: .object([
          "path": .string("../outside.sh"),
          "mode": .string("0644"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }
  }

  @Test
  func testFileFindReturnsBoundedNameMatches() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("Sources"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent(".hidden"),
      withIntermediateDirectories: true
    )
    try "swift".write(
      to: directory.appendingPathComponent("Sources/App.swift"),
      atomically: true,
      encoding: .utf8
    )
    try "swift".write(
      to: directory.appendingPathComponent(".hidden/Hidden.swift"),
      atomically: true,
      encoding: .utf8
    )

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.find"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.find",
      arguments: .object([
        "query": .string(".swift"),
        "match": .string("suffix"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let results = try #require(payload.objectValue?["results"]?.arrayValue)

    #expect((payload.objectValue?["result_count"]) == (.number(1)))
    #expect(
      (results.map { $0.objectValue?["workspace_relative_path"] })
        == ([.string("Sources/App.swift")]))

    let hiddenResult = try registry.callTool(
      name: "file.find",
      arguments: .object([
        "query": .string("Hidden.swift"),
        "match": .string("exact"),
        "include_hidden": .bool(true),
      ])
    )
    let hiddenPayload = try decodeTextPayload(hiddenResult)

    #expect((hiddenPayload.objectValue?["result_count"]) == (.number(1)))
    #expect(
      (hiddenPayload.objectValue?["results"]?.arrayValue?.first?.objectValue?[
        "workspace_relative_path"]) == (.string(".hidden/Hidden.swift")))
  }

  @Test
  func testFileFindReportsTruncation() throws {
    let directory = try temporaryDirectory()
    for name in ["a.txt", "b.txt", "c.txt"] {
      try "match".write(
        to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.find"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.find",
      arguments: .object([
        "query": .string(".txt"),
        "match": .string("suffix"),
        "max_results": .number(1),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["result_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testFileSearchReturnsBoundedTextMatches() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("Sources"),
      withIntermediateDirectories: true
    )
    try "Hello Gateway\nhello again\n".write(
      to: directory.appendingPathComponent("Sources/App.swift"),
      atomically: true,
      encoding: .utf8
    )
    try "other".write(
      to: directory.appendingPathComponent("Notes.txt"), atomically: true, encoding: .utf8)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.search"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.search",
      arguments: .object([
        "query": .string("hello"),
        "max_matches": .number(1),
      ])
    )
    let payload = try decodeTextPayload(result)
    let match = try #require(payload.objectValue?["matches"]?.arrayValue?.first?.objectValue)

    #expect((payload.objectValue?["match_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((match["workspace_relative_path"]) == (.string("Sources/App.swift")))
    #expect((match["line"]) == (.number(1)))
    #expect((match["column"]) == (.number(1)))
    #expect((match["preview"]) == (.string("Hello Gateway")))
  }

  @Test
  func testFileSearchSkipsHiddenFilesUnlessEnabled() throws {
    let directory = try temporaryDirectory()
    try "needle".write(
      to: directory.appendingPathComponent(".secret.txt"), atomically: true, encoding: .utf8)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.search"]),
        workspaceDirectory: directory
      )
    )

    let hiddenDisabled = try registry.callTool(
      name: "file.search",
      arguments: .object(["query": .string("needle")])
    )
    let hiddenDisabledPayload = try decodeTextPayload(hiddenDisabled)
    #expect((hiddenDisabledPayload.objectValue?["match_count"]) == (.number(0)))

    let hiddenEnabled = try registry.callTool(
      name: "file.search",
      arguments: .object([
        "query": .string("needle"),
        "include_hidden": .bool(true),
      ])
    )
    let hiddenEnabledPayload = try decodeTextPayload(hiddenEnabled)
    #expect((hiddenEnabledPayload.objectValue?["match_count"]) == (.number(1)))
  }

  @Test
  func testFileTimelineFiltersSortsAndReturnsContexts() throws {
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

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.timeline"]),
        workspaceDirectory: directory
      )
    )

    let result = try registry.callTool(
      name: "file.timeline",
      arguments: .object([
        "modified_after": .string("1970-01-01T00:25:00Z"),
        "modified_before": .string("1970-01-01T00:41:40Z"),
      ])
    )
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let first = try #require(files.first?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("file.timeline")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string(".")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["sort"]) == (.string("modified_desc")))
    #expect((payload.objectValue?["matched_file_count"]) == (.number(1)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((first["workspace_relative_path"]) == (.string("nested/new.txt")))
    #expect((first["read_context"]?.objectValue) != nil)
    #expect((first["stat_context"]?.objectValue) != nil)

    let sortedResult = try registry.callTool(
      name: "file.timeline",
      arguments: .object([
        "include_hidden": .bool(true),
        "sort": .string("modified_asc"),
        "max_results": .number(2),
      ])
    )
    let sortedPayload = try decodeTextPayload(sortedResult)
    let sortedFiles = try #require(sortedPayload.objectValue?["files"]?.arrayValue)
    let paths = sortedFiles.compactMap { $0.objectValue?["workspace_relative_path"]?.stringValue }

    #expect((sortedPayload.objectValue?["matched_file_count"]) == (.number(3)))
    #expect((sortedPayload.objectValue?["returned_count"]) == (.number(2)))
    #expect((sortedPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((paths) == (["old.txt", "nested/new.txt"]))
  }

  @Test
  func testFileTimelineRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try "file".write(
      to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.timeline"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.timeline",
        arguments: .object([
          "path": .string("../outside")
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.timeline",
        arguments: .object([
          "path": .string("file.txt")
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a directory"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.timeline",
        arguments: .object([
          "sort": .string("recent")
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("sort"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.timeline",
        arguments: .object([
          "modified_after": .string("not-a-date")
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("ISO8601"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.timeline",
        arguments: .object([
          "modified_after": .string("1970-01-01T00:00:02Z"),
          "modified_before": .string("1970-01-01T00:00:01Z"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("modified_after"))
    }
  }

  @Test
  func testFileBuiltinRejectsWorkspaceEscape() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.read"]),
        workspaceDirectory: try temporaryDirectory()
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.read",
        arguments: .object(["path": .string("../outside.txt")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }
  }

  @Test
  func testSearchBuiltinsRejectWorkspaceEscape() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["file.find", "file.search"]),
        workspaceDirectory: try temporaryDirectory()
      )
    )

    expectThrows(
      try registry.callTool(
        name: "file.find",
        arguments: .object([
          "path": .string("../outside"),
          "query": .string("x"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "file.search",
        arguments: .object([
          "path": .string("../outside"),
          "query": .string("x"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }
  }

  @Test
  func testWorkspaceOpenUsesMacOSOpenForWorkspacePath() throws {
    let runner = FakeCommandRunner()
    let directory = try temporaryDirectory()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.open"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    _ = try registry.callTool(
      name: "workspace.open",
      arguments: .object(["path": .string(".")])
    )

    #expect((runner.calls.first?.executable) == ("/usr/bin/open"))
    #expect(
      (runner.calls.first?.arguments)
        == ([directory.standardizedFileURL.resolvingSymlinksInPath().path]))
  }

  @Test
  func testWorkspaceRevealUsesMacOSOpenRevealForWorkspacePath() throws {
    let runner = FakeCommandRunner()
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("note.txt")
    try "ready".write(to: file, atomically: true, encoding: .utf8)
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["workspace.reveal"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    _ = try registry.callTool(
      name: "workspace.reveal",
      arguments: .object(["path": .string("note.txt")])
    )

    #expect((runner.calls.first?.executable) == ("/usr/bin/open"))
    #expect((runner.calls.first?.arguments) == (["-R", file.path]))
  }

  @Test
  func testGitBuiltinsAreExposedOnlyWhenEnabled() throws {
    let disabled = GatewayToolRegistry(configuration: .fixture())
    #expect(!(try disabled.listTools().map(\.name).contains("git.status")))
    #expect(!(try disabled.listTools().map(\.name).contains("workspace.git_changes")))

    let enabled = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: [
          "workspace.git_changes",
          "git.root", "git.config", "git.remotes", "git.worktrees", "git.stashes", "git.stash_show",
          "git.tags",
          "git.tag_show", "git.tag_create", "git.tag_delete", "git.ignored", "git.submodules",
          "git.files", "git.grep", "git.blame", "git.file_history",
          "git.file_at_revision", "git.staged_file", "git.conflicts", "git.status",
          "git.tracking_status", "git.clean_preview", "git.clean", "git.reflog", "git.refs",
          "git.resolve_ref", "git.merge_base", "git.compare_refs", "git.is_ancestor", "git.diff",
          "git.diff_summary", "git.diff_check", "git.branch", "git.branch_create",
          "git.branch_delete", "git.branch_rename", "git.branch_switch", "git.log",
          "git.commit_files", "git.show",
          "git.add", "git.unstage", "git.restore_worktree", "git.commit", "git.stash_push",
        ])
      )
    )
    let names = try enabled.listTools().map(\.name)

    #expect(names.contains("workspace.git_changes"))
    #expect(names.contains("git.root"))
    #expect(names.contains("git.config"))
    #expect(names.contains("git.remotes"))
    #expect(names.contains("git.worktrees"))
    #expect(names.contains("git.stashes"))
    #expect(names.contains("git.stash_show"))
    #expect(names.contains("git.stash_push"))
    #expect(names.contains("git.tags"))
    #expect(names.contains("git.tag_show"))
    #expect(names.contains("git.tag_create"))
    #expect(names.contains("git.tag_delete"))
    #expect(names.contains("git.ignored"))
    #expect(names.contains("git.submodules"))
    #expect(names.contains("git.files"))
    #expect(names.contains("git.grep"))
    #expect(names.contains("git.blame"))
    #expect(names.contains("git.file_history"))
    #expect(names.contains("git.file_at_revision"))
    #expect(names.contains("git.staged_file"))
    #expect(names.contains("git.conflicts"))
    #expect(names.contains("git.status"))
    #expect(names.contains("git.tracking_status"))
    #expect(names.contains("git.clean_preview"))
    #expect(names.contains("git.clean"))
    #expect(names.contains("git.reflog"))
    #expect(names.contains("git.refs"))
    #expect(names.contains("git.resolve_ref"))
    #expect(names.contains("git.merge_base"))
    #expect(names.contains("git.compare_refs"))
    #expect(names.contains("git.is_ancestor"))
    #expect(names.contains("git.diff"))
    #expect(names.contains("git.diff_summary"))
    #expect(names.contains("git.diff_check"))
    #expect(names.contains("git.branch"))
    #expect(names.contains("git.branch_create"))
    #expect(names.contains("git.branch_delete"))
    #expect(names.contains("git.branch_rename"))
    #expect(names.contains("git.branch_switch"))
    #expect(names.contains("git.log"))
    #expect(names.contains("git.commit_files"))
    #expect(names.contains("git.show"))
    #expect(names.contains("git.add"))
    #expect(names.contains("git.unstage"))
    #expect(names.contains("git.restore_worktree"))
    #expect(names.contains("git.commit"))

    let gitAdd = try #require(enabled.listTools().first { $0.name == "git.add" })
    let gitUnstage = try #require(enabled.listTools().first { $0.name == "git.unstage" })
    let gitRestoreWorktree = try #require(
      enabled.listTools().first { $0.name == "git.restore_worktree" })
    let gitCommit = try #require(enabled.listTools().first { $0.name == "git.commit" })
    let gitClean = try #require(enabled.listTools().first { $0.name == "git.clean" })
    let gitStashShow = try #require(enabled.listTools().first { $0.name == "git.stash_show" })
    let gitStashPush = try #require(enabled.listTools().first { $0.name == "git.stash_push" })
    let gitTagShow = try #require(enabled.listTools().first { $0.name == "git.tag_show" })
    let gitTagCreate = try #require(enabled.listTools().first { $0.name == "git.tag_create" })
    let gitTagDelete = try #require(enabled.listTools().first { $0.name == "git.tag_delete" })
    let gitBranchCreate = try #require(
      enabled.listTools().first { $0.name == "git.branch_create" })
    let gitBranchDelete = try #require(
      enabled.listTools().first { $0.name == "git.branch_delete" })
    let gitBranchRename = try #require(
      enabled.listTools().first { $0.name == "git.branch_rename" })
    let gitBranchSwitch = try #require(
      enabled.listTools().first { $0.name == "git.branch_switch" })
    let gitConfig = try #require(enabled.listTools().first { $0.name == "git.config" })
    let addProperties = gitAdd.inputSchema.objectValue?["properties"]?.objectValue
    let unstageProperties = gitUnstage.inputSchema.objectValue?["properties"]?.objectValue
    let restoreWorktreeProperties =
      gitRestoreWorktree.inputSchema.objectValue?["properties"]?.objectValue
    let commitProperties = gitCommit.inputSchema.objectValue?["properties"]?.objectValue
    let cleanProperties = gitClean.inputSchema.objectValue?["properties"]?.objectValue
    let stashShowProperties = gitStashShow.inputSchema.objectValue?["properties"]?.objectValue
    let stashPushProperties = gitStashPush.inputSchema.objectValue?["properties"]?.objectValue
    let tagShowProperties = gitTagShow.inputSchema.objectValue?["properties"]?.objectValue
    let tagCreateProperties = gitTagCreate.inputSchema.objectValue?["properties"]?.objectValue
    let tagDeleteProperties = gitTagDelete.inputSchema.objectValue?["properties"]?.objectValue
    let branchCreateProperties =
      gitBranchCreate.inputSchema.objectValue?["properties"]?.objectValue
    let branchDeleteProperties =
      gitBranchDelete.inputSchema.objectValue?["properties"]?.objectValue
    let branchRenameProperties =
      gitBranchRename.inputSchema.objectValue?["properties"]?.objectValue
    let branchSwitchProperties =
      gitBranchSwitch.inputSchema.objectValue?["properties"]?.objectValue
    let configProperties = gitConfig.inputSchema.objectValue?["properties"]?.objectValue
    #expect((addProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((unstageProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((restoreWorktreeProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect(
      (restoreWorktreeProperties?["confirm_discard"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((commitProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((cleanProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((cleanProperties?["confirm_delete"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((cleanProperties?["all_paths"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((stashShowProperties?["stash"]?.objectValue?["type"]) == (.string("string")))
    #expect((stashShowProperties?["patch"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((stashPushProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((tagShowProperties?["name"]?.objectValue?["type"]) == (.string("string")))
    #expect((tagShowProperties?["stat"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((tagCreateProperties?["name"]?.objectValue?["type"]) == (.string("string")))
    #expect((tagCreateProperties?["target"]?.objectValue?["type"]) == (.string("string")))
    #expect((tagCreateProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((tagCreateProperties?["confirm_create"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((tagDeleteProperties?["name"]?.objectValue?["type"]) == (.string("string")))
    #expect((tagDeleteProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((tagDeleteProperties?["confirm_delete"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchCreateProperties?["name"]?.objectValue?["type"]) == (.string("string")))
    #expect((branchCreateProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect(
      (branchCreateProperties?["confirm_create"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchDeleteProperties?["name"]?.objectValue?["type"]) == (.string("string")))
    #expect((branchDeleteProperties?["force"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchDeleteProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect(
      (branchDeleteProperties?["confirm_delete"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchRenameProperties?["old_name"]?.objectValue?["type"]) == (.string("string")))
    #expect((branchRenameProperties?["new_name"]?.objectValue?["type"]) == (.string("string")))
    #expect((branchRenameProperties?["force"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchRenameProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect(
      (branchRenameProperties?["confirm_rename"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchSwitchProperties?["name"]?.objectValue?["type"]) == (.string("string")))
    #expect((branchSwitchProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect(
      (branchSwitchProperties?["confirm_switch"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchSwitchProperties?["allow_dirty"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((configProperties?["include_values"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((configProperties?["scope"]?.objectValue?["type"]) == (.string("string")))
  }

  @Test
  func testGitRootUsesRegisteredGitProvider() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.root"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(name: "git.root", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "rev-parse",
          "--show-toplevel",
          "--git-dir",
          "--git-common-dir",
          "--is-inside-work-tree",
          "--is-bare-repository",
          "--show-prefix",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.root")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("rev-parse"),
          .string("--show-toplevel"),
          .string("--git-dir"),
          .string("--git-common-dir"),
          .string("--is-inside-work-tree"),
          .string("--is-bare-repository"),
          .string("--show-prefix"),
        ])))
  }

  @Test
  func testGitConfigParsesStructuredEntriesAndRedactsValues() throws {
    let runner = FakeCommandRunner()
    runner.stdout =
      "system\0file:/etc/gitconfig\0core.autocrlf\ninput\0"
      + "global\0file:/Users/example/.gitconfig\0user.email\nuser@example.com\0"
      + "global\0file:/Users/example/.gitconfig\0credential.helper\nosxkeychain\0"
      + "local\0file:.git/config\0remote.origin.url\nhttps://github.com/example/repo.git\0"
      + "local\0file:.git/config\0http.extraheader\nAUTHORIZATION: bearer abc123\0"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.config"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.config",
      arguments: .object([
        "include_values": .bool(true),
        "max_results": .number(10),
        "timeout_ms": .number(1234),
      ])
    )
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)
    let entryObjects = entries.compactMap(\.objectValue)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["config", "--list", "--show-origin", "--show-scope", "--null"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((payload.objectValue?["operation"]) == (.string("git.config")))
    #expect((payload.objectValue?["entry_count"]) == (.number(5)))
    #expect((payload.objectValue?["returned_count"]) == (.number(5)))
    #expect((payload.objectValue?["redacted_count"]) == (.number(2)))
    #expect((payload.objectValue?["parse_incomplete"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (nil))

    let emailEntry = try #require(
      entryObjects.first { $0["key"] == .string("user.email") })
    #expect((emailEntry["scope"]) == (.string("global")))
    #expect((emailEntry["origin"]) == (.string("file:/Users/example/.gitconfig")))
    #expect((emailEntry["value"]) == (.string("user@example.com")))
    #expect((emailEntry["value_included"]) == (.bool(true)))
    #expect((emailEntry["value_redacted"]) == (.bool(false)))

    let credentialEntry = try #require(
      entryObjects.first { $0["key"] == .string("credential.helper") })
    #expect((credentialEntry["value"]) == (.null))
    #expect((credentialEntry["value_included"]) == (.bool(false)))
    #expect((credentialEntry["value_redacted"]) == (.bool(true)))

    let headerEntry = try #require(
      entryObjects.first { $0["key"] == .string("http.extraheader") })
    #expect((headerEntry["value"]) == (.null))
    #expect((headerEntry["value_redacted"]) == (.bool(true)))
  }

  @Test
  func testGitConfigFiltersScopeAndRejectsBadInputs() throws {
    let runner = FakeCommandRunner()
    runner.stdout =
      "system\0file:/etc/gitconfig\0core.autocrlf\ninput\0"
      + "global\0file:/Users/example/.gitconfig\0user.name\nExample\0"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.config"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.config",
      arguments: .object([
        "scope": .string("global"),
        "max_results": .number(1),
      ])
    )
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)
    let firstEntry = try #require(entries.first?.objectValue)

    #expect((payload.objectValue?["scope"]) == (.string("global")))
    #expect((payload.objectValue?["entry_count"]) == (.number(1)))
    #expect((firstEntry["key"]) == (.string("user.name")))
    #expect((firstEntry["value"]) == (.null))
    #expect((firstEntry["value_redacted"]) == (.bool(true)))

    expectThrows(
      try registry.callTool(
        name: "git.config",
        arguments: .object(["scope": .string("repo")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("scope"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.config",
        arguments: .object(["max_results": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }
  }

  @Test
  func testGitRemotesUsesRegisteredGitProvider() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.remotes"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(name: "git.remotes", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect((runner.calls.first?.arguments) == (["remote", "--verbose"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.remotes")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("remote"), .string("--verbose")])))
  }

  @Test
  func testGitWorktreesUsesRegisteredGitProvider() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.worktrees"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(name: "git.worktrees", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect((runner.calls.first?.arguments) == (["worktree", "list", "--porcelain"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.worktrees")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("worktree"), .string("list"), .string("--porcelain")])))
  }

  @Test
  func testGitStashesUsesRegisteredGitProvider() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.stashes"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(name: "git.stashes", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect((runner.calls.first?.arguments) == (["stash", "list", "--date=iso-strict"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.stashes")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("stash"), .string("list"), .string("--date=iso-strict")])))
  }

  @Test
  func testGitStashShowBuildsReadOnlyArgv() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.stash_show"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.stash_show",
      arguments: .object([
        "stash": .string("stash@{2}"),
        "stat": .bool(true),
        "patch": .bool(true),
        "context_lines": .number(1),
        "paths": .array([.string("Sources"), .string("README.md")]),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "diff", "--stat", "--patch", "-U1", "stash@{2}^1", "stash@{2}", "--", "Sources",
          "README.md",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.stash_show")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("diff"), .string("--stat"), .string("--patch"), .string("-U1"),
          .string("stash@{2}^1"), .string("stash@{2}"), .string("--"), .string("Sources"),
          .string("README.md"),
        ])))
  }

  @Test
  func testGitStashShowDefaultsToLatestStatAndNameOnlyFallback() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.stash_show"])
      ),
      commandRunner: runner
    )

    _ = try registry.callTool(name: "git.stash_show", arguments: .object([:]))
    _ = try registry.callTool(
      name: "git.stash_show",
      arguments: .object([
        "stat": .bool(false),
        "patch": .bool(false),
      ])
    )

    #expect((runner.calls[0].arguments) == (["stash", "show", "--stat", "stash@{0}"]))
    #expect((runner.calls[1].arguments) == (["stash", "show", "--name-only", "stash@{0}"]))
  }

  @Test
  func testGitStashPushBuildsWriteAndDryRunArgv() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      .init(stdout: "Sources/main.swift\0"),
      .init(stdout: "Saved working directory and index state"),
      .init(stdout: ""),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.stash_push"])
      ),
      commandRunner: runner
    )

    let writeResult = try registry.callTool(
      name: "git.stash_push",
      arguments: .object([
        "message": .string("save focused work"),
        "paths": .array([.string("Sources"), .string("README.md")]),
        "include_untracked": .bool(true),
        "keep_index": .bool(true),
      ])
    )
    let writePayload = try decodeTextPayload(writeResult)

    let dryRunResult = try registry.callTool(
      name: "git.stash_push",
      arguments: .object([
        "message": .string("preview all work"),
        "all_paths": .bool(true),
        "dry_run": .bool(true),
      ])
    )
    let dryRunPayload = try decodeTextPayload(dryRunResult)

    #expect((runner.calls[0].arguments) == (["ls-files", "-z", "--", "Sources", "README.md"]))
    #expect(
      (runner.calls[1].arguments)
        == ([
          "stash", "push", "-m", "save focused work", "--include-untracked", "--keep-index", "--",
          "Sources", "README.md",
        ]))
    #expect(
      (runner.calls[2].arguments) == (["status", "--porcelain=v1", "-z", "--untracked-files=no"]))
    #expect((writePayload.objectValue?["operation"]) == (.string("git.stash_push")))
    #expect((dryRunPayload.objectValue?["operation"]) == (.string("git.stash_push")))
    #expect((writePayload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((dryRunPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((dryRunPayload.objectValue?["all_paths"]) == (.bool(true)))
    #expect((writePayload.objectValue?["effective_keep_index"]) == (.bool(true)))
    #expect(
      (writePayload.objectValue?["keep_index_omitted_for_untracked_only_paths"]) == (.bool(false)))
  }

  @Test
  func testGitStashPushOmitsKeepIndexForExplicitUntrackedOnlyPaths() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      .init(stdout: ""),
      .init(stdout: "Saved working directory and index state"),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.stash_push"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.stash_push",
      arguments: .object([
        "message": .string("save untracked-only path"),
        "paths": .array([.string("untracked.txt")]),
        "include_untracked": .bool(true),
        "keep_index": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls[0].arguments) == (["ls-files", "-z", "--", "untracked.txt"]))
    #expect(
      (runner.calls[1].arguments)
        == ([
          "stash", "push", "-m", "save untracked-only path", "--include-untracked", "--",
          "untracked.txt",
        ]))
    #expect((payload.objectValue?["keep_index"]) == (.bool(true)))
    #expect((payload.objectValue?["effective_keep_index"]) == (.bool(false)))
    #expect((payload.objectValue?["keep_index_omitted_for_untracked_only_paths"]) == (.bool(true)))
  }

  @Test
  func testGitStashPushDryRunWithPathsIncludesUntrackedPreview() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.stash_push"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.stash_push",
      arguments: .object([
        "message": .string("preview focused work"),
        "paths": .array([.string("Sources")]),
        "include_untracked": .bool(true),
        "dry_run": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.first?.arguments)
        == (["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "Sources"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.stash_push")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["include_untracked"]) == (.bool(true)))
  }

  @Test
  func testGitTagsUsesRegisteredGitProvider() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tags"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(name: "git.tags", arguments: .object([:]))
    let payload = try decodeTextPayload(result)
    let format =
      "--format=%(refname:short)%09%(objecttype)%09%(objectname:short)%09%(creatordate:iso-strict)%09%(subject)"

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect((runner.calls.first?.arguments) == (["tag", "--list", "--sort=-creatordate", format]))
    #expect((payload.objectValue?["operation"]) == (.string("git.tags")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("tag"), .string("--list"), .string("--sort=-creatordate"), .string(format),
        ])))
  }

  @Test
  func testGitTagShowUsesLocalTagRef() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "tag v1.0.0\ncommit abc123\n", exitCode: 0),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_show"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.tag_show",
      arguments: .object([
        "name": .string("v1.0.0"),
        "timeout_ms": .number(1234),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["show-ref", "--verify", "--quiet", "refs/tags/v1.0.0"],
          ["show", "--date=iso-strict", "--stat", "refs/tags/v1.0.0"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.tag_show")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["name"]) == (.string("v1.0.0")))
    #expect((payload.objectValue?["ref"]) == (.string("refs/tags/v1.0.0")))
    #expect((payload.objectValue?["stat"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("show"), .string("--date=iso-strict"), .string("--stat"),
          .string("refs/tags/v1.0.0"),
        ])))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["stdout"])
        == (.string("tag v1.0.0\ncommit abc123\n")))
  }

  @Test
  func testGitTagShowCanOmitStat() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "commit abc123\n", exitCode: 0),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_show"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.tag_show",
      arguments: .object([
        "name": .string("v1.0.0"),
        "stat": .bool(false),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["show-ref", "--verify", "--quiet", "refs/tags/v1.0.0"],
          ["show", "--date=iso-strict", "--no-patch", "refs/tags/v1.0.0"],
        ]))
    #expect((payload.objectValue?["stat"]) == (.bool(false)))
  }

  @Test
  func testGitTagShowRejectsUnsafeInputs() throws {
    let unsafeRunner = FakeCommandRunner()
    let unsafeRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_show"])
      ),
      commandRunner: unsafeRunner
    )

    expectThrows(
      try unsafeRegistry.callTool(
        name: "git.tag_show",
        arguments: .object(["name": .string("refs/tags/v1.0.0")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(unsafeRunner.calls.isEmpty)
    }

    let missingTagRunner = FakeCommandRunner()
    missingTagRunner.outputs = [FakeCommandRunner.Output(stdout: "", exitCode: 1)]
    let missingTagRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_show"])
      ),
      commandRunner: missingTagRunner
    )

    expectThrows(
      try missingTagRegistry.callTool(
        name: "git.tag_show",
        arguments: .object(["name": .string("v1.0.0")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
      #expect((missingTagRunner.calls.count) == (1))
    }
  }

  @Test
  func testGitTagCreateDryRunPreflightsWithoutCreating() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "v1.0.0\n"),
      FakeCommandRunner.Output(stdout: String(repeating: "a", count: 40) + "\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_create"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.tag_create",
      arguments: .object([
        "name": .string("v1.0.0"),
        "timeout_ms": .number(1234),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "refs/tags/v1.0.0"],
          ["rev-parse", "--verify", "HEAD^{object}"],
          ["show-ref", "--verify", "--quiet", "refs/tags/v1.0.0"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.tag_create")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["name"]) == (.string("v1.0.0")))
    #expect((payload.objectValue?["target"]) == (.string("HEAD")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_create"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("tag"), .string("v1.0.0"), .string("HEAD")])))
  }

  @Test
  func testGitTagCreateRunsAfterConfirmation() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "v1.0.0\n"),
      FakeCommandRunner.Output(stdout: String(repeating: "b", count: 40) + "\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 1),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_create"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.tag_create",
      arguments: .object([
        "name": .string("v1.0.0"),
        "target": .string("main"),
        "dry_run": .bool(false),
        "confirm_create": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "refs/tags/v1.0.0"],
          ["rev-parse", "--verify", "main^{object}"],
          ["show-ref", "--verify", "--quiet", "refs/tags/v1.0.0"],
          ["tag", "v1.0.0", "main"],
        ]))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_create"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([.string("tag"), .string("v1.0.0"), .string("main")])))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testGitTagCreateRejectsUnsafeInputs() throws {
    let missingConfirmRunner = FakeCommandRunner()
    let missingConfirmRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_create"])
      ),
      commandRunner: missingConfirmRunner
    )

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.tag_create",
        arguments: .object([
          "name": .string("v1.0.0"),
          "dry_run": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_create"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.tag_create",
        arguments: .object(["name": .string("refs/tags/v1.0.0")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let existingTagRunner = FakeCommandRunner()
    existingTagRunner.outputs = [
      FakeCommandRunner.Output(stdout: "v1.0.0\n"),
      FakeCommandRunner.Output(stdout: String(repeating: "c", count: 40) + "\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
    ]
    let existingTagRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_create"])
      ),
      commandRunner: existingTagRunner
    )

    expectThrows(
      try existingTagRegistry.callTool(
        name: "git.tag_create",
        arguments: .object(["name": .string("v1.0.0")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("already exists"))
      #expect((existingTagRunner.calls.count) == (3))
    }

    let badTargetRunner = FakeCommandRunner()
    badTargetRunner.outputs = [
      FakeCommandRunner.Output(stdout: "v1.0.0\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let badTargetRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_create"])
      ),
      commandRunner: badTargetRunner
    )

    expectThrows(
      try badTargetRegistry.callTool(
        name: "git.tag_create",
        arguments: .object([
          "name": .string("v1.0.0"),
          "target": .string("missing-ref"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("target"))
      #expect((badTargetRunner.calls.count) == (2))
    }
  }

  @Test
  func testGitTagDeleteDryRunPreflightsWithoutDeleting() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: String(repeating: "d", count: 40) + "\n"),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_delete"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.tag_delete",
      arguments: .object([
        "name": .string("v1.0.0"),
        "timeout_ms": .number(1234),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["show-ref", "--verify", "--quiet", "refs/tags/v1.0.0"],
          ["rev-parse", "--verify", "refs/tags/v1.0.0^{object}"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.tag_delete")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["name"]) == (.string("v1.0.0")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_delete"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("tag"), .string("-d"), .string("v1.0.0")])))
  }

  @Test
  func testGitTagDeleteRunsAfterConfirmation() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: String(repeating: "e", count: 40) + "\n"),
      FakeCommandRunner.Output(stdout: "Deleted tag 'v1.0.0'\n", exitCode: 0),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_delete"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.tag_delete",
      arguments: .object([
        "name": .string("v1.0.0"),
        "dry_run": .bool(false),
        "confirm_delete": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["show-ref", "--verify", "--quiet", "refs/tags/v1.0.0"],
          ["rev-parse", "--verify", "refs/tags/v1.0.0^{object}"],
          ["tag", "-d", "v1.0.0"],
        ]))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_delete"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([.string("tag"), .string("-d"), .string("v1.0.0")])))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testGitTagDeleteRejectsUnsafeInputs() throws {
    let missingConfirmRunner = FakeCommandRunner()
    let missingConfirmRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_delete"])
      ),
      commandRunner: missingConfirmRunner
    )

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.tag_delete",
        arguments: .object([
          "name": .string("v1.0.0"),
          "dry_run": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_delete"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.tag_delete",
        arguments: .object(["name": .string("refs/tags/v1.0.0")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let missingTagRunner = FakeCommandRunner()
    missingTagRunner.outputs = [FakeCommandRunner.Output(stdout: "", exitCode: 1)]
    let missingTagRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_delete"])
      ),
      commandRunner: missingTagRunner
    )

    expectThrows(
      try missingTagRegistry.callTool(
        name: "git.tag_delete",
        arguments: .object(["name": .string("v1.0.0")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
      #expect((missingTagRunner.calls.count) == (1))
    }

    let unresolvedTagRunner = FakeCommandRunner()
    unresolvedTagRunner.outputs = [
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let unresolvedTagRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tag_delete"])
      ),
      commandRunner: unresolvedTagRunner
    )

    expectThrows(
      try unresolvedTagRegistry.callTool(
        name: "git.tag_delete",
        arguments: .object(["name": .string("v1.0.0")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("cannot be resolved"))
      #expect((unresolvedTagRunner.calls.count) == (2))
    }
  }

  @Test
  func testGitIgnoredUsesRegisteredGitProvider() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.ignored"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.ignored",
      arguments: .object(["paths": .array([.string("build/output.log"), .string(".env")])])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["check-ignore", "--verbose", "--", "build/output.log", ".env"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.ignored")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("check-ignore"), .string("--verbose"), .string("--"), .string("build/output.log"),
          .string(".env"),
        ])))
  }

  @Test
  func testGitSubmodulesUsesRegisteredGitProvider() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.submodules"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(name: "git.submodules", arguments: .object([:]))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect((runner.calls.first?.arguments) == (["submodule", "status", "--recursive"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.submodules")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("submodule"), .string("status"), .string("--recursive")])))
  }

  @Test
  func testGitFilesUsesRegisteredGitProvider() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.files"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.files",
      arguments: .object(["paths": .array([.string("Sources"), .string("Package.swift")])])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["ls-files", "--stage", "--eol", "--", "Sources", "Package.swift"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.files")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("ls-files"), .string("--stage"), .string("--eol"), .string("--"),
          .string("Sources"), .string("Package.swift"),
        ])))
  }

  @Test
  func testGitGrepParsesBoundedNullSeparatedMatches() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(
        stdout:
          "Sources/App.swift\010\0let needle = true\nTests/AppTests.swift\024\0#expect(needle)\n"
      )
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.grep"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.grep",
      arguments: .object([
        "query": .string("needle"),
        "paths": .array([.string("Sources"), .string("Tests")]),
        "case_sensitive": .bool(false),
        "max_results": .number(1),
      ])
    )
    let payload = try decodeTextPayload(result)
    let matches = try #require(payload.objectValue?["matches"]?.arrayValue)
    let first = try #require(matches.first?.objectValue)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "grep", "--line-number", "-I", "--null", "--fixed-strings", "--max-count", "1",
          "--ignore-case", "-e", "needle", "--", "Sources", "Tests",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.grep")))
    #expect((payload.objectValue?["case_sensitive"]) == (.bool(false)))
    #expect((payload.objectValue?["match_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["parse_incomplete"]) == (.bool(false)))
    #expect((first["workspace_relative_path"]) == (.string("Sources/App.swift")))
    #expect((first["line"]) == (.number(10)))
    #expect((first["text"]) == (.string("let needle = true")))
    #expect((first["read_context"]?.objectValue?["tool"]) == (.string("file.read_lines")))
    #expect((first["read_context"]?.objectValue?["path"]) == (.string("Sources/App.swift")))
  }

  @Test
  func testGitBlameUsesRegisteredGitProvider() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.blame"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.blame",
      arguments: .object([
        "path": .string("Sources/main.swift"),
        "start_line": .number(10),
        "max_lines": .number(25),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["blame", "--line-porcelain", "-L", "10,+25", "--", "Sources/main.swift"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.blame")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("blame"), .string("--line-porcelain"), .string("-L"), .string("10,+25"),
          .string("--"), .string("Sources/main.swift"),
        ])))
  }

  @Test
  func testGitFileHistoryParsesBoundedCommitRows() throws {
    let runner = FakeCommandRunner()
    runner.stdout =
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\taaaaaaa\t2026-07-08T17:16:39+08:00\tAda\tupdate file\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tbbbbbbb\t2026-07-08T17:15:00+08:00\tBen\tcreate file\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.file_history"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.file_history",
      arguments: .object([
        "path": .string("Sources/main.swift"),
        "limit": .number(10),
        "max_results": .number(1),
        "follow": .bool(true),
        "include_merges": .bool(false),
      ])
    )
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect(
      (runner.calls.first?.arguments)
        == ([
          "log",
          "--follow",
          "--date=iso-strict",
          "--pretty=format:%H%x09%h%x09%ad%x09%an%x09%s",
          "-n",
          "10",
          "--no-merges",
          "--",
          "Sources/main.swift",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.file_history")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("Sources/main.swift")))
    #expect((payload.objectValue?["follow"]) == (.bool(true)))
    #expect((payload.objectValue?["include_merges"]) == (.bool(false)))
    #expect((payload.objectValue?["entry_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_entry_count"]) == (.number(1)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((entries[0].objectValue?["commit"]) == (.string(String(repeating: "a", count: 40))))
    #expect((entries[0].objectValue?["abbreviated_commit"]) == (.string("aaaaaaa")))
    #expect((entries[0].objectValue?["committed_at"]) == (.string("2026-07-08T17:16:39+08:00")))
    #expect((entries[0].objectValue?["author"]) == (.string("Ada")))
    #expect((entries[0].objectValue?["subject"]) == (.string("update file")))
  }

  @Test
  func testGitFileAtRevisionReturnsBoundedHistoricalContent() throws {
    let runner = FakeCommandRunner()
    runner.stdout = "line one\nline two\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        policy: PolicyConfig(maxOutputBytes: 64),
        builtin: BuiltinConfig(enabled: ["git.file_at_revision"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.file_at_revision",
      arguments: .object([
        "revision": .string("HEAD"),
        "path": .string("Sources/main.swift"),
        "max_bytes": .number(8),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.arguments) == (["show", "HEAD:Sources/main.swift"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.file_at_revision")))
    #expect((payload.objectValue?["revision"]) == (.string("HEAD")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("Sources/main.swift")))
    #expect((payload.objectValue?["object_spec"]) == (.string("HEAD:Sources/main.swift")))
    #expect((payload.objectValue?["content"]) == (.string("line one")))
    #expect((payload.objectValue?["bytes_returned"]) == (.number(8)))
    #expect((payload.objectValue?["content_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testGitStagedFileReturnsBoundedIndexContent() throws {
    let runner = FakeCommandRunner()
    runner.stdout = "staged one\nstaged two\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        policy: PolicyConfig(maxOutputBytes: 64),
        builtin: BuiltinConfig(enabled: ["git.staged_file"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.staged_file",
      arguments: .object([
        "path": .string("Sources/main.swift"),
        "max_bytes": .number(10),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.arguments) == (["show", ":Sources/main.swift"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.staged_file")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("Sources/main.swift")))
    #expect((payload.objectValue?["object_spec"]) == (.string(":Sources/main.swift")))
    #expect((payload.objectValue?["source"]) == (.string("index")))
    #expect((payload.objectValue?["index_stage"]) == (.number(0)))
    #expect((payload.objectValue?["content"]) == (.string("staged one")))
    #expect((payload.objectValue?["bytes_returned"]) == (.number(10)))
    #expect((payload.objectValue?["content_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testGitConflictsUsesRegisteredGitProvider() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.conflicts"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.conflicts",
      arguments: .object(["paths": .array([.string("Sources"), .string("Package.swift")])])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["ls-files", "--unmerged", "--", "Sources", "Package.swift"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.conflicts")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("ls-files"), .string("--unmerged"), .string("--"),
          .string("Sources"), .string("Package.swift"),
        ])))
  }

  @Test
  func testGitStatusUsesRegisteredGitProvider() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.status"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.status",
      arguments: .object(["paths": .array([.string("Sources")])])
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["status", "--short", "--branch", "--porcelain=v1", "--", "Sources"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.status")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("status"), .string("--short"), .string("--branch"), .string("--porcelain=v1"),
          .string("--"), .string("Sources"),
        ])))
  }

  @Test
  func testGitTrackingStatusParsesBranchUpstreamStates() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "## main...origin/main [ahead 2, behind 1]\n M file.txt\n"),
      FakeCommandRunner.Output(stdout: "## HEAD (no branch)\n"),
      FakeCommandRunner.Output(stdout: "## No commits yet on trunk\n"),
      FakeCommandRunner.Output(stdout: "## topic...origin/topic [gone]\n"),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.tracking_status"])
      ),
      commandRunner: runner
    )

    let divergedResult = try registry.callTool(name: "git.tracking_status", arguments: .object([:]))
    let divergedPayload = try decodeTextPayload(divergedResult)
    let diverged = try #require(divergedPayload.objectValue?["status"]?.objectValue)

    let detachedResult = try registry.callTool(name: "git.tracking_status", arguments: .object([:]))
    let detachedPayload = try decodeTextPayload(detachedResult)
    let detached = try #require(detachedPayload.objectValue?["status"]?.objectValue)

    let unbornResult = try registry.callTool(name: "git.tracking_status", arguments: .object([:]))
    let unbornPayload = try decodeTextPayload(unbornResult)
    let unborn = try #require(unbornPayload.objectValue?["status"]?.objectValue)

    let goneResult = try registry.callTool(name: "git.tracking_status", arguments: .object([:]))
    let gonePayload = try decodeTextPayload(goneResult)
    let gone = try #require(gonePayload.objectValue?["status"]?.objectValue)

    #expect((runner.calls.first?.arguments) == (["status", "--branch", "--porcelain=v1"]))
    #expect((divergedPayload.objectValue?["operation"]) == (.string("git.tracking_status")))
    #expect((diverged["branch"]) == (.string("main")))
    #expect((diverged["upstream"]) == (.string("origin/main")))
    #expect((diverged["ahead"]) == (.number(2)))
    #expect((diverged["behind"]) == (.number(1)))
    #expect((diverged["state"]) == (.string("diverged")))
    #expect((detached["detached"]) == (.bool(true)))
    #expect((detached["state"]) == (.string("detached")))
    #expect((unborn["branch"]) == (.string("trunk")))
    #expect((unborn["unborn"]) == (.bool(true)))
    #expect((unborn["state"]) == (.string("unborn")))
    #expect((gone["state"]) == (.string("gone")))
    #expect((gone["flags"]) == (.array([.string("gone")])))
  }

  @Test
  func testGitCleanPreviewParsesDryRunOutput() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      Would remove build/
      Would remove scratch.txt
      Would skip repository vendor/nested/
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.clean_preview"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.clean_preview",
      arguments: .object([
        "include_ignored": .bool(true),
        "paths": .array([.string("Sources")]),
        "max_results": .number(10),
      ])
    )
    let payload = try decodeTextPayload(result)
    let items = try #require(payload.objectValue?["items"]?.arrayValue)

    #expect(
      (runner.calls.first?.arguments) == (["clean", "--dry-run", "-d", "-x", "--", "Sources"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.clean_preview")))
    #expect((payload.objectValue?["include_ignored"]) == (.bool(true)))
    #expect((payload.objectValue?["ignored_only"]) == (.bool(false)))
    #expect((payload.objectValue?["item_count"]) == (.number(3)))
    #expect((items[0].objectValue?["action"]) == (.string("remove")))
    #expect((items[0].objectValue?["workspace_relative_path"]) == (.string("build/")))
    #expect((items[0].objectValue?["directory"]) == (.bool(true)))
    #expect((items[1].objectValue?["workspace_relative_path"]) == (.string("scratch.txt")))
    #expect((items[2].objectValue?["action"]) == (.string("skip_repository")))
    #expect((items[2].objectValue?["workspace_relative_path"]) == (.string("vendor/nested/")))
  }

  @Test
  func testGitCleanBuildsDryRunAndWriteArgv() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.clean"])
      ),
      commandRunner: runner
    )

    let dryRunResult = try registry.callTool(
      name: "git.clean",
      arguments: .object([
        "paths": .array([.string("build"), .string("scratch.txt")]),
        "include_ignored": .bool(true),
      ])
    )
    let dryRunPayload = try decodeTextPayload(dryRunResult)

    let writeResult = try registry.callTool(
      name: "git.clean",
      arguments: .object([
        "all_paths": .bool(true),
        "ignored_only": .bool(true),
        "dry_run": .bool(false),
        "confirm_delete": .bool(true),
      ])
    )
    let writePayload = try decodeTextPayload(writeResult)

    #expect(
      (runner.calls[0].arguments)
        == (["clean", "--dry-run", "-d", "-x", "--", "build", "scratch.txt"]))
    #expect((runner.calls[1].arguments) == (["clean", "-f", "-d", "-X"]))
    #expect((dryRunPayload.objectValue?["operation"]) == (.string("git.clean")))
    #expect((dryRunPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((dryRunPayload.objectValue?["confirm_delete"]) == (.bool(false)))
    #expect((dryRunPayload.objectValue?["all_paths"]) == (.bool(false)))
    #expect((writePayload.objectValue?["operation"]) == (.string("git.clean")))
    #expect((writePayload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((writePayload.objectValue?["confirm_delete"]) == (.bool(true)))
    #expect((writePayload.objectValue?["all_paths"]) == (.bool(true)))
    #expect((writePayload.objectValue?["ignored_only"]) == (.bool(true)))
  }

  @Test
  func testGitReflogParsesBoundedLocalEntries() throws {
    let runner = FakeCommandRunner()
    runner.stdout =
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\taaaaaaa\tHEAD@{2026-07-08T17:16:39+08:00}\tcommit: second\t2026-07-08T17:16:39+08:00\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tbbbbbbb\tHEAD@{2026-07-08T17:15:00+08:00}\tcheckout: moving from main to topic\t2026-07-08T17:15:00+08:00\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.reflog"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.reflog",
      arguments: .object(["limit": .number(10), "max_results": .number(1)])
    )
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect(
      (runner.calls.first?.arguments)
        == ([
          "reflog",
          "show",
          "--date=iso-strict",
          "--pretty=format:%H%x09%h%x09%gd%x09%gs%x09%ad",
          "-n",
          "10",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.reflog")))
    #expect((payload.objectValue?["entry_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_entry_count"]) == (.number(1)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((entries[0].objectValue?["commit"]) == (.string(String(repeating: "a", count: 40))))
    #expect((entries[0].objectValue?["abbreviated_commit"]) == (.string("aaaaaaa")))
    #expect((entries[0].objectValue?["selector"]) == (.string("HEAD@{2026-07-08T17:16:39+08:00}")))
    #expect((entries[0].objectValue?["action"]) == (.string("commit")))
    #expect((entries[0].objectValue?["message"]) == (.string("second")))
    #expect((entries[0].objectValue?["committed_at"]) == (.string("2026-07-08T17:16:39+08:00")))
  }

  @Test
  func testGitRefsParsesLocalRemoteAndTagRefs() throws {
    let runner = FakeCommandRunner()
    runner.stdout =
      "refs/heads/main\tmain\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\taaaaaaa\tcommit\t2026-07-08T17:16:39+08:00\tInitial commit\nrefs/remotes/origin/topic\torigin/topic\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tbbbbbbb\tcommit\t2026-07-08T17:15:00+08:00\tTopic work\nrefs/tags/v1.0\tv1.0\tcccccccccccccccccccccccccccccccccccccccc\tccccccc\ttag\t2026-07-08T17:14:00+08:00\tRelease v1.0\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.refs"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.refs",
      arguments: .object([
        "include_tags": .bool(true),
        "limit": .number(20),
        "max_results": .number(2),
      ])
    )
    let payload = try decodeTextPayload(result)
    let refs = try #require(payload.objectValue?["refs"]?.arrayValue)

    #expect(
      (runner.calls.first?.arguments)
        == ([
          "for-each-ref",
          "--sort=-committerdate",
          "--count",
          "20",
          "--format=%(refname)%09%(refname:short)%09%(objectname)%09%(objectname:short)%09%(objecttype)%09%(committerdate:iso-strict)%09%(subject)",
          "refs/heads",
          "refs/remotes",
          "refs/tags",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.refs")))
    #expect((payload.objectValue?["include_branches"]) == (.bool(true)))
    #expect((payload.objectValue?["include_remotes"]) == (.bool(true)))
    #expect((payload.objectValue?["include_tags"]) == (.bool(true)))
    #expect((payload.objectValue?["ref_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_ref_count"]) == (.number(2)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((refs[0].objectValue?["kind"]) == (.string("local_branch")))
    #expect((refs[0].objectValue?["refname"]) == (.string("refs/heads/main")))
    #expect((refs[0].objectValue?["short_name"]) == (.string("main")))
    #expect((refs[0].objectValue?["object"]) == (.string(String(repeating: "a", count: 40))))
    #expect((refs[0].objectValue?["abbreviated_object"]) == (.string("aaaaaaa")))
    #expect((refs[0].objectValue?["object_type"]) == (.string("commit")))
    #expect((refs[0].objectValue?["committer_date"]) == (.string("2026-07-08T17:16:39+08:00")))
    #expect((refs[0].objectValue?["subject"]) == (.string("Initial commit")))
    #expect((refs[1].objectValue?["kind"]) == (.string("remote_branch")))
    #expect((refs[1].objectValue?["short_name"]) == (.string("origin/topic")))
  }

  @Test
  func testGitCompareRefsReturnsCountsMergeBaseAndLeftRightCommits() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "2\t3\n"),
      FakeCommandRunner.Output(stdout: "dddddddddddddddddddddddddddddddddddddddd\n"),
      FakeCommandRunner.Output(
        stdout:
          "<\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\taaaaaaa\t2026-07-08T17:16:39+08:00\tAda\tbase only\n>\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tbbbbbbb\t2026-07-08T17:15:00+08:00\tBen\thead only\n"
      ),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.compare_refs"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.compare_refs",
      arguments: .object([
        "base": .string("main"),
        "head": .string("origin/topic"),
        "limit": .number(10),
        "max_results": .number(1),
        "cherry_pick": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)
    let commits = try #require(payload.objectValue?["commits"]?.arrayValue)

    #expect(
      (runner.calls[0].arguments)
        == (["rev-list", "--left-right", "--count", "--cherry-pick", "main...origin/topic"]))
    #expect((runner.calls[1].arguments) == (["merge-base", "main", "origin/topic"]))
    #expect(
      (runner.calls[2].arguments)
        == ([
          "log",
          "--left-right",
          "--cherry-pick",
          "--date=iso-strict",
          "--pretty=format:%m%x09%H%x09%h%x09%ad%x09%an%x09%s",
          "-n",
          "10",
          "main...origin/topic",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.compare_refs")))
    #expect((payload.objectValue?["base"]) == (.string("main")))
    #expect((payload.objectValue?["head"]) == (.string("origin/topic")))
    #expect((payload.objectValue?["range"]) == (.string("main...origin/topic")))
    #expect((payload.objectValue?["base_only_count"]) == (.number(2)))
    #expect((payload.objectValue?["head_only_count"]) == (.number(3)))
    #expect((payload.objectValue?["head_ahead"]) == (.number(3)))
    #expect((payload.objectValue?["head_behind"]) == (.number(2)))
    #expect((payload.objectValue?["merge_base"]) == (.string(String(repeating: "d", count: 40))))
    #expect((payload.objectValue?["commit_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_commit_count"]) == (.number(1)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((commits[0].objectValue?["side"]) == (.string("<")))
    #expect((commits[0].objectValue?["ref_side"]) == (.string("base")))
    #expect((commits[0].objectValue?["commit"]) == (.string(String(repeating: "a", count: 40))))
    #expect((commits[0].objectValue?["abbreviated_commit"]) == (.string("aaaaaaa")))
    #expect((commits[0].objectValue?["author"]) == (.string("Ada")))
    #expect((commits[0].objectValue?["subject"]) == (.string("base only")))
  }

  @Test
  func testGitResolveRefReturnsObjectAndType() throws {
    let objectID = String(repeating: "a", count: 40)
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "\(objectID)\n", exitCode: 0),
      FakeCommandRunner.Output(stdout: "commit\n", exitCode: 0),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.resolve_ref"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.resolve_ref",
      arguments: .object([
        "ref": .string("HEAD"),
        "timeout_ms": .number(1234),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["rev-parse", "--verify", "HEAD^{object}"],
          ["cat-file", "-t", objectID],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.resolve_ref")))
    #expect((payload.objectValue?["ref"]) == (.string("HEAD")))
    #expect((payload.objectValue?["object_spec"]) == (.string("HEAD^{object}")))
    #expect((payload.objectValue?["object"]) == (.string(objectID)))
    #expect((payload.objectValue?["object_type"]) == (.string("commit")))
    #expect(
      (payload.objectValue?["argv"]?.objectValue?["resolve"])
        == (.array([.string("rev-parse"), .string("--verify"), .string("HEAD^{object}")])))
    #expect(
      (payload.objectValue?["argv"]?.objectValue?["type"])
        == (.array([.string("cat-file"), .string("-t"), .string(objectID)])))
  }

  @Test
  func testGitResolveRefRejectsInvalidRefsAndCommandFailures() throws {
    let invalidRunner = FakeCommandRunner()
    let invalidRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.resolve_ref"])
      ),
      commandRunner: invalidRunner
    )

    expectThrows(
      try invalidRegistry.callTool(
        name: "git.resolve_ref",
        arguments: .object(["ref": .string("-bad")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("ref"))
      #expect(invalidRunner.calls.isEmpty)
    }

    let revParseFailureRunner = FakeCommandRunner()
    revParseFailureRunner.outputs = [
      FakeCommandRunner.Output(stdout: "", stderr: "fatal: bad object\n", exitCode: 128)
    ]
    let revParseFailureRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.resolve_ref"])
      ),
      commandRunner: revParseFailureRunner
    )

    expectThrows(
      try revParseFailureRegistry.callTool(
        name: "git.resolve_ref",
        arguments: .object(["ref": .string("missing")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("failed"))
      #expect((revParseFailureRunner.calls.count) == (1))
    }

    let typeFailureRunner = FakeCommandRunner()
    typeFailureRunner.outputs = [
      FakeCommandRunner.Output(stdout: String(repeating: "a", count: 40) + "\n", exitCode: 0),
      FakeCommandRunner.Output(stdout: "", stderr: "fatal: missing object\n", exitCode: 128),
    ]
    let typeFailureRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.resolve_ref"])
      ),
      commandRunner: typeFailureRunner
    )

    expectThrows(
      try typeFailureRegistry.callTool(
        name: "git.resolve_ref",
        arguments: .object(["ref": .string("HEAD")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("object type"))
      #expect((typeFailureRunner.calls.count) == (2))
    }
  }

  @Test
  func testGitMergeBaseReturnsMergeBasesAndNoMergeBase() throws {
    let firstBase = String(repeating: "a", count: 40)
    let secondBase = String(repeating: "b", count: 40)
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "\(firstBase)\n\(secondBase)\n", exitCode: 0),
      FakeCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.merge_base"])
      ),
      commandRunner: runner
    )

    let mergeBaseResult = try registry.callTool(
      name: "git.merge_base",
      arguments: .object([
        "refs": .array([.string("main"), .string("topic")]),
        "all": .bool(true),
        "timeout_ms": .number(1234),
      ])
    )
    let noBaseResult = try registry.callTool(
      name: "git.merge_base",
      arguments: .object([
        "refs": .array([.string("unrelated-a"), .string("unrelated-b")])
      ])
    )
    let mergeBasePayload = try decodeTextPayload(mergeBaseResult)
    let noBasePayload = try decodeTextPayload(noBaseResult)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["merge-base", "--all", "main", "topic"],
          ["merge-base", "unrelated-a", "unrelated-b"],
        ]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((mergeBasePayload.objectValue?["operation"]) == (.string("git.merge_base")))
    #expect(
      (mergeBasePayload.objectValue?["refs"]) == (.array([.string("main"), .string("topic")])))
    #expect((mergeBasePayload.objectValue?["all"]) == (.bool(true)))
    #expect((mergeBasePayload.objectValue?["merge_base"]) == (.string(firstBase)))
    #expect(
      (mergeBasePayload.objectValue?["merge_bases"])
        == (.array([.string(firstBase), .string(secondBase)])))
    #expect((mergeBasePayload.objectValue?["merge_base_count"]) == (.number(2)))
    #expect((mergeBasePayload.objectValue?["has_merge_base"]) == (.bool(true)))
    #expect((noBasePayload.objectValue?["merge_bases"]) == (.array([])))
    #expect((noBasePayload.objectValue?["merge_base"]) == (.null))
    #expect((noBasePayload.objectValue?["merge_base_count"]) == (.number(0)))
    #expect((noBasePayload.objectValue?["has_merge_base"]) == (.bool(false)))
    #expect((noBasePayload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(1)))
  }

  @Test
  func testGitMergeBaseRejectsInvalidRefsAndCommandFailures() throws {
    let invalidRunner = FakeCommandRunner()
    let invalidRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.merge_base"])
      ),
      commandRunner: invalidRunner
    )

    expectThrows(
      try invalidRegistry.callTool(
        name: "git.merge_base",
        arguments: .object(["refs": .array([.string("main")])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("at least 2"))
      #expect(invalidRunner.calls.isEmpty)
    }

    expectThrows(
      try invalidRegistry.callTool(
        name: "git.merge_base",
        arguments: .object(["refs": .array([.string("main"), .string("-bad")])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("refs[1]"))
      #expect(invalidRunner.calls.isEmpty)
    }

    let failureRunner = FakeCommandRunner()
    failureRunner.outputs = [
      FakeCommandRunner.Output(stdout: "", stderr: "fatal: bad object\n", exitCode: 128)
    ]
    let failureRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.merge_base"])
      ),
      commandRunner: failureRunner
    )

    expectThrows(
      try failureRegistry.callTool(
        name: "git.merge_base",
        arguments: .object(["refs": .array([.string("missing"), .string("main")])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("failed"))
      #expect((failureRunner.calls.count) == (1))
    }
  }

  @Test
  func testGitIsAncestorMapsExitCodeToBoolean() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.is_ancestor"])
      ),
      commandRunner: runner
    )

    let trueResult = try registry.callTool(
      name: "git.is_ancestor",
      arguments: .object([
        "ancestor": .string("main"),
        "descendant": .string("origin/main"),
        "timeout_ms": .number(1234),
      ])
    )
    let falseResult = try registry.callTool(
      name: "git.is_ancestor",
      arguments: .object([
        "ancestor": .string("feature"),
        "descendant": .string("main"),
      ])
    )
    let truePayload = try decodeTextPayload(trueResult)
    let falsePayload = try decodeTextPayload(falseResult)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["merge-base", "--is-ancestor", "main", "origin/main"],
          ["merge-base", "--is-ancestor", "feature", "main"],
        ]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((truePayload.objectValue?["operation"]) == (.string("git.is_ancestor")))
    #expect((truePayload.objectValue?["ancestor"]) == (.string("main")))
    #expect((truePayload.objectValue?["descendant"]) == (.string("origin/main")))
    #expect((truePayload.objectValue?["is_ancestor"]) == (.bool(true)))
    #expect(
      (truePayload.objectValue?["argv"])
        == (.array([
          .string("merge-base"), .string("--is-ancestor"), .string("main"),
          .string("origin/main"),
        ])))
    #expect((falsePayload.objectValue?["is_ancestor"]) == (.bool(false)))
    #expect((falsePayload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(1)))
  }

  @Test
  func testGitIsAncestorRejectsInvalidRefsAndCommandFailures() throws {
    let invalidRunner = FakeCommandRunner()
    let invalidRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.is_ancestor"])
      ),
      commandRunner: invalidRunner
    )

    expectThrows(
      try invalidRegistry.callTool(
        name: "git.is_ancestor",
        arguments: .object([
          "ancestor": .string("-bad"),
          "descendant": .string("main"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("ancestor"))
      #expect(invalidRunner.calls.isEmpty)
    }

    let failureRunner = FakeCommandRunner()
    failureRunner.outputs = [
      FakeCommandRunner.Output(stdout: "", stderr: "fatal: bad object\n", exitCode: 128)
    ]
    let failureRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.is_ancestor"])
      ),
      commandRunner: failureRunner
    )

    expectThrows(
      try failureRegistry.callTool(
        name: "git.is_ancestor",
        arguments: .object([
          "ancestor": .string("missing"),
          "descendant": .string("main"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("failed"))
      #expect((failureRunner.calls.count) == (1))
    }
  }

  @Test
  func testGitDiffBuildsReadOnlyArgv() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.diff"])
      ),
      commandRunner: runner
    )

    _ = try registry.callTool(
      name: "git.diff",
      arguments: .object([
        "staged": .bool(true),
        "stat": .bool(true),
        "context_lines": .number(3),
        "paths": .array([.string("README.md")]),
      ])
    )

    #expect(
      (runner.calls.first?.arguments)
        == (["diff", "--no-ext-diff", "--cached", "--stat", "-U3", "--", "README.md"]))
  }

  @Test
  func testGitDiffSummaryParsesNumstatAndSummaryOutput() throws {
    let runner = FakeCommandRunner()
    let nul = "\u{0}"
    let numstatOutput =
      "2\t1\tSources/App.swift\(nul)-\t-\tAssets/logo.png\(nul)1\t0\t\(nul)Old.swift\(nul)New.swift\(nul)"
    runner.outputs = [
      FakeCommandRunner.Output(
        stdout: numstatOutput
      ),
      FakeCommandRunner.Output(
        stdout:
          " create mode 100644 Assets/logo.png\n rename Old.swift => New.swift (86%)\n mode change 100644 => 100755 Scripts/build.sh\n"
      ),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.diff_summary"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.diff_summary",
      arguments: .object([
        "staged": .bool(true),
        "paths": .array([.string("Sources")]),
        "max_results": .number(10),
      ])
    )
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let summary = try #require(payload.objectValue?["summary"]?.arrayValue)

    #expect(
      (runner.calls[0].arguments)
        == (["diff", "--no-ext-diff", "--no-color", "--cached", "--numstat", "-z", "--", "Sources"])
    )
    #expect(
      (runner.calls[1].arguments)
        == (["diff", "--no-ext-diff", "--no-color", "--cached", "--summary", "--", "Sources"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.diff_summary")))
    #expect((payload.objectValue?["file_count"]) == (.number(3)))
    #expect((payload.objectValue?["total_additions"]) == (.number(3)))
    #expect((payload.objectValue?["total_deletions"]) == (.number(1)))
    #expect((payload.objectValue?["binary_file_count"]) == (.number(1)))
    #expect((files[0].objectValue?["workspace_relative_path"]) == (.string("Sources/App.swift")))
    #expect((files[0].objectValue?["additions"]) == (.number(2)))
    #expect((files[1].objectValue?["binary"]) == (.bool(true)))
    #expect((files[2].objectValue?["old_path"]) == (.string("Old.swift")))
    #expect((files[2].objectValue?["workspace_relative_path"]) == (.string("New.swift")))
    #expect((summary[0].objectValue?["kind"]) == (.string("create")))
    #expect((summary[0].objectValue?["mode"]) == (.string("100644")))
    #expect((summary[1].objectValue?["kind"]) == (.string("rename")))
    #expect((summary[1].objectValue?["similarity"]) == (.number(86)))
    #expect((summary[2].objectValue?["kind"]) == (.string("mode_change")))
    #expect((summary[2].objectValue?["old_mode"]) == (.string("100644")))
    #expect((summary[2].objectValue?["new_mode"]) == (.string("100755")))
    #expect(
      (payload.objectValue?["results"]?.objectValue?["numstat"]?.objectValue?["stdout_bytes"])
        == (.number(Double(numstatOutput.utf8.count))))
  }

  @Test
  func testGitDiffCheckParsesWhitespaceAndConflictMarkerIssues() throws {
    let runner = FakeCommandRunner()
    runner.stdout = """
      Sources/App.swift:10: trailing whitespace.
      +let value = 1\u{20}\u{20}
      Sources/App.swift:11: leftover conflict marker
      """
    runner.exitCode = 2
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.diff_check"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.diff_check",
      arguments: .object([
        "staged": .bool(true),
        "paths": .array([.string("Sources")]),
      ])
    )
    let payload = try decodeTextPayload(result)
    let issues = try #require(payload.objectValue?["issues"]?.arrayValue)
    let rawLines = try #require(payload.objectValue?["raw_lines"]?.arrayValue)

    #expect(
      (runner.calls.first?.arguments)
        == (["diff", "--no-ext-diff", "--no-color", "--check", "--cached", "--", "Sources"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.diff_check")))
    #expect((payload.objectValue?["passed"]) == (.bool(false)))
    #expect((payload.objectValue?["issue_count"]) == (.number(2)))
    #expect((issues[0].objectValue?["workspace_relative_path"]) == (.string("Sources/App.swift")))
    #expect((issues[0].objectValue?["line"]) == (.number(10)))
    #expect((issues[0].objectValue?["message"]) == (.string("trailing whitespace.")))
    #expect((issues[1].objectValue?["message"]) == (.string("leftover conflict marker")))
    #expect((rawLines[1]) == (.string("+let value = 1  ")))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(2)))
  }

  @Test
  func testGitCommitFilesParsesBoundedNameStatusRows() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(
        stdout:
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\taaaaaaa\t2026-07-08T18:30:00+08:00\tAda\tupdate files\n"
      ),
      FakeCommandRunner.Output(
        stdout: "M\0Sources/App.swift\0R100\0Sources/Old.swift\0Sources/New.swift\0"
      ),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.commit_files"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.commit_files",
      arguments: .object([
        "revision": .string("HEAD"),
        "max_results": .number(1),
      ])
    )
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let rawRecords = try #require(payload.objectValue?["raw_records"]?.arrayValue)

    #expect(
      (runner.calls[0].arguments)
        == ([
          "show",
          "-s",
          "--date=iso-strict",
          "--format=%H%x09%h%x09%ad%x09%an%x09%s",
          "HEAD",
        ]))
    #expect(
      (runner.calls[1].arguments)
        == (["diff-tree", "--root", "--no-commit-id", "--name-status", "-M", "-r", "-z", "HEAD"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.commit_files")))
    #expect((payload.objectValue?["commit_hash"]) == (.string(String(repeating: "a", count: 40))))
    #expect((payload.objectValue?["abbreviated_commit"]) == (.string("aaaaaaa")))
    #expect((payload.objectValue?["committed_at"]) == (.string("2026-07-08T18:30:00+08:00")))
    #expect((payload.objectValue?["author"]) == (.string("Ada")))
    #expect((payload.objectValue?["subject"]) == (.string("update files")))
    #expect((payload.objectValue?["file_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_file_count"]) == (.number(1)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((files[0].objectValue?["status"]) == (.string("M")))
    #expect((files[0].objectValue?["kind"]) == (.string("modified")))
    #expect((files[0].objectValue?["workspace_relative_path"]) == (.string("Sources/App.swift")))
    #expect((rawRecords[0]) == (.string("M\tSources/App.swift")))
  }

  @Test
  func testGitBranchLogAndShowBuildExpectedArgv() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch", "git.log", "git.show"])
      ),
      commandRunner: runner
    )

    _ = try registry.callTool(
      name: "git.branch",
      arguments: .object(["all": .bool(true), "verbose": .bool(true)])
    )
    _ = try registry.callTool(
      name: "git.log",
      arguments: .object([
        "limit": .number(5),
        "paths": .array([.string("Sources")]),
      ])
    )
    _ = try registry.callTool(
      name: "git.show",
      arguments: .object([
        "revision": .string("HEAD~1"),
        "patch": .bool(true),
        "context_lines": .number(1),
        "paths": .array([.string("Package.swift")]),
      ])
    )

    #expect((runner.calls[0].arguments) == (["branch", "--all", "--verbose"]))
    #expect(
      (runner.calls[1].arguments)
        == ([
          "log",
          "--date=iso-strict",
          "--pretty=format:%H%x09%h%x09%ad%x09%an%x09%s",
          "-n",
          "5",
          "--",
          "Sources",
        ]))
    #expect(
      (runner.calls[2].arguments)
        == (["show", "--date=iso-strict", "-U1", "HEAD~1", "--", "Package.swift"]))

    _ = try registry.callTool(
      name: "git.show",
      arguments: .object([
        "revision": .string("HEAD"),
        "stat": .bool(true),
      ])
    )

    #expect((runner.calls[3].arguments) == (["show", "--date=iso-strict", "--stat", "HEAD"]))
  }

  @Test
  func testGitBranchCreateDryRunPreflightsWithoutCreating() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/test\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 1),
      FakeCommandRunner.Output(stdout: String(repeating: "a", count: 40) + "\n"),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_create"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.branch_create",
      arguments: .object([
        "name": .string("feature/test"),
        "timeout_ms": .number(1234),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/test"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/test"],
          ["rev-parse", "--verify", "HEAD^{commit}"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.branch_create")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["name"]) == (.string("feature/test")))
    #expect((payload.objectValue?["start_point"]) == (.string("HEAD")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_create"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("branch"), .string("feature/test"), .string("HEAD")])))
    #expect(
      (payload.objectValue?["preflight"]?.objectValue?["existing_branch"]?.objectValue?[
        "exit_code"]) == (.number(1)))
  }

  @Test
  func testGitBranchCreateRunsAfterConfirmation() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/new\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 1),
      FakeCommandRunner.Output(stdout: String(repeating: "b", count: 40) + "\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_create"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.branch_create",
      arguments: .object([
        "name": .string("feature/new"),
        "start_point": .string("main"),
        "dry_run": .bool(false),
        "confirm_create": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/new"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/new"],
          ["rev-parse", "--verify", "main^{commit}"],
          ["branch", "feature/new", "main"],
        ]))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_create"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([.string("branch"), .string("feature/new"), .string("main")])))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testGitBranchDeleteDryRunPreflightsWithoutDeleting() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/old\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "main\n"),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_delete"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.branch_delete",
      arguments: .object([
        "name": .string("feature/old"),
        "timeout_ms": .number(1234),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/old"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/old"],
          ["branch", "--show-current"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.branch_delete")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["name"]) == (.string("feature/old")))
    #expect((payload.objectValue?["force"]) == (.bool(false)))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_delete"]) == (.bool(false)))
    #expect((payload.objectValue?["current_branch"]) == (.string("main")))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("branch"), .string("-d"), .string("feature/old")])))
  }

  @Test
  func testGitBranchDeleteRunsAfterConfirmation() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/delete\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "main\n"),
      FakeCommandRunner.Output(stdout: "Deleted branch feature/delete.\n", exitCode: 0),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_delete"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.branch_delete",
      arguments: .object([
        "name": .string("feature/delete"),
        "force": .bool(true),
        "dry_run": .bool(false),
        "confirm_delete": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/delete"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/delete"],
          ["branch", "--show-current"],
          ["branch", "-D", "feature/delete"],
        ]))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_delete"]) == (.bool(true)))
    #expect((payload.objectValue?["force"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([.string("branch"), .string("-D"), .string("feature/delete")])))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testGitBranchDeleteRejectsUnsafeInputs() throws {
    let missingConfirmRunner = FakeCommandRunner()
    let missingConfirmRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_delete"])
      ),
      commandRunner: missingConfirmRunner
    )

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.branch_delete",
        arguments: .object([
          "name": .string("feature/delete"),
          "dry_run": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_delete"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.branch_delete",
        arguments: .object(["name": .string("refs/heads/main")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let missingBranchRunner = FakeCommandRunner()
    missingBranchRunner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/missing\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let missingBranchRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_delete"])
      ),
      commandRunner: missingBranchRunner
    )

    expectThrows(
      try missingBranchRegistry.callTool(
        name: "git.branch_delete",
        arguments: .object(["name": .string("feature/missing")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
      #expect((missingBranchRunner.calls.count) == (2))
    }

    let currentBranchRunner = FakeCommandRunner()
    currentBranchRunner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/current\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "feature/current\n"),
    ]
    let currentBranchRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_delete"])
      ),
      commandRunner: currentBranchRunner
    )

    expectThrows(
      try currentBranchRegistry.callTool(
        name: "git.branch_delete",
        arguments: .object(["name": .string("feature/current")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("current branch"))
      #expect((currentBranchRunner.calls.count) == (3))
    }
  }

  @Test
  func testGitBranchRenameDryRunPreflightsWithoutRenaming() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/old\n"),
      FakeCommandRunner.Output(stdout: "feature/new\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "", exitCode: 1),
      FakeCommandRunner.Output(stdout: "main\n"),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_rename"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.branch_rename",
      arguments: .object([
        "old_name": .string("feature/old"),
        "new_name": .string("feature/new"),
        "timeout_ms": .number(1234),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/old"],
          ["check-ref-format", "--branch", "feature/new"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/old"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/new"],
          ["branch", "--show-current"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234, 1234, 1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.branch_rename")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["old_name"]) == (.string("feature/old")))
    #expect((payload.objectValue?["new_name"]) == (.string("feature/new")))
    #expect((payload.objectValue?["force"]) == (.bool(false)))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_rename"]) == (.bool(false)))
    #expect((payload.objectValue?["current_branch"]) == (.string("main")))
    #expect((payload.objectValue?["renames_current_branch"]) == (.bool(false)))
    #expect((payload.objectValue?["target_exists"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("branch"), .string("-m"), .string("feature/old"), .string("feature/new"),
        ])))
  }

  @Test
  func testGitBranchRenameRunsAfterConfirmation() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/old\n"),
      FakeCommandRunner.Output(stdout: "feature/new\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "feature/old\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_rename"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.branch_rename",
      arguments: .object([
        "old_name": .string("feature/old"),
        "new_name": .string("feature/new"),
        "force": .bool(true),
        "dry_run": .bool(false),
        "confirm_rename": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/old"],
          ["check-ref-format", "--branch", "feature/new"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/old"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/new"],
          ["branch", "--show-current"],
          ["branch", "-M", "feature/old", "feature/new"],
        ]))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_rename"]) == (.bool(true)))
    #expect((payload.objectValue?["force"]) == (.bool(true)))
    #expect((payload.objectValue?["renames_current_branch"]) == (.bool(true)))
    #expect((payload.objectValue?["target_exists"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([
          .string("branch"), .string("-M"), .string("feature/old"), .string("feature/new"),
        ])))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testGitBranchRenameRejectsUnsafeInputs() throws {
    let missingConfirmRunner = FakeCommandRunner()
    let missingConfirmRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_rename"])
      ),
      commandRunner: missingConfirmRunner
    )

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.branch_rename",
        arguments: .object([
          "old_name": .string("feature/old"),
          "new_name": .string("feature/new"),
          "dry_run": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_rename"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.branch_rename",
        arguments: .object([
          "old_name": .string("feature/same"),
          "new_name": .string("feature/same"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("must be different"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.branch_rename",
        arguments: .object([
          "old_name": .string("feature/old"),
          "new_name": .string("refs/heads/new"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let missingBranchRunner = FakeCommandRunner()
    missingBranchRunner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/missing\n"),
      FakeCommandRunner.Output(stdout: "feature/new\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let missingBranchRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_rename"])
      ),
      commandRunner: missingBranchRunner
    )

    expectThrows(
      try missingBranchRegistry.callTool(
        name: "git.branch_rename",
        arguments: .object([
          "old_name": .string("feature/missing"),
          "new_name": .string("feature/new"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
      #expect((missingBranchRunner.calls.count) == (3))
    }

    let existingTargetRunner = FakeCommandRunner()
    existingTargetRunner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/old\n"),
      FakeCommandRunner.Output(stdout: "feature/new\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
    ]
    let existingTargetRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_rename"])
      ),
      commandRunner: existingTargetRunner
    )

    expectThrows(
      try existingTargetRegistry.callTool(
        name: "git.branch_rename",
        arguments: .object([
          "old_name": .string("feature/old"),
          "new_name": .string("feature/new"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("already exists"))
      #expect((existingTargetRunner.calls.count) == (4))
    }
  }

  @Test
  func testGitBranchSwitchDryRunPreflightsWithoutSwitching() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/target\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "main\n"),
      FakeCommandRunner.Output(stdout: ""),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_switch"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.branch_switch",
      arguments: .object([
        "name": .string("feature/target"),
        "timeout_ms": .number(1234),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/target"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/target"],
          ["branch", "--show-current"],
          ["status", "--porcelain=v1", "-z"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234, 1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.branch_switch")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["name"]) == (.string("feature/target")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_switch"]) == (.bool(false)))
    #expect((payload.objectValue?["allow_dirty"]) == (.bool(false)))
    #expect((payload.objectValue?["current_branch"]) == (.string("main")))
    #expect((payload.objectValue?["already_current"]) == (.bool(false)))
    #expect((payload.objectValue?["dirty_worktree"]) == (.bool(false)))
    #expect((payload.objectValue?["working_tree_change_count"]) == (.number(0)))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("switch"), .string("--no-guess"), .string("feature/target")])))
  }

  @Test
  func testGitBranchSwitchRunsAfterConfirmation() throws {
    let runner = FakeCommandRunner()
    runner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/target\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "main\n"),
      FakeCommandRunner.Output(stdout: ""),
      FakeCommandRunner.Output(stdout: "Switched to branch 'feature/target'\n", exitCode: 0),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_switch"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "git.branch_switch",
      arguments: .object([
        "name": .string("feature/target"),
        "dry_run": .bool(false),
        "confirm_switch": .bool(true),
      ])
    )
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/target"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/target"],
          ["branch", "--show-current"],
          ["status", "--porcelain=v1", "-z"],
          ["switch", "--no-guess", "feature/target"],
        ]))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_switch"]) == (.bool(true)))
    #expect((payload.objectValue?["dirty_worktree"]) == (.bool(false)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([.string("switch"), .string("--no-guess"), .string("feature/target")])))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testGitBranchSwitchRejectsUnsafeInputs() throws {
    let missingConfirmRunner = FakeCommandRunner()
    let missingConfirmRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_switch"])
      ),
      commandRunner: missingConfirmRunner
    )

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.branch_switch",
        arguments: .object([
          "name": .string("feature/target"),
          "dry_run": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_switch"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.branch_switch",
        arguments: .object(["name": .string("refs/heads/main")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let missingBranchRunner = FakeCommandRunner()
    missingBranchRunner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/missing\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let missingBranchRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_switch"])
      ),
      commandRunner: missingBranchRunner
    )

    expectThrows(
      try missingBranchRegistry.callTool(
        name: "git.branch_switch",
        arguments: .object(["name": .string("feature/missing")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
      #expect((missingBranchRunner.calls.count) == (2))
    }

    let dirtyRunner = FakeCommandRunner()
    dirtyRunner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/target\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "main\n"),
      FakeCommandRunner.Output(stdout: " M README.md\u{0}"),
    ]
    let dirtyRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_switch"])
      ),
      commandRunner: dirtyRunner
    )

    expectThrows(
      try dirtyRegistry.callTool(
        name: "git.branch_switch",
        arguments: .object([
          "name": .string("feature/target"),
          "dry_run": .bool(false),
          "confirm_switch": .bool(true),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("allow_dirty"))
      #expect((dirtyRunner.calls.count) == (4))
    }
  }

  @Test
  func testGitBranchSwitchAllowsDirtyWorktreeWhenExplicitAndSkipsAlreadyCurrent() throws {
    let dirtyRunner = FakeCommandRunner()
    dirtyRunner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/target\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "main\n"),
      FakeCommandRunner.Output(stdout: " M README.md\u{0}?? scratch.txt\u{0}"),
      FakeCommandRunner.Output(stdout: "Switched to branch 'feature/target'\n", exitCode: 0),
    ]
    let dirtyRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_switch"])
      ),
      commandRunner: dirtyRunner
    )

    let dirtyResult = try dirtyRegistry.callTool(
      name: "git.branch_switch",
      arguments: .object([
        "name": .string("feature/target"),
        "dry_run": .bool(false),
        "confirm_switch": .bool(true),
        "allow_dirty": .bool(true),
      ])
    )
    let dirtyPayload = try decodeTextPayload(dirtyResult)

    #expect((dirtyPayload.objectValue?["dirty_worktree"]) == (.bool(true)))
    #expect((dirtyPayload.objectValue?["working_tree_change_count"]) == (.number(2)))
    #expect(
      (dirtyPayload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([.string("switch"), .string("--no-guess"), .string("feature/target")])))

    let currentRunner = FakeCommandRunner()
    currentRunner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/current\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
      FakeCommandRunner.Output(stdout: "feature/current\n"),
      FakeCommandRunner.Output(stdout: ""),
    ]
    let currentRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_switch"])
      ),
      commandRunner: currentRunner
    )

    let currentResult = try currentRegistry.callTool(
      name: "git.branch_switch",
      arguments: .object([
        "name": .string("feature/current"),
        "dry_run": .bool(false),
        "confirm_switch": .bool(true),
      ])
    )
    let currentPayload = try decodeTextPayload(currentResult)

    #expect((currentRunner.calls.count) == (4))
    #expect((currentPayload.objectValue?["already_current"]) == (.bool(true)))
    #expect((currentPayload.objectValue?["would_switch"]) == (.bool(false)))
    #expect((currentPayload.objectValue?["result"]) == (.null))
  }

  @Test
  func testGitBranchCreateRejectsUnsafeInputs() throws {
    let missingConfirmRunner = FakeCommandRunner()
    let missingConfirmRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_create"])
      ),
      commandRunner: missingConfirmRunner
    )

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.branch_create",
        arguments: .object([
          "name": .string("feature/new"),
          "dry_run": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_create"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.branch_create",
        arguments: .object(["name": .string("refs/heads/main")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.branch_create",
        arguments: .object(["name": .string("HEAD")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("must not be HEAD"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        name: "git.branch_create",
        arguments: .object([
          "name": .string("feature/new"),
          "start_point": .string("bad^{ref}"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("start_point"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let existingRunner = FakeCommandRunner()
    existingRunner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/existing\n"),
      FakeCommandRunner.Output(stdout: "", exitCode: 0),
    ]
    let existingRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_create"])
      ),
      commandRunner: existingRunner
    )

    expectThrows(
      try existingRegistry.callTool(
        name: "git.branch_create",
        arguments: .object(["name": .string("feature/existing")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("already exists"))
      #expect((existingRunner.calls.count) == (2))
    }

    let failedExistsRunner = FakeCommandRunner()
    failedExistsRunner.outputs = [
      FakeCommandRunner.Output(stdout: "feature/fail\n"),
      FakeCommandRunner.Output(stdout: "", stderr: "fatal: not a git repository\n", exitCode: 128),
    ]
    let failedExistsRegistry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: ["git.branch_create"])
      ),
      commandRunner: failedExistsRunner
    )

    expectThrows(
      try failedExistsRegistry.callTool(
        name: "git.branch_create",
        arguments: .object(["name": .string("feature/fail")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("existence check failed"))
      #expect((failedExistsRunner.calls.count) == (2))
    }
  }

  @Test
  func testGitAddUnstageAndCommitBuildExpectedWriteArgv() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: [
          "git.add", "git.unstage", "git.restore_worktree", "git.commit",
        ])
      ),
      commandRunner: runner
    )

    let addResult = try registry.callTool(
      name: "git.add",
      arguments: .object([
        "paths": .array([.string("Sources"), .string("README.md")]),
        "intent_to_add": .bool(true),
      ])
    )
    let addPayload = try decodeTextPayload(addResult)

    let unstageResult = try registry.callTool(
      name: "git.unstage",
      arguments: .object([
        "paths": .array([.string("Sources"), .string("README.md")])
      ])
    )
    let unstagePayload = try decodeTextPayload(unstageResult)

    let restoreWorktreeResult = try registry.callTool(
      name: "git.restore_worktree",
      arguments: .object([
        "paths": .array([.string("Sources"), .string("README.md")]),
        "dry_run": .bool(false),
        "confirm_discard": .bool(true),
      ])
    )
    let restoreWorktreePayload = try decodeTextPayload(restoreWorktreeResult)

    let commitResult = try registry.callTool(
      name: "git.commit",
      arguments: .object([
        "message": .string("Update gateway atomics"),
        "all": .bool(true),
        "allow_empty": .bool(true),
      ])
    )
    let commitPayload = try decodeTextPayload(commitResult)

    #expect(
      (runner.calls[0].arguments) == (["add", "--intent-to-add", "--", "Sources", "README.md"]))
    #expect((runner.calls[1].arguments) == (["restore", "--staged", "--", "Sources", "README.md"]))
    #expect(
      (runner.calls[2].arguments) == (["restore", "--worktree", "--", "Sources", "README.md"]))
    #expect(
      (runner.calls[3].arguments)
        == (["commit", "-m", "Update gateway atomics", "--all", "--allow-empty"]))
    #expect((addPayload.objectValue?["operation"]) == (.string("git.add")))
    #expect((unstagePayload.objectValue?["operation"]) == (.string("git.unstage")))
    #expect((restoreWorktreePayload.objectValue?["operation"]) == (.string("git.restore_worktree")))
    #expect((commitPayload.objectValue?["operation"]) == (.string("git.commit")))
    #expect((addPayload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((unstagePayload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((restoreWorktreePayload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((restoreWorktreePayload.objectValue?["confirm_discard"]) == (.bool(true)))
    #expect((commitPayload.objectValue?["dry_run"]) == (.bool(false)))
  }

  @Test
  func testGitWriteAtomicsDryRunBuildPreviewArgv() throws {
    let runner = FakeCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: [
          "git.add", "git.unstage", "git.restore_worktree", "git.commit",
        ])
      ),
      commandRunner: runner
    )

    let addResult = try registry.callTool(
      name: "git.add",
      arguments: .object([
        "paths": .array([.string("Sources"), .string("README.md")]),
        "intent_to_add": .bool(true),
        "dry_run": .bool(true),
      ])
    )
    let addPayload = try decodeTextPayload(addResult)

    let unstageResult = try registry.callTool(
      name: "git.unstage",
      arguments: .object([
        "paths": .array([.string("Sources"), .string("README.md")]),
        "dry_run": .bool(true),
      ])
    )
    let unstagePayload = try decodeTextPayload(unstageResult)

    let restoreWorktreeResult = try registry.callTool(
      name: "git.restore_worktree",
      arguments: .object([
        "paths": .array([.string("Sources"), .string("README.md")])
      ])
    )
    let restoreWorktreePayload = try decodeTextPayload(restoreWorktreeResult)

    let commitResult = try registry.callTool(
      name: "git.commit",
      arguments: .object([
        "message": .string("Update gateway atomics"),
        "all": .bool(true),
        "allow_empty": .bool(true),
        "dry_run": .bool(true),
      ])
    )
    let commitPayload = try decodeTextPayload(commitResult)

    #expect(
      (runner.calls[0].arguments)
        == (["add", "--dry-run", "--intent-to-add", "--", "Sources", "README.md"]))
    #expect(
      (runner.calls[1].arguments)
        == (["diff", "--cached", "--name-only", "--", "Sources", "README.md"]))
    #expect((runner.calls[2].arguments) == (["diff", "--name-only", "--", "Sources", "README.md"]))
    #expect(
      (runner.calls[3].arguments)
        == (["commit", "--dry-run", "-m", "Update gateway atomics", "--all", "--allow-empty"]))
    #expect((addPayload.objectValue?["operation"]) == (.string("git.add")))
    #expect((unstagePayload.objectValue?["operation"]) == (.string("git.unstage")))
    #expect((restoreWorktreePayload.objectValue?["operation"]) == (.string("git.restore_worktree")))
    #expect((commitPayload.objectValue?["operation"]) == (.string("git.commit")))
    #expect((addPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((unstagePayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((restoreWorktreePayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((restoreWorktreePayload.objectValue?["confirm_discard"]) == (.bool(false)))
    #expect((commitPayload.objectValue?["dry_run"]) == (.bool(true)))
  }

  @Test
  func testGitBuiltinsRequireGitProvider() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "echo", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: [
          "workspace.git_changes",
          "git.root", "git.config", "git.remotes", "git.worktrees", "git.stashes", "git.stash_show",
          "git.tags",
          "git.tag_show", "git.tag_create", "git.tag_delete", "git.ignored", "git.submodules",
          "git.files", "git.grep", "git.blame", "git.conflicts", "git.file_history",
          "git.file_at_revision", "git.staged_file",
          "git.status", "git.tracking_status", "git.clean_preview", "git.clean", "git.reflog",
          "git.refs", "git.resolve_ref", "git.merge_base", "git.compare_refs", "git.is_ancestor",
          "git.diff_summary", "git.diff_check", "git.branch_create", "git.branch_delete",
          "git.branch_rename", "git.branch_switch", "git.commit_files", "git.add", "git.unstage",
          "git.restore_worktree", "git.stash_push",
        ])
      )
    )

    expectThrows(
      try registry.callTool(name: "workspace.git_changes", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.root", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.remotes", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.worktrees", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.stashes", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.stash_show", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.tags", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.tag_show", arguments: .object(["name": .string("v1.0.0")]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.tag_create", arguments: .object(["name": .string("v1.0.0")]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.tag_delete", arguments: .object(["name": .string("v1.0.0")]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.ignored",
        arguments: .object(["paths": .array([.string("build/output.log")])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.submodules", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.files", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.grep",
        arguments: .object(["query": .string("needle")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.blame",
        arguments: .object(["path": .string("Sources/main.swift")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.file_history",
        arguments: .object(["path": .string("Sources/main.swift")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.file_at_revision",
        arguments: .object(["revision": .string("HEAD"), "path": .string("Sources/main.swift")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.staged_file",
        arguments: .object(["path": .string("Sources/main.swift")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.conflicts", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.status", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.tracking_status", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.clean_preview", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.clean",
        arguments: .object(["paths": .array([.string("build")])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.commit_files",
        arguments: .object(["revision": .string("HEAD")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.reflog", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.refs", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.resolve_ref",
        arguments: .object(["ref": .string("HEAD")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.merge_base",
        arguments: .object(["refs": .array([.string("main"), .string("topic")])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.compare_refs",
        arguments: .object(["base": .string("main"), "head": .string("topic")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.is_ancestor",
        arguments: .object([
          "ancestor": .string("main"),
          "descendant": .string("topic"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.diff_summary", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(name: "git.diff_check", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.branch_create",
        arguments: .object(["name": .string("feature/new")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.branch_delete",
        arguments: .object(["name": .string("feature/old")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.branch_rename",
        arguments: .object([
          "old_name": .string("feature/old"),
          "new_name": .string("feature/new"),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.branch_switch",
        arguments: .object(["name": .string("feature/target")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.add",
        arguments: .object(["paths": .array([.string("README.md")])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.unstage",
        arguments: .object(["paths": .array([.string("README.md")])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.restore_worktree",
        arguments: .object(["paths": .array([.string("README.md")])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.stash_push",
        arguments: .object([
          "message": .string("save work"),
          "paths": .array([.string("README.md")]),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }
  }

  @Test
  func testGitBuiltinsValidateBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: [
          "git.diff", "git.diff_summary", "git.diff_check", "git.clean_preview", "git.clean",
          "git.reflog", "git.refs", "git.compare_refs", "git.file_history",
          "git.file_at_revision", "git.staged_file", "git.commit_files", "git.grep", "git.log",
          "git.ignored", "git.blame", "git.add", "git.unstage", "git.restore_worktree",
          "git.commit", "git.stash_show", "git.stash_push",
        ])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "git.diff",
        arguments: .object(["context_lines": .number(101)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("context_lines"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.stash_show",
        arguments: .object(["context_lines": .number(101)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("context_lines"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.stash_show",
        arguments: .object(["stash": .string("main")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("stash@{N}"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.stash_show",
        arguments: .object(["stash": .string("stash@{-1}")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("non-negative integer"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.log",
        arguments: .object(["limit": .number(201)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("limit"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.diff_summary",
        arguments: .object(["max_results": .number(5_001)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.diff_check",
        arguments: .object(["max_results": .number(5_001)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.clean_preview",
        arguments: .object(["max_results": .number(5_001)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.clean_preview",
        arguments: .object(["include_ignored": .bool(true), "ignored_only": .bool(true)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("cannot both be true"))
    }

    expectThrows(
      try registry.callTool(name: "git.clean", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("paths or all_paths"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.clean",
        arguments: .object([
          "paths": .array([.string("build")]),
          "all_paths": .bool(true),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("cannot combine paths"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.clean",
        arguments: .object([
          "paths": .array([.string("build")]),
          "dry_run": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_delete"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.clean",
        arguments: .object([
          "all_paths": .bool(true),
          "include_ignored": .bool(true),
          "ignored_only": .bool(true),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("cannot both be true"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.reflog",
        arguments: .object(["limit": .number(201)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("limit"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.reflog",
        arguments: .object(["max_results": .number(201)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.refs",
        arguments: .object(["limit": .number(1_001)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("limit"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.refs",
        arguments: .object(["max_results": .number(1_001)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.refs",
        arguments: .object([
          "include_branches": .bool(false),
          "include_remotes": .bool(false),
          "include_tags": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("At least one"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.compare_refs",
        arguments: .object([
          "base": .string("main"),
          "head": .string("topic"),
          "limit": .number(201),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("limit"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.compare_refs",
        arguments: .object([
          "base": .string("main"),
          "head": .string("topic"),
          "max_results": .number(201),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.compare_refs",
        arguments: .object(["base": .string("-main"), "head": .string("topic")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("base"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.compare_refs",
        arguments: .object(["base": .string("main..topic"), "head": .string("topic")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("unsupported Git ref syntax"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.commit_files",
        arguments: .object(["revision": .string("HEAD"), "max_results": .number(5_001)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.commit_files",
        arguments: .object(["revision": .string("HEAD~1")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("revision"))
    }

    expectThrows(
      try registry.callTool(name: "git.commit_files", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("revision"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.grep",
        arguments: .object(["query": .string("needle"), "max_results": .number(5_001)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try registry.callTool(name: "git.grep", arguments: .object(["query": .string("")]))
    ) { error in
      #expect(error.localizedDescription.contains("query"))
    }

    expectThrows(
      try registry.callTool(name: "git.grep", arguments: .object(["query": .string("a\nb")]))
    ) { error in
      #expect(error.localizedDescription.contains("newlines"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.add",
        arguments: .object(["paths": .array([])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("requires at least one path"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.unstage",
        arguments: .object(["paths": .array([])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("requires at least one path"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.restore_worktree",
        arguments: .object(["paths": .array([])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("requires at least one path"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.restore_worktree",
        arguments: .object([
          "paths": .array([.string("README.md")]),
          "dry_run": .bool(false),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("confirm_discard"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.ignored",
        arguments: .object(["paths": .array([])])
      )
    ) { error in
      #expect(error.localizedDescription.contains("requires at least one path"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.blame",
        arguments: .object(["path": .string("Sources/main.swift"), "max_lines": .number(1_001)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_lines"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.blame",
        arguments: .object(["path": .string("Sources/main.swift"), "start_line": .number(0)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("start_line"))
    }

    expectThrows(
      try registry.callTool(name: "git.blame", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("requires path"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.file_history",
        arguments: .object(["path": .string("Sources/main.swift"), "limit": .number(201)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("limit"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.file_history",
        arguments: .object(["path": .string("Sources/main.swift"), "max_results": .number(201)])
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try registry.callTool(name: "git.file_history", arguments: .object([:]))
    ) { error in
      #expect(error.localizedDescription.contains("requires path"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.file_at_revision",
        arguments: .object([
          "revision": .string("HEAD"),
          "path": .string("Sources/main.swift"),
          "max_bytes": .number(1_048_577),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("policy.max_output_bytes"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.file_at_revision",
        arguments: .object(["revision": .string("HEAD~1"), "path": .string("Sources/main.swift")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("revision"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.file_at_revision",
        arguments: .object(["revision": .string("HEAD")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("requires path"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.staged_file",
        arguments: .object([
          "path": .string("Sources/main.swift"),
          "max_bytes": .number(1_048_577),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("policy.max_output_bytes"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.staged_file",
        arguments: .object([:])
      )
    ) { error in
      #expect(error.localizedDescription.contains("requires path"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.commit",
        arguments: .object(["message": .string(String(repeating: "x", count: 10_001))])
      )
    ) { error in
      #expect(error.localizedDescription.contains("10000 characters"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.stash_push",
        arguments: .object(["message": .string("save work")])
      )
    ) { error in
      #expect(error.localizedDescription.contains("paths or all_paths"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.stash_push",
        arguments: .object([
          "message": .string(""),
          "all_paths": .bool(true),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("message"))
    }

    expectThrows(
      try registry.callTool(
        name: "git.stash_push",
        arguments: .object([
          "message": .string(String(repeating: "x", count: 10_001)),
          "all_paths": .bool(true),
        ])
      )
    ) { error in
      #expect(error.localizedDescription.contains("10000 characters"))
    }
  }

  @Test
  func testGitBuiltinsRejectEscapingPaths() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
        builtin: BuiltinConfig(enabled: [
          "git.status", "git.diff_summary", "git.diff_check", "git.clean_preview",
          "git.clean", "git.ignored", "git.files", "git.grep", "git.blame", "git.file_history",
          "git.file_at_revision", "git.staged_file", "git.conflicts", "git.add",
          "git.unstage", "git.restore_worktree", "git.stash_show", "git.stash_push",
        ])
      )
    )

    for path in ["/tmp/file", "../outside", ":(top)README.md"] {
      expectThrows(
        try registry.callTool(
          name: "git.status",
          arguments: .object(["paths": .array([.string(path)])])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.add",
          arguments: .object(["paths": .array([.string(path)])])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.unstage",
          arguments: .object(["paths": .array([.string(path)])])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.restore_worktree",
          arguments: .object(["paths": .array([.string(path)])])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.stash_push",
          arguments: .object([
            "message": .string("save work"),
            "paths": .array([.string(path)]),
          ])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.clean",
          arguments: .object(["paths": .array([.string(path)])])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.stash_show",
          arguments: .object(["paths": .array([.string(path)])])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.diff_summary",
          arguments: .object(["paths": .array([.string(path)])])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.diff_check",
          arguments: .object(["paths": .array([.string(path)])])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.clean_preview",
          arguments: .object(["paths": .array([.string(path)])])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.ignored",
          arguments: .object(["paths": .array([.string(path)])])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.files",
          arguments: .object(["paths": .array([.string(path)])])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.grep",
          arguments: .object([
            "query": .string("needle"),
            "paths": .array([.string(path)]),
          ])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.blame",
          arguments: .object(["path": .string(path)])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.file_history",
          arguments: .object(["path": .string(path)])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.file_at_revision",
          arguments: .object(["revision": .string("HEAD"), "path": .string(path)])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.staged_file",
          arguments: .object(["path": .string(path)])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try registry.callTool(
          name: "git.conflicts",
          arguments: .object(["paths": .array([.string(path)])])
        )
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }
    }
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func writeSkill(root: URL, directory: String, content: String) throws {
    let skillDirectory = root.appendingPathComponent(directory, isDirectory: true)
    try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
    try content.write(
      to: skillDirectory.appendingPathComponent("SKILL.md"),
      atomically: true,
      encoding: .utf8
    )
  }

  private func writeTextPDF(pages: [String], to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(url: url as CFURL),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
      throw NSError(
        domain: "ComputerMCPTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unable to create PDF context."])
    }

    for text in pages {
      context.beginPDFPage(nil)
      context.saveGState()
      context.textMatrix = .identity
      context.translateBy(x: 0, y: mediaBox.height)
      context.scaleBy(x: 1, y: -1)

      let attributed = NSAttributedString(
        string: text,
        attributes: [
          .font: NSFont.systemFont(ofSize: 14),
          .foregroundColor: NSColor.black,
        ]
      )
      let framesetter = CTFramesetterCreateWithAttributedString(attributed)
      let path = CGMutablePath()
      path.addRect(CGRect(x: 72, y: 72, width: mediaBox.width - 144, height: mediaBox.height - 144))
      let frame = CTFramesetterCreateFrame(
        framesetter,
        CFRange(location: 0, length: attributed.length),
        path,
        nil
      )
      CTFrameDraw(frame, context)
      context.restoreGState()
      context.endPDFPage()
    }

    context.closePDF()
  }

  private func testWAVData(sampleRate: UInt32, sampleCount: UInt32) -> Data {
    let channels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let blockAlign = channels * bitsPerSample / 8
    let byteRate = sampleRate * UInt32(blockAlign)
    let dataSize = sampleCount * UInt32(blockAlign)
    let chunkSize = UInt32(36) + dataSize
    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    appendLittleEndian(chunkSize, to: &data)
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(channels, to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(byteRate, to: &data)
    appendLittleEndian(blockAlign, to: &data)
    appendLittleEndian(bitsPerSample, to: &data)
    data.append(contentsOf: "data".utf8)
    appendLittleEndian(dataSize, to: &data)
    data.append(Data(repeating: 0, count: Int(dataSize)))
    return data
  }

  private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { buffer in
      data.append(contentsOf: buffer)
    }
  }

  private func setTestExtendedAttribute(_ url: URL, name: String, value: Data) throws {
    let result = value.withUnsafeBytes { buffer -> Int32 in
      url.withUnsafeFileSystemRepresentation { pathPointer -> Int32 in
        guard let pathPointer else {
          errno = EINVAL
          return -1
        }
        return name.withCString { namePointer in
          setxattr(pathPointer, namePointer, buffer.baseAddress, value.count, 0, 0)
        }
      }
    }
    guard result == 0 else {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(errno),
        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
      )
    }
  }
}

private final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
  struct Call: Equatable {
    var executable: String
    var arguments: [String]
    var timeoutMilliseconds: Int
    var maxOutputBytes: Int
  }

  struct Output {
    var stdout: String
    var stdoutData: Data? = nil
    var stderr: String = ""
    var stderrData: Data? = nil
    var exitCode: Int32? = 0
    var stdoutTruncated: Bool = false
    var stderrTruncated: Bool = false
  }

  var stdout = "ok"
  var stderr = ""
  var exitCode: Int32? = 0
  var stdoutTruncated = false
  var stderrTruncated = false
  var outputs: [Output] = []
  var onRun: ((Call) throws -> Void)?
  private(set) var calls: [Call] = []

  func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult {
    let result = try runData(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes
    )
    return CommandResult(
      executable: result.executable,
      arguments: result.arguments,
      exitCode: result.exitCode,
      timedOut: result.timedOut,
      stdout: result.stdoutString,
      stderr: result.stderrString,
      stdoutTruncated: result.stdoutTruncated,
      stderrTruncated: result.stderrTruncated
    )
  }

  func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult {
    let call = Call(
      executable: executable,
      arguments: arguments,
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes
    )
    calls.append(call)
    try onRun?(call)
    let output =
      outputs.isEmpty
      ? Output(
        stdout: stdout,
        stderr: stderr,
        exitCode: exitCode,
        stdoutTruncated: stdoutTruncated,
        stderrTruncated: stderrTruncated
      )
      : outputs.removeFirst()
    return CommandDataResult(
      executable: executable,
      arguments: arguments,
      exitCode: output.exitCode,
      timedOut: false,
      stdout: output.stdoutData ?? Data(output.stdout.utf8),
      stderr: output.stderrData ?? Data(output.stderr.utf8),
      stdoutTruncated: output.stdoutTruncated,
      stderrTruncated: output.stderrTruncated
    )
  }
}

private final class FakeProcessManager: ProcessManaging, @unchecked Sendable {
  var snapshots: [ManagedProcessSnapshot] = []
  var spawnedIDs: [String] = []
  var cancelledIDs: [String] = []

  func spawn(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    maxOutputBytes: Int
  ) throws -> String {
    let id = "proc-\(spawnedIDs.count + 1)"
    spawnedIDs.append(id)
    return id
  }

  func list() throws -> [ManagedProcessSnapshot] {
    snapshots
  }

  func read(processID: String) throws -> ManagedProcessSnapshot {
    guard let snapshot = snapshots.first(where: { $0.processID == processID }) else {
      throw ProcessRegistryError.unknownProcess(processID)
    }
    return snapshot
  }

  func cancel(processID: String) throws -> ManagedProcessCancelResult {
    cancelledIDs.append(processID)
    return ManagedProcessCancelResult(
      processID: processID,
      cancelled: true,
      exitCode: nil
    )
  }
}

private final class FakeDownstreamMCPClient: DownstreamMCPClient, @unchecked Sendable {
  struct Call: Equatable {
    var server: String
    var tool: String
    var arguments: JSONValue
    var requestID: String? = nil
  }

  struct EventRead: Equatable {
    var afterCursor: Int
    var maxResults: Int
  }

  struct Cancellation: Equatable {
    var requestID: String
    var reason: String?
  }

  struct PromptGetCall: Equatable {
    var name: String
    var arguments: [String: String]?
  }

  private(set) var calls: [Call] = []
  private(set) var startedCalls: [Call] = []
  private(set) var resourceListCursors: [String?] = []
  private(set) var resourceTemplateListCursors: [String?] = []
  private(set) var resourceReadURIs: [String] = []
  private(set) var promptListCursors: [String?] = []
  private(set) var promptGetCalls: [PromptGetCall] = []
  private(set) var eventReads: [EventRead] = []
  private(set) var cancellations: [Cancellation] = []
  var tools = [
    MCPTool(
      name: "sample",
      description: "Sample downstream tool.",
      inputSchema: .object(["type": .string("object")])
    )
  ]
  var resources: [JSONValue] = []
  var resourceTemplates: [JSONValue] = []
  var resourceContents: [String: [JSONValue]] = [:]
  var prompts: [JSONValue] = []
  var promptResults: [String: JSONValue] = [:]
  var events: JSONValue = .object(["events": .array([])])
  var activeRequestPayload: JSONValue = .object(["requests": .array([])])

  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    tools
  }

  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    try callTool(server: server, name: name, arguments: arguments, requestID: nil)
  }

  func callTool(
    server: MCPServerConfig,
    name: String,
    arguments: JSONValue,
    requestID: String?
  ) throws -> JSONValue {
    calls.append(
      Call(server: server.id, tool: name, arguments: arguments, requestID: requestID)
    )
    return .object([
      "content": .array([.object(["type": .string("text"), "text": .string("called")])]),
      "isError": .bool(false),
    ])
  }

  func startToolCall(
    server: MCPServerConfig,
    name: String,
    arguments: JSONValue,
    requestID: String
  ) throws -> JSONValue {
    startedCalls.append(
      Call(server: server.id, tool: name, arguments: arguments, requestID: requestID)
    )
    return .object([
      "server": .string(server.id),
      "tool": .string(name),
      "request_id": .string(requestID),
      "state": .string("running"),
      "wait_for_result": .bool(false),
    ])
  }

  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue {
    resourceListCursors.append(cursor)
    return .object([
      "resources": .array(resources),
      "nextCursor": .null,
    ])
  }

  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue {
    resourceTemplateListCursors.append(cursor)
    return .object([
      "resourceTemplates": .array(resourceTemplates),
      "nextCursor": .null,
    ])
  }

  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue {
    resourceReadURIs.append(uri)
    return .object([
      "contents": .array(resourceContents[uri] ?? [])
    ])
  }

  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue {
    promptListCursors.append(cursor)
    return .object([
      "prompts": .array(prompts),
      "nextCursor": .null,
    ])
  }

  func getPrompt(
    server: MCPServerConfig,
    name: String,
    arguments: [String: String]?
  ) throws -> JSONValue {
    promptGetCalls.append(PromptGetCall(name: name, arguments: arguments))
    return promptResults[name]
      ?? .object([
        "description": .null,
        "messages": .array([]),
      ])
  }

  func connectionStatus(server: MCPServerConfig) throws -> JSONValue {
    .object([
      "state": .string("connected"),
      "persistent_session": .bool(true),
    ])
  }

  func readEvents(
    server: MCPServerConfig,
    afterCursor: Int,
    maxResults: Int
  ) throws -> JSONValue {
    eventReads.append(EventRead(afterCursor: afterCursor, maxResults: maxResults))
    return events
  }

  func activeRequests(server: MCPServerConfig) throws -> JSONValue {
    activeRequestPayload
  }

  func cancelRequest(
    server: MCPServerConfig,
    requestID: String,
    reason: String?
  ) throws -> JSONValue {
    cancellations.append(Cancellation(requestID: requestID, reason: reason))
    return .object([
      "request_id": .string(requestID),
      "cancelled": .bool(true),
    ])
  }
}
