import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway

@Suite(.nativeIntegration, .serialized)
struct GatewayWorktreeExecutionTests {
  @Test func sandboxFileGitAndRawCommandsUsePrivateObjects() async throws {
    let f = try FixedHostFixture(fullAccess: false, lifecycle: true)
    try await f.run { f in
      try await f.initializeRepository()
      let calls = GatewayStandaloneGenerations(f.runtime)
      do {
        let made = try await call(calls, "git.worktree_add", ["name": .string("execute")])
        let id = try #require(made["project_id"]?.stringValue)
        let path = try #require(made["path"]?.stringValue)
        let branch = try #require(made["branch"]?.stringValue)
        let base = try #require(made["base"]?.stringValue)
        let initial = try await f.ownerGit(["rev-parse", "HEAD"])
        _ = try await call(
          calls, "file.write",
          ["project_id": .string(id), "path": .string("value.txt"), "content": .string("edited")])
        _ = try await call(
          calls, "git.add", ["project_id": .string(id), "paths": .array([.string("value.txt")])])
        _ = try await call(
          calls, "file.write",
          ["project_id": .string(id), "path": .string("staged.txt"), "content": .string("staged")])
        _ = try await call(
          calls, "git.add", ["project_id": .string(id), "paths": .array([.string("staged.txt")])])
        _ = try await call(
          calls, "git.commit",
          [
            "project_id": .string(id), "message": .string("feat: edit"),
            "paths": .array([.string("value.txt")]),
          ])
        let author = try await shell(calls, id, "git log -1 --format=%an")
        #expect(String(describing: author).contains("Fixture"), "\(author)")
        let staged = try await shell(calls, id, "git diff --cached --name-only")
        #expect(String(describing: staged).contains("staged.txt"), "\(staged)")
        let committedPaths = try await shell(calls, id, "git show --pretty= --name-only HEAD")
        #expect(!String(describing: committedPaths).contains("staged.txt"), "\(committedPaths)")
        let result = try await shell(
          calls, id,
          "set -e; git rev-parse HEAD; printf 'raw' > raw; git add raw; git -c user.name=Fixture -c user.email=fixture@example.invalid commit -m raw; git fetch origin; git rebase origin/\(base)"
        )
        #expect(result["exit_code"] == .integer(0), "\(result)")
        #expect(try await f.ownerGit(["rev-parse", "refs/heads/" + branch]) == initial)
        #expect(
          try String(contentsOf: f.project.appendingPathComponent("value.txt"), encoding: .utf8)
            == "original")
        _ = try await call(calls, "git.status", ["project_id": .string(id)])
        let log = try await call(calls, "git.log", ["project_id": .string(id)])
        #expect(String(describing: log).contains("raw"), "\(log)")
        let denied = try await shell(calls, id, "printf bad > '\(f.project.path)/value.txt'")
        #expect(denied["exit_code"] != .integer(0))
        #expect(FileManager.default.fileExists(atPath: path + "/raw"))
        await calls.shutdown()
      } catch {
        await calls.shutdown()
        throw error
      }
    }
  }

  @Test func trackedNestedProjectWritesFollowAdmittedGrants() async throws {
    let f = try FixedHostFixture(fullAccess: false, lifecycle: true, nestedAccess: .write)
    try await f.run { f in
      try await f.initializeRepository()
      _ = try await f.ownerGit(["add", "nested"])
      _ = try await f.ownerGit(["commit", "-m", "nested content"])
      let calls = GatewayStandaloneGenerations(f.runtime)
      do {
        let made = try await call(calls, "git.worktree_add", ["name": .string("nested")])
        let root = try #require(made["path"]?.stringValue)
        let id = try #require(made["project_id"]?.stringValue)
        #expect(try String(contentsOfFile: root + "/nested/value.txt", encoding: .utf8) == "nested")
        let wrote = try await shell(calls, id, "printf changed > nested/value.txt")
        #expect(wrote["exit_code"] == .integer(0), "\(wrote)")
        #expect(
          try String(contentsOfFile: root + "/nested/value.txt", encoding: .utf8) == "changed")
        #expect(
          try String(
            contentsOf: f.project.appendingPathComponent("nested/value.txt"), encoding: .utf8)
            == "nested")
        _ = try await call(
          calls, "git.worktree_remove", ["project_id": .string(id), "force": .bool(true)])
        #expect(!FileManager.default.fileExists(atPath: root))
        await calls.shutdown()
      } catch {
        await calls.shutdown()
        throw error
      }
    }
  }

  @Test func sandboxAndHostFileChecksRefuseSourceSiblingAndLinkEscapes() async throws {
    let f = try FixedHostFixture(fullAccess: false, lifecycle: true, nestedAccess: .read)
    try await f.run { f in
      try await f.initializeRepository()
      let calls = GatewayStandaloneGenerations(f.runtime)
      do {
        let made = try await call(calls, "git.worktree_add", ["name": .string("confined")])
        let sibling = try await call(calls, "git.worktree_add", ["name": .string("sibling")])
        let id = try #require(made["project_id"]?.stringValue)
        let path = try #require(made["path"]?.stringValue)
        let siblingPath = try #require(sibling["path"]?.stringValue)
        let source = f.project.appendingPathComponent("value.txt")
        let nested = URL(fileURLWithPath: path + "/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: nested.appendingPathComponent("value.txt"))
        try FileManager.default.createSymbolicLink(
          atPath: path + "/symbolic", withDestinationPath: source.path)
        try FileManager.default.linkItem(at: source, to: URL(fileURLWithPath: path + "/hard"))
        for target in [
          "symbolic", "hard", ".git", "nested/value.txt", source.path, siblingPath + "/value.txt",
        ] {
          let result = try await calls.callToolForMCPAsync(
            name: "file.write",
            arguments: .object([
              "project_id": .string(id), "path": .string(target), "content": .string("escaped"),
            ]), context: .empty)
          #expect(result.objectValue?["isError"] == .bool(true), "\(target): \(result)")
        }
        for target in [
          path + "/nested/value.txt", source.path, siblingPath + "/value.txt",
          f.database.permissionExecutionRoot.deletingLastPathComponent().appendingPathComponent(
            "escape"
          ).path,
        ] {
          let result = try await shell(calls, id, "printf escaped > '" + target + "'")
          #expect(result["exit_code"] != .integer(0), "\(result)")
        }
        let environment = try await shell(
          calls, id,
          "set -e; test -z \"${GIT_OBJECT_DIRECTORY+x}\"; test -z \"${GIT_ALTERNATE_OBJECT_DIRECTORIES+x}\"; case \"$HOME\" in '"
            + f.database.permissionExecutionRoot.path
            + "'/*) ;; *) exit 1;; esac; test \"$HOME\" = \"${TMPDIR%/}\"")
        #expect(environment["exit_code"] == .integer(0), "\(environment)")
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        #expect(
          try String(contentsOfFile: siblingPath + "/value.txt", encoding: .utf8) == "original")
        await calls.shutdown()
      } catch {
        await calls.shutdown()
        throw error
      }
    }
  }

  @Test(
    arguments: ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].filter {
      FileManager.default.isExecutableFile(atPath: $0)
    })
  func rebaseConflictCanAbortAndContinueWithoutSharedRefWrites(binary: String) async throws {
    let f = try FixedHostFixture(fullAccess: false, lifecycle: true)
    try await f.run { f in
      try await f.initializeRepository()
      let calls = GatewayStandaloneGenerations(f.runtime)
      do {
        let made = try await call(calls, "git.worktree_add", ["name": .string("rebase")])
        let id = try #require(made["project_id"]?.stringValue)
        let base = try #require(made["base"]?.stringValue)
        let git =
          binary
          + " -c user.name=Fixture -c user.email=fixture@example.invalid -c gc.auto=0 -c maintenance.auto=false -c core.hooksPath=/dev/null"
        let committed = try await shell(
          calls, id,
          "set -e; printf worktree > value.txt; \(git) add value.txt; \(git) commit -m worktree")
        try #require(committed["exit_code"] == .integer(0), "\(committed)")
        try Data("source".utf8).write(to: f.project.appendingPathComponent("value.txt"))
        _ = try await f.ownerGit(["add", "value.txt"])
        _ = try await f.ownerGit(["commit", "-m", "source"])
        let source = try await f.ownerGit(["rev-parse", "HEAD"])
        let fetched = try await shell(calls, id, "\(git) fetch origin")
        try #require(fetched["exit_code"] == .integer(0), "\(fetched)")
        let conflict = try await shell(calls, id, "\(git) rebase origin/\(base)")
        try #require(conflict["exit_code"] == .integer(1), "\(conflict)")
        #expect(String(describing: conflict).contains("CONFLICT"), "\(conflict)")
        let abort = try await shell(calls, id, "\(git) rebase --abort")
        try #require(abort["exit_code"] == .integer(0), "\(abort)")
        let again = try await shell(calls, id, "\(git) rebase origin/\(base)")
        try #require(again["exit_code"] == .integer(1), "\(again)")
        #expect(String(describing: again).contains("CONFLICT"), "\(again)")
        let resolved = try await shell(
          calls, id,
          "set -e; printf resolved > value.txt; \(git) add value.txt; GIT_EDITOR=/usr/bin/true \(git) rebase --continue"
        )
        try #require(resolved["exit_code"] == .integer(0), "\(resolved)")
        let clean = try await shell(
          calls, id,
          "set -e; test ! -e \"$(\(binary) rev-parse --git-path CHERRY_PICK_HEAD)\"; test ! -e \"$(\(binary) rev-parse --git-path AUTO_MERGE)\"; printf next >> value.txt; \(git) add value.txt; \(git) commit --only -m next -- value.txt; printf stashed >> value.txt; \(git) stash push -m retained; \(git) stash pop; \(git) switch -c private"
        )
        try #require(clean["exit_code"] == .integer(0), "\(clean)")
        #expect(try await f.ownerGit(["rev-parse", "HEAD"]) == source)
        await calls.shutdown()
      } catch {
        await calls.shutdown()
        throw error
      }
    }
  }

  @Test(arguments: [false, true], ["shell", "process"])
  func removalTerminatesEveryAdmittedWorktreeWriter(fullAccess: Bool, kind: String) async throws {
    let f = try FixedHostFixture(fullAccess: fullAccess, lifecycle: true)
    try await f.run { f in
      if fullAccess { _ = try f.session.approveFullAccess(expectedRevision: f.session.revision) }
      try await f.initializeRepository()
      let calls = GatewayStandaloneGenerations(f.runtime)
      do {
        let made = try await call(
          calls, "git.worktree_add", ["name": .string("writer")], session: f.session)
        let id = try #require(made["project_id"]?.stringValue)
        let path = try #require(made["path"]?.stringValue)
        let script =
          "trap '' TERM; echo ready > ready; while :; do echo writing >> active; /bin/sleep 0.05; done"
        var arguments: [String: JSONValue] = ["project_id": .string(id)]
        if kind == "shell" {
          arguments["command"] = .string(script)
          arguments["shell"] = .string("/bin/sh")
        } else {
          arguments["id"] = .string("fixture")
          arguments["argv"] = .array([.string("-c"), .string(script)])
        }
        _ = try await call(calls, kind + ".spawn", arguments, session: f.session)
        let owner = try #require(f.observations.ownerships.last)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: path + "/ready"),
          ContinuousClock.now < deadline
        { try await Task.sleep(for: .milliseconds(10)) }
        try #require(FileManager.default.fileExists(atPath: path + "/ready"))
        let removed = try await call(
          calls, "git.worktree_remove", ["project_id": .string(id), "force": .bool(true)],
          session: f.session)
        let warnings = try #require(removed["terminationWarnings"]?.arrayValue)
        #expect(warnings.isEmpty == !fullAccess)
        #expect(try await owner.members().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
        await calls.shutdown()
      } catch {
        await calls.shutdown()
        throw error
      }
    }
  }

  private func call(
    _ runtime: GatewayStandaloneGenerations, _ name: String, _ arguments: [String: JSONValue],
    session: GatewayControlSession? = nil
  ) async throws -> [String: JSONValue] {
    let result = try await runtime.callToolForMCPAsync(
      name: name, arguments: .object(arguments), context: .init(session: session))
    try #require(result.objectValue?["isError"] != .bool(true), "\(result)")
    let payload = try #require(
      result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
    if let command = payload["result"]?.objectValue, let exit = command["exit_code"] {
      try #require(exit == .integer(0), "\(payload)")
    }
    return payload
  }

  private func shell(_ runtime: GatewayStandaloneGenerations, _ id: String, _ command: String)
    async throws -> [String: JSONValue]
  {
    try await call(
      runtime, "shell.run",
      ["project_id": .string(id), "command": .string(command), "shell": .string("/bin/sh")])
  }
}
