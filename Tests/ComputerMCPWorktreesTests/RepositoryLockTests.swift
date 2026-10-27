import ComputerMCPPlatformPOSIX
import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct RepositoryLockTests {
  @Test func crossProcessHolderExcludesRepositoryAdmission() throws {
    try fixture { root in
      let initial = try RepositoryLock(commonDirectory: root, owner: .init(), timeout: .zero)
      initial.release()
      let child = Process()
      let input = Pipe()
      let output = Pipe()
      child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      child.arguments = [
        "python3", "-c",
        "import fcntl,sys; f=open(sys.argv[1],'r+'); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.buffer.read(1)",
        root.appendingPathComponent("computer-mcp/repository.lock").path,
      ]
      child.standardInput = input
      child.standardOutput = output
      try child.run()
      defer {
        try? input.fileHandleForWriting.close()
        child.waitUntilExit()
      }
      try output.fileHandleForWriting.close()
      try input.fileHandleForReading.close()
      #expect(output.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8))
      #expect(throws: WorktreeError.self) {
        try RepositoryLock(commonDirectory: root, owner: .init(), timeout: .zero)
      }
      try input.fileHandleForWriting.close()
      child.waitUntilExit()
      let available = try RepositoryLock(commonDirectory: root, owner: .init(), timeout: .zero)
      try available.verify()
    }
  }

  @Test func aliasesContendAndReleasePreservesIdentity() throws {
    try fixture { root in
      let alias = root.appendingPathComponent("alias")
      let common = root.appendingPathComponent("common")
      try FileManager.default.createDirectory(at: common, withIntermediateDirectories: false)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: common)
      let first = try RepositoryLock(commonDirectory: common, owner: .init(), timeout: .zero)
      let path = common.appendingPathComponent("computer-mcp/repository.lock")
      let before = try Data(contentsOf: path)
      #expect(throws: WorktreeError.self) {
        try RepositoryLock(commonDirectory: alias, owner: .init(), timeout: .zero)
      }
      #expect(try Data(contentsOf: path) == before)
      let inode =
        try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber
      first.release()
      let second = try RepositoryLock(commonDirectory: alias, owner: .init(), timeout: .zero)
      try second.verify()
      second.release()
      #expect(
        try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber
          == inode)
    }
  }

  @Test func cancellationPreventsAdmissionAndDoesNotSteal() throws {
    try fixture { root in
      let first = try RepositoryLock(commonDirectory: root, owner: .init(), timeout: .zero)
      #expect(throws: CancellationError.self) {
        try RepositoryLock(commonDirectory: root, owner: .init(), timeout: .seconds(1)) {
          throw CancellationError()
        }
      }
      try first.verify()
    }
  }

  @Test func symlinksAndReplacementRefuse() throws {
    try fixture { root in
      let first = try RepositoryLock(commonDirectory: root, owner: .init(), timeout: .zero)
      let path = root.appendingPathComponent("computer-mcp/repository.lock")
      let moved = path.appendingPathExtension("retained")
      try FileManager.default.moveItem(at: path, to: moved)
      try Data("replacement".utf8).write(to: path)
      #expect(throws: FileLockError.identityChanged(path: path.path)) { try first.verify() }
      first.release()
      #expect(try String(contentsOf: path, encoding: .utf8) == "replacement")
      try FileManager.default.removeItem(at: path)
      try FileManager.default.createSymbolicLink(at: path, withDestinationURL: moved)
      #expect(throws: (any Error).self) {
        try RepositoryLock(commonDirectory: root, owner: .init(), timeout: .zero)
      }
    }
  }

  @Test func changedCoordinationDirectoryRefuses() throws {
    try fixture { root in
      let lock = try RepositoryLock(commonDirectory: root, owner: .init(), timeout: .zero)
      let directory = root.appendingPathComponent("computer-mcp")
      try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("retained"))
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      #expect(throws: WorktreeError.self) { try lock.verify() }
    }
  }
}

func fixture(_ action: (URL) throws -> Void) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    .resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try action(root)
}
