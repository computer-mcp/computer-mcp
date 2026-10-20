import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsCLI

@Suite(.nativeIntegration, .serialized)
final class CLIToolProviderTests {
  @Test
  func alreadyCancelledExecDoesNotReachRunner() async {
    let runner = RecordingCommandRunner()
    let provider = CLIToolProvider(
      environment: ToolEnvironment(configuration: .fixture(), commandRunner: runner))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await provider.callToolAsync(
        .init(
          name: "cli.exec",
          arguments: .object(["id": .string("echo"), "argv": .array([.string("hello")])]),
          context: .empty))
    }

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(runner.calls.isEmpty)
  }

  @Test
  func testNoAuthToolsAdvertiseNoAuthSecurityScheme() throws {
    let provider = CLIToolProvider(environment: ToolEnvironment(configuration: .fixture()))
    let tool = try #require(try provider.definitions().map(\.tool).first { $0.name == "cli.list" })

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
    let provider = CLIToolProvider(environment: ToolEnvironment(configuration: config))
    let tool = try #require(try provider.definitions().map(\.tool).first { $0.name == "cli.list" })

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
    let provider = CLIToolProvider(environment: ToolEnvironment(configuration: config))

    let result = try provider.callTool(
      .init(name: "cli.list", arguments: .object([:]), context: .empty))
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
    let provider = CLIToolProvider(environment: ToolEnvironment(configuration: config))

    let result = try provider.callTool(
      .init(
        name: "cli.describe",
        arguments: .object(["id": .string("echo")]), context: .empty
      ))
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
    let provider = CLIToolProvider(environment: ToolEnvironment(configuration: config))

    let result = try provider.callTool(
      .init(
        name: "cli.status",
        arguments: .object(["id": .string("tool")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let command = try #require(payload.objectValue?["commands"]?.arrayValue?.first?.objectValue)

    #expect((command["id"]) == (.string("tool")))
    #expect((command["exists"]) == (.bool(true)))
    #expect((command["is_executable"]) == (.bool(true)))
    #expect((command["resolved_path"]) == (.string(executable.path)))

    let allResult = try provider.callTool(
      .init(
        name: "cli.status", arguments: .object([:]), context: .empty))
    let allPayload = try decodeTextPayload(allResult)
    #expect((allPayload.objectValue?["commands"]?.arrayValue?.count) == (2))
  }

  @Test
  func testCLIStatusRejectsUnknownID() {
    let provider = CLIToolProvider(environment: ToolEnvironment(configuration: .fixture()))

    expectThrows(
      try provider.callTool(
        .init(
          name: "cli.status",
          arguments: .object(["id": .string("missing")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unknown CLI command id"))
    }
  }

  @Test
  func testCLIHelpReturnsRawHelpAndExecContext() throws {
    let runner = RecordingCommandRunner()
    let config = GatewayConfiguration.fixture(
      cli: CLISectionConfig(commands: [
        CLICommandConfig(
          id: "echo",
          executable: "/bin/echo",
          interface: CLIInterfaceConfig(formatFlag: "--format", defaultFormat: "json")
        )
      ])
    )
    let provider = CLIToolProvider(
      environment: ToolEnvironment(configuration: config, commandRunner: runner))

    let result = try provider.callTool(
      .init(
        name: "cli.help",
        arguments: .object([
          "id": .string("echo"),
          "path": .array([.string("sub")]),
        ]), context: .empty
      ))
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
    let runner = RecordingCommandRunner()
    let provider = CLIToolProvider(
      environment: ToolEnvironment(configuration: .fixture(), commandRunner: runner))

    let result = try provider.callTool(
      .init(
        name: "cli.exec",
        arguments: .object([
          "id": .string("echo"),
          "argv": .array([.string("hello")]),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect((runner.calls.first?.arguments) == (["hello"]))
    #expect((payload.objectValue?["stdout"]) == (.string("ok")))
  }

  @Test
  func testCLIExecSchemaRequiresArgv() throws {
    let provider = CLIToolProvider(environment: ToolEnvironment(configuration: .fixture()))
    let tools = try provider.definitions().map(\.tool)

    let cliExec = try #require(tools.first { $0.name == "cli.exec" })

    #expect(
      (cliExec.inputSchema.objectValue?["required"]) == (.array([.string("id"), .string("argv")])))
  }

  @Test
  func testCLIExecRejectsMissingArgv() {
    let provider = CLIToolProvider(environment: ToolEnvironment(configuration: .fixture()))

    expectThrows(
      try provider.callTool(
        .init(
          name: "cli.exec",
          arguments: .object(["id": .string("echo")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Missing required array argument: argv"))
    }
  }

  @Test
  func testCLIExecRejectsUnknownID() {
    let provider = CLIToolProvider(environment: ToolEnvironment(configuration: .fixture()))

    expectThrows(
      try provider.callTool(
        .init(
          name: "cli.exec",
          arguments: .object([
            "id": .string("missing"),
            "argv": .array([.string("--version")]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unknown CLI command id"))
    }
  }

  @Test
  func testCLIExecRejectsCommandThatDisallowsArbitraryArgs() {
    let provider = CLIToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(
          cli: CLISectionConfig(commands: [
            CLICommandConfig(id: "echo", executable: "/bin/echo", allowAnyArgs: false)
          ])
        )
      ))

    expectThrows(
      try provider.callTool(
        .init(
          name: "cli.exec",
          arguments: .object([
            "id": .string("echo"),
            "argv": .array([.string("hello")]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("does not allow arbitrary args"))
    }
  }

  @Test
  func testStatusUsesProviderEnvironmentForScriptInterpretersWithoutStartingThem() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("script")
    try "#!/usr/bin/env sh\ntouch should-not-run\n".write(
      to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let config = GatewayConfiguration.fixture(
      cli: .init(commands: [
        .init(
          id: "missing-runtime", executable: script.path, cwd: directory.path,
          env: ["PATH": directory.path]),
        .init(
          id: "available-runtime", executable: script.path, cwd: directory.path,
          env: ["PATH": "/bin"]),
      ]))
    let cli = try decodeTextPayload(
      CLIToolProvider(
        environment: ToolEnvironment(configuration: config, environment: ["PATH": "/bin"])
      ).callTool(.init(name: "cli.status", arguments: .object([:]), context: .empty)))
    let commands = try #require(cli.objectValue?["commands"]?.arrayValue)
    #expect(
      commands[0].objectValue?["resolution"]?.objectValue?["status"]
        == .string("interpreter_unavailable"))
    #expect(commands[1].objectValue?["resolution"]?.objectValue?["status"] == .string("passed"))
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("should-not-run").path))
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

}
