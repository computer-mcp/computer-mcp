import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPDelivery

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

// Immutable fixture ownership; repository mutations are serialized by Git and delivery locks.
final class DeliveryFixture: @unchecked Sendable {
  let temporary: ScopedTemporaryDirectory
  let root: URL
  let executable: String
  let environment: [String: String]
  let runner: ProcessCommandRunner

  init(ignored: Bool = true) throws {
    temporary = try ScopedTemporaryDirectory()
    root = temporary.url.appendingPathComponent("repository", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    executable = try testExecutable("git")
    environment = ["PATH": systemUtilityPath, "HOME": temporary.url.path, "LC_ALL": "C"]
    runner = ProcessCommandRunner(launcher: testExecutionLauncher(), environment: environment)
    try git(["init", "-b", "main"])
    try git(["config", "user.name", "Delivery Test"])
    try git(["config", "user.email", "delivery@example.invalid"])
    try git(["config", "commit.gpgsign", "false"])
    try write(".gitignore", ignored ? ".claude/worktrees/\n" : "*.ignored\n")
    try write("notes/log.md", "alpha\nstable\n")
    try write("outside.txt", "untouched\n")
    try git(["add", "."])
    try git(["commit", "-m", "test: initialize repository"])
  }

  var scope: DeliveryScope {
    .init(id: "notes", project: "fixture", paths: ["notes/**"], defaultBranch: "main")
  }

  func tools(
    scope: DeliveryScope? = nil, extraEnvironment: [String: String] = [:],
    commandEnvironment: [String: String] = [:], timeout: Int? = nil
  ) -> ToolEnvironment {
    ToolEnvironment(
      launcher: testExecutionLauncher(),
      configuration: .init(
        projects: [.init(id: "fixture", path: root.path)],
        cli: .init(commands: [
          .init(
            id: "git", executable: executable, env: commandEnvironment, defaultTimeoutMs: timeout)
        ]),
        builtin: .init(enabled: ["delivery.scopes.list", "delivery.apply"]),
        delivery: .init(scopes: [scope ?? self.scope]), projectDirectory: root),
      environment: environment.merging(extraEnvironment) { _, value in value })
  }

  func provider(scope: DeliveryScope? = nil, io: DeliveryIO = .init()) -> DeliveryToolProvider {
    DeliveryToolProvider(environment: tools(scope: scope), io: io, startsRecovery: false)
  }

  func provider(
    wrappingGit body: String, timeout: Int? = nil, io: DeliveryIO = .init(),
    scope: DeliveryScope? = nil
  ) throws
    -> DeliveryToolProvider
  {
    let wrapper = temporary.url.appendingPathComponent("git-wrapper")
    let script = "#!\(try testExecutable("sh"))\n" + body + "\nexec \(quote(executable)) \"$@\"\n"
    try Data(script.utf8).write(to: wrapper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    var configuration = tools(scope: scope, timeout: timeout).configuration
    configuration.cli.commands[0].executable = wrapper.path
    return DeliveryToolProvider(
      environment: .init(
        launcher: testExecutionLauncher(), configuration: configuration, environment: environment),
      io: io, startsRecovery: false)
  }

  func request(
    path: String = "notes/log.md", old: String = "alpha", new: String = "beta",
    slug: String = "entry", message: String = "docs: record entry"
  ) -> JSONValue {
    .object([
      "scope": .string("notes"), "message": .string(message), "slug": .string(slug),
      "edits": .array([replace(path, old, new)]),
    ])
  }

  func replace(_ path: String, _ old: String, _ new: String) -> JSONValue {
    .object([
      "path": .string(path), "replace": .object(["old": .string(old), "new": .string(new)]),
    ])
  }

  func create(_ path: String, _ content: String) -> JSONValue {
    .object(["path": .string(path), "create": .object(["content": .string(content)])])
  }

  func apply(_ input: JSONValue? = nil, provider: DeliveryToolProvider? = nil) throws -> [String:
    JSONValue]
  {
    let envelope = try (provider ?? self.provider()).callTool(
      .init(name: "delivery.apply", arguments: input ?? request(), context: .empty))
    return try #require(
      envelope.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
  }

  @discardableResult
  func git(_ arguments: [String], at: URL? = nil, accepting: Set<Int32> = [0]) throws -> String {
    let result = try runner.run(
      executable: executable, arguments: arguments, workingDirectory: at ?? root,
      environment: [:], timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576)
    try #require(
      !result.timedOut && result.exitCode.map(accepting.contains) == true,
      "Git \(arguments) failed: \(result.stderr)")
    return result.stdout.trimmingCharacters(in: .newlines)
  }

  func write(_ path: String, _ content: String, at: URL? = nil) throws {
    let url = (at ?? root).appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  func read(_ path: String, at: URL? = nil) throws -> String {
    try String(contentsOf: (at ?? root).appendingPathComponent(path), encoding: .utf8)
  }

  func repository(scope: DeliveryScope? = nil, io: DeliveryIO = .init()) throws
    -> DeliveryRepository
  {
    try DeliveryRepository(
      scope: scope ?? self.scope, project: root,
      git: DeliveryGit(environment: tools(scope: scope)), io: io)
  }

  func journals() throws -> [DeliveryJournal] {
    let directory = root.appendingPathComponent(".git/computer-mcp/delivery")
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }.map {
      try JSONDecoder().decode(DeliveryJournal.self, from: Data(contentsOf: $0))
    }
  }

  func assertClean(_ branch: String = "docs/entry", retained: Bool = false) throws {
    let worktrees = try git(["worktree", "list", "--porcelain"])
    #expect(worktrees.components(separatedBy: "worktree ").count == 2)
    let branches = try git(["branch", "--list", branch])
    #expect(branches.isEmpty == !retained)
    let status = try git(["status", "--porcelain"])
    #expect(status.isEmpty)
  }

  func hook(_ name: String, body: String) throws {
    let url = root.appendingPathComponent(".git/hooks/\(name)")
    let shell = try testExecutable("sh")
    let script = "#!\(shell)\nset -eu\n" + body + "\n"
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  /// Hook-created commits model other writers that do not participate in the delivery lock.
  func advanceDuringCommit(conflict: Bool = false, twice: Bool = false) throws {
    let main = quote(root.path)
    let git = quote(executable)
    let clean =
      "env -i PATH=\(quote(systemUtilityPath)) HOME=\(quote(temporary.url.path)) \(git) -C \(main) -c core.hooksPath=/dev/null"
    let content = conflict ? "gamma\\nstable\\n" : "concurrent\\n"
    let path = conflict ? "notes/log.md" : "concurrent.txt"
    try hook(
      "post-commit",
      body: """
        if test "$(git branch --show-current)" = docs/entry && ! test -f \(main)/advanced; then
          touch \(main)/advanced
          printf '\(content)' > \(main)/\(path)
          \(clean) add -- \(path)
          \(clean) commit -m 'test: advance default'
          rm \(main)/advanced
          # Disable this hook after its single simulated external write.
          rm \(main)/.git/hooks/post-commit
        fi
        """)
    if twice {
      try hook(
        "post-rewrite",
        body: """
          printf 'second\\n' > \(main)/second.txt
          \(clean) add -- second.txt
          \(clean) commit -m 'test: advance again'
          """)
    }
  }
}

func quote(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private let deliveryTestExecution = BlockingOperationExecutor(
  label: "computer-mcp.delivery-tests", serial: false)

func deliveryTest(_ operation: @escaping @Sendable () throws -> Void) async throws {
  try await deliveryTestExecution.perform(operation)
}
