import ComputerMCPProcess
import ComputerMCPSandbox
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

// Process-table churn is global; keep these scenarios from invalidating each other's scans.
@Suite(.serialized) struct ExecutionOwnershipTests {
  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases, ["orphan", "group"])
  func sandboxFindsOrphansAfterRootExit(method: ExecutionLaunchMethod, variant: String) async throws
  {
    let fixture = try OwnershipFixture()
    defer { fixture.files.remove() }
    let handle = try await fixture.start(method: method, variant: variant)
    defer { Task { _ = try? await handle.cancel() } }
    let leaf = try await fixture.record("leaf")
    try await fixture.waitForExec(leaf.identity)
    let root = try await fixture.record("root")
    try await waitUntil { DarwinProcessIdentity.current(pid: root.identity.pid) == nil }
    #expect(leaf.parent == 1)
    #expect(leaf.group == leaf.identity.pid)
    if variant == "orphan" { #expect(leaf.session == leaf.identity.pid) }
    try await waitUntil {
      try await handle.members() == [
        ExecutionMember(processID: leaf.identity.pid, identity: leaf.identity.uniqueID)
      ]
    }
    let start = ContinuousClock.now
    let result = try await handle.cancel()
    #expect(start.duration(to: .now) >= .milliseconds(400))
    #expect(result.status == 23)
    #expect(try await handle.members().isEmpty)
    #expect(DarwinProcessIdentity.current(pid: leaf.identity.pid)?.identity != leaf.identity)
    #expect(try await handle.wait() == result)
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases)
  func waitsForAllMembersAndRetainsRootStatus(method: ExecutionLaunchMethod) async throws {
    let fixture = try OwnershipFixture()
    defer { fixture.files.remove() }
    let handle = try await fixture.start(method: method, variant: "natural")
    defer { Task { _ = try? await handle.cancel() } }
    let leaf = try await fixture.record("leaf")
    let root = try await fixture.record("root")
    try await waitUntil { DarwinProcessIdentity.current(pid: root.identity.pid) == nil }
    try await waitUntil {
      try await handle.members().contains { $0.identity == leaf.identity.uniqueID }
    }
    let completion = OwnershipWaitState()
    let waiter = Task {
      let result = try await handle.wait()
      await completion.finish()
      return result
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await !completion.finished)
    try fixture.files.write("worktree/finish", "go")
    let result = try await waiter.value
    #expect(DarwinProcessIdentity.current(pid: leaf.identity.pid)?.identity != leaf.identity)
    #expect(result.status == 23)
    #expect(try await handle.members().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases, [false, true])
  func concurrentExecutionsCancelIndependently(method: ExecutionLaunchMethod, sandboxed: Bool)
    async throws
  {
    let first = try OwnershipFixture()
    let second = try OwnershipFixture()
    defer {
      first.files.remove()
      second.files.remove()
    }
    let a = try await first.start(
      method: method, variant: sandboxed ? "orphan" : "observed", sandboxed: sandboxed)
    let b = try await second.start(
      method: method, variant: sandboxed ? "orphan" : "observed", sandboxed: sandboxed)
    defer {
      Task {
        _ = try? await a.cancel()
        _ = try? await b.cancel()
      }
    }
    if !sandboxed {
      try await first.observeThenDetach(a)
      try await second.observeThenDetach(b)
    }
    let leafA = try await first.record("leaf")
    let leafB = try await second.record("leaf")
    try await waitUntil {
      try await a.members().contains { $0.identity == leafA.identity.uniqueID }
    }
    try await waitUntil {
      try await b.members().contains { $0.identity == leafB.identity.uniqueID }
    }
    #expect(try await a.members().allSatisfy { $0.identity != leafB.identity.uniqueID })
    #expect(try await a.cancel().status == 23)
    #expect(DarwinProcessIdentity.current(pid: leafB.identity.pid)?.identity == leafB.identity)
    #expect(try await b.members().contains { $0.identity == leafB.identity.uniqueID })
    #expect(try await b.cancel().status == 23)
    #expect(try await a.members().isEmpty)
    #expect(try await b.members().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases)
  func independentHostsCompleteWhileEachOthersSentinelsRemain(method: ExecutionLaunchMethod)
    async throws
  {
    let first = try OwnershipFixture()
    let second = try OwnershipFixture()
    defer {
      first.files.remove()
      second.files.remove()
    }
    let sentinelA = try DarwinExecutionSentinel()
    let a = try await first.start(method: method, variant: "natural", sentinel: sentinelA)
    defer { Task { _ = try? await a.cancel() } }
    let hostB = Process()
    hostB.executableURL = try SeatbeltFixture.executionBootstrap.deletingLastPathComponent()
      .appendingPathComponent("ComputerMCPExecutionProbe")
    hostB.arguments = ["ownership-host", second.configuration.worktree.value, method.rawValue]
    let hostExit = Task {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Int32, Error>) in
        DispatchQueue(label: "test.independent-host").async {
          continuation.resume(
            with: Result {
              try hostB.run()
              hostB.waitUntilExit()
              return hostB.terminationStatus
            })
        }
      }
    }
    do {
      _ = try await first.record("leaf")
      try await waitUntil {
        FileManager.default.fileExists(
          atPath: second.files.root.appendingPathComponent("worktree/ready").path)
      }
      // Each OS process has its own sentinel registry, as independent running hosts do.
      let table = DarwinExecutionProcessTable.system
      let snapshot = try table.list(.now.advanced(by: .seconds(5)), sentinelA.identity)
      let sentinelB = try #require(
        snapshot.pids.compactMap { try? table.read($0) }.first {
          $0.parentID == hostB.processIdentifier && $0.state == .zombie
        }?.identity)
      #expect(!DarwinExecutionSentinel.identities().contains(sentinelB))
      try first.files.write("worktree/finish", "go")
      #expect(try await a.wait(until: .now.advanced(by: .seconds(5))).status == 23)
      #expect(try table.read(sentinelB.pid)?.identity == sentinelB)
      #expect(try table.read(sentinelB.pid)?.state == .zombie)
      try second.files.write("worktree/finish", "go")
      try await waitUntil {
        FileManager.default.fileExists(
          atPath: second.files.root.appendingPathComponent("worktree/complete").path)
      }
      #expect(try table.read(sentinelA.identity.pid)?.state == .zombie)
      #expect(try table.read(sentinelB.pid)?.state == .zombie)
      #expect(try await a.members().isEmpty)
      try second.files.write("worktree/release", "go")
      #expect(try await hostExit.value == 0)
    } catch {
      try? second.files.write("worktree/finish", "go")
      try? second.files.write("worktree/release", "go")
      _ = try? await hostExit.value
      throw error
    }
    withExtendedLifetime(a) {}
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases)
  func cancellingWaiterCancelsOrphanMembers(method: ExecutionLaunchMethod) async throws {
    let fixture = try OwnershipFixture()
    defer { fixture.files.remove() }
    let handle = try await fixture.start(method: method, variant: "orphan")
    defer { Task { _ = try? await handle.cancel() } }
    let leaf = try await fixture.record("leaf")
    let waiter = Task { try await handle.wait() }
    waiter.cancel()
    #expect(try await waiter.value.status == 23)
    #expect(DarwinProcessIdentity.current(pid: leaf.identity.pid)?.identity != leaf.identity)
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases)
  func cancellationFindsMembersBornDuringGrace(method: ExecutionLaunchMethod) async throws {
    let fixture = try OwnershipFixture()
    defer { fixture.files.remove() }
    let handle = try await fixture.start(method: method, variant: "term-fork")
    defer { Task { _ = try? await handle.cancel() } }
    _ = try await fixture.record("ready")
    #expect(try await handle.cancel().status == 23)
    let leaf = try await fixture.record("leaf")
    #expect(DarwinProcessIdentity.current(pid: leaf.identity.pid)?.identity != leaf.identity)
    #expect(try await handle.members().isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases)
  func kernelZombieRemainsMemberUntilReaped(method: ExecutionLaunchMethod) async throws {
    let fixture = try OwnershipFixture()
    defer { fixture.files.remove() }
    let handle = try await fixture.start(method: method, variant: "zombie")
    defer { Task { _ = try? await handle.cancel() } }
    let leaf = try await fixture.record("leaf")
    _ = try await fixture.record("root")
    try await waitUntil {
      try DarwinExecutionProcessTable.system.read(leaf.identity.pid)?.state == .zombie
    }
    #expect(
      DarwinProcessIdentity.current(pid: leaf.identity.pid, includingZombies: true)?.identity
        == leaf.identity)
    do {
      _ = try await handle.wait(until: .now.advanced(by: .milliseconds(150)))
      Issue.record("Unreaped member must prevent completion")
    } catch is ExecutionCompletionFailure {}
    #expect(try DarwinExecutionProcessTable.system.read(leaf.identity.pid)?.state == .zombie)
    try fixture.files.write("worktree/finish", "go")
    #expect(try await handle.wait(until: .now.advanced(by: .seconds(5))).status == 23)
    #expect(try await handle.members().isEmpty)
  }

  @Test(
    .timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases,
    ["exec-churn", "fork-churn"])
  func kernelChurningMembersAreKilled(method: ExecutionLaunchMethod, variant: String) async throws {
    let fixture = try OwnershipFixture()
    defer { fixture.files.remove() }
    let handle = try await fixture.start(method: method, variant: variant)
    defer { Task { _ = try? await handle.cancel() } }
    let root = try await fixture.record("root")
    _ = try await fixture.record("ready")
    if variant == "exec-churn" {
      let first = try #require(DarwinProcessIdentity.current(pid: root.identity.pid))
      try await waitUntil {
        let next = DarwinProcessIdentity.current(pid: root.identity.pid)
        return next?.identity == root.identity && next?.version != first.version
      }
    }
    #expect(try await handle.members().contains { $0.identity == root.identity.uniqueID })
    let result = try await handle.cancel(until: .now.advanced(by: .seconds(5)))
    #expect(result.status == 128 + SIGKILL)
    #expect(try await handle.members().isEmpty)
    #expect(DarwinProcessIdentity.current(pid: root.identity.pid)?.identity != root.identity)
  }

  @Test func kernelLastUnreapedMemberBlocksCompletionAndSentinelBoundsZombies() async throws {
    let older = try DarwinExecutionSentinel()
    let boundary = try DarwinExecutionSentinel()
    var member: DarwinExecutionSentinel? = try DarwinExecutionSentinel()
    let identity = try #require(member?.identity)
    let owner = DarwinExecutionOwnership(marker: try ExecutionSandboxMarker(), sentinel: boundary)
    owner.launched(identity)
    // WNOWAIT collected the exit status but left the member's proc record in zombproc.
    owner.exited(.success(.init(status: 0)))
    let snapshot = try DarwinExecutionProcessTable.system.list(
      .now.advanced(by: .seconds(5)), boundary.identity)
    let kernelIndex = try #require(snapshot.pids.firstIndex(of: 0))
    let memberIndex = try #require(snapshot.pids.firstIndex(of: identity.pid))
    let boundaryIndex = try #require(snapshot.pids.firstIndex(of: boundary.identity.pid))
    let olderIndex = try #require(snapshot.pids.firstIndex(of: older.identity.pid))
    #expect(kernelIndex < memberIndex && memberIndex < boundaryIndex && boundaryIndex < olderIndex)
    do {
      _ = try await owner.wait(until: .now.advanced(by: .milliseconds(200)))
      Issue.record("Last unreaped member must prevent completion")
    } catch is ExecutionCompletionFailure {}
    #expect(try DarwinExecutionProcessTable.system.read(identity.pid)?.state == .zombie)
    member = nil
    #expect(DarwinProcessIdentity.current(pid: identity.pid, includingZombies: true) == nil)
    #expect(try await owner.wait(until: .now.advanced(by: .seconds(5))).status == 0)
    // The execution boundary stays unreaped for the entire handle lifetime.
    #expect(try DarwinExecutionProcessTable.system.read(boundary.identity.pid)?.state == .zombie)
    withExtendedLifetime(older) {}
  }

  @Test func kernelProcessListEndsLiveProcessesAtPIDZero() throws {
    let boundary = try DarwinExecutionSentinel()
    let snapshot = try DarwinExecutionProcessTable.system.list(
      .now.advanced(by: .seconds(5)), boundary.identity)
    defer { withExtendedLifetime(boundary) {} }
    let sentinel = try #require(snapshot.pids.firstIndex(of: 0))
    #expect(try #require(snapshot.pids.firstIndex(of: boundary.identity.pid)) > sentinel)
    #expect(snapshot.pids.filter { $0 == 0 }.count == 1)
    #expect(snapshot.pids[..<sentinel].contains(1))
    for pid in snapshot.pids.dropFirst(sentinel + 1) {
      // kern_exit.c publishes to zombproc before SZOMB; proc_find must exclude the identity
      // even while the exit threads are still running. A reaped PID may already be reused.
      if let process = try DarwinExecutionProcessTable.system.read(pid),
        process.identity.uniqueID < snapshot.watermark
      {
        #expect(DarwinProcessIdentity.current(pid: pid)?.identity != process.identity)
      }
    }
  }

  @Test(
    .timeLimit(.minutes(10)),
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_PID_REUSE_TESTS"] == "1",
      "Local kernel stress test: cycles the PID allocator until an identity is reused"))
  func kernelRejectsStaleTokensAfterActualPIDReuse() throws {
    let files = try SeatbeltFixture()
    defer { files.remove() }
    let source = try #require(
      Bundle.module.url(
        forResource: "audit-token-reuse", withExtension: "c", subdirectory: "Fixtures"))
    let binary = files.root.appendingPathComponent("audit-token-reuse")
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compiler.arguments = ["-Wall", "-Wextra", "-Werror", source.path, "-o", binary.path]
    try compiler.run()
    compiler.waitUntilExit()
    try #require(compiler.terminationStatus == 0)
    let probe = Process()
    probe.executableURL = binary
    try probe.run()
    probe.waitUntilExit()
    #expect(probe.terminationReason == .exit)
    #expect(probe.terminationStatus == 0)
  }

  @Test func kernelRejectsMismatchedPIDVersion() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["10"]
    try process.run()
    let current = try #require(DarwinProcessIdentity.current(pid: process.processIdentifier))
    defer {
      process.terminate()
      process.waitUntilExit()
    }
    var token = audit_token_t(
      val: (0, 0, 0, 0, 0, UInt32(current.identity.pid), 0, current.version &+ 1))
    #expect(proc_signal_with_audittoken(&token, SIGKILL) == ESRCH)
    #expect(DarwinProcessIdentity.current(pid: current.identity.pid)?.identity == current.identity)
  }

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while try await !condition() {
      try #require(ContinuousClock.now < deadline, "Execution did not reach expected state")
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private struct OwnershipFixture {
  let files: SeatbeltFixture
  let configuration: SandboxConfiguration
  let environment: ExecutionEnvironment
  let executable: SandboxPath

  init() throws {
    files = try SeatbeltFixture()
    configuration = try files.configuration()
    environment = try ExecutionEnvironment(
      searchPath: [.init("/bin"), .init("/usr/bin")], home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory)
    executable = try files.path("worktree/member")
    let source = try #require(
      Bundle.module.url(
        forResource: "execution-member", withExtension: "c", subdirectory: "Fixtures"))
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compiler.arguments = ["-Wall", "-Wextra", "-Werror", source.path, "-o", executable.value]
    try compiler.run()
    compiler.waitUntilExit()
    try #require(compiler.terminationStatus == 0)
  }

  func start(
    method: ExecutionLaunchMethod, variant: String, sandboxed: Bool = true,
    sentinel: DarwinExecutionSentinel? = nil
  ) async throws
    -> any ExecutionOwnership
  {
    let bootstrap = try SeatbeltFixture.executionBootstrap
    return try await ExecutionLauncher(
      platform: DarwinExecutionPlatform(
        bootstrapExecutable: bootstrap,
        makeSentinel: {
          if let sentinel { return sentinel }
          return try await DarwinExecutionSentinel.create()
        })
    ).start(
      executable: executable, arguments: [variant], directory: configuration.worktree,
      environment: environment, mode: sandboxed ? .sandbox(configuration) : .fullAccess,
      method: method)
  }

  func record(_ name: String) async throws -> (
    identity: DarwinProcessIdentity, parent: Int32, group: Int32, session: Int32
  ) {
    let path = files.root.appendingPathComponent("worktree/" + name)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      if let text = try? String(contentsOf: path, encoding: .utf8), text.hasSuffix("\n") {
        let values = text.split(separator: " ").compactMap {
          UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if values.count == 5 {
          return (
            DarwinProcessIdentity(pid: Int32(values[0]), uniqueID: values[1]), Int32(values[2]),
            Int32(values[3]), Int32(values[4])
          )
        }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ExecutionEnvironmentError.launchFailed("Missing fixture record: " + name)
  }

  func observeThenDetach(_ handle: any ExecutionOwnership) async throws {
    let child = try await record("observed")
    #expect(try await handle.members().contains { $0.identity == child.identity.uniqueID })
    try files.write("worktree/detach", "go")
  }

  func waitForExec(_ identity: DarwinProcessIdentity) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      var path = [CChar](repeating: 0, count: 4096)
      if proc_pidpath(identity.pid, &path, UInt32(path.count)) > 0,
        String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
          == "/bin/sleep"
      {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw ExecutionEnvironmentError.launchFailed("Fixture did not exec sleep")
  }
}

private actor OwnershipWaitState {
  var finished = false
  func finish() { finished = true }
}
