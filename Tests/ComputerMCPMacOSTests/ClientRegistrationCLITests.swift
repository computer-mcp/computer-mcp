import ArgumentParser
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import computer_mcp

@Suite(.timeLimit(.minutes(2)))
struct ClientRegistrationCLITests {
  @Test(arguments: ["codex", "claude-code"])
  func dryRunConfirmationAndExpectedFingerprint(client: String) throws {
    let fixture = try RegistrationCLIFixture()
    let preview = try fixture.run(["install", client] + fixture.installOptions + ["--dry-run"])
    #expect(preview.exitCode == 0)
    let plan = try fixture.json(preview)
    #expect(plan["schema_version"] == .integer(1))
    #expect(plan["state"] == .string("not_registered"))
    #expect(plan["fingerprint"]?.stringValue?.count == 64)
    #expect(!FileManager.default.fileExists(atPath: fixture.configurationFile(client).path))
    try fixture.setEntry(client, command: "user-server", argument: "PRIVATE_SENTINEL")
    let refused = try fixture.run(["install", client] + fixture.installOptions)
    #expect(refused.exitCode == 1)
    let refusal = try fixture.json(refused)
    #expect(refusal["error_code"] == .string("confirmation_required"))
    let fingerprint = try #require(refusal["plan"]?.objectValue?["fingerprint"]?.stringValue)
    let bad = try fixture.run(
      ["install", client] + fixture.installOptions + ["--expect", "wrong"])
    #expect(bad.exitCode == 1 && bad.stdout.contains("changed_since_preview"))
    let applied = try fixture.run(
      ["install", client] + fixture.installOptions + ["--expect", fingerprint])
    #expect(applied.exitCode == 0 && applied.stdout.contains("succeeded"))
    #expect(try fixture.json(applied)["recovery"] == nil)
    #expect(
      !refused.stdout.contains("PRIVATE_SENTINEL") && !refused.stderr.contains("PRIVATE_SENTINEL"))
    let again = try fixture.run(["install", client] + fixture.installOptions)
    #expect(again.exitCode == 0)
    #expect(try fixture.json(again)["steps"] == .array([]))
    #expect(try fixture.json(again)["recovery"] == nil)
    let removed = try fixture.run(["uninstall", client, "--client-cli", fixture.client.path])
    #expect(removed.exitCode == 0)
    #expect(try fixture.json(removed)["final_state"] == .string("not_registered"))
    #expect(try fixture.json(removed)["recovery"] == nil)
  }

  @Test(arguments: ["codex", "claude-code"])
  func changedEntryInvalidatesReviewedCLIPlan(client: String) throws {
    let fixture = try RegistrationCLIFixture()
    try fixture.setEntry(client, command: "first", argument: "first-private")
    let preview = try fixture.json(
      fixture.run(["install", client] + fixture.installOptions + ["--dry-run"]))
    try fixture.setEntry(client, command: "second", argument: "second-private")
    let result = try fixture.run(
      ["install", client] + fixture.installOptions + [
        "--expect", try #require(preview["fingerprint"]?.stringValue),
      ])
    #expect(result.exitCode == 1 && result.stdout.contains("changed_since_preview"))
    #expect(try Data(contentsOf: fixture.configurationFile(client)).count > 0)
    #expect(!result.stdout.contains("second-private"))
  }

  @Test(arguments: ["codex_probe", "codex_read", "claude_probe"], ["reviewed", "uncertain"])
  func expectReportsUncertaintyBeforeComparingFingerprints(
    scenario: String, fingerprintSource: String
  ) throws {
    let fixture = try RegistrationCLIFixture()
    let client: RegistrationClient = scenario.hasPrefix("codex") ? .codex : .claudeCode
    let step = scenario.hasSuffix("probe") ? "probe" : "read"
    try fixture.setEntry(client.rawValue, command: "user-server", argument: "PRIVATE_SENTINEL")
    let runner = UnconfirmedCLIRegistrationRunner(step: step)
    let service = fixture.service(processRunner: runner)
    let server = ClientRegistrationCommand.app(
      executable: fixture.executable.path,
      socket: fixture.root.appendingPathComponent("gateway.sock").path)
    let reviewed = try (fingerprintSource == "reviewed" ? fixture.service() : service).preview(
      client: client, operation: .register, server: server, clientCLI: fixture.client.path)
    let options = try ClientRegistrationOptions.parse([
      "--client-cli", fixture.client.path, "--expect", reviewed.fingerprint,
    ])
    let before = try Data(contentsOf: fixture.configurationFile(client.rawValue))
    let count = runner.calls.count
    var output: [JSONValue] = []
    do {
      try options.run(
        client: client, operation: .register, server: server, service: service,
        output: { output.append($0) })
      Issue.record("An unconfirmed client process did not exit with code 2")
    } catch let code as ExitCode { #expect(code.rawValue == 2) }
    #expect(output.count == 1)
    let result = try #require(output.first?.objectValue)
    #expect(result["outcome"] == .string("uncertain"))
    #expect(result["error_code"] == .string("uncertain"))
    #expect(result["recovery"] == nil)
    #expect(result["final_state"] == .string(step == "probe" ? "unavailable" : "unreadable"))
    #expect(
      result["steps"]
        == .array([.object(["step": .string(step), "outcome": .string("uncertain")])]))
    #expect(runner.calls.count - count == (step == "probe" ? 1 : 2))
    #expect(try Data(contentsOf: fixture.configurationFile(client.rawValue)) == before)
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("state").path))
    #expect(
      !String(decoding: try JSONEncoder().encode(output), as: UTF8.self).contains(
        "PRIVATE_SENTINEL"))
  }

  @Test(arguments: [false, true], [false, true])
  func recoveryJSONReportsTheObservedEntry(writesEntry: Bool, timedOut: Bool) throws {
    let fixture = try RegistrationCLIFixture()
    try fixture.setEntry("claude-code", command: "user-server", argument: "PRIVATE_SENTINEL")
    let service = fixture.service(
      processRunner: RecoveryCLIRegistrationRunner(writesEntry: writesEntry, timedOut: timedOut))
    let server = ClientRegistrationCommand.app(
      executable: fixture.executable.path,
      socket: fixture.root.appendingPathComponent("gateway.sock").path)
    let plan = try service.preview(
      client: .claudeCode, operation: .register, server: server, clientCLI: fixture.client.path)
    let options = try ClientRegistrationOptions.parse([
      "--client-cli", fixture.client.path, "--expect", plan.fingerprint,
    ])
    var output: [JSONValue] = []
    do {
      try options.run(
        client: .claudeCode, operation: .register, server: server, service: service,
        output: { output.append($0) })
      Issue.record("A failed replacement did not exit with code 1")
    } catch let code as ExitCode { #expect(code.rawValue == 1) }
    #expect(output.count == 1)
    let result = try #require(output.first?.objectValue)
    #expect(result["outcome"] == .string("failed"))
    #expect(result["recovery"] == .string(writesEntry ? "restored" : "not_restored"))
    #expect(
      result["steps"]?.arrayValue?.last?.objectValue?["outcome"]
        == .string(timedOut ? "timed_out" : "failed"))
    let json = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
    #expect(!json.contains("PRIVATE_SENTINEL") && !json.contains("OUTSIDE_SENTINEL"))
  }

  @Test(arguments: ["codex", "claude-code"])
  func removalDoesNotNeedTheManifestOrServerExecutable(client: String) throws {
    let fixture = try RegistrationCLIFixture()
    try fixture.setEntry(
      client, command: fixture.root.appendingPathComponent("deleted-server").path,
      argument: fixture.root.appendingPathComponent("deleted.toml").path)
    let base = ["uninstall", client, "--client-cli", fixture.client.path]
    let unconfirmed = try fixture.run(base)
    #expect(unconfirmed.exitCode == 1)
    let plan = try fixture.json(fixture.run(base + ["--dry-run"]))
    #expect(plan["state"] == .string("different"))
    let result = try fixture.run(
      base + ["--expect", try #require(plan["fingerprint"]?.stringValue)])
    #expect(result.exitCode == 0)
  }

  @Test(arguments: [
    ["install", "codex"],
    ["install", "codex", "--app", "--config", "nonexistent"],
    ["install", "codex", "--config", "nonexistent", "--socket", "socket"],
    ["install", "claude-desktop", "--app", "--client-cli", "/bin/echo"],
    ["uninstall", "codex", "--config", "nonexistent"],
    ["uninstall", "codex", "--server-executable", "nonexistent"],
  ])
  func validatesOptions(arguments: [String]) throws {
    let fixture = try RegistrationCLIFixture()
    let result = try fixture.run(arguments)
    #expect(result.exitCode == 64)
  }

  @Test
  func standaloneManifestIsValidatedAndItsPathIsAbsolute() throws {
    let fixture = try RegistrationCLIFixture()
    let manifest = fixture.root.appendingPathComponent("server.toml")
    try Data("invalid = [".utf8).write(to: manifest)
    let base = [
      "install", "codex", "--client-cli", fixture.client.path, "--config", manifest.path,
      "--dry-run",
    ]
    #expect(try fixture.run(base).exitCode != 0)
    try Data("schema_version = 1\n".utf8).write(to: manifest)
    let plan = try fixture.json(fixture.run(base))
    #expect(
      plan["server"]?.objectValue?["arguments"]
        == .array(["serve", "stdio", "--config", manifest.path].map(JSONValue.string)))
  }
}

