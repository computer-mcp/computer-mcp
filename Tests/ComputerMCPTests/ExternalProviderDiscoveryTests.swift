import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class ExternalProviderDiscoveryTests {
  @Test
  func testMissingProviderReturnsStableUnavailableResultWithoutExecutingCommands() throws {
    let runner = DiscoveryCommandRunner()
    let discovery = ExternalProviderDiscovery(
      definitions: [appleDefinition],
      commandRunner: runner,
      environment: ["PATH": ""],
      commonSearchDirectories: []
    )

    let result = try #require(discovery.discover().first)

    #expect((result.providerID) == ("apple-cli-mcp"))
    #expect((result.kind) == (.appleCLIMCP))
    #expect((result.resolvedPath) == nil)
    #expect((result.version) == nil)
    #expect((result.doctorStatus.state) == (.unavailable))
    #expect((result.diagnostics.map(\.code)) == ([.executableNotFound]))
    #expect((runner.recordedCalls) == ([]))
  }

  @Test
  func testResolvedProviderReportsLaunchPathAndVersion() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = try makeExecutable(named: "tunnel-client", in: directory)
    let runner = DiscoveryCommandRunner { call in
      #expect((call.arguments) == (["--version"]))
      return .init(stdout: "tunnel-client 2.7.1\n")
    }
    let discovery = ExternalProviderDiscovery(
      definitions: [tunnelDefinition],
      commandRunner: runner,
      environment: ["PATH": directory.path],
      commonSearchDirectories: []
    )

    let result = try #require(discovery.discover().first)

    #expect((result.resolvedPath) == (executable.resolvingSymlinksInPath().path))
    #expect((result.version) == ("tunnel-client 2.7.1"))
    #expect((result.doctorStatus.state) == (.notApplicable))
    #expect((runner.recordedCalls.count) == (1))
  }

  @Test
  func testAppleCLIContractIncompleteWhenDryRunIsNotDeclared() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try makeExecutable(named: "apple-cli-mcp", in: directory)
    let runner = DiscoveryCommandRunner { call in
      switch call.arguments {
      case ["--version"]:
        return .init(stdout: "apple-cli-mcp 1.0.0\n")
      case ["--help"]:
        return .init(stdout: "Commands: catalog doctor\n")
      case ["catalog"]:
        return .init(stdout: #"{"commands":["calendar.list"]}"#)
      default:
        Issue.record("Unexpected command: \(call.arguments)")
        return .init(exitCode: 64)
      }
    }
    let discovery = ExternalProviderDiscovery(
      definitions: [appleDefinition],
      commandRunner: runner,
      environment: ["PATH": directory.path],
      commonSearchDirectories: []
    )

    let result = try #require(discovery.discover().first)

    #expect((result.version) == ("apple-cli-mcp 1.0.0"))
    #expect((result.doctorStatus.state) == (.contractIncomplete))
    #expect((result.doctorStatus.missingCapabilities) == (["dry-run"]))
    #expect((result.diagnostics.last?.code) == (.contractIncomplete))
    #expect(!(runner.recordedCalls.contains { $0.arguments == ["doctor"] }))
  }

  @Test
  func testAppleCLIDoctorFailureIsReportedWithoutExecutingDomainOperations() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try makeExecutable(named: "apple-cli-mcp", in: directory)
    let runner = DiscoveryCommandRunner { call in
      switch call.arguments {
      case ["--version"]:
        return .init(stdout: "1.2.3\n")
      case ["--help"]:
        return .init(stdout: "Commands: catalog doctor\nOptions: --dry-run\n")
      case ["catalog"]:
        return .init(stdout: #"{"capabilities":["dry-run"]}"#)
      case ["doctor"]:
        return .init(stderr: "permission unavailable\n", exitCode: 2)
      default:
        Issue.record("Discovery must not execute domain operations: \(call.arguments)")
        return .init(exitCode: 64)
      }
    }
    let discovery = ExternalProviderDiscovery(
      definitions: [appleDefinition],
      commandRunner: runner,
      environment: ["PATH": directory.path],
      commonSearchDirectories: []
    )

    let result = try #require(discovery.discover().first)

    #expect((result.doctorStatus.state) == (.failed))
    #expect((result.doctorStatus.exitCode) == (2))
    #expect((result.diagnostics.last?.code) == (.doctorFailed))
    #expect(
      (runner.recordedCalls.map(\.arguments))
        == ([["--version"], ["--help"], ["catalog"], ["doctor"]]))
  }

  @Test
  func testAppleCLICompleteContractPassesDoctor() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try makeExecutable(named: "apple-cli-mcp", in: directory)
    let runner = DiscoveryCommandRunner { call in
      switch call.arguments {
      case ["--version"]:
        return .init(stdout: "apple-cli-mcp 3.0.0\n")
      case ["--help"]:
        return .init(stdout: "Commands: catalog doctor\n")
      case ["catalog"]:
        return .init(stdout: #"{"safety":{"supports_dry_run":true}}"#)
      case ["doctor"]:
        return .init(stdout: "ok\n")
      default:
        return .init(exitCode: 64)
      }
    }
    let discovery = ExternalProviderDiscovery(
      definitions: [appleDefinition],
      commandRunner: runner,
      environment: ["PATH": directory.path],
      commonSearchDirectories: []
    )

    let result = try #require(discovery.discover().first)

    #expect((result.doctorStatus.state) == (.passed))
    #expect((result.doctorStatus.exitCode) == (0))
    #expect((result.diagnostics) == ([]))
  }

  @Test
  func testConfiguredGatewayProviderTakesPriorityOverPATHAndCommonLocations() throws {
    let configuredDirectory = try makeTemporaryDirectory()
    let pathDirectory = try makeTemporaryDirectory()
    let commonDirectory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: configuredDirectory)
      try? FileManager.default.removeItem(at: pathDirectory)
      try? FileManager.default.removeItem(at: commonDirectory)
    }
    let configured = try makeExecutable(named: "custom-apple-provider", in: configuredDirectory)
    _ = try makeExecutable(named: "apple-cli-mcp", in: pathDirectory)
    _ = try makeExecutable(named: "apple-cli-mcp", in: commonDirectory)
    let configuration = GatewayConfiguration(
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "apple-cli-mcp",
          transport: .stdio,
          command: configured.path
        )
      ])
    )
    let runner = passingAppleRunner()
    let discovery = ExternalProviderDiscovery(
      configuration: configuration,
      definitions: [appleDefinition],
      commandRunner: runner,
      environment: ["PATH": pathDirectory.path],
      commonSearchDirectories: [commonDirectory]
    )

    let result = try #require(discovery.discover().first)

    #expect((result.resolvedPath) == (configured.resolvingSymlinksInPath().path))
    #expect(runner.recordedCalls.allSatisfy { $0.executable == result.resolvedPath })
  }

  @Test
  func testUnavailableInterpreterPreventsProbingOrSelectingADifferentExecutable() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configured = try makeExecutable(named: "configured-codex", in: directory)
    try "#!/usr/bin/env missing-runtime\n".write(to: configured, atomically: true, encoding: .utf8)
    _ = try makeExecutable(named: "codex", in: directory)
    let runner = DiscoveryCommandRunner()
    let discovery = ExternalProviderDiscovery(
      configuration: GatewayConfiguration(
        codex: CodexConfigurationImport(enabled: true, executable: configured.path)),
      definitions: [codexDefinition], commandRunner: runner,
      environment: ["PATH": directory.path], commonSearchDirectories: [])
    let result = try #require(discovery.discover().first)
    #expect(result.resolvedPath == configured.resolvingSymlinksInPath().path)
    #expect(result.doctorStatus.state == .unavailable)
    #expect(result.diagnostics.map(\.code) == [.executableUnavailable])
    #expect(runner.recordedCalls.isEmpty)
  }

  @Test
  func disabledMCPRegistrationDoesNotSelectItsExecutableForProviderProbes() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = try makeExecutable(named: "disabled-provider", in: directory)
    let runner = DiscoveryCommandRunner()
    let discovery = ExternalProviderDiscovery(
      configuration: .init(
        mcp: .init(servers: [
          .init(id: "apple-cli-mcp", transport: .stdio, command: executable.path, enabled: false)
        ])), definitions: [appleDefinition], commandRunner: runner,
      environment: ["PATH": ""], commonSearchDirectories: [])
    let result = try #require(discovery.discover().first)
    #expect(result.resolvedPath == nil)
    #expect(runner.recordedCalls.isEmpty)
  }

  @Test
  func testPATHTakesPriorityOverCommonLocations() throws {
    let pathDirectory = try makeTemporaryDirectory()
    let commonDirectory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: pathDirectory)
      try? FileManager.default.removeItem(at: commonDirectory)
    }
    let pathExecutable = try makeExecutable(named: "playwright-mcp", in: pathDirectory)
    _ = try makeExecutable(named: "playwright-mcp", in: commonDirectory)
    let runner = DiscoveryCommandRunner { _ in .init(stdout: "playwright-mcp 1.0\n") }
    let discovery = ExternalProviderDiscovery(
      definitions: [browserDefinition],
      commandRunner: runner,
      environment: ["PATH": pathDirectory.path],
      commonSearchDirectories: [commonDirectory]
    )

    let result = try #require(discovery.discover().first)

    #expect((result.resolvedPath) == (pathExecutable.resolvingSymlinksInPath().path))
  }

  @Test
  func testConfiguredCodexProviderUsesItsNarrowVersionDoctor() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = try makeExecutable(named: "codex", in: directory)
    let configuration = GatewayConfiguration(
      codex: CodexConfigurationImport(enabled: true, executable: executable.path)
    )
    let runner = DiscoveryCommandRunner { call in
      #expect((call.arguments) == (["--version"]))
      return .init(stdout: "codex-cli 2.0.0\n")
    }
    let discovery = ExternalProviderDiscovery(
      configuration: configuration,
      definitions: [codexDefinition],
      commandRunner: runner,
      environment: ["PATH": ""],
      commonSearchDirectories: []
    )

    let result = try #require(discovery.discover().first)

    #expect((result.kind) == (.codex))
    #expect((result.resolvedPath) == (executable.resolvingSymlinksInPath().path))
    #expect((result.version) == ("codex-cli 2.0.0"))
    #expect((result.doctorStatus.state) == (.passed))
    #expect((runner.recordedCalls.map(\.arguments)) == ([["--version"]]))
  }

  @Test(arguments: ["mcp", "cli"])
  func configuredContextIsUsedForEveryProbe(_ source: String) throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = root.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: false)
    let executable = try makeExecutable(named: "apple-cli-mcp", in: cwd)
    let overrides = [
      "PATH": "", "PROVIDER_SECRET": "fixture-secret", "OVERRIDE": "child", "EMPTY": "",
    ]
    var configuration = GatewayConfiguration(workspaceDirectory: root)
    if source == "mcp" {
      configuration.mcp.servers = [
        .init(
          id: "apple-cli-mcp", transport: .stdio,
          command: "./apple-cli-mcp", args: ["serve"], env: overrides, cwd: "child")
      ]
    } else {
      configuration.cli.commands = [
        .init(
          id: "apple-cli-mcp", executable: "./apple-cli-mcp",
          cwd: "child", env: overrides)
      ]
    }
    let runner = DiscoveryCommandRunner { call in
      #expect(call.executable == executable.path)
      #expect(call.workingDirectory?.path == cwd.path)
      #expect(call.environment["PROVIDER_SECRET"] == "fixture-secret")
      #expect(call.environment["OVERRIDE"] == "child")
      #expect(call.environment["INHERITED"] == "host")
      #expect(call.environment["EMPTY"] == "")
      #expect(call.environment["PATH"] == "")
      let arguments = source == "mcp" ? Array(call.arguments.dropFirst()) : call.arguments
      if source == "mcp" { #expect(call.arguments.first == "serve") }
      switch arguments {
      case ["--version"]: return .init(stdout: "fixture 1.0\n")
      case ["--help"]: return .init(stdout: "catalog doctor --dry-run\n")
      case ["catalog"]: return .init(stdout: "catalog doctor --dry-run\n")
      case ["doctor"]: return .init(stdout: "ok\n")
      default: return .init(exitCode: 64)
      }
    }
    let result = try #require(
      ExternalProviderDiscovery(
        configuration: configuration,
        definitions: [appleDefinition], commandRunner: runner,
        environment: ["PATH": "/bin", "OVERRIDE": "host", "INHERITED": "host", "EMPTY": "host"],
        commonSearchDirectories: []
      ).discover().first)
    #expect(result.doctorStatus.state == .passed)
    #expect(runner.recordedCalls.count == 4)
    #expect(
      !String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("fixture-secret"))
  }

  @Test(arguments: ["", "bin", ":bin"])
  func relativeAndEmptyPATHEntriesUseTheLaunchDirectory(_ path: String) throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
    let local = try makeExecutable(named: "codex", in: root)
    let nested = try makeExecutable(named: "codex", in: bin)
    let runner = DiscoveryCommandRunner { _ in .init(stdout: "fixture 1.0\n") }
    let discovery = ExternalProviderDiscovery(
      definitions: [codexDefinition],
      configuredProviders: [
        "codex": [
          .init(
            executable: "codex", workingDirectory: root,
            environment: ["PATH": path])
        ]
      ], commandRunner: runner,
      environment: ["PATH": "/unrelated"], configurationBaseDirectory: URL(fileURLWithPath: "/tmp"),
      commonSearchDirectories: [])
    let result = try #require(discovery.discover().first)
    #expect(result.resolvedPath == (path == "bin" ? nested.path : local.path))
    #expect(result.doctorStatus.state == .passed)
    #expect(runner.recordedCalls.first?.workingDirectory == root)
  }

  @Test(arguments: ["missing", "notExecutable", "directory"])
  func configuredFailureDoesNotProbeAnotherInstallation(_ failure: String) throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fallback = try makeExecutable(named: "codex", in: root)
    let selected = root.appendingPathComponent("selected")
    if failure == "notExecutable" {
      try Data("not executable".utf8).write(to: selected)
    } else if failure == "directory" {
      try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
    }
    let runner = DiscoveryCommandRunner()
    let result = try #require(
      ExternalProviderDiscovery(
        definitions: [codexDefinition],
        configuredProviders: [
          "codex": [.init(executable: selected.path), .init(executable: fallback.path)]
        ],
        commandRunner: runner, environment: ["PATH": root.path], commonSearchDirectories: [root]
      )
      .discover().first)
    #expect(result.doctorStatus.state == .unavailable)
    #expect(result.diagnostics.map(\.code) == [.executableUnavailable])
    #expect(result.resolvedPath != fallback.path)
    #expect(runner.recordedCalls.isEmpty)
  }

  @Test
  func configuredSymlinkRetainsItsLaunchName() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeExecutable(named: "actual", in: root)
    let link = root.appendingPathComponent("codex")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
    let runner = DiscoveryCommandRunner { _ in .init(stdout: "fixture 1.0\n") }
    let result = try #require(
      ExternalProviderDiscovery(
        definitions: [codexDefinition],
        configuredProviders: ["codex": [.init(executable: link.path)]], commandRunner: runner,
        commonSearchDirectories: []
      ).discover().first)
    #expect(result.resolvedPath == link.path)
    #expect(runner.recordedCalls.first?.executable == link.path)
  }

  @Test(arguments: [false, true], ExternalProviderKind.allCases)
  func truncatedVersionOutputCannotReportAHealthyProvider(
    _ stderr: Bool, _ kind: ExternalProviderKind
  ) throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = try makeExecutable(named: "codex", in: root)
    let runner = DiscoveryCommandRunner { _ in
      .init(stdout: "fixture 1.0\n", stdoutTruncated: !stderr, stderrTruncated: stderr)
    }
    let result = try #require(
      ExternalProviderDiscovery(
        definitions: [.init(id: "codex", kind: kind, executableNames: ["codex"])],
        configuredProviders: ["codex": [.init(executable: binary.path)]], commandRunner: runner,
        commonSearchDirectories: []
      ).discover().first)
    #expect(result.version == nil)
    #expect(result.doctorStatus.state == .failed)
    #expect(result.diagnostics.first?.message == "Version probe output was truncated.")
    #expect(runner.recordedCalls.map(\.arguments) == [["--version"]])
  }

  @Test(arguments: ["mcp", "cli"])
  func realScriptFindsItsInterpreterAndReadsItsRegisteredDirectory(_ source: String) async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cwd = root.appendingPathComponent("provider")
    let bin = cwd.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let executable = try makeExecutable(named: "probe", in: cwd)
    try """
    #!/usr/bin/env fixture-runtime
    [ "$PROVIDER_SECRET" = 'fixture-secret' ] || exit 12
    [ "${EMPTY+x}" = x ] && [ "$EMPTY" = '' ] || exit 13
    [ "$INHERITED" = host ] || exit 14
    \(source == "mcp" ? "[ \"$1\" = serve ] || exit 15; shift" : "")
    [ "$1" = --version ] && [ "$#" = 1 ] || exit 16
    /bin/cat version.txt
    """.appending("\n").write(to: executable, atomically: true, encoding: .utf8)
    let interpreter = try makeExecutable(named: "fixture-runtime", in: bin)
    try "#!/bin/sh\nexec /bin/sh \"$@\"\n".write(to: interpreter, atomically: true, encoding: .utf8)
    try Data("fixture 7.2\n".utf8).write(to: cwd.appendingPathComponent("version.txt"))
    let overrides = ["PATH": "bin", "PROVIDER_SECRET": "fixture-secret", "EMPTY": ""]
    var configuration = GatewayConfiguration(workspaceDirectory: root)
    if source == "mcp" {
      configuration.mcp.servers = [
        .init(
          id: "codex", transport: .stdio,
          command: "./probe", args: ["serve"], env: overrides, cwd: "provider")
      ]
    } else {
      configuration.cli.commands = [
        .init(id: "codex", executable: "./probe", cwd: "provider", env: overrides)
      ]
    }
    let discovery = ExternalProviderDiscovery(
      configuration: configuration,
      definitions: [codexDefinition],
      environment: ["PATH": "/unrelated", "EMPTY": "host", "INHERITED": "host"],
      commonSearchDirectories: [])
    let results = try await BlockingOperationExecutor(label: "test.provider-context").perform {
      try discovery.discover()
    }
    let result = try #require(results.first)
    #expect(result.resolvedPath == executable.path)
    #expect(result.version == "fixture 7.2")
    #expect(result.doctorStatus.state == .passed)
    #expect(result.diagnostics.isEmpty)
    #expect(
      !String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("fixture-secret"))
  }

  @Test
  func missingRegisteredInterpreterPreventsAllProbes() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeExecutable(named: "codex", in: root)
    try Data("#!/usr/bin/env fixture-runtime\nexit 0\n".utf8).write(to: executable)
    _ = try makeExecutable(named: "fixture-runtime", in: root)
    var configuration = GatewayConfiguration(workspaceDirectory: root)
    configuration.cli.commands = [
      .init(id: "codex", executable: "./codex", env: ["PATH": "missing-bin"])
    ]
    let runner = DiscoveryCommandRunner()
    let result = try #require(
      ExternalProviderDiscovery(
        configuration: configuration, definitions: [codexDefinition], commandRunner: runner,
        environment: ["PATH": root.path], commonSearchDirectories: [root]
      ).discover().first)
    #expect(result.resolvedPath == executable.path)
    #expect(result.doctorStatus.state == .unavailable)
    #expect(result.diagnostics.map(\.code) == [.executableUnavailable])
    #expect(result.version == nil)
    #expect(runner.recordedCalls.isEmpty)
  }

  @Test(arguments: ["--help", "catalog", "doctor"])
  func truncatedContractOutputDoesNotEstablishHealth(_ operation: String) throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeExecutable(named: "apple-cli-mcp", in: root)
    let runner = DiscoveryCommandRunner { call in
      .init(
        stdout: call.arguments == ["--version"] ? "fixture 1.0\n" : "catalog doctor --dry-run\n",
        stdoutTruncated: call.arguments == [operation])
    }
    let result = try #require(
      ExternalProviderDiscovery(
        definitions: [appleDefinition],
        configuredProviders: ["apple-cli-mcp": [.init(executable: executable.path)]],
        commandRunner: runner, commonSearchDirectories: []
      ).discover().first)
    #expect(result.doctorStatus.state != .passed)
    #expect(result.diagnostics.contains { $0.message.contains("truncated") })
    #expect(
      runner.recordedCalls.map(\.arguments)
        == (operation == "doctor"
          ? [["--version"], ["--help"], ["catalog"], ["doctor"]]
          : [["--version"], ["--help"], ["catalog"]]))
  }

  @Test(arguments: [nil, "", "workspace", "child", "/tmp/provider-absolute"] as [String?])
  func registeredDirectoryConventionsAreShared(_ cwd: String?) {
    let base = URL(fileURLWithPath: "/tmp/provider-base")
    let mcp = MCPServerConfig(id: "fixture", transport: .stdio, command: "probe", cwd: cwd)
    let cli = CLICommandConfig(id: "fixture", executable: "probe", cwd: cwd)
    #expect(mcp.resolvedWorkingDirectory(base: base) == cli.resolvedWorkingDirectory(base: base))
  }

  private var appleDefinition: ExternalProviderDefinition {
    ExternalProviderDefinition(
      id: "apple-cli-mcp",
      kind: .appleCLIMCP,
      executableNames: ["apple-cli-mcp"]
    )
  }

  private var browserDefinition: ExternalProviderDefinition {
    ExternalProviderDefinition(
      id: "browser",
      kind: .browser,
      executableNames: ["playwright-mcp"]
    )
  }

  private var tunnelDefinition: ExternalProviderDefinition {
    ExternalProviderDefinition(
      id: "tunnel-client",
      kind: .tunnelClient,
      executableNames: ["tunnel-client"]
    )
  }

  private var codexDefinition: ExternalProviderDefinition {
    ExternalProviderDefinition(
      id: "codex",
      kind: .codex,
      executableNames: ["codex"]
    )
  }

  private func passingAppleRunner() -> DiscoveryCommandRunner {
    DiscoveryCommandRunner { call in
      switch call.arguments {
      case ["--version"]:
        return .init(stdout: "1.0.0\n")
      case ["--help"]:
        return .init(stdout: "Commands: catalog doctor --dry-run\n")
      case ["catalog"]:
        return .init(stdout: #"{"dry-run":true}"#)
      case ["doctor"]:
        return .init(stdout: "ok\n")
      default:
        return .init(exitCode: 64)
      }
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.resolvingSymlinksInPath()
  }

  private func makeExecutable(named name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o755))],
      ofItemAtPath: url.path
    )
    return url
  }
}

