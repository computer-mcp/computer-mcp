import Foundation
import Testing

@testable import ComputerMCPPlatformPOSIX

struct ProcessTableTests {
  @Test(arguments: [false, true])
  func findsEveryProcessHoldingAFileOpen(throughHardLink: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("file")
    try Data("held".utf8).write(to: url)
    let opened = directory.appendingPathComponent("alias")
    try FileManager.default.linkItem(at: url, to: opened)
    #expect(try ProcessTable.processesHoldingOpen(path: url.path).isEmpty)

    let openedURL = throughHardLink ? opened : url
    let holder = try FileHandle(forReadingFrom: openedURL)
    defer { try? holder.close() }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = [
      "-c", #"exec 3<"$0"; printf 'ready\n'; read -r command || :"#, openedURL.path,
    ]
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

    try holder.close()
    #expect(try ProcessTable.processesHoldingOpen(path: url.path) == [child.processIdentifier])
    try input.fileHandleForWriting.close()
    child.waitUntilExit()
    #expect(try ProcessTable.processesHoldingOpen(path: url.path).isEmpty)
  }
}
