import ComputerMCPPlatform
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct DirectoryEventFileChangeMonitorTests {
  @Test
  func reportsStartupAndAtomicReplacementsAndFinishesOnClose() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("watched")
    try Data("first".utf8).write(to: url)
    let monitor: any FileChangeMonitor = try DirectoryEventFileChangeMonitor(fileURL: url)
    var changes = monitor.changes.makeAsyncIterator()
    #expect(await changes.next() != nil)
    for content in ["second", "third"] {
      try Data(content.utf8).write(to: url, options: .atomic)
      #expect(await changes.next() != nil)
      #expect(try Data(contentsOf: url) == Data(content.utf8))
    }
    await monitor.close()
    #expect(await changes.next() == nil)
    await monitor.close()
  }

  @Test
  func missingParentThrowsPOSIXError() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("watched")
    #expect(throws: POSIXError(.ENOENT)) {
      try DirectoryEventFileChangeMonitor(fileURL: url)
    }
  }
}
