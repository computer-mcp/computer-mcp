import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPControlPlane

@Suite(.timeLimit(.minutes(2)))
struct ClientRegistrationTests {
  @Test(arguments: RegistrationClient.allCases)
  func fiveStates(client: RegistrationClient) throws {
    let fixture = try RegistrationFixture()
    let service = fixture.service()
    #expect(try fixture.preview(client, service: service).display.state == .notRegistered)
    try fixture.setEntry(fixture.expectedEntry(client), client: client)
    #expect(try fixture.preview(client, service: service).display.state == .registered)
    try fixture.setEntry(
      .object(["command": .string("earlier-app"), "args": .array([])]), client: client)
    #expect(try fixture.preview(client, service: service).display.state == .different)
    try Data("[]".utf8).write(to: fixture.file(client))
    #expect(try fixture.preview(client, service: service).display.state == .unreadable)
    #expect(
      try fixture.preview(client, service: fixture.service(installed: false)).display.state
        == .unavailable)
  }

  @Test(arguments: RegistrationClient.allCases, ["arguments", "moved", "symlink"])
  func comparisonUsesExactStrings(client: RegistrationClient, difference: String) throws {
    let fixture = try RegistrationFixture()
    let link = fixture.root.appendingPathComponent("server-link")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: fixture.serverExecutable)
    let command =
      difference == "moved"
      ? fixture.root.appendingPathComponent("Old App/server").path
      : difference == "symlink" ? link.path : fixture.server.executable
    let entry: JSONValue = .object([
      "type": .string("stdio"), "command": .string(command),
      "args": .array(
        (difference == "arguments" ? ["bridge", "--old"] : fixture.server.arguments).map(
          JSONValue.string)),
    ])
    try fixture.setEntry(entry, client: client)
    #expect(try fixture.preview(client).display.state == .different)
  }

  @Test(arguments: [Int32(1), 2, 0], [false, true])
  func codexAbsenceRequiresThePositiveDiagnostic(code: Int32, diagnostic: Bool) throws {
    let fixture = try RegistrationFixture()
    fixture.runner.intercept = { call in
      guard call.arguments.contains("get") else { return nil }
      return .init(
        code: code,
        stderr: diagnostic ? "Error: No MCP server named fixture found." : "some failure")
    }
    let state = try fixture.preview(.codex).display.state
    #expect(state == (code == 1 && diagnostic ? .notRegistered : .unreadable))
  }

  @Test(arguments: [
    "timeout", "stdout_limit", "stderr_limit", "json", "shape", "launch", "uncertain",
  ])
  func codexReadFailuresAreUnreadable(failure: String) throws {
    let fixture = try RegistrationFixture()
    fixture.runner.intercept = { call in
      guard call.arguments.contains("get") else { return nil }
      if failure == "launch" { throw CommandRunnerError.launchFailed("PRIVATE_SENTINEL") }
      return .init(
        code: failure == "uncertain" ? nil : 0,
        stdout: failure == "shape" ? "{}" : "PRIVATE_SENTINEL",
        timedOut: failure == "timeout", stdoutTruncated: failure == "stdout_limit",
        stderrTruncated: failure == "stderr_limit")
    }
    let plan = try fixture.preview(.codex)
    #expect(plan.display.state == .unreadable)
    #expect(plan.display.refusalCode == (failure == "uncertain" ? .uncertain : .unreadable))
    #expect(!String(describing: plan).contains("PRIVATE_SENTINEL"))
  }

  @Test(
    arguments: ["codex_probe", "codex_read", "claude_probe"],
    ["success", "failed", "timed_out", "unconfirmed", "unconfirmed_timeout"])
  func statusesPreserveProcessUncertainty(scenario: String, outcome: String) throws {
    let fixture = try RegistrationFixture()
    let client: RegistrationClient = scenario.hasPrefix("codex") ? .codex : .claudeCode
    let probe = scenario.hasSuffix("probe")
    let unconfirmed = outcome.hasPrefix("unconfirmed")
    try FileManager.default.copyItem(
      at: fixture.clientExecutable,
      to: fixture.root.appendingPathComponent(client == .codex ? "codex" : "claude"))
    try fixture.setEntry(fixture.expectedEntry(client), client: client)
    fixture.runner.intercept = { call in
      guard outcome != "success",
        probe ? call.arguments == ["--version"] : call.arguments.contains("get")
      else { return nil }
      return .init(
        code: unconfirmed ? nil : 1, stderr: "PRIVATE_SENTINEL",
        timedOut: outcome == "timed_out" || outcome == "unconfirmed_timeout")
    }
    let statuses = try fixture.service().statuses(server: fixture.server)
    let status = try #require(statuses.first { $0.client == client })
    #expect(status.uncertain == unconfirmed)
    #expect(
      status.state == (outcome == "success" ? .registered : probe ? .unavailable : .unreadable))
    #expect(statuses.filter { $0.client != client }.allSatisfy { !$0.uncertain })
    let json = try JSONValue.encoded(status)
    #expect(json.objectValue?["uncertain"] == .bool(unconfirmed))
    #expect(
      fixture.runner.calls.count == (probe && outcome != "success" ? 1 : client == .codex ? 2 : 1))
    #expect(
      !String(decoding: try JSONEncoder().encode(statuses), as: UTF8.self).contains(
        "PRIVATE_SENTINEL"))
  }

  @Test(arguments: ["codex_probe", "codex_read", "claude_probe"], [false, true])
  func applyRecheckUncertaintyPrecedesStaleness(scenario: String, existing: Bool) throws {
    let fixture = try RegistrationFixture()
    let client: RegistrationClient = scenario.hasPrefix("codex") ? .codex : .claudeCode
    let step = scenario.hasSuffix("probe") ? "probe" : "read"
    if existing {
      try fixture.setEntry(
        .object([
          "type": .string("stdio"), "command": .string("old-server"),
          "args": .array([.string("PRIVATE_SENTINEL")]),
        ]), client: client)
    }
    let service = fixture.service()
    let plan = try fixture.preview(client, service: service)
    let before = try? Data(contentsOf: fixture.file(client))
    let count = fixture.runner.calls.count
    fixture.runner.intercept = { call in
      if step == "probe" ? call.arguments == ["--version"] : call.arguments.contains("get") {
        return .init(code: nil, stderr: "PRIVATE_SENTINEL", timedOut: true)
      }
      return nil
    }
    let result = try service.apply(plan)
    #expect(result.outcome == .uncertain && result.errorCode == .uncertain)
    #expect(result.recovery == nil)
    #expect(result.steps == [.init(step: step, outcome: .uncertain, exitCode: nil)])
    #expect(result.finalState == plan.display.state)
    #expect(result.finalEntry == plan.display.observedEntry)
    #expect(fixture.runner.calls.count - count == (step == "probe" ? 1 : 2))
    #expect((try? Data(contentsOf: fixture.file(client))) == before)
    #expect(
      !String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(
        "PRIVATE_SENTINEL"))
  }

  @Test(arguments: ["codex_probe", "codex_read", "claude_probe"])
  func uncertainPreviewIsTerminal(scenario: String) throws {
    let fixture = try RegistrationFixture()
    let client: RegistrationClient = scenario.hasPrefix("codex") ? .codex : .claudeCode
    let step = scenario.hasSuffix("probe") ? "probe" : "read"
    fixture.runner.intercept = { call in
      if step == "probe" ? call.arguments == ["--version"] : call.arguments.contains("get") {
        return .init(code: nil, timedOut: true)
      }
      return nil
    }
    let service = fixture.service()
    let plan = try fixture.preview(client, service: service)
    #expect(plan.display.refusalCode == .uncertain)
    let count = fixture.runner.calls.count
    let result = try service.apply(plan)
    #expect(result.outcome == .uncertain && result.errorCode == .uncertain)
    #expect(result.recovery == nil)
    #expect(result.steps == [.init(step: step, outcome: .uncertain, exitCode: nil)])
    #expect(result.finalState == plan.display.state)
    #expect(fixture.runner.calls.count == count)
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("state").path))
  }

  @Test(
    arguments: [RegistrationClient.codex, .claudeCode],
    ["probe", "interpreter", "directory", "missing"])
  func unusableClientsAreUnavailable(client: RegistrationClient, failure: String) throws {
    let fixture = try RegistrationFixture()
    var executable = fixture.clientExecutable
    if failure == "probe" {
      fixture.runner.intercept = { call in call.arguments == ["--version"] ? .init(code: 1) : nil }
    } else if failure == "interpreter" {
      try Data("#!/nonexistent/registration-interpreter\n".utf8).write(to: executable)
      return try assertUnavailableWithRealRunner(fixture, client, executable)
    } else if failure == "directory" {
      executable = fixture.root
    } else {
      executable = fixture.root.appendingPathComponent("missing")
    }
    let plan = try fixture.service().preview(
      client: client, operation: .register, server: fixture.server, clientCLI: executable.path)
    #expect(plan.display.state == .unavailable)
  }

  private func assertUnavailableWithRealRunner(
    _ fixture: RegistrationFixture, _ client: RegistrationClient, _ executable: URL
  ) throws {
    let service = ClientRegistrationService(
      homeDirectory: fixture.root, stateDirectory: fixture.root.appendingPathComponent("state"),
      executableSearchDirectories: [], environment: [:])
    #expect(
      try service.preview(
        client: client, operation: .register, server: fixture.server, clientCLI: executable.path
      ).display.state == .unavailable)
  }

  @Test(arguments: [RegistrationClient.codex, .claudeCode], [false, true])
  func locationAndEnvironmentStayBound(client: RegistrationClient, override: Bool) throws {
    let fixture = try RegistrationFixture()
    let variable = client == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
    let directory = fixture.root.appendingPathComponent("override")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let environment =
      override ? [variable: directory.path, "PRIVATE_SENTINEL": "secret", "PATH": "ignored"] : [:]
    let service = fixture.service(environment: environment)
    let plan = try fixture.preview(client, service: service)
    let result = try service.apply(plan)
    #expect(result.outcome == .succeeded)
    #expect(
      plan.display.location.configurationFile.hasPrefix(
        override ? directory.path : fixture.root.path))
    let expected = Set(
      ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "PATH"]
        + (override || client == .codex ? [variable] : []))
    for call in fixture.runner.calls {
      #expect(Set(call.environment.keys) == expected)
      #expect(call.environment["HOME"] == fixture.root.path)
      #expect(
        call.environment[variable]
          == (override
            ? directory.path
            : client == .codex ? fixture.root.appendingPathComponent(".codex").path : nil))
      #expect(call.environment["PATH"]?.hasPrefix(fixture.root.path + ":") == true)
    }
    let later = fixture.service(environment: [
      variable: fixture.root.appendingPathComponent("other").path
    ])
    #expect(throws: ClientRegistrationError.self) { try later.apply(plan) }
    // An already registered plan applied by a differently configured service still uses its binding.
    let retained = try fixture.preview(client, service: service)
    #expect(try later.apply(retained).outcome == .succeeded)
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("other").path))
  }

  @Test
  func executableDiscoveryUsesHostDirectoriesThenLocalBin() throws {
    let fixture = try RegistrationFixture()
    let local = fixture.root.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let codex = local.appendingPathComponent("codex")
    try FileManager.default.copyItem(at: fixture.clientExecutable, to: codex)
    let service = ClientRegistrationService(
      homeDirectory: fixture.root, stateDirectory: fixture.root.appendingPathComponent("state"),
      executableSearchDirectories: [], environment: ["PATH": "/not-used"],
      processRunner: fixture.runner)
    #expect(
      try service.preview(client: .codex, operation: .register, server: fixture.server).contents
        .clientExecutable == codex.path)
    let preferred = fixture.root.appendingPathComponent("codex")
    try FileManager.default.copyItem(at: fixture.clientExecutable, to: preferred)
    #expect(
      try fixture.service().preview(client: .codex, operation: .register, server: fixture.server)
        .contents.clientExecutable == preferred.path)
    #expect(
      try service.preview(
        client: .codex, operation: .register, server: fixture.server,
        clientCLI: fixture.clientExecutable.path
      ).contents.clientExecutable == fixture.clientExecutable.path)
  }

  @Test(arguments: [RegistrationClient.codex, .claudeCode])
  func fakeClientPrintsOnlyTheAllowedEnvironment(client: RegistrationClient) throws {
    let fixture = try RegistrationFixture()
    let source = fixture.root.appendingPathComponent("environment-client.c")
    try Data(
      """
      #include <stdio.h>
      #include <string.h>
      extern char **environ;
      int main(int argc, char **argv) {
        if (argc == 2 && strcmp(argv[1], "--version") == 0) {
          for (char **p = environ; *p; ++p) puts(*p);
          return 0;
        }
        fputs("No MCP server named computer-mcp", stderr);
        return 1;
      }
      """.utf8
    ).write(to: source)
    let compiled = try RegistrationProcessRunner().run(
      executable: "/usr/bin/env",
      arguments: ["cc", source.path, "-o", fixture.clientExecutable.path],
      environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/bin"],
      timeoutMilliseconds: 10_000, maxOutputBytes: 16_384)
    #expect(compiled.exitCode == 0)
    let runner = EnvironmentRegistrationRunner()
    let variable = client == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
    let service = ClientRegistrationService(
      homeDirectory: fixture.root, stateDirectory: fixture.root.appendingPathComponent("state"),
      executableSearchDirectories: [],
      environment: [
        variable: fixture.root.path, "PRIVATE_SENTINEL": "not inherited", "PATH": "ignored",
      ],
      processRunner: runner)
    _ = try service.preview(
      client: client, operation: .register, server: fixture.server,
      clientCLI: fixture.clientExecutable.path)
    let environment = try #require(runner.versionEnvironment)
    #expect(
      Set(environment.keys) == Set(["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "PATH", variable]))
    #expect(environment[variable] == fixture.root.path)
    #expect(
      environment["PATH"] == fixture.root.path + ":"
        + fixture.root.appendingPathComponent(".local/bin").path)
  }

  @Test(arguments: RegistrationClient.allCases)
  func fingerprintIncludesValuesThatTheDisplayOmits(client: RegistrationClient) throws {
    let fixture = try RegistrationFixture()
    let first: JSONValue = .object([
      "type": .string("stdio"), "command": .string("user-server"),
      "args": .array([.string("first-private")]),
      "env": .object(["TOKEN": .string("first-secret")]),
    ])
    let second: JSONValue = .object([
      "type": .string("stdio"), "command": .string("user-server"),
      "args": .array([.string("second-private")]),
      "env": .object(["TOKEN": .string("second-secret")]),
    ])
    try fixture.setEntry(first, client: client)
    let reviewed = try fixture.preview(client)
    try fixture.setEntry(second, client: client)
    let changed = try fixture.preview(client)
    #expect(reviewed.display.observedEntry == changed.display.observedEntry)
    #expect(reviewed.fingerprint != changed.fingerprint)
  }

  @Test(arguments: RegistrationClient.allCases)
  func fingerprintsBindTheEntryAndRegistrationIsIdempotent(client: RegistrationClient) throws {
    let fixture = try RegistrationFixture()
    let service = fixture.service()
    let missing = try fixture.preview(client, service: service)
    #expect(missing.fingerprint.count == 64)
    #expect(try fixture.preview(client, service: service).fingerprint == missing.fingerprint)
    try fixture.setEntry(fixture.expectedEntry(client), client: client)
    #expect(throws: ClientRegistrationError.self) { try service.apply(missing) }
    let plan = try fixture.preview(client, service: service)
    #expect(plan.display.actions.isEmpty)
    let before = fixture.runner.calls.count
    let result = try service.apply(plan)
    #expect(result.outcome == .succeeded && result.steps.isEmpty)
    #expect(result.recovery == nil)
    #expect(
      fixture.runner.calls.dropFirst(before).allSatisfy {
        $0.arguments == ["--version"] || $0.arguments.contains("get")
      })
    var entry = fixture.expectedEntry(client).objectValue!
    entry["env"] = .object(["TOKEN": .string("changed private value")])
    try fixture.setEntry(.object(entry), client: client)
    let changed = try fixture.preview(client, service: service)
    #expect(changed.fingerprint != plan.fingerprint)
  }

  @Test
  func desktopRefusesUnrelatedInPlaceChangesAfterPreview() throws {
    let fixture = try RegistrationFixture()
    let file = fixture.file(.claudeDesktop)
    try Data("{\"theme\":\"dark\" }".utf8).write(to: file)
    let service = fixture.service()
    let plan = try fixture.preview(.claudeDesktop, service: service)
    let before = try RegistrationJSONFile.read(file.path)
    let changedBytes = Data("{\"theme\":\"light\"}".utf8)
    let handle = try FileHandle(forWritingTo: file)
    try handle.write(contentsOf: changedBytes)
    try handle.close()
    let after = try RegistrationJSONFile.read(file.path)
    #expect(after.bytes != before.bytes)
    #expect(after.inode == before.inode)
    #expect(after.mode == before.mode)
    #expect(after.size == before.size)
    let fresh = try fixture.preview(.claudeDesktop, service: service)
    #expect(fresh.display.state == plan.display.state)
    #expect(fresh.display.observedEntry == plan.display.observedEntry)
    #expect(fresh.fingerprint != plan.fingerprint)
    do {
      _ = try service.apply(plan)
      Issue.record("Applied a plan after an unrelated file change")
    } catch let error as ClientRegistrationError { #expect(error.code == .changedSincePreview) }
    #expect(try Data(contentsOf: file) == changedBytes)
  }

  @Test
  func desktopRefusesFileCreationAfterPreview() throws {
    let fixture = try RegistrationFixture()
    let file = fixture.file(.claudeDesktop)
    let service = fixture.service()
    let plan = try fixture.preview(.claudeDesktop, service: service)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let changedBytes = Data("{\"theme\":\"light\"}".utf8)
    try changedBytes.write(to: file)
    let fresh = try fixture.preview(.claudeDesktop, service: service)
    #expect(fresh.display.state == plan.display.state)
    #expect(fresh.display.observedEntry == plan.display.observedEntry)
    #expect(fresh.fingerprint != plan.fingerprint)
    do {
      _ = try service.apply(plan)
      Issue.record("Applied a plan after the configuration file appeared")
    } catch let error as ClientRegistrationError { #expect(error.code == .changedSincePreview) }
    #expect(try Data(contentsOf: file) == changedBytes)
  }

  @Test(arguments: ["edit", "appearance", "disappearance"])
  func desktopRefusesFileChangesBeforeWriterSnapshot(change: String) throws {
    let fixture = try RegistrationFixture()
    let file = fixture.file(.claudeDesktop)
    if change != "appearance" {
      try Data("{\"theme\":\"dark\" }".utf8).write(to: file)
    }
    let changedBytes = Data("{\"theme\":\"light\"}".utf8)
    let service = ClientRegistrationService(
      homeDirectory: fixture.root, stateDirectory: fixture.root.appendingPathComponent("state"),
      executableSearchDirectories: [], environment: [:], processRunner: fixture.runner,
      desktop: .init(
        configurationFile: file, isInstalled: { true },
        isRunning: {
          // The writer checks running state after the fingerprint recheck, before its snapshot.
          do {
            if change == "disappearance" {
              if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
              }
            } else {
              try changedBytes.write(to: file)
            }
          } catch { Issue.record(error) }
          return false
        }))
    let plan = try fixture.preview(.claudeDesktop, service: service)
    do {
      _ = try service.apply(plan)
      Issue.record("Applied a plan after the configuration file changed")
    } catch let error as ClientRegistrationError { #expect(error.code == .changedSincePreview) }
    if change == "disappearance" {
      #expect(!FileManager.default.fileExists(atPath: file.path))
    } else {
      #expect(try Data(contentsOf: file) == changedBytes)
    }
  }

  @Test(arguments: RegistrationClient.allCases)
  func displayAndDiagnosticsExcludePrivateValues(client: RegistrationClient) throws {
    let fixture = try RegistrationFixture()
    let sentinels = [
      "ARG_SENTINEL", "USERINFO_SENTINEL", "PATH_SENTINEL", "QUERY_SENTINEL", "FRAGMENT_SENTINEL",
      "ENV_SENTINEL", "HEADER_SENTINEL", "OUTSIDE_SENTINEL",
    ]
    let entry: JSONValue = .object([
      "type": .string("http"), "command": .string("user-command"),
      "args": .array([.string(sentinels[0])]),
      "url": .string(
        "https://USERINFO_SENTINEL:password@example.test:8443/PATH_SENTINEL?QUERY_SENTINEL#FRAGMENT_SENTINEL"
      ),
      "env": .object(["TOKEN": .string(sentinels[5])]),
      "headers": .object(["Authorization": .string(sentinels[6])]),
    ])
    try fixture.setEntry(entry, client: client, outside: sentinels[7])
    let plan = try fixture.preview(client)
    let display = String(decoding: try JSONEncoder().encode(plan.display), as: UTF8.self)
    let representations =
      display + String(describing: plan) + String(reflecting: plan)
      + String(reflecting: Mirror(reflecting: plan))
    for sentinel in sentinels { #expect(!representations.contains(sentinel)) }
    if client == .claudeDesktop {
      let digest = try #require(plan.contents.observation.fileSHA256)
      #expect(!representations.contains(digest))
    }
    #expect(plan.display.observedEntry?.urlOrigin == "https://example.test:8443")
    #expect(plan.display.observedEntry?.environmentNames == ["TOKEN"])
    #expect(plan.display.observedEntry?.headerNames == ["Authorization"])
    #expect(!String(describing: plan.contents.observation.entry).contains("OUTSIDE_SENTINEL"))
    #expect(display.contains("argument_count") && !display.contains("argumentCount"))
    let first = plan.fingerprint
    try fixture.setEntry(entry, client: client, outside: "a different outside value")
    let changed = try fixture.preview(client).fingerprint
    if client == .claudeDesktop {
      #expect(changed != first)
    } else {
      #expect(changed == first)
    }
  }

  @Test(arguments: ["add", "remove"], ["nonzero", "launch", "timeout", "uncertain", "committed"])
  func claudeReplacementReconcilesFailures(step: String, failure: String) throws {
    let fixture = try RegistrationFixture()
    let original: JSONValue = .object([
      "type": .string("stdio"), "command": .string("old-server"),
      "args": .array([.string("PRIVATE_SENTINEL")]),
      "env": .object(["TOKEN": .string("PRIVATE_SENTINEL")]),
    ])
    try fixture.setEntry(original, client: .claudeCode)
    fixture.runner.intercept = { call in
      guard call.arguments.dropFirst().first == step else { return nil }
      if failure == "launch" { throw CommandRunnerError.launchFailed("PRIVATE_SENTINEL") }
      if failure == "committed" {
        _ = try RegistrationFixture.perform(call)
      }
      return .init(
        code: failure == "uncertain" ? nil : 1, stderr: "PRIVATE_SENTINEL",
        timedOut: failure == "timeout")
    }
    let service = fixture.service()
    let result = try service.apply(fixture.preview(.claudeCode, service: service))
    #expect(result.steps.first?.step == "remove")
    let recovered =
      failure != "uncertain" && (step == "add" || failure == "committed")
      && !(failure == "committed" && step == "add")
    #expect(result.recovery == (recovered ? .restored : nil))
    if failure == "uncertain" {
      #expect(result.outcome == .uncertain)
      #expect(!result.steps.contains { $0.step == "restore" })
      #expect(result.steps.last?.step == step)
    } else if failure == "committed" && step == "add" {
      #expect(result.outcome == .succeeded && result.finalState == .registered)
    } else {
      #expect(result.outcome == .failed && result.finalState == .different)
      if step == "add" || failure == "committed" { #expect(result.steps.last?.step == "restore") }
      #expect(
        try RegistrationJSONFile.read(fixture.file(.claudeCode).path).entry(named: "computer-mcp")
          == original)
    }
    #expect(
      !String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(
        "PRIVATE_SENTINEL"))
    #expect(
      !fixture.runner.calls.contains {
        $0.arguments.contains("get") || $0.arguments.contains("list")
      })
  }

  @Test(
    arguments: [RegistrationClient.codex, .claudeCode],
    [ClientRegistrationOperation.register, .remove])
  func failedRegistrationAndRemovalHaveNoRecovery(
    client: RegistrationClient, operation: ClientRegistrationOperation
  ) throws {
    let fixture = try RegistrationFixture()
    if operation == .remove {
      try fixture.setEntry(.object(["command": .string("user-server")]), client: client)
    }
    fixture.runner.intercept = { call in
      guard call.arguments.contains(operation == .register ? "add" : "remove") else { return nil }
      return .init(code: 1)
    }
    let service = fixture.service()
    let plan = try service.preview(
      client: client, operation: operation, server: fixture.server,
      clientCLI: fixture.clientExecutable.path)
    let result = try service.apply(plan)
    #expect(result.outcome == .failed)
    #expect(result.recovery == nil)
    #expect(result.steps.count == 1)
  }

  @Test(arguments: ["success", "restore_fails", "occupied", "restore_uncertain"])
  func claudeReplacementOrderAndRecoveryOwnership(mode: String) throws {
    let fixture = try RegistrationFixture()
    let old: JSONValue = .object([
      "type": .string("http"), "url": .string("https://example.test/private"),
      "headers": .object(["Key": .string("secret")]),
    ])
    try fixture.setEntry(old, client: .claudeCode)
    fixture.runner.intercept = { call in
      if call.arguments.contains("add"), mode != "success" {
        if mode == "occupied" {
          try fixture.setEntry(.object(["command": .string("another-writer")]), client: .claudeCode)
        }
        return .init(code: 1)
      }
      if call.arguments.contains("add-json") {
        return .init(code: mode == "restore_uncertain" ? nil : 1)
      }
      return nil
    }
    let service = fixture.service()
    let plan = try fixture.preview(.claudeCode, service: service)
    #expect(plan.display.actions.map(\.step) == ["remove", "add"])
    #expect(
      !String(decoding: try JSONEncoder().encode(plan.display), as: UTF8.self).contains("private"))
    let result = try service.apply(plan)
    #expect(result.steps.map(\.step).prefix(2) == ["remove", "add"])
    if mode == "success" { #expect(result.outcome == .succeeded) }
    if mode == "occupied" {
      #expect(result.finalEntry?.command == "another-writer")
      #expect(!result.steps.contains { $0.step == "restore" })
    }
    if mode == "restore_fails" {
      #expect(result.outcome == .failed && result.finalState == .notRegistered)
    }
    #expect(result.recovery == (mode == "restore_fails" ? .notRestored : nil))
    if mode == "restore_uncertain" {
      #expect(result.outcome == .uncertain && result.steps.last?.step == "restore")
    }
  }

  @Test(
    arguments: ["absent", "original", "changed", "planned"],
    ["succeeded", "failed", "timed_out", "unconfirmed"])
  func claudeRecoveryComparesThePrivateObservedEntry(entry: String, process: String) throws {
    let fixture = try RegistrationFixture()
    let original: JSONValue = .object([
      "type": .string("http"), "url": .string("https://example.test/PRIVATE_SENTINEL"),
      "headers": .object(["Authorization": .string("PRIVATE_SENTINEL")]),
    ])
    try fixture.setEntry(original, client: .claudeCode)
    fixture.runner.intercept = { call in
      if call.arguments.contains("add") { return .init(code: 1) }
      guard call.arguments.contains("add-json") else { return nil }
      switch entry {
      case "original": _ = try RegistrationFixture.perform(call)
      case "changed":
        try fixture.setEntry(
          .object([
            "type": .string("http"), "url": .string("https://example.test/PRIVATE_SENTINEL"),
            "headers": .object(["Authorization": .string("DIFFERENT_PRIVATE_SENTINEL")]),
          ]), client: .claudeCode)
      case "planned": try fixture.setEntry(fixture.expectedEntry(.claudeCode), client: .claudeCode)
      default: break
      }
      return .init(
        code: process == "unconfirmed" ? nil : process == "succeeded" ? 0 : 1,
        stderr: "PRIVATE_SENTINEL", timedOut: process == "timed_out" || process == "unconfirmed")
    }
    let service = fixture.service()
    let result = try service.apply(fixture.preview(.claudeCode, service: service))
    #expect(result.steps.map(\.step) == ["remove", "add", "restore"])
    let expected: ClientRegistrationRecovery? =
      process == "unconfirmed" || entry == "planned"
      ? nil : entry == "original" ? .restored : .notRestored
    #expect(result.recovery == expected)
    if process == "unconfirmed" {
      #expect(result.outcome == .uncertain && result.finalState == .notRegistered)
    } else {
      #expect(result.outcome == (entry == "planned" ? .succeeded : .failed))
      #expect(
        result.finalState
          == (entry == "planned" ? .registered : entry == "absent" ? .notRegistered : .different))
    }
    let data = try JSONEncoder().encode(result)
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(json.objectValue?["recovery"] == expected.map { .string($0.rawValue) })
    #expect(
      try JSONDecoder().decode(ClientRegistrationResult.self, from: data).recovery == expected)
    #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE_SENTINEL"))
  }

  @Test
  func unsupportedClaudeReplacementIsRefusedButRemovalIsAvailable() throws {
    let fixture = try RegistrationFixture()
    try fixture.setEntry(
      .object(["type": .string("stdio"), "command": .string("old"), "custom": .bool(true)]),
      client: .claudeCode)
    let service = fixture.service()
    let plan = try fixture.preview(.claudeCode, service: service)
    #expect(plan.display.refusalCode == .unsupportedEntry && plan.display.actions.isEmpty)
    #expect(throws: ClientRegistrationError.self) { try service.apply(plan) }
    let removal = try service.preview(
      client: .claudeCode, operation: .remove, server: fixture.server,
      clientCLI: fixture.clientExecutable.path)
    #expect(removal.display.refusalCode == nil)
    #expect(try service.apply(removal).finalState == .notRegistered)
  }

  @Test(arguments: [JSONValue.integer(42), .null, .object([:]), .string("unknown")])
  func invalidClaudeEntryTypesRefuseReplacement(type: JSONValue) throws {
    let fixture = try RegistrationFixture()
    let entry: JSONValue = .object([
      "type": type, "command": .string("old-server"), "args": .array([]),
    ])
    try fixture.setEntry(entry, client: .claudeCode)
    let service = fixture.service()
    let plan = try fixture.preview(.claudeCode, service: service)
    #expect(plan.display.state == .different)
    #expect(plan.display.refusalCode == .unsupportedEntry && plan.display.actions.isEmpty)
    do {
      _ = try service.apply(plan)
      Issue.record("Replaced an entry with an invalid type")
    } catch let error as ClientRegistrationError { #expect(error.code == .unsupportedEntry) }
    #expect(fixture.runner.calls.allSatisfy { $0.arguments == ["--version"] })
    #expect(
      try RegistrationJSONFile.read(fixture.file(.claudeCode).path).entry(named: "computer-mcp")
        == entry)
  }

  @Test(arguments: [nil, .string("stdio"), .string("http"), .string("sse")] as [JSONValue?])
  func supportedClaudeEntryTypesCanBeRestored(type: JSONValue?) throws {
    let fixture = try RegistrationFixture()
    var object: [String: JSONValue] =
      type == .string("http") || type == .string("sse")
      ? ["url": .string("https://example.test/private")]
      : ["command": .string("old-server"), "args": .array([])]
    object["type"] = type
    let entry = JSONValue.object(object)
    try fixture.setEntry(entry, client: .claudeCode)
    fixture.runner.intercept = { call in call.arguments.contains("add") ? .init(code: 1) : nil }
    let service = fixture.service()
    let plan = try fixture.preview(.claudeCode, service: service)
    #expect(plan.display.refusalCode == nil)
    #expect(plan.display.actions.map(\.step) == ["remove", "add"])
    let result = try service.apply(plan)
    #expect(result.steps.map(\.step) == ["remove", "add", "restore"])
    #expect(result.steps.last?.outcome == .succeeded)
    #expect(
      try RegistrationJSONFile.read(fixture.file(.claudeCode).path).entry(named: "computer-mcp")
        == entry)
  }

  @Test(arguments: [-1, 0, 1], [false, true])
  func claudeRecoveryInvocationMustFitArgumentBudget(offset: Int, largeEnvironment: Bool) throws {
    let fixture = try RegistrationFixture()
    let entry: JSONValue = .object([
      "command": .string("old-server"),
      "args": .array([.string(String(repeating: "é\"\\\n", count: 32))]),
      "env": .object(["TOKEN": .string("PRIVATE_SENTINEL")]),
    ])
    try fixture.setEntry(entry, client: .claudeCode)
    let environment = [
      "LANG": largeEnvironment ? String(repeating: "é", count: 1_024) : "C",
      "UNUSED": String(repeating: "not inherited", count: 1_024),
    ]
    let baseline = try fixture.preview(
      .claudeCode, service: fixture.service(environment: environment))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = String(decoding: try encoder.encode(entry), as: UTF8.self)
    let arguments = ["mcp", "add-json", "--scope", "user", "computer-mcp", payload]
    let argv = [fixture.clientExecutable.path] + arguments
    let envp = baseline.contents.environment.map { "\($0.key)=\($0.value)" }
    let bytes = (argv + envp).reduce(0) { $0 + $1.utf8.count + 1 }
    let pointers = (argv.count + envp.count + 2) * MemoryLayout<UnsafeRawPointer?>.stride
    let service = fixture.service(
      environment: environment, argumentLimit: bytes + pointers + 2_048 + offset)
    fixture.runner.intercept = { call in call.arguments.contains("add") ? .init(code: 1) : nil }
    let plan = try fixture.preview(.claudeCode, service: service)
    if offset < 0 {
      #expect(plan.display.refusalCode == .unsupportedEntry && plan.display.actions.isEmpty)
      do {
        _ = try service.apply(plan)
        Issue.record("Replaced an entry whose recovery invocation exceeds the argument budget")
      } catch let error as ClientRegistrationError { #expect(error.code == .unsupportedEntry) }
      #expect(fixture.runner.calls.allSatisfy { $0.arguments == ["--version"] })
    } else {
      #expect(plan.display.refusalCode == nil)
      #expect(plan.display.actions.map(\.step) == ["remove", "add"])
      let result = try service.apply(plan)
      #expect(result.steps.map(\.step) == ["remove", "add", "restore"])
      #expect(result.steps.last?.outcome == .succeeded)
      #expect(fixture.runner.calls.last?.arguments == arguments)
    }
    #expect(
      try RegistrationJSONFile.read(fixture.file(.claudeCode).path).entry(named: "computer-mcp")
        == entry)
    #expect(
      !String(decoding: try JSONEncoder().encode(plan.display), as: UTF8.self).contains(
        "PRIVATE_SENTINEL"))
  }

  @Test(arguments: [
    "[]", "null", "{\"mcpServers\":[]}", "{\"mcpServers\":null}",
    "{\"mcpServers\":{\"computer-mcp\":false}}", "malformed",
  ])
  func jsonShapeFailuresRefuseWrites(contents: String) throws {
    let fixture = try RegistrationFixture()
    for client in [RegistrationClient.claudeCode, .claudeDesktop] {
      try Data(contents.utf8).write(to: fixture.file(client))
      let plan = try fixture.preview(client)
      #expect(plan.display.state == .unreadable && plan.display.actions.isEmpty)
    }
  }

  @Test(arguments: [false, true])
  func fileReadsRejectSymlinksAndNonregularFiles(symlink: Bool) throws {
    let fixture = try RegistrationFixture()
    for client in [RegistrationClient.claudeCode, .claudeDesktop] {
      let file = fixture.file(client)
      if symlink {
        try FileManager.default.createSymbolicLink(
          at: file, withDestinationURL: fixture.serverExecutable)
      } else {
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
      }
      #expect(try fixture.preview(client).display.state == .unreadable)
    }
  }

  @Test
  func desktopIsUnavailableWithoutAHostImplementation() throws {
    let fixture = try RegistrationFixture()
    let service = ClientRegistrationService(
      homeDirectory: fixture.root, stateDirectory: fixture.root.appendingPathComponent("state"),
      executableSearchDirectories: [], environment: [:], processRunner: fixture.runner)
    #expect(try fixture.preview(.claudeDesktop, service: service).display.state == .unavailable)
  }

  @Test
  func writerLockSerializesRecheckAcrossServiceInstances() throws {
    let fixture = try RegistrationFixture()
    let service = fixture.service()
    let first = try fixture.preview(.claudeCode, service: service)
    let second = try fixture.preview(.claudeCode, service: service)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    fixture.runner.intercept = { call in
      if call.arguments.contains("add") {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      return nil
    }
    DispatchQueue.global().async {
      defer { completed.signal() }
      do { #expect(try service.apply(first).outcome == .succeeded) } catch { Issue.record(error) }
    }
    #expect(entered.wait(timeout: .now() + 5) == .success)
    let state = fixture.root.appendingPathComponent("state/client-registration.lock")
    #expect(throws: FileLockError.self) { try FileLock(path: state.path, mode: .exclusive) }
    release.signal()
    #expect(completed.wait(timeout: .now() + 5) == .success)
    #expect(throws: ClientRegistrationError.self) { try fixture.service().apply(second) }
  }

  #if os(macOS)
    @Test(arguments: [false, true])
    func desktopPreservesContentAndPermissions(existing: Bool) throws {
      let fixture = try RegistrationFixture()
      if existing {
        try fixture.setEntry(nil, client: .claudeDesktop, outside: "retained")
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o640], ofItemAtPath: fixture.file(.claudeDesktop).path)
      }
      var service = fixture.service()
      service.desktopWriter.temporaryFileCreated = { path in
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.size] as? NSNumber)?.intValue == 0)
      }
      #expect(
        try service.apply(fixture.preview(.claudeDesktop, service: service)).outcome == .succeeded)
      let file = try RegistrationJSONFile.read(fixture.file(.claudeDesktop).path)
      #expect(file.mode == (existing ? 0o640 : 0o600))
      if existing {
        #expect(file.object["outside"] == .string("retained"))
        #expect(
          file.object["mcpServers"]?.objectValue?["other-server"]?.objectValue?["command"]
            == .string("retained-server"))
      }
      let removal = try service.preview(
        client: .claudeDesktop, operation: .remove, server: fixture.server)
      #expect(try service.apply(removal).finalState == .notRegistered)
      if existing {
        #expect(
          try RegistrationJSONFile.read(fixture.file(.claudeDesktop).path).object["outside"]
            == .string("retained"))
      }
    }

    @Test(arguments: ["bytes", "inode", "mode", "size", "appearance"])
    func desktopDetectsFinalCheckRaces(change: String) throws {
      let fixture = try RegistrationFixture()
      if change != "appearance" {
        try fixture.setEntry(nil, client: .claudeDesktop)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: fixture.file(.claudeDesktop).path)
      }
      var service = fixture.service()
      let path = fixture.file(.claudeDesktop)
      let changeFile: @Sendable () throws -> Void = {
        if change == "mode" {
          try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        } else if change == "inode" {
          let data = try Data(contentsOf: path)
          try data.write(to: path, options: .atomic)
        } else if change == "bytes" {
          let before = try RegistrationJSONFile.read(path.path)
          let bytes = try #require(before.bytes)
          let range = try #require(bytes.range(of: Data("unrelated".utf8)))
          let handle = try FileHandle(forWritingTo: path)
          defer { try? handle.close() }
          try handle.seek(toOffset: UInt64(range.lowerBound))
          try handle.write(contentsOf: Data("different".utf8))
          let after = try RegistrationJSONFile.read(path.path)
          #expect(after.bytes != before.bytes)
          #expect(after.inode == before.inode)
          #expect(after.mode == before.mode)
          #expect(after.size == before.size)
        } else {
          try Data("{\"writer\":true}".utf8).write(to: path)
        }
      }
      if change == "appearance" {
        service.desktopWriter.beforeRename = changeFile
      } else {
        service.desktopWriter.beforeFinalCheck = changeFile
      }
      let plan = try fixture.preview(.claudeDesktop, service: service)
      do {
        _ = try service.apply(plan)
        Issue.record("A concurrent file change was overwritten")
      } catch let error as ClientRegistrationError { #expect(error.code == .changedSincePreview) }
      #expect(try RegistrationJSONFile.read(path.path).entry(named: "computer-mcp") == nil)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)
          .allSatisfy { !$0.hasPrefix(".computer-mcp-registration-") })
    }

    @Test
    func desktopRequiresClosedClientAndExistingSupportDirectory() throws {
      let fixture = try RegistrationFixture()
      let running = fixture.service(running: true)
      let plan = try fixture.preview(.claudeDesktop, service: running)
      do {
        _ = try running.apply(plan)
        Issue.record("Wrote while Desktop was running")
      } catch let error as ClientRegistrationError { #expect(error.code == .clientRunning) }
      try FileManager.default.removeItem(
        at: fixture.file(.claudeDesktop).deletingLastPathComponent())
      let service = fixture.service()
      do {
        _ = try service.apply(fixture.preview(.claudeDesktop, service: service))
        Issue.record("Created a support directory")
      } catch let error as ClientRegistrationError {
        #expect(error.code == .supportDirectoryMissing)
      }
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.file(.claudeDesktop).deletingLastPathComponent().path))
    }
  #endif
}

