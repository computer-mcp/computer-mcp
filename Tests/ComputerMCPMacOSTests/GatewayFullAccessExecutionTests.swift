import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPGateway

@Suite(.nativeIntegration, .serialized)
struct GatewayFullAccessExecutionTests {
  @Test func shellAndCLIRequireConsentAndReportTheirBoundary() async throws {
    let f = try FixedHostFixture()
    try await f.run { f in
      let arguments: [String: JSONValue] = [
        "command": .string("printf full-access"), "shell": .string("/bin/sh"),
      ]
      #expect(try await f.call("shell.run", arguments).objectValue?["isError"] == .bool(true))
      #expect(f.observations.ownerships.isEmpty)
      _ = try f.session.approveFullAccess(expectedRevision: f.session.revision)
      for (tool, input) in [
        ("shell.run", arguments),
        (
          "cli.exec",
          [
            "id": .string("fixture"),
            "argv": .array([.string("-c"), .string("printf full-access")]),
          ]
        ),
      ] {
        let result = try await f.call(tool, input)
        #expect(result.objectValue?["isError"] != .bool(true), "\(result)")
        let content = try #require(
          result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
        #expect(String(describing: content["stdout"]).contains("full-access"))
        #expect(content["ownership"]?.objectValue?["scope"] == .string("process_group_best_effort"))
        #expect(
          content["ownership"]?.objectValue?["warning"]?.stringValue?.contains("outside ownership")
            == true)
      }
      try f.session.limitAccess(
        to: .init(allowsFullAccess: false), expectedRevision: f.session.revision)
      let starts = f.observations.ownerships.count
      #expect(try await f.call("shell.run", arguments).objectValue?["isError"] == .bool(true))
      #expect(f.observations.ownerships.count == starts)
    }
  }

  @Test(arguments: ["shell", "process"], ["cancel", "revoke", "limits", "connection"])
  func groupTerminationFollowsLiveAuthority(kind: String, ending: String) async throws {
    let f = try FixedHostFixture()
    try await f.run { f in
      _ = try f.session.approveFullAccess(expectedRevision: f.session.revision)
      let script = "trap '' TERM; /bin/sleep 120 & echo \"$$ $!\" > pids; printf ready; wait"
      let arguments: [String: JSONValue] =
        kind == "shell"
        ? ["command": .string(script), "shell": .string("/bin/sh")]
        : ["id": .string("fixture"), "argv": .array([.string("-c"), .string(script)])]
      let spawned = try await f.call(kind + ".spawn", arguments)
      let idKey = kind == "shell" ? "session_id" : "process_id"
      let id = try #require(
        spawned.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?[idKey]?
          .stringValue, "\(spawned)")
      let owner = try #require(f.observations.ownerships.last)
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      var members: [ExecutionMember] = []
      repeat {
        members = try await owner.members()
        if members.count >= 2 { break }
        try await Task.sleep(for: .milliseconds(10))
      } while ContinuousClock.now < deadline
      try #require(members.count >= 2)
      let read = try await f.call(kind + ".read", [idKey: .string(id)])
      let snapshot = read.objectValue?["structuredContent"]?.objectValue?["result"]
      let execution = kind == "shell" ? snapshot : snapshot?.objectValue?["execution"]
      #expect(
        execution?.objectValue?["ownership"]?.objectValue?["scope"]
          == .string("process_group_best_effort"), "\(read)")
      switch ending {
      case "cancel":
        let result = try await f.call(kind + ".cancel", [idKey: .string(id)])
        #expect(result.objectValue?["isError"] != .bool(true), "\(result)")
      case "revoke":
        try f.session.limitAccess(
          to: .init(permissionCeilings: fixturePermissions([.project("fixture"): .granted(.read)])),
          expectedRevision: f.session.revision)
      case "limits":
        try f.session.limitAccess(
          to: .init(executionLimits: .init(timeMilliseconds: 1)),
          expectedRevision: f.session.revision)
      default: f.session.end()
      }
      _ = try await owner.wait(until: .now.advanced(by: .seconds(10)))
      #expect(try await owner.members().isEmpty)
      try await f.requireNoScratch()
    }
  }

  @Test func detachedDescendantDoesNotAcquireADurableSandboxClaim() async throws {
    let f = try FixedHostFixture()
    try await f.run { f in
      _ = try f.session.approveFullAccess(expectedRevision: f.session.revision)
      let program = """
        import os, time
        child = os.fork()
        if child == 0:
            os.setsid()
            with open('detached', 'w') as output: output.write(str(os.getpid()))
            time.sleep(0.5)
            os._exit(0)
        while not os.path.exists('detached'): time.sleep(0.01)
        print('detached descendant', flush=True)
        """
      let result = try await f.call(
        "shell.run",
        [
          "mode": .string("argv"), "executable": .string("/usr/bin/python3"),
          "argv": .array([.string("-I"), .string("-c"), .string(program)]),
        ])
      #expect(result.objectValue?["isError"] != .bool(true), "\(result)")
      let ownership = result.objectValue?["structuredContent"]?.objectValue?["result"]?
        .objectValue?["ownership"]?
        .objectValue
      #expect(ownership?["scope"] == .string("process_group_best_effort"))
      #expect(ownership?["warning"]?.stringValue?.contains("outside ownership") == true)
      #expect(
        FileManager.default.fileExists(atPath: f.project.appendingPathComponent("detached").path))
      // The bounded child exits independently even if it detached before observation.
      try await Task.sleep(for: .milliseconds(600))
    }
  }
}
