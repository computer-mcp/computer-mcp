import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPWorktrees

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
      fullAccess: false, lifecycle: true, caller: .cloudflareTunnel, gitExecutable: gitExecutable,
      managed: managed)
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
      let logs = WorktreeAcceptanceLogs()
      let accessToken = "worktree-acceptance-" + UUID().uuidString
      let privateContent = "private-content-" + UUID().uuidString
      let privateOutput = "private-output-" + UUID().uuidString
      let http = GatewayHTTPRuntime(
        configuration: f.configuration, source: source, host: "127.0.0.1", port: 0,
        publicBaseURL: nil,
        accessToken: accessToken, logger: logs.logger)
      try await http.startListening()
      let endpoint = URL(string: "http://127.0.0.1:\(try #require(await http.boundPort()))/mcp")!
      let client = try await GatewayClientSession.connectHTTP(
        endpoint: endpoint, accessToken: accessToken)
      do {
        let session = try #require(await http.controlSessions().only)
        let made = try await call(client, "git.worktree_add", "fixture", ["name": .string("http")])
        let id = try #require(made["project_id"]?.stringValue)
        let path = try #require(made["path"]?.stringValue)
        let branch = try #require(made["branch"]?.stringValue)
        let base = try #require(made["base"]?.stringValue)
        if managed {
          let directories = GatewayManagedHostFixture.directories(root: f.root)
          #expect(
            path.hasPrefix(
              directories.applicationSupport.appendingPathComponent("Worktrees").path + "/"))
          #expect(
            Set(
              try f.platform.hostDataPaths.map {
                try ProjectPathResolver.resolve($0.path, relativeTo: URL(fileURLWithPath: "/")).path
              }
            ).isSuperset(
              of: try directories.hostDataPaths.map {
                try ProjectPathResolver.resolve($0.path, relativeTo: URL(fileURLWithPath: "/")).path
              }))
        }
        let binding = try #require(
          try f.database.executionWorktree(
            projectID: id, directory: URL(fileURLWithPath: path), platform: f.platform))
        try binding.binding.verify()
        #expect(try f.database.profiles() == profiles)
        _ = try await call(client, "git.worktree_list", "fixture")
        _ = try await call(client, "project.describe", id)
        _ = try await call(
          client, "file.write", id,
          ["path": .string("value.txt"), "content": .string(privateContent)])
        _ = try await call(client, "git.add", id, ["paths": .array([.string("value.txt")])])
        _ = try await call(
          client, "git.commit", id,
          ["message": .string("edit"), "paths": .array([.string("value.txt")])])
        let secretOutput = try await shell(client, id, "printf '%s' '" + privateOutput + "'")
        #expect(secretOutput["stdout"]?.objectValue?["text"]?.stringValue == privateOutput)
        if managed {
          let hostDatabase = try #require(f.database.fileURL).path
          let denied = try await shell(
            client, id, "if cat '" + hostDatabase + "' >/dev/null 2>&1; then exit 1; fi")
          #expect(denied["exit_code"] == .integer(0))
        }
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
        try await f.verifyRetainedObjects(roots, storage: #require(f.database.worktreeStorage))
        #expect(await http.controlSessions().map(\.id) == [session.id])
        #expect(try f.database.profiles() == profiles)
        let audit = try await f.database.connection.writer.read { db in
          try AuditEventRecord.fetchAll(db).map { try $0.value() }
        }
        #expect(!audit.isEmpty)
        #expect(!audit.contains { $0.decision == .failed })
        let principal = try #require(AuditEvent.verifiedPrincipalDigest(session.principalID))
        #expect(audit.allSatisfy { $0.principalDigest == principal })
        let ledger = try await f.database.configuredPermissionStore().read()
        #expect(ledger.requests.isEmpty)
        #expect(await http.controlSessions().allSatisfy { $0.fullAccessConsent == nil })
        #expect(try f.database.clientTrusts().isEmpty)
        #expect(!audit.contains { $0.capabilityID.hasPrefix("control.full-access.") })
        let encodedAudit = String(decoding: try JSONEncoder().encode(audit), as: UTF8.self)
        #expect(!logs.entries.isEmpty)
        for secret in [accessToken, privateContent, privateOutput] {
          #expect(!encodedAudit.contains(secret), "Audit rows must omit fixture secrets")
          #expect(
            !logs.entries.contains { $0.contains(secret) }, "HTTP logs must omit fixture secrets")
        }
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
      fullAccess: false, lifecycle: true, caller: .cloudflareTunnel, gitExecutable: gitExecutable,
      managed: managed)
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
              "set -e; echo BUILD_STARTED; echo STDERR_STARTED >&2; sleep 5; /usr/bin/swift build --build-system native --disable-sandbox --scratch-path \"$TMPDIR/build\"; /usr/bin/swift test --build-system native --disable-sandbox --scratch-path \"$TMPDIR/build\"; echo BUILD_FINISHED"
            ),
            "shell": .string("/bin/sh"), "timeout_ms": .integer(180_000),
          ])
        let sessionID = try #require(started["session_id"]?.stringValue)
        var initial = try await call(client, "shell.read", id, ["session_id": .string(sessionID)])
        let deadline = ContinuousClock.now + .seconds(10)
        while initial["stdout"]?.objectValue?["text"]?.stringValue?.contains("BUILD_STARTED")
          != true
          || initial["stderr"]?.objectValue?["text"]?.stringValue?.contains("STDERR_STARTED")
            != true
        {
          try #require(ContinuousClock.now < deadline)
          try await Task.sleep(for: .milliseconds(20))
          initial = try await call(client, "shell.read", id, ["session_id": .string(sessionID)])
        }
        #expect(initial["is_running"] == .bool(true))
        let stdout = try #require(initial["stdout"]?.objectValue?["next_cursor"]?.intValue)
        let stderr = try #require(initial["stderr"]?.objectValue?["next_cursor"]?.intValue)
        #expect(stdout > 0 && stderr > 0)
        let executionID = try #require(initial["execution_id"]?.stringValue)
        await client.disconnect()
        client = try await GatewayClientSession.connectHTTP(
          endpoint: endpoint, accessToken: "reconnect-fixture")
        let second = try #require(await http.controlSessions().only)
        #expect(first.id != second.id && first.principalID == second.principalID)
        let resumed = try await call(
          client, "shell.read", id,
          [
            "session_id": .string(sessionID), "stdout_cursor": .integer(Int64(stdout)),
            "stderr_cursor": .integer(Int64(stderr)),
          ])
        #expect(resumed["execution_id"]?.stringValue == executionID)
        var output = ""
        for (key, cursor) in [("stdout", stdout), ("stderr", stderr)] {
          let stream = try #require(resumed[key]?.objectValue)
          #expect(stream["requested_cursor"] == .integer(Int64(cursor)))
          #expect(stream["start_cursor"] == .integer(Int64(cursor)))
          #expect(stream["missed_bytes"] == .bool(false))
          output += initial[key]?.objectValue?["text"]?.stringValue ?? ""
          output += stream["text"]?.stringValue ?? ""
        }
        try await readBuild(
          client, projectID: id, sessionID: sessionID,
          stdoutCursor: Int64(
            try #require(resumed["stdout"]?.objectValue?["next_cursor"]?.intValue)),
          stderrCursor: Int64(
            try #require(resumed["stderr"]?.objectValue?["next_cursor"]?.intValue)),
          priorOutput: output)
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

  private func readBuild(
    _ client: GatewayClientSession, projectID: String, sessionID: String,
    stdoutCursor: Int64 = 0, stderrCursor: Int64 = 0, priorOutput: String = ""
  ) async throws {
    var stdout = stdoutCursor
    var stderr = stderrCursor
    var output = priorOutput
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
        #expect(output.components(separatedBy: "BUILD_STARTED").count == 2)
        #expect(output.components(separatedBy: "BUILD_FINISHED").count == 2)
        #expect(sawRunning && reads > 1)
        return
      }
      sawRunning = true
      try await Task.sleep(for: .milliseconds(250))
    }
    Issue.record("Background build did not finish within its acceptance budget")
  }
}