/// The lock serializes handler execution and call storage. Each fixture owns its files.
private final class RegistrationTestRunner: RegistrationProcessRunning, @unchecked Sendable {
  struct Call: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
  }
  struct Reply {
    var code: Int32? = 0
    var stdout = ""
    var stderr = ""
    var timedOut = false
    var stdoutTruncated = false
    var stderrTruncated = false
  }
  private let lock = NSLock()
  private var recorded: [Call] = []
  var intercept: ((Call) throws -> Reply?)?
  var calls: [Call] { lock.withLock { recorded } }
  func run(
    executable: String, arguments: [String], environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    try lock.withLock {
      let call = Call(executable: executable, arguments: arguments, environment: environment)
      recorded.append(call)
      let reply: Reply
      if let injected = try intercept?(call) {
        reply = injected
      } else {
        reply = try RegistrationFixture.perform(call)
      }
      return .init(
        executable: executable, arguments: arguments, exitCode: reply.code,
        timedOut: reply.timedOut, stdout: reply.stdout, stderr: reply.stderr,
        stdoutTruncated: reply.stdoutTruncated, stderrTruncated: reply.stderrTruncated)
    }
  }
}

private final class RegistrationFixture: @unchecked Sendable {
  private let temporary: ScopedTemporaryDirectory
  var root: URL { temporary.url }
  let runner = RegistrationTestRunner()
  var clientExecutable: URL { root.appendingPathComponent("client") }
  var serverExecutable: URL { root.appendingPathComponent("server") }
  var server: ClientRegistrationCommand {
    .app(
      executable: serverExecutable.path, socket: root.appendingPathComponent("gateway.sock").path)
  }

