import Foundation
import Testing

@testable import ComputerMCPPlatformPOSIX

struct ProcessTableTests {
  @Test
  func findsEveryProcessHoldingAFileOpen() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("held".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try ProcessTable.processesHoldingOpen(path: url.path).isEmpty)

    let handle = try FileHandle(forReadingFrom: url)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", #"exec 3<"$0"; exec sleep 30"#, url.path]
    try child.run()
    defer {
      if child.isRunning { child.terminate() }
      child.waitUntilExit()
    }
    let expected = [ProcessInfo.processInfo.processIdentifier, child.processIdentifier].sorted()
    var holders: [Int32] = []
    // The child opens the file after it starts.
    for _ in 0..<200 where holders != expected {
      holders = try ProcessTable.processesHoldingOpen(path: url.path)
      if holders != expected { Thread.sleep(forTimeInterval: 0.025) }
    }
    #expect(holders == expected)

    try handle.close()
    child.terminate()
    child.waitUntilExit()
    #expect(try ProcessTable.processesHoldingOpen(path: url.path).isEmpty)
  }
}
