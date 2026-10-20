import Foundation
import Testing

@testable import ComputerMCPPlatformPOSIX

struct FileLockTests {
  @Test func separateOpenDescriptionsConflictAndReleaseIsIdempotent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("database.lock").path
    let first = try FileLock(path: path, mode: .shared)
    let second = try FileLock(path: path, mode: .shared)
    #expect(throws: FileLockError.held(path: path)) {
      try FileLock(path: path, mode: .exclusive)
    }
    first.release()
    first.release()
    #expect(throws: FileLockError.held(path: path)) {
      try FileLock(path: path, mode: .exclusive)
    }
    second.release()

    var exclusive: FileLock? = try FileLock(path: path, mode: .exclusive)
    withExtendedLifetime(exclusive) {
      for mode in [FileLock.Mode.shared, .exclusive] {
        #expect(throws: FileLockError.held(path: path)) { try FileLock(path: path, mode: mode) }
      }
    }
    exclusive = nil
    let available = try FileLock(path: path, mode: .exclusive)
    available.release()
    #expect(FileManager.default.fileExists(atPath: path))
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test(arguments: [FileLock.Mode.shared, .exclusive])
  func locksConflictAcrossProcesses(_ mode: FileLock.Mode) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("database.lock").path
    let child = Process()
    let input = Pipe()
    let output = Pipe()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    child.arguments = [
      "python3", "-c",
      """
      import fcntl, os, sys
      fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
      mode = fcntl.LOCK_SH if sys.argv[2] == "shared" else fcntl.LOCK_EX
      fcntl.flock(fd, mode | fcntl.LOCK_NB)
      print("ready", flush=True)
      sys.stdin.buffer.read(1)
      os.close(fd)
      """, path, mode == .shared ? "shared" : "exclusive",
    ]
    child.standardInput = input
    child.standardOutput = output
    try child.run()
    try output.fileHandleForWriting.close()
    try input.fileHandleForReading.close()
    defer {
      try? input.fileHandleForWriting.close()
      child.waitUntilExit()
    }
    #expect(output.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8))
    #expect(throws: FileLockError.held(path: path)) {
      try FileLock(path: path, mode: .exclusive)
    }
    if mode == .exclusive {
      #expect(throws: FileLockError.held(path: path)) {
        try FileLock(path: path, mode: .shared)
      }
    } else {
      let shared = try FileLock(path: path, mode: .shared)
      shared.release()
    }
    try input.fileHandleForWriting.close()
    child.waitUntilExit()
    #expect(child.terminationStatus == 0)
    let available = try FileLock(path: path, mode: .exclusive)
    available.release()
  }
}