extension FixedHostFixture {
  func verifyRetainedObjects(_ roots: [String], storage: WorktreeStorage) async throws {
    _ = try await ownerGit(["reflog", "expire", "--expire=now", "--all"])
    _ = try await ownerGit(["gc", "--prune=now"])
    let snapshot = try #require(try WorktreeRecoveryStore(storage: storage).list().only)
    try #require(snapshot.repository.sourcePath == project.resolvingSymlinksInPath().path)
    let recovery = storage.recovery.appendingPathComponent(
      "stores/" + snapshot.key + "/repository.git")
    let gitDirectory = "--git-dir=" + recovery.path
    for (oid, type) in zip(roots, ["commit", "tag", "blob", "tree"]) {
      #expect(snapshot.catalog.records.contains { $0.oid == oid })
      #expect(try await ownerGit([gitDirectory, "cat-file", "-t", oid]) == type + "\n")
      _ = try await ownerGit([gitDirectory, "cat-file", "-p", oid])
    }
    #expect(try await ownerGit(["for-each-ref", "refs/computer-mcp/recovery/"]).isEmpty)
    _ = try await ownerGit([gitDirectory, "fsck", "--full", "--strict", "--no-dangling"])
    _ = try await ownerGit(["fsck", "--full", "--strict", "--no-dangling"])
  }
}

extension Array {
  fileprivate var only: Element? { count == 1 ? first : nil }
}

private final class WorktreeAcceptanceLogs: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []
  var entries: [String] { lock.withLock { messages } }
  var logger: Logger { Logger(label: "worktree-acceptance", factory: { _ in Handler(logs: self) }) }
  private func append(_ message: String) { lock.withLock { messages.append(message) } }

  private struct Handler: LogHandler {
    let logs: WorktreeAcceptanceLogs
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
      get { metadata[key] }
      set { metadata[key] = newValue }
    }
    func log(
      level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
      source: String, file: String, function: String, line: UInt
    ) {
      logs.append("\(message) \(self.metadata) \(metadata ?? [:])")
    }
  }
}
