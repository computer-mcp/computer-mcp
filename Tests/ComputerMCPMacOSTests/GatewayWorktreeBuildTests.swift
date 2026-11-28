import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway

/// Inputs are disposable source archives and dependency mirrors prepared by the
/// acceptance runner. Neither the original checkout nor its caches are opened.
@Suite(.nativeIntegration, .serialized)
struct GatewayWorktreeBuildTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["COMPUTER_MCP_WORKTREE_BUILD_SPEC"] != nil))
  func coldNativePackageBuildAndFilteredTests() async throws {
    struct Input: Decodable {
      let source: String
      let mirrors: String
      let locations: [String: String]
      let swift: String
      let sdk: String
      let filter: String
      let evidence: String
    }
    let input = try JSONDecoder().decode(
      Input.self,
      from: Data(
        contentsOf: URL(
          fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["COMPUTER_MCP_WORKTREE_BUILD_SPEC"]))))
    let f = try FixedHostFixture(fullAccess: false, lifecycle: true)
    try await f.run { f in
      let files = FileManager.default
      for item in try files.contentsOfDirectory(
        at: URL(fileURLWithPath: input.source), includingPropertiesForKeys: nil)
      {
        try files.copyItem(at: item, to: f.project.appendingPathComponent(item.lastPathComponent))
      }
      try await f.initializeRepository()
      _ = try await f.ownerGit(["add", "--all"])
      _ = try await f.ownerGit(["commit", "--allow-empty", "-m", "source fixture"])
      let sourceHEAD = try await f.ownerGit(["rev-parse", "HEAD"])
      let sourceObjects = try await f.ownerGit(["count-objects", "-v"])
      let calls = GatewayStandaloneGenerations(f.runtime)
      do {
        let made = try await call(calls, f, "git.worktree_add", ["name": .string("cold-build")])
        let id = try #require(made["project_id"]?.stringValue)
        let root = URL(fileURLWithPath: try #require(made["path"]?.stringValue))
        let probe = root.appendingPathComponent(".worktree-build")
        try files.createDirectory(at: probe, withIntermediateDirectories: false)
        try files.copyItem(
          at: URL(fileURLWithPath: input.mirrors), to: probe.appendingPathComponent("mirrors"))
        let mirrors: [String: Any] = [
          "version": 1,
          "object": input.locations.sorted { $0.key < $1.key }.map { original, name in
            [
              "original": original,
              "mirror": probe.appendingPathComponent("mirrors/" + name).absoluteString,
            ]
          },
        ]
        try JSONSerialization.data(withJSONObject: mirrors, options: [.sortedKeys]).write(
          to: probe.appendingPathComponent("mirrors.json"))
        func quoted(_ value: String) -> String {
          "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var gitConfiguration = [("protocol.file.allow", "always")]
        gitConfiguration += input.locations.sorted { $0.key < $1.key }.map { original, name in
          (
            "url." + probe.appendingPathComponent("mirrors/" + name).absoluteString + ".insteadOf",
            original
          )
        }
        let gitEnvironment =
          (["export GIT_CONFIG_COUNT=\(gitConfiguration.count)"]
          + gitConfiguration.enumerated().flatMap { index, entry in
            [
              "export GIT_CONFIG_KEY_\(index)=\(quoted(entry.0))",
              "export GIT_CONFIG_VALUE_\(index)=\(quoted(entry.1))",
            ]
          }).joined(separator: "\n")
        let options =
          "--build-system native --disable-sandbox --jobs 4 --sdk " + quoted(input.sdk)
          + " --cache-path \"$HOME/cache\" --config-path \"$HOME/configuration\" --security-path \"$HOME/security\" --skip-update"
        let script = """
          set -e
          printf '%s' "$HOME" > .worktree-build/home
          mkdir -p "$HOME/configuration" "$HOME/cache" "$HOME/security"
          cp .worktree-build/mirrors.json "$HOME/configuration/mirrors.json"
          export SWIFTPM_MIRROR_CONFIG="$HOME/configuration/mirrors.json"
          \(gitEnvironment)
          set +e
          { \(quoted(input.swift)) build --build-tests \(options) && \(quoted(input.swift)) test --skip-build --no-parallel --filter \(quoted(input.filter)) \(options) && printf '\\nAllocated KiB (build, private home, mirrors):\\n' && /usr/bin/du -sk .build "$HOME" .worktree-build/mirrors && git count-objects -v; } > .worktree-build/output.log 2>&1
          code=$?
          printf '%s' "$code" > .worktree-build/exit
          exit "$code"
          """
        let started = ContinuousClock.now
        let spawned = try await call(
          calls, f, "shell.spawn",
          ["project_id": .string(id), "command": .string(script), "shell": .string("/bin/sh")])
        let session = try #require(spawned["session_id"]?.stringValue)
        var snapshot = try await call(
          calls, f, "shell.read", ["project_id": .string(id), "session_id": .string(session)])
        let deadline = started.advanced(by: .seconds(1800))
        while snapshot["is_running"] == .bool(true), ContinuousClock.now < deadline {
          try await Task.sleep(for: .seconds(5))
          snapshot = try await call(
            calls, f, "shell.read", ["project_id": .string(id), "session_id": .string(session)])
          let log =
            (try? String(contentsOf: probe.appendingPathComponent("output.log"), encoding: .utf8))
            ?? ""
          try log.split(separator: "\n").suffix(4).joined(separator: "\n").write(
            toFile: input.evidence + ".progress", atomically: true, encoding: .utf8)
        }
        let log =
          (try? String(contentsOf: probe.appendingPathComponent("output.log"), encoding: .utf8))
          ?? "No build output"
        try ("Source objects:\n\(sourceObjects)\nElapsed: \(started.duration(to: .now))\n" + log)
          .write(
            toFile: input.evidence, atomically: true, encoding: .utf8)
        #expect(snapshot["is_running"] == .bool(false), "Cold build exceeded its bounded interval")
        #expect(snapshot["exit_code"] == .integer(0), "\(snapshot)\n\(log.suffix(12_000))")
        let home = try String(contentsOf: probe.appendingPathComponent("home"), encoding: .utf8)
        #expect(home.hasPrefix(f.database.permissionExecutionRoot.path + "/"))
        #expect(files.fileExists(atPath: root.appendingPathComponent(".build").path))
        #expect(!files.fileExists(atPath: f.project.appendingPathComponent(".build").path))
        #expect(try await f.ownerGit(["status", "--porcelain"]).isEmpty)
        #expect(try await f.ownerGit(["rev-parse", "HEAD"]) == sourceHEAD)
        await calls.shutdown()
      } catch {
        await calls.shutdown()
        throw error
      }
    }
  }

  private func call(
    _ runtime: GatewayStandaloneGenerations, _ f: FixedHostFixture, _ name: String,
    _ arguments: [String: JSONValue]
  ) async throws -> [String: JSONValue] {
    let result = try await runtime.callToolForMCPAsync(
      name: name, arguments: .object(arguments), context: .init(session: f.session))
    try #require(result.objectValue?["isError"] != .bool(true), "\(result)")
    return try #require(
      result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
  }
}
