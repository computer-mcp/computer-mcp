import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct CLIExecutionContextTests {
  @Test(arguments: ["probe", "./probe"], [String?.none, "nested"])
  func rawHelpAndExecUseTheInspectedWorkspaceAndEnvironment(executable: String, cwd: String?)
    async throws
  {
    let fixture = try ContextFixture(cwd: cwd)
    defer { fixture.cleanup() }
    let registry = GatewayToolRegistry(
      configuration: fixture.configuration(executable: executable, cwd: cwd),
      environment: [
        "PATH": ".:/usr/bin:/bin", "CLI_CONTEXT_VALUE": "host", "CLI_CONTEXT_OVERRIDE": "base",
      ])
    let status = try payload(registry.callTool(name: "cli.status", arguments: .object([:])))
    #expect(
      status.objectValue?["commands"]?.arrayValue?.first?.objectValue?["resolved_path"]
        == .string(fixture.executable.path))
    let help = try payload(
      registry.callTool(name: "cli.help", arguments: .object(["id": .string("probe")])))
    let execution = try payload(
      registry.callTool(
        name: "cli.exec",
        arguments: .object([
          "id": .string("probe"), "argv": .array([.string("hello world"), .string("")]),
        ])))
    #expect(help.objectValue?["stdout"] == .string("host|override|--help\n"))
    #expect(execution.objectValue?["stdout"] == .string("host|override|hello world\n"))
    #expect(execution.objectValue?["executable"] == .string(executable))
    await registry.shutdown()
  }

  @Test(arguments: [CLITreeSource.Kind.file, .introspection, .helper])
  func treeDiscoveryAndExecutionUseTheInspectedEnvironment(kind: CLITreeSource.Kind) async throws {
    let fixture = try ContextFixture(cwd: nil)
    defer { fixture.cleanup() }
    let command = CLICommandDescriptor(
      id: "probe", path: [], description: "Read isolated process context",
      argv: [.init(kind: .literal, value: "call")])
    let tree = CLITreeTests.tree(command)
    let treeURL = fixture.root.appendingPathComponent("tree.json")
    try JSONEncoder().encode(tree).write(to: treeURL)
    let exporter = fixture.root.appendingPathComponent("exporter")
    try "#!/bin/sh\n[ \"$CLI_CONTEXT_VALUE\" = host ] || exit 42\nexec /bin/cat tree.json\n".write(
      to: exporter, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exporter.path)
    var configuration = fixture.configuration(executable: "probe", cwd: nil)
    if kind == .introspection {
      try
        "#!/bin/sh\nif [ \"$1\" = export ]; then\n [ \"$CLI_CONTEXT_VALUE\" = host ] || exit 42\n exec /bin/cat tree.json\nfi\nprintf '%s|%s|%s\\n' \"$CLI_CONTEXT_VALUE\" \"$CLI_CONTEXT_OVERRIDE\" \"$1\"\n"
        .write(to: fixture.executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: fixture.executable.path)
    }
    configuration.cli.commands[0].allowAnyArgs = false
    configuration.cli.commands[0].tree = .init(
      kind: kind, path: kind == .file ? treeURL.path : nil,
      helper: kind == .helper ? exporter.path : nil,
      args: kind == .introspection ? ["export"] : [])
    let registry = GatewayToolRegistry(
      configuration: configuration,
      environment: [
        "PATH": ".:/usr/bin:/bin", "CLI_CONTEXT_VALUE": "host", "CLI_CONTEXT_OVERRIDE": "base",
      ])
    let router = try GatewayProviderRouter(registry: registry)
    let tool = try #require(router.listTools().first { $0.name.hasPrefix("cli_") })
    let result = try await router.callToolAsync(name: tool.name, arguments: .object([:]))
    #expect(
      CLITreeTests.output(result)?["stdout"]?.objectValue?["data"]
        == .string("host|override|call\n"))
    await router.shutdown()
  }

  @Test
  func anExplicitRunnerEnvironmentDoesNotReintroduceAmbientValues() throws {
    let result = try ProcessCommandRunner(environment: ["PATH": "/usr/bin:/bin"]).run(
      executable: "/usr/bin/env",
      arguments: [],
      workingDirectory: FileManager.default.temporaryDirectory,
      environment: ["CLI_CONTEXT_VALUE": "isolated"], timeoutMilliseconds: 2_000,
      maxOutputBytes: 1_024)
    #expect(result.exitCode == 0, "\(result.stderr)")
    #expect(!result.timedOut)
    let variables = result.stdout.split(separator: "\n")
    #expect(variables.contains("CLI_CONTEXT_VALUE=isolated"))
    #expect(!variables.contains { $0.hasPrefix("HOME=") })
  }

  @Test
  func aMissingInterpreterFailsBeforeRawHelpOrExecution() async throws {
    let fixture = try ContextFixture(cwd: nil)
    defer { fixture.cleanup() }
    try "#!/usr/bin/env unavailable-cli-context-interpreter\n".write(
      to: fixture.executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: fixture.executable.path)
    let registry = GatewayToolRegistry(
      configuration: fixture.configuration(executable: "./probe", cwd: nil),
      environment: ["PATH": fixture.root.path])
    let status = try payload(registry.callTool(name: "cli.status", arguments: .object([:])))
    #expect(
      status.objectValue?["commands"]?.arrayValue?.first?.objectValue?["resolution"]?.objectValue?[
        "status"] == .string("interpreter_unavailable"))
    #expect(throws: CommandRunnerError.self) {
      try registry.callTool(name: "cli.help", arguments: .object(["id": .string("probe")]))
    }
    #expect(throws: CommandRunnerError.self) {
      try registry.callTool(
        name: "cli.exec", arguments: .object(["id": .string("probe"), "argv": .array([])]))
    }
    await registry.shutdown()
  }

  private func payload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}

private struct ContextFixture {
  let root: URL
  let executable: URL

  init(cwd: String?) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cli-context-\(UUID().uuidString)"
    ).standardizedFileURL.resolvingSymlinksInPath()
    self.root = root
    let directory = cwd.map { root.appendingPathComponent($0) } ?? root
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    executable = directory.appendingPathComponent("probe")
    try "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$CLI_CONTEXT_VALUE\" \"$CLI_CONTEXT_OVERRIDE\" \"$1\"\n"
      .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }

  func configuration(executable: String, cwd: String?) -> GatewayConfiguration {
    var configuration = GatewayConfiguration()
    configuration.workspaceDirectory = root
    configuration.cli.commands = [
      .init(
        id: "probe", executable: executable, cwd: cwd, env: ["CLI_CONTEXT_OVERRIDE": "override"])
    ]
    return configuration
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