private final class DiscoveryCommandRunner: CommandRunning, @unchecked Sendable {
  struct Call: Equatable, Sendable {
    var executable: String
    var arguments: [String]
    var workingDirectory: URL?
    var environment: [String: String]
  }

  struct Output: Equatable, Sendable {
    var stdout: String = ""
    var stderr: String = ""
    var exitCode: Int32? = 0
    var timedOut: Bool = false
    var stdoutTruncated: Bool = false
    var stderrTruncated: Bool = false
  }

  private let handler: @Sendable (Call) -> Output
  private let lock = NSLock()
  private var calls: [Call] = []

  init(handler: @escaping @Sendable (Call) -> Output = { _ in Output() }) {
    self.handler = handler
  }

  var recordedCalls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }

  func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult {
    let call = Call(
      executable: executable, arguments: arguments,
      workingDirectory: workingDirectory, environment: environment)
    lock.lock()
    calls.append(call)
    lock.unlock()
    let output = handler(call)
    return CommandResult(
      executable: executable,
      arguments: arguments,
      exitCode: output.exitCode,
      timedOut: output.timedOut,
      stdout: output.stdout,
      stderr: output.stderr,
      stdoutTruncated: output.stdoutTruncated,
      stderrTruncated: output.stderrTruncated
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
    let result = try run(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes
    )
    return CommandDataResult(
      executable: executable,
      arguments: arguments,
      exitCode: result.exitCode,
      timedOut: result.timedOut,
      stdout: Data(result.stdout.utf8),
      stderr: Data(result.stderr.utf8),
      stdoutTruncated: result.stdoutTruncated,
      stderrTruncated: result.stderrTruncated
    )
  }
}
