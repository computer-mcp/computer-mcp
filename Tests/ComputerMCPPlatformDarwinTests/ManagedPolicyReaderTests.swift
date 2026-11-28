import ComputerMCPPlatform
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite struct ManagedPolicyReaderTests {
  @Test(arguments: [
    "absent", "readable", "writable-parent", "missing-in-writable-parent", "writable",
    "wrong-owner", "directory", "symlink", "oversize", "acl-file", "acl-parent",
  ])
  func fileStates(state: String) throws {
    let temporary = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(temporary) }
    let directory = URL(fileURLWithPath: String(cString: temporary)).appendingPathComponent(
      "policy-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(chmod(directory.path, state.contains("writable-parent") ? 0o777 : 0o700) == 0)
    let path = directory.appendingPathComponent("policy.toml").path
    if state == "directory" {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    } else if state == "symlink" {
      try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "missing")
    } else if state != "absent" && state != "missing-in-writable-parent" {
      try Data(repeating: 32, count: state == "oversize" ? 1_048_577 : 8).write(
        to: URL(fileURLWithPath: path))
      #expect(chmod(path, state == "writable" ? 0o666 : 0o600) == 0)
    }
    if state.hasPrefix("acl-") {
      let command = Process()
      command.executableURL = URL(fileURLWithPath: "/bin/chmod")
      command.arguments = [
        "+a", "everyone allow write,delete,delete_child",
        state == "acl-parent" ? directory.path : path,
      ]
      try command.run()
      command.waitUntilExit()
      #expect(command.terminationStatus == 0)
    }
    let reader = DarwinManagedPolicyReader(
      machinePath: path, expectedOwner: state == "wrong-owner" ? getuid() + 1 : getuid(),
      preferences: { .absent })
    let status = try #require(reader.readSources().first).status
    switch state {
    case "absent": #expect(status == .absent)
    case "readable": #expect(status == .available(Data(repeating: 32, count: 8)))
    default:
      if case .unreadable = status {
      } else {
        Issue.record("Unsafe file became available or absent")
      }
    }
  }

  @Test func canonicalPathsUseFilesystemIdentityIncludingMissingSuffixes() throws {
    let reader = DarwinManagedPolicyReader()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let alias = root.appendingPathComponent("alias")
    let target = root.appendingPathComponent("Target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    let real = try #require(realpath(target.path, nil))
    defer { free(real) }
    #expect(
      try reader.canonicalPolicyPath(alias.path + "/future") == String(cString: real) + "/future")
  }

  @Test(arguments: [EACCES, EPERM])
  func inaccessibleDeniedLocationsKeepTheirAccessiblePrefix(failure: Int32) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = try #require(realpath(root.path, nil))
    defer { free(real) }
    let prefix = String(cString: real)
    let result = try DarwinManagedPolicyReader.canonicalPolicyPath(prefix + "/private/file") {
      path, flags in
      #expect(flags & O_NONBLOCK != 0)
      if path.hasPrefix(prefix + "/private") {
        errno = failure
        return -1
      }
      return open(path, flags)
    }
    #expect(result == prefix + "/private/file")
  }

  @Test func deniedFIFOIsCanonicalizedWithoutWaitingForAWriter() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fifo = root.appendingPathComponent("fifo").path
    #expect(mkfifo(fifo, 0o600) == 0)
    let real = try #require(realpath(fifo, nil))
    defer { free(real) }
    #expect(try DarwinManagedPolicyReader().canonicalPolicyPath(fifo) == String(cString: real))
  }

  @Test func preferenceIdentityIsIndependentOfBuildNamespace() {
    let reader = DarwinManagedPolicyReader(
      machinePath: "/absent/fixture-policy", expectedOwner: getuid(),
      preferences: { .unreadable("fixture") })
    #expect(reader.readSources()[1].location == "com.showxu.computer-mcp/Policy")
    #expect(reader.readSources()[1].status == .unreadable("fixture"))
    #expect(
      DarwinManagedPolicyReader.machinePath
        == "/Library/Application Support/Computer MCP/policy.toml")
  }
}
