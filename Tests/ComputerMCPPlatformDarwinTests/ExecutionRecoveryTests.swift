import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite(.nativeIntegration, .serialized) struct ExecutionRecoveryTests {
  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases, [false, true])
  func abruptHostExitRecoversOwnedSurvivorsWithoutReplay(
    method: ExecutionLaunchMethod, sandboxed: Bool
  ) async throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = URL(
      fileURLWithPath: try #require(realpath(temporary.url.path, nil)).withCStringCopy())
    let host = Process()
    host.executableURL = try SeatbeltFixture.executionBootstrap.deletingLastPathComponent()
      .appendingPathComponent("ComputerMCPExecutionProbe")
    host.arguments = [
      sandboxed ? "recovery-host" : "recovery-host-full", root.path, method.rawValue,
    ]
    try host.run()
    host.waitUntilExit()
    #expect(host.terminationStatus == 0)
    let receipt = try JSONDecoder().decode(
      ExecutionRecoveryState.self,
      from: Data(contentsOf: root.appendingPathComponent("ownership.json")))
    let leafPID = try #require(
      Int32(String(contentsOf: root.appendingPathComponent("leaf"), encoding: .utf8)))
    let leaf = try #require(DarwinProcessIdentity.current(pid: leafPID))
    defer {
      let table = DarwinExecutionProcessTable.system
      if let process = try? table.read(leafPID), process.identity == leaf.identity {
        _ = process.signal(SIGKILL)
      }
      if let process = try? table.read(receipt.root.processID),
        process.identity.uniqueID == receipt.root.identity
      {
        _ = process.signal(SIGKILL)
      }
    }
    #expect(leaf.identity.pid != receipt.root.processID)
    let launcher = ExecutionLauncher(platform: DarwinExecutionPlatform())
    let owner = try await launcher.recover(receipt)
    _ = try await owner.cancel(until: .now.advanced(by: .seconds(20)))
    #expect(DarwinProcessIdentity.current(pid: leafPID)?.identity != leaf.identity)
    #expect(try await owner.members().isEmpty)
    #expect(receipt.sandboxed == sandboxed)
    #expect(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8) == "x")
    try launcher.releaseRecovery(receipt)
    try launcher.releaseRecovery(receipt)
  }

  @Test(arguments: ExecutionLaunchMethod.allCases)
  func fullAccessDisclaimsPrivacyResponsibility(method: ExecutionLaunchMethod) async throws {
    let temporary = try ScopedTemporaryDirectory()
    let path = try SandboxPath(temporary.url.path)
    let output = Pipe()
    let probe = try SeatbeltFixture.executionBootstrap.deletingLastPathComponent()
      .appendingPathComponent("ComputerMCPExecutionProbe")
    let result = try await ExecutionAdministration.$current.withValue(
      .init(mode: .fullAccess, environment: .init(fullAccessVariables: ["PATH": "/usr/bin:/bin"]))
    ) {
      try await ExecutionLauncher(
        platform: DarwinExecutionPlatform(
          bootstrapExecutable: try SeatbeltFixture.executionBootstrap)
      ).run(
        executable: .init(probe.path), arguments: ["child", "privacy", "leaf"], directory: path,
        environment: .init(fullAccessVariables: ["PATH": "/usr/bin:/bin"]), mode: .fullAccess,
        method: method, output: output.fileHandleForWriting.fileDescriptor)
    }
    try output.fileHandleForWriting.close()
    let fields = String(
      decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self
    ).split(whereSeparator: \.isWhitespace)
    #expect(result.status == 0)
    try #require(fields.count == 4)
    #expect(fields[1] == fields[3])
  }

  @Test func durableFullAccessOwnershipIsUnavailable() {
    let platform = DarwinExecutionPlatform()
    #expect(platform.supportsDurableOwnership(sandboxed: true))
    #expect(!platform.supportsDurableOwnership(sandboxed: false))
    #expect(platform.supportsBestEffortOwnership)
  }

  @Test func markerRecoveryRejectsReplacedInodes() throws {
    let marker = try ExecutionSandboxMarker()
    let receipt = try marker.recovery()
    try FileManager.default.removeItem(atPath: marker.own.value)
    try Data("replacement".utf8).write(to: URL(fileURLWithPath: marker.own.value))
    #expect(throws: (any Error).self) { try ExecutionSandboxMarker(recovery: receipt) }
    #expect(throws: (any Error).self) { try ExecutionSandboxMarker.release(receipt) }
    try FileManager.default.removeItem(atPath: marker.own.value)
    try ExecutionSandboxMarker.release(receipt)
  }
}

