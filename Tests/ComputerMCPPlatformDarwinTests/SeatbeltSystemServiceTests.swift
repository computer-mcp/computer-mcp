import ComputerMCPPlatformDarwin
import ComputerMCPSandbox
import CryptoKit
import Foundation
import Testing

@Suite struct SeatbeltSystemServiceTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_LOCAL_SERVICE_TESTS"] == "1",
      "Local macOS test: requires a graphical login and existing Screen Recording, Accessibility and Automation grants for the fixture app"
    ))
  func inheritedPrivacyPermissionsRemainBoundedByEachServiceSwitch() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent(".agent/execution-environment/service-fixture")
      .resolvingSymlinksInPath()
    let app = root.appendingPathComponent("ServiceTarget.app")
    let executable = app.appendingPathComponent("Contents/MacOS/ServiceProbe")
    for directory in [
      executable.deletingLastPathComponent(), root.appendingPathComponent("home"),
      root.appendingPathComponent("tmp"), root.appendingPathComponent("cache"),
    ] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let source = try #require(
      Bundle.module.url(
        forResource: "SystemServiceProbe", withExtension: "m", subdirectory: "Fixtures"))
    try prepareApp(app, source: source, root: root)
    var ancestors: [SandboxPath] = []
    var ancestor = root.deletingLastPathComponent()
    while ancestor.path != "/" {
      ancestors.append(try SandboxPath(ancestor.path))
      ancestor.deleteLastPathComponent()
    }
    ancestors.append(try SandboxPath("/"))
    for mask in 0..<8 {
      let configuration = try SandboxConfiguration(
        worktree: .init(root.path),
        temporaryDirectory: .init(root.appendingPathComponent("tmp").path),
        homeDirectory: .init(root.appendingPathComponent("home").path),
        cacheDirectory: .init(root.appendingPathComponent("cache").path),
        readableRoots: [
          "/usr", "/bin", "/System", "/dev", "/private/etc", "/Library/Apple", "/Applications",
        ].map(SandboxPath.init),
        listableAncestors: ancestors,
        services: .init(
          screenCapture: mask & 1 != 0, accessibility: mask & 2 != 0, appleEvents: mask & 4 != 0))
      try SeatbeltProfile.generate(configuration).write(
        to: root.appendingPathComponent("\(mask).sb"), atomically: true, encoding: .utf8)
    }
    let output = root.appendingPathComponent("results.json")
    if FileManager.default.fileExists(atPath: output.path) {
      try FileManager.default.removeItem(at: output)
    }
    try #require(
      run("/usr/bin/open", ["-n", "-W", app.path, "--args", "host", root.path, UUID().uuidString])
        == 0)
    let results = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: output))
    #expect(
      results["hostPID"] == results["responsiblePID"],
      "The open-launched fixture must own its privacy responsibility")
    for (service, bit) in [
      ("screen", 1), ("screen-cg", 1), ("screen-cli", 1), ("accessibility", 2), ("apple-events", 4),
    ] {
      let preflight = try #require(results["\(service)/preflight"])
      #expect(
        preflight == 0,
        "\(service) positive control unavailable (\(preflight)); fixture \(app.path) requires an existing grant. No permission prompt or TCC change is performed."
      )
      guard preflight == 0 else { continue }
      let control = try #require(results["\(service)/control"])
      // A removed dynamic symbol has no legacy capture surface to exercise.
      if service == "screen-cg", control == 77 { continue }
      #expect(
        control == 0,
        "\(service) unsandboxed fixture operation must succeed before isolation can be evaluated")
      guard control == 0 else { continue }
      for mask in 0..<8 {
        let status = try #require(results["\(service)/\(mask)"])
        #expect(
          status == (mask & bit != 0 ? 0 : 1), "\(service), service mask \(mask), status \(status)")
      }
    }
  }

  private struct AppBuild: Codable {
    let inputs: String
    let executable: String
  }

  private func prepareApp(_ app: URL, source: URL, root: URL) throws {
    let executable = app.appendingPathComponent("Contents/MacOS/ServiceProbe")
    let info = app.appendingPathComponent("Contents/Info.plist")
    let entitlements = root.appendingPathComponent("entitlements.plist")
    let record = root.appendingPathComponent("build.json")
    let compileArguments = [
      "-fobjc-arc", "-framework", "AppKit", "-framework", "ApplicationServices",
      "-framework", "ScreenCaptureKit",
    ]
    let signArguments = ["--force", "--sign", "-", "--options", "runtime"]
    let plist: [String: Any] = [
      "CFBundleIdentifier": "local.computer-mcp.seatbelt-service-fixture",
      "CFBundleExecutable": "ServiceProbe", "CFBundlePackageType": "APPL", "LSUIElement": true,
      "NSAppleEventsUsageDescription":
        "Test service isolation using only this fixture's own window and custom Apple event.",
    ]
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: plist, format: .xml, options: 0)
    let entitlementData = try PropertyListSerialization.data(
      fromPropertyList: ["com.apple.security.automation.apple-events": true], format: .xml,
      options: 0)
    let inputs = try JSONSerialization.data(
      withJSONObject: [
        "source": Data(contentsOf: source).base64EncodedString(),
        "compile": compileArguments,
        "sign": signArguments,
        "plist": infoData.base64EncodedString(),
        "entitlements": entitlementData.base64EncodedString(),
        "compiler": commandOutput("/usr/bin/clang", ["--version"]),
        "sdk": commandOutput("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"]),
        "environment": ProcessInfo.processInfo.environment.filter {
          [
            "DEVELOPER_DIR", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "CPATH", "C_INCLUDE_PATH",
            "OBJC_INCLUDE_PATH", "LIBRARY_PATH",
          ].contains($0.key)
        },
      ], options: [.sortedKeys])
    let fingerprint = digest(inputs)
    if let savedData = try? Data(contentsOf: record),
      let saved = try? JSONDecoder().decode(AppBuild.self, from: savedData),
      saved.inputs == fingerprint,
      let binary = try? Data(contentsOf: executable), saved.executable == digest(binary),
      (try? Data(contentsOf: info)) == infoData,
      try run("/usr/bin/codesign", ["--verify", "--strict", app.path]) == 0
    {
      return
    }
    print(
      "Building local service fixture at \(app.path); its privacy permissions may need authorization again."
    )
    try #require(
      run("/usr/bin/clang", compileArguments + [source.path, "-o", executable.path]) == 0)
    try infoData.write(to: info)
    try entitlementData.write(to: entitlements)
    try #require(
      run("/usr/bin/codesign", signArguments + ["--entitlements", entitlements.path, app.path]) == 0
    )
    try #require(run("/usr/bin/codesign", ["--verify", "--strict", app.path]) == 0)
    let build = AppBuild(inputs: fingerprint, executable: try digest(Data(contentsOf: executable)))
    try JSONEncoder().encode(build).write(to: record, options: .atomic)
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func commandOutput(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return String(decoding: data, as: UTF8.self)
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
