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
  func testResolvedProviderReportsCanonicalPathAndVersion() throws {
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
      codex: CodexConfig(enabled: true, executable: executable.path)
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
    return directory
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
  }

  struct Output: Equatable, Sendable {
    var stdout: String = ""
    var stderr: String = ""
    var exitCode: Int32? = 0
    var timedOut: Bool = false
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
    let call = Call(executable: executable, arguments: arguments)
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
      stdoutTruncated: false,
      stderrTruncated: false
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
