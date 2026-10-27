import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformPOSIX
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct StandaloneToolCommandTests {
  @Test(arguments: StandaloneToolCommandMode.allCases)
  func standaloneCommandsExposeRequirementsAndRespectSandboxExecution(
    mode: StandaloneToolCommandMode
  ) async throws {
    let fixture = try StandaloneToolCommandFixture()
    let profile = try GatewayConfiguration.load(path: fixture.manifest.path)
      .profileGrant(for: .localAdmin)
    #expect(!profile.fullAccess)
    #expect(profile.allowedCallers == [.localCLI])
    #expect(profile.permissions.state(for: .project("fixture")) == .granted(.read))
    #expect(profile.permissions.state(for: .mcpServer("owned")) == .granted(.read))
    let result = try await fixture.run(mode)
    #expect(!result.timedOut && !result.stdoutTruncated && !result.stderrTruncated)
    #expect(!FileManager.default.fileExists(atPath: fixture.started.path))
    switch mode {
    case .list, .inspect:
      try #require(result.exitCode == 0, "\(result.stderr)")
      let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
      let tool: JSONValue
      if mode == .list {
        let tools = try #require(value.objectValue?["tools"]?.arrayValue)
        tool = try #require(tools.first { $0.objectValue?["name"] == .string("mcp.tools.list") })
        #expect(!tools.contains { $0.objectValue?["name"] == .string("owned.inspect") })
      } else {
        tool = value
      }
      #expect(tool.objectValue?["name"] == .string("mcp.tools.list"))
      let metadata = try #require(
        tool.objectValue?["_meta"]?.objectValue?["computer_mcp"]?.objectValue?["requirements"])
      let requirement = try JSONDecoder().decode(
        ToolRequirement.self, from: JSONEncoder().encode(metadata))
      #expect(requirement.target == .mcp(server: .argument(name: "server"), access: .read))
      #expect(!requirement.requiresFullAccess)
    case .missing:
      #expect(result.exitCode == 64)
      #expect(result.stdout.isEmpty)
      #expect(result.stderr.contains("Unknown tool: owned.missing"))
    case .metadata:
      try #require(result.exitCode == 0, "\(result.stderr)")
      let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
      #expect(value.objectValue?["isError"] == .bool(false))
      let servers = try #require(
        value.objectValue?["structuredContent"]?.objectValue?["result"]?.arrayValue)
      #expect(servers.map { $0.objectValue?["id"] } == [.string("owned")])
      let execution = try #require(
        value.objectValue?["_meta"]?.objectValue?["computer_mcp"]?.objectValue)
      #expect(execution["caller"] == .string("local-cli"))
      #expect(execution["profile_id"] == .string("local-admin"))
      #expect(execution["project_id"] == .string("fixture"))
    case .discovery:
      #expect(result.exitCode == 1)
      #expect(result.stdout.isEmpty)
      #expect(
        result.stderr.contains("Execution requires a verified worktree and private Git context"),
        "\(result.stderr)")
      #expect(!result.stderr.contains("permission.required"))
      #expect(!result.stderr.contains("Unknown tool"))
    }
  }
}

enum StandaloneToolCommandMode: String, CaseIterable, Sendable {
  case list, inspect, missing, metadata, discovery
}

private final class StandaloneToolCommandFixture: @unchecked Sendable {
  private let files: ScopedTemporaryDirectory
  let root: URL
  let manifest: URL
  let started: URL
  private let executable: URL
  private let variables: [String: String]

  init() throws {
    let files = try ScopedTemporaryDirectory()
    self.files = files
    let root = try ProjectPathResolver.canonicalProject(files.url)
    self.root = root
    let manifest = root.appendingPathComponent("config.toml")
    self.manifest = manifest
    let started = root.appendingPathComponent("provider-started")
    self.started = started
    executable = try ProjectPathResolver.canonicalProject(nativeGatewayTestExecutable())
    let home = root.appendingPathComponent("home")
    let temporary = root.appendingPathComponent("tmp")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    variables = [
      "PATH": "/usr/bin:/bin", "HOME": home.path, "TMPDIR": temporary.path + "/",
      "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
      "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path, "LANG": "C", "LC_ALL": "C",
    ]
    let markerProgram = root.appendingPathComponent("start-marker.py")
    try Data(
      """
      import pathlib, sys
      pathlib.Path(sys.argv[1]).write_text("started")
      raise SystemExit("Unexpected fixture provider launch")
      """.utf8
    ).write(to: markerProgram)
    let grant = ProfileGrant(
      id: .localAdmin,
      permissions: fixturePermissions([
        .project("fixture"): .granted(.read), .mcpServer("owned"): .granted(.read),
      ]), allowedCallers: [.localCLI])
    let config = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: grant.id),
      projects: [.init(id: "fixture", path: root.path)], profiles: [.init(grant: grant)],
      mcp: .init(servers: [
        .init(
          id: "owned", transport: .stdio, command: "/usr/bin/python3",
          args: ["-I", markerProgram.path, started.path],
          exposure: .reexport, prefix: "owned", allowedTools: ["inspect"],
          requestTimeoutMs: 2000, toolRisks: ["inspect": .readOnly])
      ]), projectDirectory: root)
    try Data(config.exportedTOML().utf8).write(to: manifest)
  }

  func run(_ mode: StandaloneToolCommandMode) async throws -> CommandResult {
    let operation: [String]
    switch mode {
    case .list: operation = ["tools", "list"]
    case .inspect: operation = ["tools", "inspect", "mcp.tools.list"]
    case .missing: operation = ["tools", "inspect", "owned.missing"]
    case .metadata: operation = ["tools", "call", "mcp.servers.list", "--arguments-json", "{}"]
    case .discovery:
      operation = [
        "tools", "call", "mcp.tools.list", "--arguments-json",
        #"{"project_id":"fixture","server":"owned"}"#,
      ]
    }
    let arguments =
      operation + [
        "--config", manifest.path, "--caller", "local-cli", "--profile", "local-admin",
        "--project-id", "fixture",
      ]
    let result = try await BlockingOperationExecutor(label: "standalone-tool-test").perform {
      try #require(InvocationExecution.current == nil)
      try #require(
        try ProjectPathResolver.canonicalProject(nativeGatewayTestExecutable()) == self.executable)
      let administration = try ExecutionAdministration(
        mode: .fullAccess, environment: .init(fullAccessVariables: self.variables))
      return try ExecutionAdministration.$current.withValue(administration) {
        try ProcessCommandRunner(
          launcher: testExecutionLauncher(), environment: self.variables
        ).run(
          executable: self.executable.path, arguments: arguments, workingDirectory: self.root,
          environment: self.variables, timeoutMilliseconds: 8000, maxOutputBytes: 1_048_576)
      }
    }
    withExtendedLifetime(files) {}
    return result
  }
}