private struct RegistrationCLIFixture {
  let temporary: ScopedTemporaryDirectory
  var root: URL { temporary.url }
  let executable: URL
  var client: URL { root.appendingPathComponent("fake-client") }
  var installOptions: [String] {
    ["--app", "--client-cli", client.path, "--server-executable", executable.path]
  }

  init() throws {
    temporary = try ScopedTemporaryDirectory()
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    executable = repository.appendingPathComponent(".build/debug/computer-mcp")
      .resolvingSymlinksInPath()
    _ = try #require(FileManager.default.isExecutableFile(atPath: executable.path))
    try Data().write(to: root.appendingPathComponent(".registration-fixture"))
    try FileManager.default.copyItem(
      at: repository.appendingPathComponent(
        "Tests/ComputerMCPMacOSTests/Fixtures/registration-client.py"), to: client)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: client.path)
  }

  func configurationFile(_ client: String) -> URL {
    root.appendingPathComponent(
      client == "codex" ? "codex/fixture-mcp.json" : "claude/.claude.json")
  }
  func service(processRunner: any RegistrationProcessRunning = RegistrationProcessRunner())
    -> ClientRegistrationService
  {
    ClientRegistrationService(
      homeDirectory: root, stateDirectory: root.appendingPathComponent("state"),
      executableSearchDirectories: [],
      environment: [
        "CODEX_HOME": root.appendingPathComponent("codex").path,
        "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path,
        "USER": "fixture", "TMPDIR": root.path,
      ], processRunner: processRunner)
  }
  func setEntry(_ client: String, command: String, argument: String) throws {
    let file = configurationFile(client)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(
      JSONValue.object([
        "other": .string("OUTSIDE_SENTINEL"),
        "mcpServers": .object([
          "computer-mcp": .object([
            "type": .string("stdio"), "command": .string(command),
            "args": .array([.string(argument)]), "env": .object([:]),
          ])
        ]),
      ])
    ).write(to: file)
  }
  func run(_ arguments: [String]) throws -> CommandResult {
    try RegistrationProcessRunner().run(
      executable: executable.path, arguments: arguments,
      environment: [
        "HOME": root.path, "USER": "fixture", "LOGNAME": "fixture", "LANG": "C",
        "TMPDIR": root.path,
        "PATH": "/usr/bin:/bin", "CODEX_HOME": root.appendingPathComponent("codex").path,
        "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path,
      ],
      timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576)
  }
  func json(_ result: CommandResult) throws -> [String: JSONValue] {
    try #require(JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8)).objectValue)
  }
}

