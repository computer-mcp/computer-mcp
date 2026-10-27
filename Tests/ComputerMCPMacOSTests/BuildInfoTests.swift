import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlugins
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

struct BuildInfoTests {
  @Test
  func jsonAndHumanOutputReportTheHostPluginAPIRange() throws {
    let scratch = try ScopedTemporaryDirectory()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: scratch.url.path)
    let executable = try nativeGatewayTestExecutable()
    func run(_ arguments: [String]) throws -> CommandResult {
      let environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": scratch.url.path,
        "TMPDIR": scratch.url.path + "/", "TMP": scratch.url.path, "TEMP": scratch.url.path,
      ]
      let administration = ExecutionAdministration(
        mode: .fullAccess,
        environment: try ExecutionEnvironment(fullAccessVariables: environment))
      return try ExecutionAdministration.$current.withValue(administration) {
        try ProcessCommandRunner(launcher: testExecutionLauncher(), environment: [:]).run(
          executable: executable.path, arguments: ["build-info"] + arguments,
          workingDirectory: scratch.url, environment: environment, timeoutMilliseconds: 10_000,
          maxOutputBytes: 16_384)
      }
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
