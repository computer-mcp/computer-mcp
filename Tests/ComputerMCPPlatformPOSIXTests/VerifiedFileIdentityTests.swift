import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Foundation
import Testing

struct VerifiedFileIdentityTests {
  @Test func editsRetainIdentityButReplacementAndSymlinkRetargetingDoNot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("First")
    let second = directory.appendingPathComponent("Second")
    let link = directory.appendingPathComponent("Link")
    try Data("original".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
    let identity = try VerifiedFileIdentity.capture(link)
    #expect(identity.path == (try ProjectPathResolver.canonicalProject(first).path))
    #expect(!identity.isDirectory)
    let handle = try FileHandle(forWritingTo: first)
    try handle.write(contentsOf: Data("edit".utf8))
    try handle.close()
    try identity.verify(link)
    #expect(
      try JSONDecoder().decode(VerifiedFileIdentity.self, from: identity.evidence) == identity)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
    #expect(throws: (any Error).self) { try identity.verify(link) }
    try FileManager.default.removeItem(at: first)
    try Data("replacement".utf8).write(to: first)
    #expect(throws: (any Error).self) { try identity.verify(first) }
    #expect(throws: (any Error).self) {
      try VerifiedFileIdentity.capture(directory.appendingPathComponent("missing"))
    }
    let folder = try VerifiedFileIdentity.capture(directory)
    #expect(folder.isDirectory)
    try folder.verify(directory)
  }
}
