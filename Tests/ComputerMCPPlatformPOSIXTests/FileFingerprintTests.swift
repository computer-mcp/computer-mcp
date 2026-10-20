import Foundation
import Testing

@testable import ComputerMCPPlatformPOSIX

struct FileFingerprintTests {
  @Test
  func writesChangeTheFingerprint() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FileFingerprint.current(of: url) == nil)
    try Data("first".utf8).write(to: url)
    let before = try #require(FileFingerprint.current(of: url))
    #expect(FileFingerprint.current(of: url) == before)
    try Data("longer content".utf8).write(to: url)
    let after = try #require(FileFingerprint.current(of: url))
    #expect(after != before)
    #expect(after.size == 14)
  }

  @Test
  func atomicReplacementChangesIdentityEvenWithTheSameSize() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("first".utf8).write(to: url)
    let before = try #require(FileFingerprint.current(of: url))
    try Data("other".utf8).write(to: url, options: .atomic)
    let after = try #require(FileFingerprint.current(of: url))
    #expect(after != before)
    #expect(after.inode != before.inode)
    #expect(after.size == before.size)
  }

  @Test
  func deletedFileHasNoFingerprint() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data().write(to: url)
    #expect(FileFingerprint.current(of: url) != nil)
    try FileManager.default.removeItem(at: url)
    #expect(FileFingerprint.current(of: url) == nil)
  }
}
