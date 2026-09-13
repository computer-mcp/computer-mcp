import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct VerificationScriptDependencyTests {
  @Test(
    arguments: ["verify-package-boundary.sh", "verify-cli-interface.sh"],
    ["missing", "version-error"])
  func requiredSearchToolFailuresCannotBecomeSuccess(script: String, fault: String) throws {
    let fixture = try GateFixture(script: script)
    defer { fixture.remove() }
    if fault == "version-error" {
      try fixture.searchTool("#!/bin/zsh\nexit 9\n")
    }
    let result = try fixture.run()
    #expect(!result.timedOut)
    #expect(result.exitCode == (fault == "missing" ? 127 : 9))
    #expect(!result.stdout.contains("passed"))
    if fault == "missing" { #expect(result.stderr.contains("ripgrep is unavailable")) }
  }

  @Test
  func unsuccessfulInspectionCannotCountAsNoForbiddenDeclarations() throws {
    let fixture = try GateFixture(script: "verify-package-boundary.sh")
    defer { fixture.remove() }
    // This package exists only so the gate reaches its negative source scan.
    // Dumping its manifest has no dependencies and does not contend for the real build directory.
    try #"""
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(name: "gate-fixture", products: [
      .executable(name: "ComputerMCPApp", targets: ["App"]),
      .executable(name: "computer-mcp", targets: ["CLI"]),
    ], targets: [.executableTarget(name: "App"), .executableTarget(name: "CLI")])
    """#.write(
      to: fixture.root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try fixture.searchTool(
      "#!/bin/zsh\nif [[ \"$1\" == \"--version\" ]]; then exit 0; fi\nexit 2\n")
    let result = try fixture.run()
    #expect(!result.timedOut)
    #expect(result.exitCode == 2)
    #expect(result.stderr.contains("could not complete the inspection"))
    #expect(!result.stdout.contains("gate passed"))
  }
}

private struct GateFixture {
  let root: URL
  let script: URL
  let dependency: URL

  init(script name: String) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "verification-gate-" + UUID().uuidString)
    let scripts = root.appendingPathComponent("Scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    script = scripts.appendingPathComponent(name)
    try FileManager.default.copyItem(
      at: repository.appendingPathComponent("Scripts").appendingPathComponent(name), to: script)
    dependency = root.appendingPathComponent("search-fixture")
  }

  func searchTool(_ contents: String) throws {
    try contents.write(to: dependency, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dependency.path)
  }

  func run() throws -> CommandResult {
    try ProcessCommandRunner().run(
      executable: "/bin/zsh", arguments: [script.path],
      workingDirectory: root, environment: ["RIPGREP_EXECUTABLE": dependency.path],
      timeoutMilliseconds: 30_000, maxOutputBytes: 32_768)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
