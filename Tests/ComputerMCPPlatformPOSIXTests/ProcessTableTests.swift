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
    child.arguments = ["-c", #"exec 3<"$0"; printf 'ready\n'; read -r command || :"#, url.path]
    let input = Pipe()
    let output = Pipe()
    child.standardInput = input
    child.standardOutput = output
    try child.run()
    try input.fileHandleForReading.close()
    try output.fileHandleForWriting.close()
    defer {
      if child.isRunning { child.terminate() }
      child.waitUntilExit()
    }
    let expected = [ProcessInfo.processInfo.processIdentifier, child.processIdentifier].sorted()
    #expect(output.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8))
    #expect(try ProcessTable.processesHoldingOpen(path: url.path) == expected)

    try handle.close()
    #expect(try ProcessTable.processesHoldingOpen(path: url.path) == [child.processIdentifier])
    try input.fileHandleForWriting.close()
    child.waitUntilExit()
    #expect(try ProcessTable.processesHoldingOpen(path: url.path).isEmpty)
  }
}
