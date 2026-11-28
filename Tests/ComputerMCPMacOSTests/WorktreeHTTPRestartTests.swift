import ComputerMCPTestSupport
import ComputerMCPWorktrees
import Darwin
import Foundation
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway

@Suite(
  .nativeIntegration, .serialized, .timeLimit(.minutes(5)),
  .enabled(
    if: ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_WORKTREE_HTTP_ACCEPTANCE"] == "1"))
struct WorktreeHTTPRestartTests {
  @Test(arguments: [false, true])
  func killedHostRestoresWorktreeAndRetainedHistoryWithoutReplay(managed: Bool) async throws {
    let f = try FixedHostFixture(
      fullAccess: false, lifecycle: true,
      gitExecutable: WorktreeHTTPAcceptanceTests().gitExecutable)
    try await f.run { f in
      try await f.initializeRepository()
      let root = f.root.appendingPathComponent("restart-host")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      let spec = root.appendingPathComponent("spec.json")
      let settings = WorktreeRestartSpec(
        root: root.path, source: f.project.path, managed: managed,
        gitExecutable: f.platform.gitExecutable)
      try JSONEncoder().encode(settings).write(to: spec)
      let first = try RestartHostProcess(spec: spec, log: root.appendingPathComponent("first.log"))
      var second: RestartHostProcess?
      var client: GatewayClientSession?
      do {
        client = try await GatewayClientSession.connectHTTP(
          endpoint: first.ready(root), accessToken: "restart-owner")
        let active = try #require(client)
        let calls = WorktreeHTTPAcceptanceTests()
        let made = try await calls.call(
          active, "git.worktree_add", "fixture", ["name": .string("history")])
        let project = try #require(made["project_id"]?.stringValue)
        let branch = try #require(made["branch"]?.stringValue)
        let base = try #require(made["base"]?.stringValue)
        _ = try await calls.call(
          active, "file.write", project,
          ["path": .string("change.txt"), "content": .string("retained")])
        _ = try await shell(
          active, project,
          "git add change.txt; git commit -qm retained; git tag -a retained -m retained; blob=$(printf blob | git hash-object -w --stdin); git update-ref refs/retained/blob \"$blob\"; tree=$(printf '100644 blob %s\\tretained.txt\\n' \"$blob\" | git mktree); git update-ref refs/retained/tree \"$tree\""
        )
        let roots = try await shell(
          active, project,
          "git rev-parse HEAD refs/tags/retained refs/retained/blob refs/retained/tree")
        let oids = roots.split(separator: "\n").map(String.init)
        try #require(oids.count == 4)
        try Data("owner".utf8).write(to: f.project.appendingPathComponent("owner.txt"))
        _ = try await f.ownerGit(["add", "owner.txt"])
        _ = try await f.ownerGit(["commit", "-qm", "advance"])
        _ = try await shell(active, project, "git fetch origin; git rebase origin/\(base)")
        _ = try await calls.call(
          active, "git.merge", "fixture", ["branch": .string(branch)])
        _ = try await calls.call(active, "git.worktree_remove", project)
        _ = try await calls.call(
          active, "git.branch_delete", "fixture",
          ["name": .string(branch), "dry_run": .bool(false), "confirm_delete": .bool(true)])

        let standing = try await calls.call(
          active, "git.worktree_add", "fixture", ["name": .string("standing")])
        let standingID = try #require(standing["project_id"]?.stringValue)
        let standingPath = try #require(standing["path"]?.stringValue)
        let started = try await calls.call(
          active, "shell.spawn", standingID,
          ["shell": .string("/bin/sh"), "command": .string("printf once >> launches; sleep 120")])
        let sessionID = try #require(started["session_id"]?.stringValue)
        let running = try await calls.call(
          active, "shell.read", standingID, ["session_id": .string(sessionID)])
        let execution = try #require(running["execution_id"]?.stringValue)
        try #require(running["is_running"] == .bool(true))
        let launchFile = URL(fileURLWithPath: standingPath).appendingPathComponent("launches")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: launchFile.path),
          ContinuousClock.now < deadline
        {
          try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try String(contentsOf: launchFile, encoding: .utf8) == "once")
        await first.killAndReap()
        await active.disconnect()
        client = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent("ready.json"))
        let restarted = try RestartHostProcess(
          spec: spec, log: root.appendingPathComponent("second.log"))
        second = restarted
        let next = try await GatewayClientSession.connectHTTP(
          endpoint: restarted.ready(root), accessToken: "restart-owner")
        client = next
        let interrupted = try await calls.call(
          next, "shell.read", standingID, ["session_id": .string(sessionID)])
        #expect(interrupted["execution_id"]?.stringValue == execution)
        #expect(interrupted["is_running"] == .bool(false))
        #expect(interrupted["end_reason"] == .string("interrupted"))
        #expect(try String(contentsOf: launchFile, encoding: .utf8) == "once")
        _ = try await calls.call(
          next, "file.write", standingID,
          ["path": .string("after.txt"), "content": .string("usable")])
        _ = try await calls.call(next, "git.worktree_remove", standingID, ["force": .bool(true)])
        _ = try await calls.call(
          next, "git.branch_delete", "fixture",
          [
            "name": try #require(standing["branch"]), "dry_run": .bool(false),
            "confirm_delete": .bool(true),
          ])
        let storage = try #require(
          WorktreeStorage(
            databaseURL: settings.databaseURL,
            applicationSupportRoot: settings.directories?.applicationSupport))
        try await f.verifyRetainedObjects(oids, storage: storage)
        print(
          "WORKTREE_RESTART managed=\(managed) killed_and_reaped=true interrupted=true replay=false worktree=usable retained_original_types=commit,tag,blob,tree gc=passed"
        )
        await next.disconnect()
        await restarted.killAndReap()
      } catch {
        await client?.disconnect()
        await first.killAndReap()
        await second?.killAndReap()
        for name in ["first.log", "second.log"] {
          if let log = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) {
            print("RESTART_HOST \(name):\n\(log.suffix(20_000))")
          }
        }
        throw error
      }
    }
  }

  private func shell(_ client: GatewayClientSession, _ project: String, _ script: String)
    async throws -> String
  {
    let git = WorktreeHTTPAcceptanceTests().gitExecutable
    let quotedGit = "'" + git.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let result = try await WorktreeHTTPAcceptanceTests().call(
      client, "shell.run", project,
      [
        "shell": .string("/bin/sh"), "timeout_ms": .integer(60_000),
        "command": .string(
          "set -e; git() { \(quotedGit) -c user.name=Fixture -c user.email=fixture@example.invalid \"$@\"; }; "
            + script),
      ])
    try #require(result["exit_code"] == .integer(0), "\(result)")
    return result["stdout"]?.objectValue?["text"]?.stringValue ?? ""
  }
}