  init() throws {
    temporary = try ScopedTemporaryDirectory()
    for executable in [clientExecutable, serverExecutable] {
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    try FileManager.default.createDirectory(
      at: file(.claudeDesktop).deletingLastPathComponent(), withIntermediateDirectories: true)
  }
  func file(_ client: RegistrationClient) -> URL {
    switch client {
    case .codex: root.appendingPathComponent(".codex/entry.json")
    case .claudeCode: root.appendingPathComponent(".claude.json")
    case .claudeDesktop: root.appendingPathComponent("desktop/config.json")
    }
  }
  func expectedEntry(_ client: RegistrationClient) -> JSONValue {
    .object([
      "type": .string("stdio"), "command": .string(server.executable),
      "args": .array(server.arguments.map(JSONValue.string)),
    ])
  }
  func setEntry(_ entry: JSONValue?, client: RegistrationClient, outside: String = "unrelated")
    throws
  {
    let file = file(client)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var entries = entry.map { ["computer-mcp": $0] } ?? [:]
    entries["other-server"] = .object(["command": .string("retained-server")])
    let value: JSONValue =
      client == .codex
      ? .object(["transport": entry ?? .object([:])])
      : .object([
        "outside": .string(outside),
        "mcpServers": .object(entries),
      ])
    try JSONEncoder().encode(value).write(to: file)
  }
  func service(
    environment: [String: String] = [:], installed: Bool = true, running: Bool = false,
    argumentLimit: Int? = nil
  )
    -> ClientRegistrationService
  {
    let runner: any RegistrationProcessRunning =
      installed ? self.runner : UnavailableRegistrationRunner()
    return ClientRegistrationService(
      homeDirectory: root, stateDirectory: root.appendingPathComponent("state"),
      executableSearchDirectories: [root.path], environment: environment, processRunner: runner,
      desktop: .init(
        configurationFile: file(.claudeDesktop), isInstalled: { installed }, isRunning: { running }),
      argumentLimit: argumentLimit
    )
  }
  func preview(_ client: RegistrationClient, service: ClientRegistrationService? = nil) throws
    -> ClientRegistrationPlan
  {
    try (service ?? self.service()).preview(
      client: client, operation: .register, server: server,
      clientCLI: client == .claudeDesktop ? nil : clientExecutable.path)
  }
  static func perform(_ call: RegistrationTestRunner.Call) throws -> RegistrationTestRunner.Reply {
    if call.arguments == ["--version"] { return .init(stdout: "fixture 1.0") }
    let args = call.arguments
    guard args.first == "mcp", let verb = args.dropFirst().first else { return .init(code: 1) }
    if let codexHome = call.environment["CODEX_HOME"] {
      let file = URL(fileURLWithPath: codexHome).appendingPathComponent("entry.json")
      if verb == "get" {
        guard FileManager.default.fileExists(atPath: file.path) else {
          return .init(code: 1, stderr: "No MCP server named computer-mcp")
        }
        return .init(stdout: String(decoding: try Data(contentsOf: file), as: UTF8.self))
      }
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      if verb == "remove" { try? FileManager.default.removeItem(at: file) }
      if verb == "add", let separator = args.firstIndex(of: "--") {
        let command = Array(args.dropFirst(separator + 1))
        try JSONEncoder().encode(
          JSONValue.object([
            "transport": .object([
              "type": .string("stdio"), "command": .string(command[0]),
              "args": .array(command.dropFirst().map(JSONValue.string)),
            ])
          ])
        ).write(to: file)
      }
      return .init()
    }
    let file = URL(
      fileURLWithPath: call.environment["CLAUDE_CONFIG_DIR"] ?? call.environment["HOME"]!
    ).appendingPathComponent(".claude.json")
    let old = try RegistrationJSONFile.read(file.path)
    var object = old.object
    var servers = object["mcpServers"]?.objectValue ?? [:]
    if verb == "remove" { servers.removeValue(forKey: args[4]) }
    if verb == "add" || verb == "add-json" {
      let name = args[4]
      guard servers[name] == nil else {
        return .init(code: 1, stderr: "already exists in user config")
      }
      if verb == "add-json" {
        servers[name] = try JSONDecoder().decode(JSONValue.self, from: Data(args[5].utf8))
      } else {
        let command = Array(args.dropFirst(6))
        servers[name] = .object([
          "type": .string("stdio"), "command": .string(command[0]),
          "args": .array(command.dropFirst().map(JSONValue.string)), "env": .object([:]),
        ])
      }
    }
    object["mcpServers"] = .object(servers)
    try JSONEncoder().encode(JSONValue.object(object)).write(to: file)
    return .init()
  }
}

private struct UnavailableRegistrationRunner: RegistrationProcessRunning {
  func run(
    executable: String, arguments: [String], environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    throw CommandRunnerError.launchFailed("Unavailable fixture")
  }
}

private final class EnvironmentRegistrationRunner: RegistrationProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var captured: [String: String]?
  var versionEnvironment: [String: String]? { lock.withLock { captured } }
  func run(
    executable: String, arguments: [String], environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    let result = try RegistrationProcessRunner().run(
      executable: executable, arguments: arguments, environment: environment,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
    if arguments == ["--version"] {
      let values = Dictionary(
        uniqueKeysWithValues: result.stdout.split(separator: "\n").map { line in
          let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          return (String(parts[0]), String(parts[1]))
        })
      lock.withLock { captured = values }
    }
    return result
  }
}
