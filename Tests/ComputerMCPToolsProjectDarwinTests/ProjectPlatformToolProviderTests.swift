import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformDarwin
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsProject

@Suite(.nativeIntegration, .serialized)
final class ProjectPlatformToolProviderTests {
  @Test
  func testProjectOpenUsesMacOSOpenForProjectPath() throws {
    let runner = RecordingCommandRunner()
    let directory = try temporaryDirectory()
    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.open"]),
          projectDirectory: directory
        ),
        commandRunner: runner, projectOpener: DarwinProjectOpener(commandRunner: runner)))

    _ = try provider.callTool(
      .init(
        name: "project.open",
        arguments: .object(["path": .string(".")]), context: .empty
      ))

    #expect((runner.calls.first?.executable) == ("/usr/bin/open"))
    #expect(
      (runner.calls.first?.arguments)
        == ([directory.standardizedFileURL.resolvingSymlinksInPath().path]))
  }

  @Test
  func testProjectRevealUsesMacOSOpenRevealForProjectPath() throws {
    let runner = RecordingCommandRunner()
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("note.txt")
    try "ready".write(to: file, atomically: true, encoding: .utf8)
    let provider = ProjectToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.reveal"]),
          projectDirectory: directory
        ),
        commandRunner: runner, projectOpener: DarwinProjectOpener(commandRunner: runner)))

    _ = try provider.callTool(
      .init(
        name: "project.reveal",
        arguments: .object(["path": .string("note.txt")]), context: .empty
      ))

    #expect((runner.calls.first?.executable) == ("/usr/bin/open"))
    #expect((runner.calls.first?.arguments) == (["-R", file.path]))
  }

  private var temporaryDirectories: [ScopedTemporaryDirectory] = []

  private func temporaryDirectory() throws -> URL {
    let directory = try ScopedTemporaryDirectory()
    temporaryDirectories.append(directory)
    return directory.url
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}
