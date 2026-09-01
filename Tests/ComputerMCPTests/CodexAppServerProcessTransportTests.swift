import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)
struct CodexAppServerProcessTransportTests {
  @Test
  func closeTerminatesAndReapsEntireProcessGroup() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let childPIDFile = directory.appendingPathComponent("child.pid")
    let script = directory.appendingPathComponent("stubborn-app-server.sh")
    try Data(
      """
      #!/bin/sh
      trap '' TERM
      /bin/sh -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
      child=$!
      printf '%s\\n' "$child" > "$CHILD_PID_FILE"
      while :; do /bin/sleep 1; done
      """.utf8
    ).write(to: script)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: script.path
    )

    var environment = ProcessInfo.processInfo.environment
    environment["CHILD_PID_FILE"] = childPIDFile.path
    let transport = ManagedCodexAppServerTransport(
      configuration: .init(
        executable: script.path,
        arguments: [],
        environment: environment,
        workingDirectory: directory,
        terminationGraceMilliseconds: 100,
        killGraceMilliseconds: 2_000
      )
    )

    let running = try await waitForRunning(transport)
    let parentPID = try #require(running.processID)
    let supervisorPID = try #require(running.supervisorProcessID)
    let childPID = try await waitForPID(at: childPIDFile)
    #expect(parentPID != childPID)
    #expect(supervisorPID != parentPID)
    #expect(processExists(parentPID))
    #expect(processExists(childPID))

    await transport.close()

    let stopped = await transport.snapshot()
    #expect(stopped.state == .stopped)
    #expect(stopped.processGroupID == parentPID)
    #expect(stopped.terminationEscalated)
    #expect(await waitForProcessExit(parentPID))
    #expect(await waitForProcessExit(childPID))
    #expect(await waitForProcessExit(supervisorPID))
  }

  @Test
  func repeatedCloseIsIdempotent() async throws {
    let transport = ManagedCodexAppServerTransport(
      configuration: .init(
        executable: "/bin/sh",
        arguments: ["-c", "while read line; do :; done"],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 500,
        killGraceMilliseconds: 1_000
      )
    )
    let running = try await waitForRunning(transport)
    let processID = try #require(running.processID)

    await transport.close()
    await transport.close()

    let stopped = await transport.snapshot()
    #expect(stopped.state == .stopped)
    #expect(await waitForProcessExit(processID))
  }

  @Test
  func closeDoesNotWaitForBackpressuredProtocolWriter() async throws {
    let transport = ManagedCodexAppServerTransport(
      configuration: .init(
        executable: "/bin/sh",
        arguments: ["-c", "trap '' TERM; while :; do /bin/sleep 1; done"],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 100,
        killGraceMilliseconds: 2_000,
        maximumMessageBytes: 8 * 1_024 * 1_024
      )
    )
    let running = try await waitForRunning(transport)
    let processID = try #require(running.processID)
    let blockedWrite = Task {
      try? await transport.sendLine(String(repeating: "x", count: 4 * 1_024 * 1_024))
    }
    try await Task.sleep(for: .milliseconds(100))
    let clock = ContinuousClock()
    let started = clock.now

    await transport.close()

    #expect(started.duration(to: clock.now) < .seconds(3))
    #expect(await waitForProcessExit(processID))
    _ = await blockedWrite.value
  }

  @Test
  func outboundProtocolLinesAreBoundedBeforeWrite() async throws {
    let transport = ManagedCodexAppServerTransport(
      configuration: .init(
        executable: "/bin/sh",
        arguments: ["-c", "while read line; do :; done"],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 500,
        killGraceMilliseconds: 1_000,
        maximumMessageBytes: 16
      )
    )
    _ = try await waitForRunning(transport)

    var rejected = false
    do {
      try await transport.sendLine(String(repeating: "x", count: 17))
    } catch {
      rejected = true
      #expect(error is CodexAppServerProcessTransportError)
    }
    #expect(rejected)

    await transport.close()
  }

  @Test(arguments: 0..<5)
  func ownerProcessDeathTerminatesTheEntireAppServerGroup(iteration: Int) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("owner-death-\(iteration)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = Process()
    owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
    owner.arguments = ["0.3"]
    try owner.run()

    let descendantPIDFile = directory.appendingPathComponent("descendant.pid")
    let script = directory.appendingPathComponent("app-server.sh")
    try Data(
      """
      #!/bin/sh
      trap '' TERM
      /bin/sh -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
      printf '%s\n' "$!" > "$DESCENDANT_PID_FILE"
      while :; do /bin/sleep 1; done
      """.utf8
    ).write(to: script)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: script.path
    )
    var environment = ProcessInfo.processInfo.environment
    environment["DESCENDANT_PID_FILE"] = descendantPIDFile.path
    let transport = ManagedCodexAppServerTransport(
      configuration: .init(
        executable: script.path,
        arguments: [],
        environment: environment,
        workingDirectory: directory,
        terminationGraceMilliseconds: 100,
        killGraceMilliseconds: 2_000,
        ownerProcessID: owner.processIdentifier
      )
    )
    let running = try await waitForRunning(transport)
    let appServerPID = try #require(running.processID)
    let supervisorPID = try #require(running.supervisorProcessID)
    let descendantPID = try await waitForPID(at: descendantPIDFile)

    let ownerExited = await waitForProcessExit(owner)
    #expect(ownerExited)
    if !ownerExited {
      owner.terminate()
      await transport.close()
      return
    }

    #expect(await waitForProcessExit(appServerPID))
    #expect(await waitForProcessExit(descendantPID))
    #expect(await waitForProcessExit(supervisorPID))
    await transport.close()
  }

  private func waitForRunning(
    _ transport: ManagedCodexAppServerTransport
  ) async throws -> CodexAppServerProcessSnapshot {
    for _ in 0..<500 {
      let snapshot = await transport.snapshot()
      if snapshot.state == .running {
        return snapshot
      }
      if snapshot.state == .failed {
        throw CodexAppServerProcessTransportError.launchFailed(
          snapshot.lastError ?? "Unknown launch failure."
        )
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CodexAppServerProcessTransportError.launchFailed(
      "Timed out waiting for the fixture process."
    )
  }

  private func waitForPID(at file: URL) async throws -> Int32 {
    for _ in 0..<500 {
      if let contents = try? String(contentsOf: file, encoding: .utf8),
        let processID = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        return processID
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CodexAppServerProcessTransportError.launchFailed(
      "Timed out waiting for the fixture child PID."
    )
  }

  private func waitForProcessExit(_ processID: Int32) async -> Bool {
    for _ in 0..<500 {
      if !processExists(processID) {
        return true
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  private func waitForProcessExit(_ process: Process) async -> Bool {
    for _ in 0..<500 {
      if !process.isRunning {
        return true
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  private func processExists(_ processID: Int32) -> Bool {
    errno = 0
    if kill(processID, 0) == 0 {
      return true
    }
    return errno != ESRCH
  }
}
