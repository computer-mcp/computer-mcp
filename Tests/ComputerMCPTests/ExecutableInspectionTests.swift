import Darwin
import Foundation
import Testing

@testable import ComputerMCP

struct ExecutableInspectionTests {
  @Test
  func unreadableHeadersAndUnsupportedEncodingsDoNotAssertLaunchFailure() throws {
    let unreadable = ExecutableInspection(
      executable: "/tool", path: "/tool", source: "absolute_path", status: .unreadable)
    #expect(!unreadable.hasKnownFailure)
    let fixture = try ExecutableInspectionFixture()
    defer { fixture.cleanup() }
    let script = try fixture.script("tool", "")
    try Data([35, 33, 47, 255, 10]).write(to: script)
    let inspection = fixture.inspect(script.path)
    #expect(inspection.status == .unverified)
    #expect(!inspection.hasKnownFailure)
  }

  @Test
  func reportsFileTypesAndPermissionsWithoutOpeningSpecialFiles() throws {
    let fixture = try ExecutableInspectionFixture()
    defer { fixture.cleanup() }
    let file = try fixture.script("tool", "#!/bin/sh\nexit 0\n")
    #expect(fixture.inspect(file.path).status == .passed)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(fixture.inspect(file.path).status == .notExecutable)
    #expect(fixture.inspect(fixture.root.path).status == .notRegularFile)
    let fifo = fixture.root.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o700) == 0)
    #expect(fixture.inspect(fifo.path).status == .notRegularFile)
    #expect(fixture.inspect(fixture.root.appendingPathComponent("missing").path).status == .missing)
    #expect(fixture.inspect("").status == .invalidPath)
    #expect(fixture.inspect("/bin/echo\0ignored").status == .invalidPath)
    #expect(fixture.inspect(String(repeating: "a", count: 4096)).status == .invalidPath)
  }

  @Test
  func findsMissingEnvInterpreterWithoutExecutingOrExposingScriptArguments() throws {
    let fixture = try ExecutableInspectionFixture()
    defer { fixture.cleanup() }
    let script = try fixture.script(
      "tool", "#!/usr/bin/env unavailable-test-runtime --token=do-not-print\ntouch marker\n")
    let result = fixture.inspect(script.path)
    #expect(result.exists && result.isExecutable && result.isRegularFile && result.isScript)
    #expect(result.status == .interpreterUnavailable)
    #expect(result.interpreters.map(\.executable) == ["/usr/bin/env", "unavailable-test-runtime"])
    #expect(result.interpreters.last?.status == .missing)
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("marker").path))
    let data = try JSONEncoder().encode(result)
    #expect(!String(decoding: data, as: UTF8.self).contains("do-not-print"))
    #expect(try JSONDecoder().decode(ExecutableInspection.self, from: data) == result)
  }

  @Test
  func honorsChildPathAndCwdWithoutFallingThroughABrokenInterpreter() throws {
    let fixture = try ExecutableInspectionFixture()
    defer { fixture.cleanup() }
    let first = fixture.root.appendingPathComponent("first")
    let second = fixture.root.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let broken = try fixture.script("first/tool", "#!/definitely-missing/interpreter\n")
    let good = try fixture.script("second/tool", "#!/bin/sh\nexit 0\n")
    let result = fixture.inspect("tool", path: "\(first.path):\(second.path)")
    #expect(result.path == broken.path)
    #expect(result.status == .interpreterUnavailable)
    #expect(fixture.inspect("tool", path: second.path).path == good.path)
    #expect(fixture.inspect("second/tool", path: "").path == good.path)
    let local = try fixture.script("local", "#!/bin/sh\nexit 0\n")
    #expect(fixture.inspect("local", path: "").path == local.path)
    #expect(fixture.inspect("tool", path: "second").path == good.path)
    #expect(fixture.inspect(broken.path, path: second.path).path == broken.path)
  }

  @Test
  func skipsDirectoriesOnPathAndAcceptsExternalSymlinks() throws {
    let fixture = try ExecutableInspectionFixture()
    defer { fixture.cleanup() }
    let directory = fixture.root.appendingPathComponent("echo")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(fixture.inspect("echo", path: "\(fixture.root.path):/bin").path == "/bin/echo")
    let link = fixture.root.appendingPathComponent("运行工具")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
    #expect(fixture.inspect(link.path).status == .passed)
    #expect(fixture.inspect(link.path).path == link.path)
  }

  @Test(arguments: [
    ("#!/bin/sh -e\n", ExecutableInspection.Status.passed),
    ("#! \t/bin/sh # comment\n", .passed),
    ("#!/usr/bin/env sh\n", .passed),
    ("#!/usr/bin/env -S sh -e\n", .passed),
    ("#!/usr/bin/env -S 'sh' -e\n", .unverified),
    ("#!/usr/bin/env PATH=/custom sh\n", .unverified),
    ("#!/usr/bin/env -i sh\n", .unverified),
    ("#!\n", .invalidShebang),
    ("#!/bin/sh\0ignored\n", .invalidShebang),
    ("#!/bin/sh\r\n", .interpreterUnavailable),
    ("#!/bin/sh" + String(repeating: " ", count: 512) + "\n", .invalidShebang),
  ])
  func interpretsSupportedShebangsAndReportsUncertainty(
    header: String, expected: ExecutableInspection.Status
  ) throws {
    let fixture = try ExecutableInspectionFixture()
    defer { fixture.cleanup() }
    let script = try fixture.script("tool", header + "exit 0\n")
    #expect(fixture.inspect(script.path, path: "/usr/bin:/bin").status == expected)
  }

  @Test
  func rejectsDirectScriptInterpretersAndBoundsEnvCycles() throws {
    let fixture = try ExecutableInspectionFixture()
    defer { fixture.cleanup() }
    let interpreter = try fixture.script("interpreter", "#!/bin/sh\n")
    let script = try fixture.script("tool", "#!\(interpreter.path)\n")
    #expect(fixture.inspect(script.path).status == .invalidShebang)
    let cycle = try fixture.script("cycle", "#!/usr/bin/env cycle\n")
    #expect(fixture.inspect(cycle.path).status == .unverified)
  }

  @Test
  func inspectionMatchesARealIsolatedEnvLaunch() throws {
    let fixture = try ExecutableInspectionFixture()
    defer { fixture.cleanup() }
    let script = try fixture.script("tool", "#!/usr/bin/env fixture-runtime\n")
    let runner = ProcessCommandRunner()
    func run() throws -> CommandResult {
      try runner.run(
        executable: "/usr/bin/env", arguments: [script.path], workingDirectory: fixture.root,
        environment: ["PATH": fixture.root.path], timeoutMilliseconds: 3000, maxOutputBytes: 1024)
    }
    #expect(fixture.inspect(script.path).status == .interpreterUnavailable)
    let missing = try run()
    #expect(missing.exitCode == 127 && !missing.timedOut)
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appendingPathComponent("fixture-runtime"),
      withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
    #expect(fixture.inspect(script.path).status == .passed)
    let available = try run()
    #expect(available.exitCode == 0 && !available.timedOut)
    #expect(available.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == script.path)
  }
}

private struct ExecutableInspectionFixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "executable-inspection-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  func script(_ name: String, _ contents: String) throws -> URL {
    let file = root.appendingPathComponent(name)
    try contents.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    return file
  }
  func inspect(_ executable: String, path: String? = nil) -> ExecutableInspection {
    ExecutableInspection.inspect(
      executable, workingDirectory: root, environment: ["PATH": path ?? root.path])
  }
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
