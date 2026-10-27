import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformPOSIX
@testable import ComputerMCPProcess
@testable import ComputerMCPToolsCLI

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct CLIExecutionContextTests {
  @Test(arguments: ["probe", "./probe"], [String?.none, "nested"])
  func metadataHelpAndExecUseRegisteredContext(executable: String, cwd: String?)
    async throws
  {
    let fixture = try ContextFixture(cwd: cwd)
    defer { fixture.cleanup() }
    let host = [
      "PATH": ".:/usr/bin:/bin", "CLI_CONTEXT_VALUE": "host", "CLI_CONTEXT_OVERRIDE": "base",
    ]
    let runner = CLIContextCommandRunner(environment: host)
    let provider = CLIToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: fixture.configuration(executable: executable, cwd: cwd),
        commandRunner: runner, environment: host))
    let status = try payload(
      provider.callTool(.init(name: "cli.status", arguments: .object([:]), context: .empty)))
    let resolvedPath = try #require(
      status.objectValue?["commands"]?.arrayValue?.first?.objectValue?["resolved_path"]?.stringValue
    )
    let resolvedExecutable = try ProjectPathResolver.canonicalProject(
      URL(fileURLWithPath: resolvedPath))
    #expect(resolvedExecutable.path == fixture.executable.path)
    let help = try payload(
      provider.callTool(
        .init(
          name: "cli.help", arguments: .object(["id": .string("probe")]), context: .empty)))
    #expect(runner.calls.isEmpty)
    let execution = try await withCLIProcessScope(
      directory: fixture.executable.deletingLastPathComponent(), readOnly: true,
      variables: host.merging(["CLI_CONTEXT_OVERRIDE": "override"]) { _, value in value }
    ) {
      try payload(
        provider.callTool(
          .init(
            name: "cli.exec",
            arguments: .object([
              "id": .string("probe"), "argv": .array([.string("hello world"), .string("")]),
            ]), context: .empty)))
    }
    #expect(help.objectValue?["executed"] == .bool(false))
    #expect(execution.objectValue?["stdout"] == .string("host|override|hello world\n"))
    #expect(execution.objectValue?["executable"] == .string(executable))
    let call = try #require(runner.calls.first)
    #expect(runner.calls.count == 1 && call.executable == executable)
    #expect(call.arguments == ["hello world", ""])
    #expect(call.directory == fixture.executable.deletingLastPathComponent())
    #expect(call.environment == ["CLI_CONTEXT_OVERRIDE": "override"])
    await provider.environment.registeredCommands.execution.shutdown()
  }

  @Test(
    arguments: nativeSandboxAvailable
      ? [CLITreeSource.Kind.file, .introspection, .helper] : [.file])
  func treeDiscoveryUsesFixedEnvironmentAndExecutionUsesConfiguredEnvironment(
    kind: CLITreeSource.Kind
  ) async throws {
    let fixture = try ContextFixture(cwd: nil)
    defer { fixture.cleanup() }
    let command = CLICommandDescriptor(
      id: "probe", path: [], description: "Read isolated process context",
      argv: [.init(kind: .literal, value: "call")])
    let tree = CLITreeTests.tree(command)
    let treeURL = fixture.root.appendingPathComponent("tree.json")
    try JSONEncoder().encode(tree).write(to: treeURL)
    let exporter = fixture.root.appendingPathComponent("exporter")
    try "#!/bin/sh\n[ -z \"$CLI_CONTEXT_VALUE\" ] || exit 42\nexec /bin/cat tree.json\n".write(
      to: exporter, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exporter.path)
    var configuration = fixture.configuration(executable: "probe", cwd: nil)
    if kind == .introspection {
      try
        "#!/bin/sh\nif [ \"$1\" = export ]; then\n [ -z \"$CLI_CONTEXT_VALUE\" ] || exit 42\n exec /bin/cat tree.json\nfi\nprintf '%s|%s|%s\\n' \"$CLI_CONTEXT_VALUE\" \"$CLI_CONTEXT_OVERRIDE\" \"$1\"\n"
        .write(to: fixture.executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: fixture.executable.path)
    }
    configuration.cli.commands[0].allowAnyArgs = false
    configuration.cli.commands[0].tree = .init(
      kind: kind, path: kind == .file ? treeURL.path : nil,
      helper: kind == .helper ? exporter.path : nil,
      args: kind == .introspection ? ["export"] : [])
    let provider = CLIToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: configuration,
        environment: [
          "PATH": ".:/usr/bin:/bin", "CLI_CONTEXT_VALUE": "host", "CLI_CONTEXT_OVERRIDE": "base",
        ]))
    let treeProvider = try await withCLIProcessScope(directory: fixture.root, readOnly: true) {
      try #require(provider.treeProviders().first)
    }
    let native = try #require(treeProvider as? CLITreeToolProvider)
    #expect(
      native.registration.env == [
        "PATH": ".:/usr/bin:/bin", "CLI_CONTEXT_VALUE": "host", "CLI_CONTEXT_OVERRIDE": "override",
      ])
    let tool = try #require(
      treeProvider.definitions().map(\.tool).first { $0.name.hasPrefix("cli_") })
    let result = try await withCLIProcessScope(
      directory: fixture.root, readOnly: true, variables: native.registration.env
    ) {
      try await treeProvider.callToolAsync(
        .init(name: tool.name, arguments: .object([:]), context: .empty))
    }
    #expect(
      CLITreeTests.output(result)?["stdout"]?.objectValue?["data"]
        == .string("host|override|call\n"))
    await provider.environment.registeredCommands.execution.shutdown()
  }

  @Test
  func anExplicitRunnerEnvironmentDoesNotReintroduceAmbientValues() throws {
    let administration = try ExecutionAdministration(
      mode: .fullAccess,
      environment: .init(fullAccessVariables: [
        "PATH": "/usr/bin:/bin", "CLI_CONTEXT_VALUE": "isolated",
      ]))
    let result = try ExecutionAdministration.$current.withValue(administration) {
      try ProcessCommandRunner(
        launcher: testExecutionLauncher(), environment: ["PATH": "/usr/bin:/bin"]
      ).run(
        executable: "/usr/bin/env", arguments: [],
        workingDirectory: FileManager.default.temporaryDirectory,
        environment: ["CLI_CONTEXT_VALUE": "isolated"], timeoutMilliseconds: 2_000,
        maxOutputBytes: 1_024)
    }
    #expect(result.exitCode == 0, "\(result.stderr)")
    #expect(!result.timedOut)
    let variables = result.stdout.split(separator: "\n")
    #expect(variables.contains("CLI_CONTEXT_VALUE=isolated"))
    #expect(!variables.contains { $0.hasPrefix("HOME=") })
  }

  @Test
  func aMissingInterpreterAllowsMetadataHelpAndRejectsExecution() async throws {
    let fixture = try ContextFixture(cwd: nil)
    defer { fixture.cleanup() }
    try "#!/usr/bin/env unavailable-cli-context-interpreter\n".write(
      to: fixture.executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: fixture.executable.path)
    let provider = CLIToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: fixture.configuration(executable: "./probe", cwd: nil),
        environment: ["PATH": fixture.root.path]))
    let status = try payload(
      provider.callTool(.init(name: "cli.status", arguments: .object([:]), context: .empty)))
    #expect(
      status.objectValue?["commands"]?.arrayValue?.first?.objectValue?["resolution"]?.objectValue?[
        "status"] == .string("interpreter_unavailable"))
    let help = try payload(
      provider.callTool(
        .init(name: "cli.help", arguments: .object(["id": .string("probe")]), context: .empty)))
    #expect(help.objectValue?["executed"] == .bool(false))
    #expect(throws: CommandRunnerError.self) {
      try provider.callTool(
        .init(
          name: "cli.exec", arguments: .object(["id": .string("probe"), "argv": .array([])]),
          context: .empty))
    }
    await provider.environment.registeredCommands.execution.shutdown()
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
    let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cli-context-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: cwd.map { candidate.appendingPathComponent($0) } ?? candidate,
      withIntermediateDirectories: true)
    let root = try ProjectPathResolver.canonicalProject(candidate)
    self.root = root
    let directory = cwd.map { root.appendingPathComponent($0) } ?? root
    executable = directory.appendingPathComponent("probe")
    try "#!/bin/sh\nprintf '%s|%s|%s\\n' \"$CLI_CONTEXT_VALUE\" \"$CLI_CONTEXT_OVERRIDE\" \"$1\"\n"
      .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }

  func configuration(executable: String, cwd: String?) -> GatewayConfiguration {
    var configuration = GatewayConfiguration()
    configuration.projectDirectory = root
    configuration.cli.commands = [
      .init(
        id: "probe", executable: executable, cwd: cwd, env: ["CLI_CONTEXT_OVERRIDE": "override"])
    ]
    return configuration
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