extension UnsafeMutablePointer<CChar> {
  fileprivate func withCStringCopy() -> String {
    defer { free(self) }
    return String(cString: self)
  }
}

@Suite struct ExecutionRecoverySnapshotTests {
  @Test func fullAccessRecoveryFindsAnchoredChildrenAfterRootReaping() async throws {
    let processes = SimulatedProcessTable()
    let root = DarwinProcessIdentity(pid: 1_000_001, uniqueID: 100)
    let leaf = DarwinProcessIdentity(pid: 1_000_002, uniqueID: 101)
    let unrelated = DarwinProcessIdentity(pid: 1_000_003, uniqueID: 102)
    processes.mutate {
      $0.entries = [
        leaf.pid: .init(
          identity: leaf, parentUniqueID: root.uniqueID,
          group: root.pid, session: root.pid, state: .running),
        unrelated.pid: .init(
          identity: unrelated, parentUniqueID: 999,
          group: unrelated.pid, session: unrelated.pid, state: .running),
      ]
    }
    let platform = DarwinExecutionPlatform(table: processes.table)
    let receipt = ExecutionRecoveryState(
      root: .init(processID: root.pid, identity: root.uniqueID), sandboxed: false, backend: "darwin"
    )
    let owner = try await platform.recover(receipt)
    _ = try await owner.cancel(until: .now.advanced(by: .seconds(3)))
    #expect(processes.state.signals.contains { $0.0 == leaf })
    #expect(processes.state.entries[leaf.pid] == nil)
    #expect(processes.state.entries[unrelated.pid] != nil)
    #expect(!processes.state.signals.contains { $0.0 == unrelated })
    try platform.releaseRecovery(receipt)
  }

  @Test(arguments: [false, true])
  func recoveryScansPastOlderRecordsAndRequiresCompleteEvidence(newZombie: Bool) async throws {
    let processes = SimulatedProcessTable()
    let root = DarwinProcessIdentity(pid: 1_000_001, uniqueID: 100)
    let leaf = DarwinProcessIdentity(pid: 1_000_002, uniqueID: 101)
    let unrelated: pid_t = 1_000_090
    processes.mutate {
      $0.entries = [
        unrelated: .init(
          identity: .init(pid: unrelated, uniqueID: newZombie ? 102 : 99), parentUniqueID: 999,
          group: 0, session: 0, state: .zombie),
        leaf.pid: .init(
          identity: leaf, parentUniqueID: 100, group: leaf.pid, session: leaf.pid, state: .running),
      ]
      $0.continuousChurn = true
    }
    let marker = try ExecutionSandboxMarker()
    var table = processes.table
    table.wholeList = { _ in
      let state = processes.state
      return .init(
        pids: [unrelated, leaf.pid].filter { state.entries[$0] != nil } + [0], watermark: 1000,
        complete: !state.continuousChurn)
    }
    let owner = DarwinExecutionOwnership(marker: marker, table: table, recoveryRoot: root)
    try owner.recover([root])
    await #expect(throws: ExecutionWaitExpired.self) {
      try await owner.cancel(until: .now.advanced(by: .milliseconds(750)))
    }
    #expect(processes.state.signals.contains { $0.0 == leaf && $0.1 == SIGKILL })
    #expect(!processes.state.signals.contains { $0.0.pid == unrelated })
    processes.mutate { $0.continuousChurn = false }
    if newZombie {
      await #expect(throws: ExecutionWaitExpired.self) {
        try await owner.wait(until: .now.advanced(by: .milliseconds(100)))
      }
      processes.mutate { $0.entries[unrelated] = nil }
    }
    _ = try await owner.wait(until: .now.advanced(by: .seconds(3)))
    #expect(try await owner.members().isEmpty)
  }
}