private struct RecoveryCLIRegistrationRunner: RegistrationProcessRunning {
  let writesEntry: Bool
  let timedOut: Bool

  func run(
    executable: String, arguments: [String], environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    let restore = arguments.contains("add-json")
    if !arguments.contains("add"), !restore || writesEntry {
      let result = try RegistrationProcessRunner().run(
        executable: executable, arguments: arguments, environment: environment,
        timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
      if !restore { return result }
    }
    return .init(
      executable: executable, arguments: arguments, exitCode: 1, timedOut: restore && timedOut,
      stdout: "PRIVATE_SENTINEL", stderr: "PRIVATE_SENTINEL", stdoutTruncated: false,
      stderrTruncated: false)
  }
}

private final class UnconfirmedCLIRegistrationRunner: RegistrationProcessRunning,
  @unchecked Sendable
{
  let step: String
  private let lock = NSLock()
  private var recorded: [[String]] = []
  var calls: [[String]] { lock.withLock { recorded } }

  init(step: String) { self.step = step }

  func run(
    executable: String, arguments: [String], environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    lock.withLock { recorded.append(arguments) }
    if step == "probe" ? arguments == ["--version"] : arguments.contains("get") {
      return .init(
        executable: executable, arguments: arguments, exitCode: nil, timedOut: true,
        stdout: "PRIVATE_SENTINEL", stderr: "PRIVATE_SENTINEL", stdoutTruncated: false,
        stderrTruncated: false)
    }
    return try RegistrationProcessRunner().run(
      executable: executable, arguments: arguments, environment: environment,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
  }
}
