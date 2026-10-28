import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

@Suite(
  .nativeIntegration, .serialized, .timeLimit(.minutes(5)),
  .enabled(
    if: ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_WORKTREE_HTTP_ACCEPTANCE"] == "1",
    "Run the named WorktreeHTTPAcceptanceTests invocation for native HTTP acceptance."))
struct WorktreeHTTPAcceptanceTests {
  var gitExecutable: String {
    ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_WORKTREE_GIT"] ?? "/usr/bin/git"
  }

  @Test(arguments: [false, true])
  func oneAuthenticatedSessionCompletesTheWorktreeFlow(managed: Bool) async throws {
    let f = try FixedHostFixture(
      fullAccess: false, lifecycle: true, caller: .cloudflareTunnel, gitExecutable: gitExecutable)
    try await f.run { f in
      try await preparePackage(f)
      let initial = try await f.ownerGit(["rev-parse", "HEAD"])
      let app = managed ? try await GatewayManagedHostFixture(f) : nil
      let profiles = try f.database.profiles()
      print(
        "WORKTREE_HTTP git=\(try await f.ownerGit(["--version"]).trimmingCharacters(in: .newlines))"
      )
      let source: GatewayHTTPSessionSource
      if let app {
        source = .managed(
          try await app.service.makeHTTPSessions(
            profileID: .chatGPTOperate, trace: .init(transport: "http")))
      } else {
        source = .registry(f.runtime)
      }
      let http = GatewayHTTPRuntime(
        configuration: f.configuration, source: source, host: "127.0.0.1", port: 0,
        publicBaseURL: nil,
        accessToken: "worktree-acceptance-fixture")
      try await http.startListening()
      let endpoint = URL(string: "http://127.0.0.1:\(try #require(await http.boundPort()))/mcp")!
      let client = try await GatewayClientSession.connectHTTP(
        endpoint: endpoint, accessToken: "worktree-acceptance-fixture")
      do {
        let session = try #require(await http.controlSessions().only)
        let made = try await call(client, "git.worktree_add", "fixture", ["name": .string("http")])
        let id = try #require(made["project_id"]?.stringValue)
        let path = try #require(made["path"]?.stringValue)
        let branch = try #require(made["branch"]?.stringValue)
        let base = try #require(made["base"]?.stringValue)
        let binding = try #require(
          try f.database.executionWorktree(
            projectID: id, directory: URL(fileURLWithPath: path), platform: f.platform))
        try binding.binding.verify()
        #expect(try f.database.profiles() == profiles)
        _ = try await call(client, "git.worktree_list", "fixture")
        _ = try await call(client, "project.describe", id)
        _ = try await call(
          client, "file.write", id, ["path": .string("value.txt"), "content": .string("edited")])
        _ = try await call(client, "git.add", id, ["paths": .array([.string("value.txt")])])
        _ = try await call(
          client, "git.commit", id,
          ["message": .string("edit"), "paths": .array([.string("value.txt")])])
        let detached = try await shell(client, id, "git symbolic-ref -q HEAD; test $? = 1")
        #expect(detached["exit_code"] == .integer(0))
        let build = try await call(
          client, "shell.spawn", id,
          [
            "command": .string(
              "set -e; echo BUILD_STARTED; /bin/sleep 2; /usr/bin/swift build --build-system native --disable-sandbox --scratch-path \"$TMPDIR/build\"; /usr/bin/swift test --build-system native --disable-sandbox --scratch-path \"$TMPDIR/build\"; echo BUILD_FINISHED"
            ),
            "shell": .string("/bin/sh"), "timeout_ms": .integer(180_000),
          ])
        let execution = try #require(build["session_id"]?.stringValue)
        _ = try await call(client, "project.describe", id)
        try await readBuild(client, projectID: id, sessionID: execution)
        _ = try await shell(
          client, id,
          "set -e; printf raw > raw.txt; git add raw.txt; git -c user.name=Fixture -c user.email=fixture@example.invalid commit -m raw"
        )
        let rootsOutput = try await shell(
          client, id,
          """
          set -e
          git tag -a retained-tag -m retained HEAD
          blob=$(printf 'independent retained blob' | git hash-object -w --stdin)
          git update-ref refs/retained/blob "$blob"
          tree=$(printf '100644 blob %s\tretained.txt\n' "$blob" | git mktree)
          git update-ref refs/retained/tree "$tree"
          git rev-parse HEAD refs/tags/retained-tag refs/retained/blob refs/retained/tree
          """)
        let rootText = try #require(rootsOutput["stdout"]?.objectValue?["text"]?.stringValue)
        let roots = rootText.split(separator: "\n").map(String.init)
        try #require(roots.count == 4)
        #expect(try await f.ownerGit(["rev-parse", "refs/heads/" + branch]) == initial)
        try Data("base".utf8).write(to: f.project.appendingPathComponent("base.txt"))
        _ = try await f.ownerGit(["add", "base.txt"])
        _ = try await f.ownerGit(["commit", "-qm", "advance base"])
        try Data("owner edit".utf8).write(to: f.project.appendingPathComponent("owner.txt"))
        _ = try await shell(
          client, id,
          "git fetch origin && git -c user.name=Fixture -c user.email=fixture@example.invalid rebase origin/\(base)"
        )
        #expect(try await f.ownerGit(["rev-parse", "refs/heads/" + branch]) == initial)
        let merged = try await call(client, "git.merge", "fixture", ["branch": .string(branch)])
        #expect(
          try await f.ownerGit(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
            == merged["oid"]?.stringValue)
        #expect(
          try String(contentsOf: f.project.appendingPathComponent("owner.txt"), encoding: .utf8)
            == "owner edit")
        _ = try await call(client, "git.worktree_remove", id)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try f.database.project(id: id) == nil)
        _ = try await call(
          client, "git.branch_delete", "fixture",
          ["name": .string(branch), "dry_run": .bool(false), "confirm_delete": .bool(true)])
        #expect(try await f.ownerGit(["for-each-ref", "refs/heads/" + branch]).isEmpty)
        _ = try await f.ownerGit(["reflog", "expire", "--expire=now", "--all"])
        _ = try await f.ownerGit(["gc", "--prune=now"])
        let retained = try await f.ownerGit([
          "for-each-ref", "--format=%(objectname)", "refs/computer-mcp/recovery/",
        ])
        for (oid, type) in zip(roots, ["commit", "tag", "blob", "tree"]) {
          #expect(retained.split(separator: "\n").contains(Substring(oid)))
          #expect(try await f.ownerGit(["cat-file", "-t", oid]) == type + "\n")
          _ = try await f.ownerGit(["cat-file", "-p", oid])
        }
        _ = try await f.ownerGit(["fsck", "--full", "--strict", "--no-dangling"])
        #expect(await http.controlSessions().map(\.id) == [session.id])
        #expect(try f.database.profiles() == profiles)
        let audit = try f.database.auditEvents(limit: 200)
        #expect(!audit.isEmpty)
        #expect(!audit.contains { $0.decision == .failed })
        print(
          "WORKTREE_HTTP managed=\(managed) session=1 approvals=0 lifecycle=complete build=passed")
        await client.disconnect()
        await http.stop()
        await app?.service.stop()
      } catch {
        await client.disconnect()
        await http.stop()
        await app?.service.stop()
        throw error
      }
    }
  }

  @Test(arguments: [false, true])
  func backgroundBuildSurvivesAuthenticatedReconnect(managed: Bool) async throws {
    let f = try FixedHostFixture(
      fullAccess: false, lifecycle: true, caller: .cloudflareTunnel, gitExecutable: gitExecutable)
    try await f.run { f in
      try await preparePackage(f)
      let app = managed ? try await GatewayManagedHostFixture(f) : nil
      let source: GatewayHTTPSessionSource
      if let app {
        source = .managed(
          try await app.service.makeHTTPSessions(
            profileID: .chatGPTOperate, trace: .init(transport: "http")))
      } else {
        source = .registry(f.runtime)
      }
      let http = GatewayHTTPRuntime(
        configuration: f.configuration, source: source,
        host: "127.0.0.1", port: 0, publicBaseURL: nil, accessToken: "reconnect-fixture")
      try await http.startListening()
      let endpoint = URL(string: "http://127.0.0.1:\(try #require(await http.boundPort()))/mcp")!
      var client = try await GatewayClientSession.connectHTTP(
        endpoint: endpoint, accessToken: "reconnect-fixture")
      do {
        let first = try #require(await http.controlSessions().only)
        let worktree = try await call(
          client, "git.worktree_add", "fixture", ["name": .string("reconnect")])
        let id = try #require(worktree["project_id"]?.stringValue)
        let started = try await call(
          client, "shell.spawn", id,
          [
            "command": .string(
              "set -e; echo BUILD_STARTED; sleep 5; /usr/bin/swift build --build-system native --disable-sandbox --scratch-path \"$TMPDIR/build\"; /usr/bin/swift test --build-system native --disable-sandbox --scratch-path \"$TMPDIR/build\"; echo BUILD_FINISHED"
            ),
            "shell": .string("/bin/sh"), "timeout_ms": .integer(180_000),
          ])
        let sessionID = try #require(started["session_id"]?.stringValue)
        let initial = try await call(client, "shell.read", id, ["session_id": .string(sessionID)])
        #expect(initial["is_running"] == .bool(true))
        let executionID = try #require(initial["execution_id"]?.stringValue)
        await client.disconnect()
        client = try await GatewayClientSession.connectHTTP(
          endpoint: endpoint, accessToken: "reconnect-fixture")
        let second = try #require(await http.controlSessions().only)
        #expect(first.id != second.id && first.principalID == second.principalID)
        let resumed = try await call(client, "shell.read", id, ["session_id": .string(sessionID)])
        #expect(resumed["execution_id"]?.stringValue == executionID)
        try await readBuild(client, projectID: id, sessionID: sessionID)
        _ = try await call(client, "git.worktree_remove", id)
        print("WORKTREE_HTTP managed=\(managed) reconnect=true same_execution=true completed=true")
        await client.disconnect()
        await http.stop()
        await app?.service.stop()
      } catch {
        await client.disconnect()
        await http.stop()
        await app?.service.stop()
        throw error
      }
    }
  }

  private func preparePackage(_ f: FixedHostFixture) async throws {
    try await f.initializeRepository()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Tools/Validation/Fixtures/WorktreePackage")
    for entry in try FileManager.default.contentsOfDirectory(atPath: fixture.path) {
      try FileManager.default.copyItem(
        at: fixture.appendingPathComponent(entry), to: f.project.appendingPathComponent(entry))
    }
    try Data("original".utf8).write(to: f.project.appendingPathComponent("owner.txt"))
    _ = try await f.ownerGit(["add", "."])
    _ = try await f.ownerGit(["commit", "-qm", "package"])
  }

  func call(
    _ client: GatewayClientSession, _ name: String, _ project: String,
    _ arguments: [String: JSONValue] = [:]
  ) async throws -> [String: JSONValue] {
    var arguments = arguments
    arguments["project_id"] = .string(project)
    let report = try await client.call(toolName: name, arguments: .object(arguments))
    try #require(report.result.objectValue?["isError"] != .bool(true), "\(name): \(report.result)")
    print("WORKTREE_HTTP call=\(name) request=\(report.requestID) result=allowed")
    return try #require(
      report.result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
  }

  private func shell(_ client: GatewayClientSession, _ project: String, _ command: String)
    async throws -> [String: JSONValue]
  {
    let quotedGit = "'" + gitExecutable.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let script =
      "git() { " + quotedGit
      + " -c user.name=Fixture -c user.email=fixture@example.invalid \"$@\"; }; " + command
    let result = try await call(
      client, "shell.run", project,
      ["command": .string(script), "shell": .string("/bin/sh"), "timeout_ms": .integer(60_000)])
    try #require(result["exit_code"] == .integer(0), "\(result)")
    return result
  }

  private func readBuild(_ client: GatewayClientSession, projectID: String, sessionID: String)
    async throws
  {
    var stdout: Int64 = 0
    var stderr: Int64 = 0
    var output = ""
    var reads = 0
    var sawRunning = false
    let deadline = ContinuousClock.now + .seconds(180)
    while ContinuousClock.now < deadline {
      let value = try await call(
        client, "shell.read", projectID,
        [
          "session_id": .string(sessionID), "stdout_cursor": .integer(stdout),
          "stderr_cursor": .integer(stderr), "max_bytes": .integer(65_536),
        ])
      reads += 1
      for key in ["stdout", "stderr"] {
        let stream = try #require(value[key]?.objectValue)
        #expect(stream["missed_bytes"] == .bool(false))
        output += stream["text"]?.stringValue ?? ""
        let cursor = try #require(stream["next_cursor"]?.intValue)
        if key == "stdout" { stdout = Int64(cursor) } else { stderr = Int64(cursor) }
      }
      if value["is_running"] == .bool(false) {
        try #require(value["exit_code"] == .integer(0), "\(value)\n\(output)")
        #expect(output.contains("BUILD_STARTED") && output.contains("BUILD_FINISHED"))
        #expect(sawRunning && reads > 1)
        return
      }
      sawRunning = true
      try await Task.sleep(for: .milliseconds(250))
    }
    Issue.record("Background build did not finish within its acceptance budget")
  }
}

extension Array {
  fileprivate var only: Element? { count == 1 ? first : nil }
}
