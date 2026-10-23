import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlugins
import ComputerMCPProcess
import ComputerMCPTestSupport
import Foundation
import Testing

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

struct BuildInfoTests {
  @Test
  func jsonAndHumanOutputReportTheHostPluginAPIRange() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let executable = repository.appendingPathComponent(".build/debug/computer-mcp")
    func run(_ arguments: [String]) throws -> CommandResult {
      try ProcessCommandRunner(launcher: testExecutionLauncher()).run(
        executable: executable.path, arguments: ["build-info"] + arguments,
        workingDirectory: repository, environment: [:], timeoutMilliseconds: 10_000,
        maxOutputBytes: 16_384)
    }
    for arguments in [[], ["--format", "json"]] {
      let output = try run(arguments)
      #expect(output.exitCode == 0)
      let json = try JSONDecoder().decode(JSONValue.self, from: Data(output.stdout.utf8))
      let supported = try JSONValue.encoded(PluginAPIVersions.supported)
      #expect(json.objectValue?["plugin_api"] == supported)
      #expect(json.objectValue?["version"] == .string(ComputerMCPCLI.version))
    }
    let human = try run(["--format", "human"])
    #expect(human.exitCode == 0)
    let range = PluginAPIVersions.supported
    #expect(human.stdout.contains("plugin_api: minimum \(range.minimum), maximum \(range.maximum)"))
  }
}
