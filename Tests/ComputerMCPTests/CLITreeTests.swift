import Darwin
import Foundation
import Testing

@testable import ComputerMCP

struct CLITreeTests {
  @Test(arguments: [
    "", "hello world", "你好🙂", "a\"b'c", "$(touch should-not-exist)", "-42", "--", "a\nb",
  ])
  func positionalBytesAreNotShellParsed(_ value: String) throws {
    let invocation = try CLIArgumentEncoder.encode(
      .object(["values": .array([.string(value)])]), command: Self.printCommand())
    #expect(invocation.arguments == ["--", "%s\n", value])
    #expect(invocation.standardInput.isEmpty)
  }

  @Test
  func orderedOptionsArraysDefaultsAndInverseFlags() throws {
    let command = CLICommandDescriptor(
      id: "query", path: ["query"], description: "Query fixture",
      parameters: [
        .init(name: "label", schema: Self.strings),
        .init(
          name: "limit", schema: .object(["type": .string("integer")]), defaultValue: .number(10)),
        .init(name: "color", schema: .object(["type": .string("boolean")])),
      ],
      argv: [
        .init(kind: .option, parameter: "label", flag: "--label", style: .repeated),
        .init(kind: .literal, value: "query"),
        .init(kind: .option, parameter: "limit", flag: "--limit", style: .equals),
        .init(kind: .flag, parameter: "color", flag: "--color", inverse: "--no-color"),
      ])
    #expect(try CLIArgumentEncoder.encode(.object([:]), command: command).arguments == ["query"])
    let invocation = try CLIArgumentEncoder.encode(
      .object([
        "label": .array([.string(""), .string("你好 world")]), "limit": .number(-3),
        "color": .bool(false),
      ]), command: command)
    #expect(
      invocation.arguments == [
        "--label", "", "--label", "你好 world", "query", "--limit=-3", "--no-color",
      ])
    #expect(
      command.inputSchema.objectValue?["properties"]?.objectValue?["limit"]?.objectValue?["default"]
        == .number(10))
  }

  @Test
  func schemaAndEncoderEnforceTheSameRelationships() throws {
    let command = CLICommandDescriptor(
      id: "relation", path: [], description: "Related values",
      parameters: [
        .init(name: "left", schema: Self.string, conflicts: ["right"], requires: ["scope"]),
        .init(name: "right", schema: Self.string), .init(name: "scope", schema: Self.string),
      ],
      argv: [
        .init(kind: .option, parameter: "left", flag: "--left", style: .equals),
        .init(kind: .option, parameter: "right", flag: "--right", style: .equals),
        .init(kind: .option, parameter: "scope", flag: "--scope", style: .equals),
      ])
    #expect(throws: CLITreeError.self) {
      try CLIArgumentEncoder.encode(.object(["left": .string("x")]), command: command)
    }
    #expect(throws: CLITreeError.self) {
      try CLIArgumentEncoder.encode(
        .object(["left": .string("x"), "right": .string("y"), "scope": .string("z")]),
        command: command)
    }
    #expect(
      command.inputSchema.objectValue?["dependentRequired"]?.objectValue?["left"]
        == .array([.string("scope")]))
    #expect(command.inputSchema.objectValue?["allOf"]?.arrayValue?.count == 1)
  }

  @Test(arguments: [
    JSONValue.object([:]), .object(["values": .string("not an array")]),
    .object(["values": .array([.number(1)])]), .object(["values": .array([.string("bad\0value")])]),
    .object(["values": .array([]), "unknown": .string("credential-must-not-appear")]),
  ])
  func invalidInputFailsBeforeExecution(_ input: JSONValue) {
    #expect(throws: CLITreeError.self) {
      try CLIArgumentEncoder.encode(input, command: Self.printCommand())
    }
  }

  @Test
  func ambiguousArgvAndUnsupportedSchemasFailClosed() throws {
    var command = Self.printCommand()
    command.argv.removeFirst()
    #expect(throws: CLITreeError.self) {
      try CLIArgumentEncoder.encode(
        .object(["values": .array([.string("--delete")])]), command: command)
    }
    command.parameters = [
      .init(name: "x", schema: Self.string), .init(name: "y", schema: Self.string),
    ]
    command.argv = [
      .init(kind: .positional, parameter: "x"), .init(kind: .positional, parameter: "y"),
    ]
    #expect(throws: CLITreeError.self) {
      try CLIArgumentEncoder.encode(.object(["y": .string("value")]), command: command)
    }
    #expect(throws: CLITreeError.self) {
      try CLIValueValidation.validateSchema(
        .object(["type": .string("string"), "pattern": .string(".*")]))
    }
    command.parameters = [
      .init(name: "secret", schema: Self.string, defaultValue: .string("credential"), secret: true)
    ]
    #expect(throws: CLITreeError.self) { try command.validate() }
  }

  @Test
  func treeRoundTripAndUnknownFields() throws {
    let tree = Self.tree(Self.printCommand())
    let data = try JSONEncoder().encode(tree)
    #expect(try CLITree.parse(data) == tree)
    var value = try #require(JSONValue.encoded(tree).objectValue)
    value["invented_permission"] = .string("admin")
    #expect(throws: CLITreeError.self) {
      try CLITree.parse(JSONEncoder().encode(JSONValue.object(value)))
    }
    #expect(throws: CLITreeError.self) {
      try CLITree(
        formatVersion: 1, source: "fixture", executableVersion: "test", coverage: .complete,
        omissions: ["unmapped"], commands: [Self.printCommand()]
      ).validate()
    }
  }

  @Test
  func realCLIThroughFileCatalogAndRefresh() async throws {
    let fixture = try CLITreeFixture()
    defer { fixture.cleanup() }
    try fixture.write(Self.tree(Self.printCommand()))
    var configuration = GatewayConfiguration()
    configuration.workspaceDirectory = fixture.root
    configuration.cli.commands = [
      .init(
        id: "printf", executable: "/usr/bin/printf", allowAnyArgs: false,
        tree: .init(kind: .file, path: fixture.treeURL.path))
    ]
    let registry = GatewayToolRegistry(configuration: configuration)
    let router = try GatewayProviderRouter(registry: registry)
    let tool = try #require(router.listTools().first { $0.name.hasPrefix("cli_") })
    #expect(tool.name.count <= 128)
    #expect(try router.capability(named: tool.name).risk == .fullShell)
    let result = try await router.callToolAsync(
      name: tool.name,
      arguments: .object([
        "values": .array([.string("你好 world"), .string("'\"$HOME"), .string("-42"), .string("")])
      ]))
    #expect(
      Self.output(result)?["stdout"]?.objectValue?["data"] == .string("你好 world\n'\"$HOME\n-42\n\n")
    )
    #expect(result.objectValue?["isError"] == .bool(false))
    #expect(Self.output(result)?["arguments"] == nil)
    #expect(throws: GatewayToolError.self) {
      try registry.callTool(
        name: "cli.exec", arguments: .object(["id": .string("printf"), "argv": .array([])]))
    }
    #expect(throws: GatewayToolError.self) {
      try registry.callTool(
        name: "cli.help",
        arguments: .object(["id": .string("printf"), "path": .array([.string("--anything")])]))
    }
    let help = try registry.callTool(
      name: "cli.help", arguments: .object(["id": .string("printf")]))
    #expect(Self.output(help)?["executed"] == .bool(false))
    let events = router.toolChanges()
    var next = Self.printCommand()
    next.parameters = [.init(name: "values", schema: Self.strings)]
    try fixture.write(Self.tree(next))
    try await router.refreshTools()
    #expect(try router.listTools().first { $0.name == tool.name }?.inputSchema != tool.inputSchema)
    try Data("invalid".utf8).write(to: fixture.treeURL)
    await #expect(throws: (any Error).self) { try await router.refreshTools() }
    #expect(router.lastRefreshError != nil)
    #expect(try router.listTools().contains { $0.name == tool.name })
    await router.shutdown()
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() != nil)
    #expect(await iterator.next() == nil)
  }

  @Test(arguments: [CLITreeSource.Kind.introspection, .helper])
  func validatedExportersUseTheSameTreeContract(_ kind: CLITreeSource.Kind) async throws {
    let fixture = try CLITreeFixture()
    defer { fixture.cleanup() }
    let tree = Self.tree(Self.printCommand())
    try fixture.write(tree)
    let execution = CLIProcessExecution()
    let source = CLITreeSource(
      kind: kind, helper: kind == .helper ? "/bin/cat" : nil, args: [fixture.treeURL.path])
    let loaded = try source.load(
      command: .init(id: "cat", executable: "/bin/cat", allowAnyArgs: false),
      workspace: fixture.root, execution: execution)
    #expect(loaded == tree)
    await execution.shutdown()
  }

  @Test
  func binaryStdinAndOutputAreLossless() async throws {
    let command = CLICommandDescriptor(
      id: "copy", path: [], description: "Copy fixture bytes",
      parameters: [.init(name: "input", schema: Self.string, required: true, secret: true)],
      stdin: .init(parameter: "input", encoding: .base64), stdout: .binary)
    let provider = Self.provider(command, executable: "/bin/cat")
    let name = try #require(provider.listTools().first?.name)
    let bytes = Data([0, 255, 13, 10, 192, 128])
    let result = try await provider.callToolAsync(
      name: name, arguments: .object(["input": .string(bytes.base64EncodedString())]))
    #expect(Self.output(result)?["stdout"]?.objectValue?["encoding"] == .string("base64"))
    #expect(
      Self.output(result)?["stdout"]?.objectValue?["data"] == .string(bytes.base64EncodedString()))
    #expect(result.objectValue?["isError"] == .bool(false))
    await provider.execution.shutdown()
  }

  @Test(arguments: [("{\"ok\":true}", false), ("{\"ok\":1}", true), ("not JSON", true)])
  func jsonOutputIsActuallyValidated(_ text: String, fails: Bool) async throws {
    let command = CLICommandDescriptor(
      id: "json", path: [], description: "JSON fixture",
      parameters: [.init(name: "input", schema: Self.string, required: true)],
      stdin: .init(parameter: "input", encoding: .utf8), stdout: .json,
      outputSchema: .object([
        "type": .string("object"),
        "properties": .object(["ok": .object(["type": .string("boolean")])]),
        "required": .array([.string("ok")]), "additionalProperties": .bool(false),
      ]))
    let provider = Self.provider(command, executable: "/bin/cat")
    let name = try #require(provider.listTools().first?.name)
    let result = try await provider.callToolAsync(
      name: name, arguments: .object(["input": .string(text)]))
    #expect(result.objectValue?["isError"] == .bool(fails))
    #expect(Self.output(result)?["stdout"]?.objectValue?["data"] == .string(text))
    await provider.execution.shutdown()
  }

  @Test
  func cancellationReapsOnlyItsOwnedProcess() async throws {
    let fixture = try CLITreeFixture()
    defer { fixture.cleanup() }
    let execution = CLIProcessExecution()
    let marker = fixture.root.appendingPathComponent("pid")
    let task = Task {
      try await execution.runAsync(
        executable: "/bin/sh",
        invocation: .init(
          arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "fixture", marker.path],
          standardInput: Data()),
        cwd: fixture.root, environment: [:], timeoutMilliseconds: 30_000, maxOutputBytes: 1_024)
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !FileManager.default.fileExists(atPath: marker.path), clock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    // Always cancel, including a failed startup observation, so the fixture cannot leave sleep running.
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    await execution.shutdown()
    let pid = try #require(
      Int32(
        String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    )
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
  }

  @Test
  func pluginAndDirectRegistrationUseTheSamePolicyAndExecution() async throws {
    let fixture = try CLITreeFixture()
    defer { fixture.cleanup() }
    try fixture.write(Self.tree(Self.printCommand()))
    let manifest = """
      id = 'tree-test'
      name = 'Tree test'
      version = '1.0.0'
      [[dependencies]]
      id = 'printf'
      commands = ['printf']
      instructions = 'Use the system printf.'
      [[cli]]
      id = 'print'
      executable = { dependency = 'printf' }
      tree = { kind = 'file', path = 'tree.json' }
      """
    try manifest.write(
      to: fixture.root.appendingPathComponent(PluginManifest.filename), atomically: true,
      encoding: .utf8)
    let package = try PluginPackage.load(at: fixture.root)
    let plugin = try PluginResolver.resolve(
      package: package, source: .init(kind: .development, root: package.root),
      settings: .init(enabled: true, cli: ["print": .init(registrationID: "printf")]),
      dependencyExecutables: ["printf": URL(fileURLWithPath: "/usr/bin/printf")],
      hostVersion: PluginVersion("1.0.29"), architecture: "arm64")
    #expect(plugin.cliCommands.first?.tree?.packageRoot == package.root)
    let workspaces = [
      RegisteredWorkspace(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
    ]
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: .localAdmin))
    let runtime = try GatewayRuntime(
      configuration: configuration, registeredWorkspaces: workspaces, plugins: [plugin])
    let tool = try #require(runtime.listTools().first { $0.name.hasPrefix("cli_") })
    let result = try await runtime.callToolAsync(
      name: tool.name, arguments: .object(["values": .array([.string("plugin value")])]))
    #expect(Self.output(result)?["stdout"]?.objectValue?["data"] == .string("plugin value\n"))
    await runtime.shutdown()

    var direct = configuration
    direct.cli.commands = [
      .init(
        id: "printf", executable: "/usr/bin/printf", allowAnyArgs: false,
        tree: .init(kind: .file, path: fixture.treeURL.path))
    ]
    let directRuntime = try GatewayRuntime(
      configuration: direct, registeredWorkspaces: workspaces, plugins: [])
    let directTool = try #require(directRuntime.listTools().first { $0.name.hasPrefix("cli_") })
    #expect(directTool == tool)
    await directRuntime.shutdown()
    let observeContext = ExecutionContext(caller: .secureTunnel, profileID: .chatGPTObserve)
    let observe = try GatewayRuntime(
      configuration: direct, context: observeContext, registeredWorkspaces: workspaces, plugins: [])
    #expect(try !observe.listTools().contains { $0.name == tool.name })
    await #expect(throws: (any Error).self) {
      try await observe.callToolAsync(
        name: tool.name, arguments: .object(["values": .array([.string("denied")])]))
    }
    await observe.shutdown()
  }

  @Test
  func processContextAndTimeoutAreObservable() async throws {
    let fixture = try CLITreeFixture()
    defer { fixture.cleanup() }
    let execution = CLIProcessExecution()
    let context = try await execution.runAsync(
      executable: "/bin/sh",
      invocation: .init(
        arguments: ["-c", "printf '%s\\n%s' \"$PWD\" \"$CLI_TREE_TEST_VALUE\""],
        standardInput: Data()),
      cwd: fixture.root, environment: ["CLI_TREE_TEST_VALUE": "not global"],
      timeoutMilliseconds: 5_000, maxOutputBytes: 4_096)
    let output = try #require(context.stdout.base64.flatMap { Data(base64Encoded: $0) })
    let canonical = try WorkspacePathResolver.canonicalWorkspace(fixture.root).path
    #expect(String(decoding: output, as: UTF8.self) == "\(canonical)\nnot global")
    let timeout = try await execution.runAsync(
      executable: "/bin/sleep", invocation: .init(arguments: ["30"], standardInput: Data()),
      cwd: fixture.root, environment: [:], timeoutMilliseconds: 50, maxOutputBytes: 1_024)
    #expect(timeout.timedOut)
    #expect(!timeout.isRunning)
    await execution.shutdown()
  }

  @Test
  func nullDefaultAndJSONStdinPreservePresence() throws {
    let command = CLICommandDescriptor(
      id: "null", path: [], description: "Null default",
      parameters: [
        .init(name: "input", schema: .object(["type": .string("null")]), defaultValue: .null)
      ],
      stdin: .init(parameter: "input", encoding: .json))
    let roundTrip = try CLITree.parse(JSONEncoder().encode(Self.tree(command)))
    #expect(roundTrip.commands.first?.parameters.first?.defaultValue == .null)
    #expect(try CLIArgumentEncoder.encode(.object([:]), command: command).standardInput.isEmpty)
    #expect(
      try CLIArgumentEncoder.encode(.object(["input": .null]), command: command).standardInput
        == Data("null".utf8))
  }

  @Test
  func documentedExampleIsParsedAndExecuted() async throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let tree = try CLITree.parse(
      Data(contentsOf: repo.appendingPathComponent("Examples/printf-cli-tree.json")))
    #expect(tree.coverage == .partial)
    let command = try #require(tree.commands.first)
    let provider = Self.provider(command, executable: "/usr/bin/printf")
    let name = try #require(provider.listTools().first?.name)
    let response = try await provider.callToolAsync(
      name: name, arguments: .object(["values": .array([.string("example works")])]))
    #expect(Self.output(response)?["stdout"]?.objectValue?["data"] == .string("example works\n"))
    await provider.execution.shutdown()
  }

  @Test
  func sourceContainmentAndRegularFileChecksAreRetained() async throws {
    let fixture = try CLITreeFixture()
    let outside = try CLITreeFixture()
    defer {
      fixture.cleanup()
      outside.cleanup()
    }
    try outside.write(Self.tree(Self.printCommand()))
    try FileManager.default.createSymbolicLink(
      at: fixture.treeURL, withDestinationURL: outside.treeURL)
    var source = CLITreeSource(kind: .file, path: fixture.treeURL.path)
    source.packageRoot = fixture.root
    let execution = CLIProcessExecution()
    let command = CLICommandConfig(id: "fixture", executable: "/bin/cat", allowAnyArgs: false)
    #expect(throws: (any Error).self) {
      try source.load(command: command, workspace: fixture.root, execution: execution)
    }
    let fifo = fixture.root.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    source = .init(kind: .file, path: fifo.path)
    #expect(throws: (any Error).self) {
      try source.load(command: command, workspace: fixture.root, execution: execution)
    }
    await execution.shutdown()
  }

  @Test
  func typedBoundsAndAmbiguousVariadicsAreValidated() throws {
    let unicodeSchema = JSONValue.object([
      "type": .string("string"), "minLength": .number(2), "maxLength": .number(2),
    ])
    try CLIValueValidation.validate(.string("e\u{301}"), schema: unicodeSchema, path: "value")
    #expect(throws: CLITreeError.self) {
      try CLIValueValidation.validate(.string("e"), schema: unicodeSchema, path: "value")
    }
    var command = Self.printCommand()
    command.parameters += [.init(name: "trailing", schema: Self.string)]
    command.argv += [.init(kind: .positional, parameter: "trailing")]
    #expect(throws: CLITreeError.self) { try command.validate() }
    command = Self.printCommand()
    command.parameters += [.init(name: "flag", schema: .object(["type": .string("boolean")]))]
    command.argv += [.init(kind: .flag, parameter: "flag", flag: "--flag")]
    #expect(throws: CLITreeError.self) { try command.validate() }
  }

  @Test
  func routingNamesAndOneWayFlagsHaveFaithfulSchemas() throws {
    var command = CLICommandDescriptor(
      id: "flag", path: [], description: "One-way flag",
      parameters: [
        .init(
          name: "flag", schema: .object(["type": .string("boolean")]), defaultValue: .bool(false))
      ],
      argv: [.init(kind: .flag, parameter: "flag", flag: "--flag")])
    try command.validate()
    let property = try #require(
      command.inputSchema.objectValue?["properties"]?.objectValue?["flag"]?.objectValue)
    #expect(property["const"] == .bool(true))
    #expect(property["default"] == nil)
    #expect(
      try CLIArgumentEncoder.encode(.object(["flag": .bool(true)]), command: command).arguments == [
        "--flag"
      ])
    #expect(throws: CLITreeError.self) {
      try CLIArgumentEncoder.encode(.object(["flag": .bool(false)]), command: command)
    }
    command.parameters = [.init(name: "workspace_id", schema: Self.string)]
    #expect(throws: CLITreeError.self) { try command.validate() }
  }

  static let string = JSONValue.object(["type": .string("string")])
  static let strings = JSONValue.object(["type": .string("array"), "items": string])

  static func printCommand() -> CLICommandDescriptor {
    CLICommandDescriptor(
      id: "print", path: [], description: "Print each supplied string literally",
      parameters: [.init(name: "values", schema: strings, required: true)],
      argv: [
        .init(kind: .literal, value: "--"), .init(kind: .literal, value: "%s\n"),
        .init(kind: .positional, parameter: "values"),
      ],
      helpArgv: ["--help"], riskHint: .readOnly)
  }

  static func tree(_ command: CLICommandDescriptor) -> CLITree {
    .init(
      formatVersion: 1, source: "test fixture; not upstream discovery",
      executableVersion: "fixture",
      coverage: .partial, omissions: ["Only the declared test invocation is represented."],
      commands: [command])
  }

  static func provider(_ command: CLICommandDescriptor, executable: String) -> CLITreeToolProvider {
    .init(
      registration: .init(id: "fixture", executable: executable, allowAnyArgs: false),
      tree: tree(command), workspace: URL(fileURLWithPath: "/tmp"),
      execution: CLIProcessExecution(),
      timeoutMilliseconds: 5_000, maxOutputBytes: 4_096)
  }

  static func output(_ result: JSONValue) -> [String: JSONValue]? {
    result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue
  }
}

private struct CLITreeFixture {
  let root: URL
  var treeURL: URL { root.appendingPathComponent("tree.json") }
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cli-tree-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  func write(_ tree: CLITree) throws {
    try JSONEncoder().encode(tree).write(to: treeURL, options: .atomic)
  }
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
