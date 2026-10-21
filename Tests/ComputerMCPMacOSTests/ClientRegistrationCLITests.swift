import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import Foundation
import Testing

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
    #expect(
      !refused.stdout.contains("PRIVATE_SENTINEL") && !refused.stderr.contains("PRIVATE_SENTINEL"))
    let again = try fixture.run(["install", client] + fixture.installOptions)
    #expect(again.exitCode == 0)
    #expect(try fixture.json(again)["steps"] == .array([]))
    let removed = try fixture.run(["uninstall", client, "--client-cli", fixture.client.path])
    #expect(removed.exitCode == 0)
    #expect(try fixture.json(removed)["final_state"] == .string("not_registered"))
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
