import ComputerMCPPlatformDarwin
import Foundation
import Testing

@Suite struct ResponsibilityAppTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_LOCAL_RESPONSIBILITY_TESTS"] == "1",
      "Local macOS test: requires Launch Services open and ad-hoc code signing"))
  func openLaunchedAppHasIndependentResponsibility() throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let binaryDirectory = Bundle.module.bundleURL.deletingLastPathComponent()
    let candidateDirectories = Array(
      sequence(first: binaryDirectory) { $0.deletingLastPathComponent() }.prefix(6))
    let helper = try #require(
      candidateDirectories.map { $0.appendingPathComponent("ComputerMCPExecutionProbe") }
        .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }))
    let app = fixture.root.appendingPathComponent("Responsibility.app")
    let executable = app.appendingPathComponent("Contents/MacOS/Probe")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: helper, to: executable)
    let bootstrap = try #require(
      candidateDirectories.map { $0.appendingPathComponent("computer-mcp-execution-bootstrap") }
        .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }))
    let bundledBootstrap = app.appendingPathComponent(
      "Contents/Helpers/computer-mcp-execution-bootstrap")
    try FileManager.default.createDirectory(
      at: bundledBootstrap.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: bootstrap, to: bundledBootstrap)
    #expect(
      try run(
        "/usr/bin/codesign",
        ["--force", "--sign", "-", "--options", "runtime", bundledBootstrap.path]) == 0)
    let plist: [String: Any] = [
      "CFBundleIdentifier": "local.execution-probe." + UUID().uuidString.lowercased(),
      "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL", "LSUIElement": true,
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    #expect(
      try run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", app.path])
        == 0)
    let output = fixture.root.appendingPathComponent("responsibility.txt")
    #expect(try run("/usr/bin/open", ["-n", "-W", app.path, "--args", "host", output.path]) == 0)
    let text = try String(contentsOf: output, encoding: .utf8)
    #expect(text.contains("complete"), "\(text)")
    let records = Dictionary(
      uniqueKeysWithValues: text.split(separator: "\n").compactMap { line -> (String, [Int])? in
        let parts = line.split(separator: " ")
        guard parts.count == 4, parts.dropFirst().allSatisfy({ Int($0) != nil }) else { return nil }
        return (String(parts[0]), parts.dropFirst().compactMap { Int($0) })
      })
    let host = try #require(records["host"])
    #expect(host[1] == 1)
    #expect(host[0] == host[2])
    for label in [
      "posixSpawn-disclaim", "foundation-disclaim", "subprocess-disclaim",
      "posixSpawn-inherit", "foundation-default", "foundation-false", "subprocess-inherit",
    ] {
      let child = try #require(records[label])
      let inherited = try #require(records[label + "/inherit"])
      let disclaimed = try #require(records[label + "/disclaim"])
      #expect(child[2] == (label.hasSuffix("-disclaim") ? child[0] : host[0]), "\(label)")
      #expect(inherited[2] == child[2], "\(label)/inherit")
      #expect(disclaimed[2] == disclaimed[0], "\(label)/disclaim")
    }
  }

  private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }
}
