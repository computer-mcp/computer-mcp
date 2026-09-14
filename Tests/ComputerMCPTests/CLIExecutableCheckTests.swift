import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct CLIExecutableCheckTests {
  @Test
  func optionalChecksRoundTripAndStrictFields() throws {
    let tree = Self.tree([.init(args: ["--version"], stdout: "fixture\n")])
    #expect(try CLITree.parse(JSONEncoder().encode(tree)) == tree)
    var value = try #require(JSONValue.encoded(tree).objectValue)
    value.removeValue(forKey: "executable_checks")
    #expect(try CLITree.parse(JSONEncoder().encode(JSONValue.object(value))).executableChecks == [])
    for checks: JSONValue in [
      .null, .string("unchecked"),
      .array([
        .object([
          "args": .array([.string("--version")]), "stdout": .string("ok"),
          "grant": .string("admin"),
        ])
      ]),
    ] {
      value["executable_checks"] = checks
      #expect(throws: (any Error).self) {
        try CLITree.parse(JSONEncoder().encode(JSONValue.object(value)))
      }
    }
    #expect(throws: CLITreeError.self) {
      try Self.tree(Array(repeating: .init(args: ["--version"], stdout: "ok"), count: 5)).validate()
    }
  }

  @Test(arguments: 0..<9)
  func invalidAssertionsAreRejected(_ fault: Int) {
    let check: CLIExecutableCheck
    switch fault {
    case 0: check = .init(args: [], stdout: "")
    case 1: check = .init(args: ["\0"], stdout: "")
    case 2: check = .init(args: Array(repeating: "a", count: 129), stdout: "")
    case 3: check = .init(args: [String(repeating: "a", count: 65_536)], stdout: "")
    case 4: check = .init(args: ["--version"], stdout: String(repeating: "a", count: 65_537))
    case 5: check = .init(args: ["--version"])
    case 6:
      check = .init(
        args: ["--version"], stdout: "", stdoutSHA256: String(repeating: "a", count: 64))
    case 7: check = .init(args: ["--version"], stdoutSHA256: String(repeating: "A", count: 64))
    default: check = .init(args: ["--version"], stdoutSHA256: String(repeating: "a", count: 63))
    }
    #expect(throws: CLITreeError.self) { try check.validate() }
  }

  @Test
  func exactBytesAndDigestRunSequentiallyWithoutLeakingProbeOutput() async throws {
    let execution = CLIProcessExecution()
    let text = "检查 ' \" $(not-executed)\n"
    let checks: [CLIExecutableCheck] = [
      .init(args: ["%s", text], stdout: text),
      .init(args: ["%s", text], stdoutSHA256: Self.digest(Data(text.utf8))),
    ]
    do {
      let sync = try execution.run(
        executable: "/usr/bin/printf",
        invocation: .init(arguments: ["%s", "target"], standardInput: Data()),
        cwd: URL(fileURLWithPath: "/tmp"), environment: [:], timeoutMilliseconds: 5_000,
        maxOutputBytes: 16, executableChecks: checks)
      let async = try await execution.runAsync(
        executable: "/usr/bin/printf",
        invocation: .init(arguments: ["%s", "target"], standardInput: Data()),
        cwd: URL(fileURLWithPath: "/tmp"), environment: [:], timeoutMilliseconds: 5_000,
        maxOutputBytes: 16, executableChecks: checks)
      #expect(sync.exitCode == 0 && async.exitCode == 0)
      #expect(sync.stdout.base64 == Data("target".utf8).base64EncodedString())
      #expect(async.stdout.base64 == sync.stdout.base64)
      #expect(!String(decoding: try JSONEncoder().encode(async), as: UTF8.self).contains(text))
      let assertion = CLIExecutableCheck(args: ["%s", "target"], stdout: "target")
      #expect(assertion.matches(async))
      for fault in 0..<9 {
        var broken = async
        switch fault {
        case 0: broken.exitCode = 1
        case 1: broken.signal = 15
        case 2: broken.isRunning = true
        case 3: broken.timedOut = true
        case 4: broken.cancelled = true
        case 5: broken.stdout.truncated = true
        case 6: broken.stderr.missedBytes = true
        case 7: broken.streamErrors = ["stream failed"]
        default: broken.stdout.base64 = "not base64"
        }
        #expect(!assertion.matches(broken))
      }
    } catch {
      await execution.shutdown()
      throw error
    }
    await execution.shutdown()
  }

  @Test
  func everyCallChecksCurrentContextAndClosedStdin() async throws {
    let fixture = try ExecutableCheckFixture()
    defer { fixture.cleanup() }
    try fixture.script(
      """
      if [ "$1" = "--version" ]; then
        if read -r input; then exit 9; fi
        printf '%s\n%s\n' "$CLI_CHECK_VALUE" "$PWD"
        exit 0
      fi
      printf target > action
      """)
    let execution = CLIProcessExecution()
    let checks = [CLIExecutableCheck(args: ["--version"], stdout: "first\n\(fixture.root.path)\n")]
    do {
      let result = try await fixture.run(
        execution, checks: checks, environment: ["CLI_CHECK_VALUE": "first"])
      #expect(result.exitCode == 0)
      try FileManager.default.removeItem(at: fixture.file("action"))
      await #expect(throws: CLITreeError.self) {
        try await fixture.run(execution, checks: checks, environment: ["CLI_CHECK_VALUE": "second"])
      }
      #expect(!fixture.exists("action"))
    } catch {
      await execution.shutdown()
      throw error
    }
    await execution.shutdown()
  }

  @Test(arguments: [false, true])
  func executableOrInterpreterMutationBlocksAction(_ interpreter: Bool) async throws {
    let fixture = try ExecutableCheckFixture()
    defer { fixture.cleanup() }
    if interpreter {
      try fixture.script("unused", shebang: "#!/usr/bin/env fixture-runtime")
      try fixture.script(
        """
        if [ "$2" = "--version" ]; then
          /bin/chmod 700 "$0"
          printf 'compatible\n'
          exit 0
        fi
        printf target > action
        """, name: "fixture-runtime")
    } else {
      try fixture.script(
        """
        if [ "$1" = "--version" ]; then
          /bin/chmod 700 "$0"
          printf 'compatible\n'
          exit 0
        fi
        printf target > action
        """)
    }
    let execution = CLIProcessExecution()
    await #expect(
      throws: CLITreeError.invalid(
        "CLI executable or interpreter changed during compatibility checks; retry after the update completes."
      )
    ) {
      try await fixture.run(
        execution, checks: [.init(args: ["--version"], stdout: "compatible\n")],
        environment: ["PATH": "\(fixture.root.path):/usr/bin:/bin"])
    }
    await execution.shutdown()
    #expect(!fixture.exists("action"))
  }

  @Test(arguments: ["mismatch", "exit", "overflow", "timeout"])
  func failedProbeNeverRunsActionOrEchoesOutput(_ failure: String) async throws {
    let fixture = try ExecutableCheckFixture()
    defer { fixture.cleanup() }
    let probe: String
    switch failure {
    case "exit": probe = "printf 'compatible\\n'; exit 7"
    case "overflow": probe = "/bin/dd if=/dev/zero bs=1048576 count=5 2>/dev/null"
    case "timeout": probe = "echo $$ > pid; exec /bin/sleep 30"
    default: probe = "printf 'private-probe-value\\n'"
    }
    try fixture.script(
      """
      if [ "$1" = "--version" ]; then
        \(probe)
        exit 0
      fi
      printf target > action
      """)
    let execution = CLIProcessExecution()
    await #expect(
      throws: CLITreeError.invalid(
        "CLI executable failed its compatibility check; target command was not executed.")
    ) {
      try await fixture.run(
        execution, checks: [.init(args: ["--version"], stdout: "compatible\n")],
        timeout: failure == "timeout" ? 1_000 : 5_000)
    }
    await execution.shutdown()
    #expect(!fixture.exists("action"))
    if failure == "timeout" { try fixture.expectReaped() }
  }

  @Test
  func laterAssertionAndRetargetedExecutableAreRechecked() async throws {
    let fixture = try ExecutableCheckFixture()
    defer { fixture.cleanup() }
    try fixture.script(
      """
      if [ "$1" = "--version" ]; then printf 'compatible\n'; exit 0; fi
      if [ "$1" = "--interface" ]; then printf 'changed\n'; exit 0; fi
      printf target > action
      """, name: "first")
    try fixture.script(
      """
      if [ "$1" = "--version" ]; then printf 'other\n'; exit 0; fi
      printf target > action
      """, name: "second")
    try FileManager.default.createSymbolicLink(
      at: fixture.file("tool"), withDestinationURL: fixture.file("first"))
    let execution = CLIProcessExecution()
    let version = CLIExecutableCheck(args: ["--version"], stdout: "compatible\n")
    do {
      await #expect(throws: CLITreeError.self) {
        try await fixture.run(
          execution, checks: [version, .init(args: ["--interface"], stdout: "expected\n")])
      }
      #expect(!fixture.exists("action"))
      _ = try await fixture.run(execution, checks: [version])
      try #require(fixture.exists("action"))
      try FileManager.default.removeItem(at: fixture.file("action"))
      try FileManager.default.removeItem(at: fixture.file("tool"))
      try FileManager.default.createSymbolicLink(
        at: fixture.file("tool"), withDestinationURL: fixture.file("second"))
      await #expect(throws: CLITreeError.self) {
        try await fixture.run(execution, checks: [version])
      }
      #expect(!fixture.exists("action"))
    } catch {
      await execution.shutdown()
      throw error
    }
    await execution.shutdown()
  }

  @Test(arguments: [false, true])
  func cancellationAndShutdownOwnTheProbeAndConcurrencySlot(_ shutdown: Bool) async throws {
    let fixture = try ExecutableCheckFixture()
    defer { fixture.cleanup() }
    try fixture.script(
      """
      if [ "$1" = "--version" ]; then
        echo $$ > pid.pending
        /bin/mv pid.pending pid
        exec /bin/sleep 30
      fi
      printf target > action
      """)
    let execution = CLIProcessExecution(maxConcurrentCalls: 1)
    let task = Task {
      try await fixture.run(execution, checks: [.init(args: ["--version"], stdout: "compatible\n")])
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !fixture.exists("pid"), ContinuousClock.now < deadline {
      _ = try? await Task.sleep(for: .milliseconds(10))
    }
    await #expect(throws: CLITreeError.invalid("CLI invocation limit reached.")) {
      try await fixture.run(execution, checks: [])
    }
    if shutdown { await execution.shutdown() } else { task.cancel() }
    await #expect(throws: CancellationError.self) { try await task.value }
    await execution.shutdown()
    try fixture.expectReaped()
    #expect(!fixture.exists("action"))
  }

  @Test
  func policyStaticHelpAndCatalogRefreshKeepChecksAtCallTime() async throws {
    let fixture = try ExecutableCheckFixture()
    defer { fixture.cleanup() }
    try fixture.script(
      """
      if [ "$1" = "--version" ]; then
        printf probe >> probes
        /bin/cat version
        exit 0
      fi
      printf target >> action
      """)
    try Data("one".utf8).write(to: fixture.file("version"))
    try JSONEncoder().encode(Self.tree([.init(args: ["--version"], stdout: "one")]))
      .write(to: fixture.file("tree.json"))
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: .localAdmin))
    configuration.workspaceDirectory = fixture.root
    configuration.cli.commands = [
      .init(
        id: "checked", executable: fixture.file("tool").path,
        allowAnyArgs: false, tree: .init(kind: .file, path: fixture.file("tree.json").path))
    ]
    let registry = GatewayToolRegistry(configuration: configuration)
    let router = try GatewayProviderRouter(registry: registry)
    do {
      let tool = try #require(router.listTools().first { $0.name.hasPrefix("cli_") })
      #expect(
        tool.meta?.objectValue?["cli"]?.objectValue?["compatibility"]
          == .string("required_before_call"))
      _ = try registry.callTool(name: "cli.help", arguments: .object(["id": .string("checked")]))
      #expect(!fixture.exists("probes"))
      let observe = try GatewayRuntime(
        configuration: configuration,
        context: .init(caller: .secureTunnel, profileID: .chatGPTObserve),
        registeredWorkspaces: [
          .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
        ])
      #expect(try !observe.listTools().contains { $0.name == tool.name })
      await #expect(throws: (any Error).self) {
        try await observe.callToolAsync(name: tool.name, arguments: .object([:]))
      }
      await observe.shutdown()
      #expect(!fixture.exists("probes"))
      _ = try await router.callToolAsync(name: tool.name, arguments: .object([:]))
      try #require(fixture.exists("action"))
      try FileManager.default.removeItem(at: fixture.file("action"))
      try Data("two".utf8).write(to: fixture.file("version"))
      await #expect(throws: CLITreeError.self) {
        try await router.callToolAsync(name: tool.name, arguments: .object([:]))
      }
      #expect(!fixture.exists("action"))
      try Data("invalid".utf8).write(to: fixture.file("tree.json"))
      await #expect(throws: (any Error).self) { try await router.refreshTools() }
      await #expect(throws: CLITreeError.self) {
        try await router.callToolAsync(name: tool.name, arguments: .object([:]))
      }
      #expect(!fixture.exists("action"))
      try JSONEncoder().encode(Self.tree([.init(args: ["--version"], stdout: "two")]))
        .write(to: fixture.file("tree.json"))
      try await router.refreshTools()
      _ = try await router.callToolAsync(name: tool.name, arguments: .object([:]))
      #expect(try String(contentsOf: fixture.file("action"), encoding: .utf8) == "target")
      #expect(
        try String(contentsOf: fixture.file("probes"), encoding: .utf8) == "probeprobeprobeprobe")
    } catch {
      await router.shutdown()
      throw error
    }
    await router.shutdown()
  }

  private static func tree(_ checks: [CLIExecutableCheck]) -> CLITree {
    .init(
      formatVersion: 1, source: "isolated fixture", executableVersion: "fixture",
      coverage: .complete, omissions: [],
      commands: [.init(id: "run", path: [], description: "Fixture action")],
      executableChecks: checks)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct ExecutableCheckFixture: Sendable {
  let root: URL
  init() throws {
    let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cli-check-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
    root = try WorkspacePathResolver.canonicalWorkspace(candidate)
  }
  func file(_ name: String) -> URL { root.appendingPathComponent(name) }
  func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path) }
  func script(_ body: String, name: String = "tool", shebang: String = "#!/bin/sh") throws {
    try Data("\(shebang)\n\(body)\n".utf8).write(to: file(name), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file(name).path)
  }
  func run(
    _ execution: CLIProcessExecution, checks: [CLIExecutableCheck],
    environment: [String: String] = [:], timeout: Int = 5_000
  ) async throws -> ShellSessionSnapshot {
    try await execution.runAsync(
      executable: file("tool").path,
      invocation: .init(arguments: [], standardInput: Data()), cwd: root,
      environment: environment, timeoutMilliseconds: timeout, maxOutputBytes: 4_096,
      executableChecks: checks)
  }
  func expectReaped() throws {
    let pid = try #require(
      Int32(
        String(contentsOf: file("pid"), encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
  }
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
