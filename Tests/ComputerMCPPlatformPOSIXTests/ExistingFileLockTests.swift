import Foundation
import Testing

@testable import ComputerMCPPlatformPOSIX

struct ExistingFileLockTests {
  @Test func missingLockIsNotCreated() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("missing.lock").path

    #expect(throws: (any Error).self) { try FileLock(sharingExisting: path) }
    #expect(throws: (any Error).self) { try FileLock(lockingExisting: path) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test func readersCanShareReadOnlyFileAndExcludeWriter() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("store.lock").path
    let bytes = Data("stable lock".utf8)
    try bytes.write(to: URL(fileURLWithPath: path))
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)

    let first = try FileLock(sharingExisting: path)
    let second = try FileLock(sharingExisting: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    #expect(throws: FileLockError.held(path: path)) {
      try FileLock(path: path, mode: .exclusive)
    }
    try first.verifyIdentity()
    first.release()
    second.release()
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["store.lock"])

    let writer = try FileLock(lockingExisting: path)
    #expect(throws: FileLockError.held(path: path)) { try FileLock(sharingExisting: path) }
    writer.release()
    let reader = try FileLock(sharingExisting: path)
    reader.release()
  }

  @Test func replacementAndLinkedLockFilesAreRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("store.lock")
    try Data("original".utf8).write(to: url)
    let reader = try FileLock(sharingExisting: url.path)
    try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("old.lock"))
    try Data("replacement".utf8).write(to: url)
    #expect(throws: FileLockError.identityChanged(path: url.path)) { try reader.verifyIdentity() }
    reader.release()

    let hardLink = directory.appendingPathComponent("hard.lock")
    try FileManager.default.linkItem(at: url, to: hardLink)
    #expect(throws: FileLockError.identityChanged(path: url.path)) {
      try FileLock(sharingExisting: url.path)
    }
    try FileManager.default.removeItem(at: hardLink)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(
      at: url, withDestinationURL: directory.appendingPathComponent("old.lock"))
    #expect(throws: (any Error).self) { try FileLock(sharingExisting: url.path) }
  }
}
