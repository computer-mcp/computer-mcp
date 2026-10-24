import ComputerMCPSandbox
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite struct ExecutionSandboxMarkerTests {
  @Test func anotherLaunchEnteringItsSandboxCannotAcquireMembership() throws {
    let marker = try ExecutionSandboxMarker()
    var sandboxApplied = false
    let belongs = try marker.contains(getpid()) { _, _ in
      defer { sandboxApplied = true }
      // The first check sees the unsandboxed bootstrap. The second sees another
      // execution's profile, which denies both this execution's marker and the common marker.
      return sandboxApplied ? 1 : 0
    }
    #expect(!belongs)
  }

  @Test(arguments: [false, true])
  func failedMembershipQueryIsNotNonmembership(ownQuery: Bool) throws {
    let marker = try ExecutionSandboxMarker()
    #expect(throws: ExecutionEnvironmentError.self) {
      _ = try marker.contains(getpid()) { _, path in
        ownQuery && path == marker.common.value ? 1 : -1
      }
    }
  }

  @Test func existingMarkersDiscriminatePermissionsAndProtectStorage() throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    var first: ExecutionSandboxMarker? = try ExecutionSandboxMarker()
    var second: ExecutionSandboxMarker? = try ExecutionSandboxMarker()
    let own = try #require(first?.own.value)
    let other = try #require(second?.own.value)
    let directory = try #require(first?.directory)
    let common = try #require(first?.common.value)
    #expect(FileManager.default.fileExists(atPath: own))
    #expect(FileManager.default.fileExists(atPath: common))
    #expect(try first?.contains(getpid()) == false)
    let configuration = try SandboxConfiguration(
      worktree: fixture.path("worktree"), temporaryDirectory: directory,
      homeDirectory: directory, cacheDirectory: directory, readableRoots: [.init("/")])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments = [
      "-p", SeatbeltProfile.generate(configuration, marker: first), "/bin/sh", "-c",
      "cat \"$1\" && ! cat \"$2\" && ! cat \"$3\" && ! rm \"$1\" && ! touch \"$4/new\" && echo ready > \"$5\"; exec /bin/sleep 10",
      "test", own, other, common, directory.value,
      fixture.root.appendingPathComponent("worktree/ready").path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(
      atPath: fixture.root.appendingPathComponent("worktree/ready").path), Date() < deadline
    {
      Thread.sleep(forTimeInterval: 0.01)
    }
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("worktree/ready").path))
    #expect(try first?.contains(process.processIdentifier) == true)
    #expect(try second?.contains(process.processIdentifier) == false)

    // Models the unrelated App Sandbox permission shape: neither marker is readable.
    let unrelated = Process()
    unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    unrelated.arguments = [
      "-p", "(version 1)(allow default)(deny file-read-data (subpath \"\(directory.value)\"))",
      "/bin/sleep", "10",
    ]
    try unrelated.run()
    defer {
      if unrelated.isRunning { unrelated.terminate() }
      unrelated.waitUntilExit()
    }
    Thread.sleep(forTimeInterval: 0.05)
    #expect(try first?.contains(unrelated.processIdentifier) == false)
    #expect(try second?.contains(unrelated.processIdentifier) == false)
    first = nil
    #expect(!FileManager.default.fileExists(atPath: own))
    #expect(FileManager.default.fileExists(atPath: other))
    second = nil
    #expect(!FileManager.default.fileExists(atPath: other))
    // Other parallel executions may retain the shared directory until their own completion.
  }
}
