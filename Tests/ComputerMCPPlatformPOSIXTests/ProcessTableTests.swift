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
    let parent = ProcessInfo.processInfo.processIdentifier
    #expect(try !ProcessTable.processesHoldingOpen(path: url.path).contains(parent))

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
    // Processes that concurrent tests fork share the holder descriptor until they execute.
    func holders() throws -> Set<Int32> {
      let found = try ProcessTable.processesHoldingOpen(path: url.path)
      #expect(found == found.sorted())
      return Set(found).intersection([parent, child.processIdentifier])
    }
    #expect(output.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8))
    #expect(try holders() == [parent, child.processIdentifier])

    try holder.close()
    #expect(try holders() == [child.processIdentifier])
    try input.fileHandleForWriting.close()
    child.waitUntilExit()
    #expect(try holders().isEmpty)
  }
}