private final class RestartBundleMarker: NSObject {}

private final class RestartHostProcess: @unchecked Sendable {
  private let process = Process()
  private let output: FileHandle
  init(spec: URL, log: URL) throws {
    let executable = try #require(Bundle.main.executableURL)
    let bundle = try #require(Bundle(for: RestartBundleMarker.self).executableURL)
    FileManager.default.createFile(atPath: log.path, contents: nil)
    output = try FileHandle(forWritingTo: log)
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
    process.arguments = [
      "-n", "10", executable.path, "--test-bundle-path", bundle.path, bundle.path,
      "--testing-library", "swift-testing", "--filter",
      "WorktreeHTTPRestartHostTests/serveUntilKilled",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "COMPUTER_MCP_TEST_WORKTREE_HTTP_ACCEPTANCE")
    environment["COMPUTER_MCP_TEST_WORKTREE_RESTART_CHILD"] = spec.path
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    print("WORKTREE_RESTART helper=\(executable.path) bundle=\(bundle.path)")
    try process.run()
  }
  func ready(_ root: URL) async throws -> URL {
    let ready = root.appendingPathComponent("ready.json")
    let deadline = ContinuousClock.now + .seconds(45)
    while process.isRunning && ContinuousClock.now < deadline {
      if let data = try? Data(contentsOf: ready),
        let port = try? JSONDecoder().decode(Int.self, from: data)
      {
        return URL(string: "http://127.0.0.1:\(port)/mcp")!
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw CocoaError(.executableRuntimeMismatch)
  }
  func killAndReap() async {
    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    await Task.detached { [process] in process.waitUntilExit() }.value
    try? output.close()
  }
}
