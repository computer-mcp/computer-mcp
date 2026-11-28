import ComputerMCPDarwinTestSupport
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite(.nativeIntegration, .serialized)
struct ExecutionJournalTests {
  @Test(arguments: [true, false])
  func restartInterruptsOwnedProcessesAndRetainsScopedCursors(sameBoot: Bool) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let journal = fixture.root.appendingPathComponent("journal")
    let scope = UUID()
    let probe = try SeatbeltFixture.executionBootstrap.deletingLastPathComponent()
      .appendingPathComponent("ComputerMCPExecutionProbe")
    let process = Process()
    process.executableURL = probe
    process.arguments = ["journal-host", journal.path, scope.uuidString]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let id = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(UUID(uuidString: id) != nil)
    let recordURL = journal.appendingPathComponent(id + ".json")
    var record = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
    let savedMembers = try JSONDecoder().decode(
      [ExecutionMember].self,
      from: JSONSerialization.data(withJSONObject: try #require(record["members"])))
    let stored = try #require(record["snapshot"] as? [String: Any])
    let output = try #require(stored["stdout"] as? [String: Any])
    let base64 = try #require(output["base64"] as? String)
    let data = try #require(Data(base64Encoded: base64))
    let text = String(decoding: data, as: UTF8.self)
    let childPID = try #require(
      Int32(text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(6)))
    let childIdentity = try #require(DarwinProcessIdentity.current(pid: childPID)?.identity)
    if !sameBoot {
      record["bootSessionID"] = "different-boot"
      try JSONSerialization.data(withJSONObject: record).write(to: recordURL)
    }
    let sessions = GatewayTerminalSessions()
    try sessions.enablePersistence(at: journal, launcher: testExecutionLauncher())
    let runtime = ShellSessionRuntime(
      launcher: testExecutionLauncher(), sessions: sessions,
      scope: .isolated(scope))
    let snapshot = try runtime.read(
      sessionID: id, stdoutCursor: 0, stderrCursor: 0,
      maxReadBytes: 4096, encoding: .utf8)
    #expect(!snapshot.isRunning)
    #expect(snapshot.endReason == .interrupted)
    #expect(snapshot.stdout.text == text)
    #expect(snapshot.stdout.nextCursor == Int64(data.count))
    if sameBoot {
      #expect(DarwinProcessIdentity.current(pid: childPID)?.identity != childIdentity)
    } else {
      #expect(DarwinProcessIdentity.current(pid: childPID)?.identity == childIdentity)
      try await testExecutionLauncher().interrupt(savedMembers)
    }
    #expect(snapshot.members.isEmpty)
    let other = ShellSessionRuntime(launcher: testExecutionLauncher(), sessions: sessions)
    #expect(throws: (any Error).self) {
      try other.read(
        sessionID: id, stdoutCursor: 0, stderrCursor: 0,
        maxReadBytes: 4096, encoding: .utf8)
    }
    #expect(throws: (any Error).self) {
      try GatewayTerminalSessions().enablePersistence(
        at: journal, launcher: testExecutionLauncher())
    }
    await runtime.shutdown()
  }
}
