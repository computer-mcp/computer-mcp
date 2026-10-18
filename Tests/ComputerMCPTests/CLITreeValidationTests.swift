import CryptoKit
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct CLITreeValidationTests {
  @Test
  func reportsTheSameAcceptanceAsRuntimeWithoutExecution() throws {
    let data = try fixture()
    let tree = try CLITree.parse(data)
    let report = CLITreeValidation.validate(data: data, expectedVersion: "fixture-1")
    #expect(report.valid && !report.checkedExecutable && report.executableCheckCount == 0)
    #expect(report.tree?.commandCount == tree.commands.count)
    let encoded = try #require(try JSONValue.encoded(report).objectValue)
    #expect(encoded["format_version"] == .integer(1))
    #expect(encoded["valid"] == .bool(true))
    #expect(encoded["diagnostics"] == .array([]))
  }

  @Test(arguments: ["a/b~c", "unexpected"])
  func unknownFieldHasEscapedDeterministicPointer(_ field: String) throws {
    var value = try #require(try JSONDecoder().decode(JSONValue.self, from: fixture()).objectValue)
    value[field] = .string("ignored")
    let report = CLITreeValidation.validate(data: try JSONEncoder().encode(value))
    #expect(!report.valid)
    #expect(report.diagnostics.first?.code == "clitree.document.unknown_field")
    #expect(report.diagnostics.first?.path == CLITreeDiagnostic.pointer([field]))
  }

  @Test
  func missingTypedFieldAndMalformedJSONAreStructured() throws {
    var value = try #require(try JSONDecoder().decode(JSONValue.self, from: fixture()).objectValue)
    value.removeValue(forKey: "coverage")
    let missing = CLITreeValidation.validate(data: try JSONEncoder().encode(value))
    #expect(missing.diagnostics.first?.code == "clitree.document.missing_field")
    #expect(missing.diagnostics.first?.path == "/coverage")
    let malformed = CLITreeValidation.validate(data: Data("{".utf8))
    #expect(!malformed.valid && malformed.diagnostics.first?.code == "clitree.document.encoding")
    let oversized = CLITreeValidation.validate(data: Data(repeating: 32, count: 4_194_305))
    #expect(oversized.diagnostics.first?.code == "clitree.document.too_large")
  }

  @Test
  func decoderArrayIndicesAreJSONPointers() throws {
    var value = try #require(try JSONDecoder().decode(JSONValue.self, from: fixture()).objectValue)
    var commands = try #require(value["commands"]?.arrayValue)
    var command = try #require(commands[0].objectValue)
    command["stdout"] = .integer(7)
    commands[0] = .object(command)
    value["commands"] = .array(commands)
    let report = CLITreeValidation.validate(data: try JSONEncoder().encode(value))
    #expect(report.diagnostics.first?.code == "clitree.document.type")
    #expect(report.diagnostics.first?.path == "/commands/0/stdout")
  }

  @Test
  func parameterDefaultAndArgumentFailuresIdentifyTheirNode() throws {
    var command = CLICommandDescriptor(id: "run", path: [], description: "Fixture")
    command.parameters = [
      .init(
        name: "count", schema: .object(["type": .string("integer")]),
        defaultValue: .string("secret-invalid-value"))
    ]
    command.argv = [.init(kind: .option, parameter: "count", flag: "--count", style: .equals)]
    let report = CLITreeValidation.validate(
      data: try JSONEncoder().encode(CLITreeTests.tree(command)))
    #expect(report.diagnostics.first?.code == "clitree.parameter.invalid")
    #expect(report.diagnostics.first?.path == "/commands/0/parameters/0")
    #expect(!report.diagnostics[0].message.contains("secret-invalid-value"))
    command.parameters[0].defaultValue = .integer(4)
    command.argv[0].flag = "--bad=flag"
    let argv = CLITreeValidation.validate(
      data: try JSONEncoder().encode(CLITreeTests.tree(command)))
    #expect(argv.diagnostics.first?.code == "clitree.argv.invalid")
    #expect(argv.diagnostics.first?.path == "/commands/0/argv/0")
  }

  @Test
  func duplicateCommandAndMissingParentAreDistinct() throws {
    let node = CLICommandDescriptor(id: "run", path: ["missing", "run"], description: "Fixture")
    let duplicate = CLITree(
      formatVersion: 1, source: "fixture", executableVersion: "1", coverage: .complete,
      omissions: [], commands: [node, node])
    let repeated = CLITreeValidation.validate(data: try JSONEncoder().encode(duplicate))
    #expect(repeated.diagnostics.first?.code == "clitree.command.duplicate")
    #expect(repeated.diagnostics.first?.path == "/commands/1")
    let missing = CLITreeValidation.validate(
      data: try JSONEncoder().encode(CLITreeTests.tree(node)))
    #expect(missing.diagnostics.first?.code == "clitree.command.missing_parent")
    #expect(missing.diagnostics.first?.path == "/commands/0/path")
  }

  @Test
  func noChecksAreHonestAndCannotBecomeCompatibilitySuccess() async throws {
    let data = try fixture(checks: [])
    let validation = CLITreeValidation.validate(data: data)
    #expect(validation.valid && validation.diagnostics.first?.severity == "warning")
    let checked = await CLITreeValidation.check(
      data: data, executable: "/nonexistent", workingDirectory: URL(fileURLWithPath: "/tmp"))
    #expect(!checked.valid && !checked.checkedExecutable)
    #expect(checked.diagnostics.last?.code == "clitree.check.missing")
  }

  @Test
  func exactOutputAndHashChecksDoNotExecuteCommandNodes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let digest = SHA256.hash(data: Data("fixture\n".utf8)).map { String(format: "%02x", $0) }
      .joined()
    let data = try fixture(checks: [
      .init(args: ["fixture\n"], stdout: "fixture\n"),
      .init(args: ["fixture\n"], stdoutSHA256: digest),
    ])
    let executable = root.appendingPathComponent("probe")
    try Data("#!/bin/sh\nprintf 'checked\\n' >> calls\nprintf '%s' \"$1\"\n".utf8)
      .write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let report = await CLITreeValidation.check(
      data: data, executable: executable.path, workingDirectory: root,
      environment: ["PATH": "/usr/bin:/bin"])
    #expect(report.valid && report.checkedExecutable && report.executableCheckCount == 2)
    #expect(
      try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
        == "checked\nchecked\n")
    let drift = await CLITreeValidation.check(
      data: try fixture(checks: [.init(args: ["actual"], stdout: "different")]),
      executable: "/usr/bin/printf", workingDirectory: root)
    #expect(!drift.valid && !drift.checkedExecutable && drift.executableCheckCount == 0)
    #expect(drift.diagnostics.first?.code == "clitree.check.mismatch")
    #expect(drift.diagnostics.first?.path == "/executable_checks/0")
    #expect(!drift.diagnostics[0].message.contains("actual"))
  }

  @Test
  func versionMismatchStopsBeforeLaunchingTheExecutable() async throws {
    let report = await CLITreeValidation.check(
      data: try fixture(), executable: "/nonexistent",
      workingDirectory: URL(fileURLWithPath: "/tmp"),
      expectedVersion: "different")
    #expect(report.diagnostics.map(\.code) == ["clitree.version.mismatch"])
    #expect(report.executableCheckCount == 0 && !report.checkedExecutable)
  }

  @Test
  func boundedFileReadsAllowContainedLinksAndRejectEscapes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("tree.json")
    try fixture().write(to: file)
    let link = root.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(CLITreeValidation.validate(file: file).valid)
    #expect(CLITreeValidation.validate(file: link).valid)
    let nested = root.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    let escape = nested.appendingPathComponent("escape.json")
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: file)
    #expect(
      CLITreeValidation.validate(file: escape).diagnostics.first?.code
        == "clitree.document.unreadable")
    #expect(
      CLITreeValidation.validate(file: root.appendingPathComponent("missing")).diagnostics.first?
        .code == "clitree.document.unreadable")
  }

  private func fixture(
    checks: [CLIExecutableCheck] = [.init(args: ["fixture\n"], stdout: "fixture\n")]
  ) throws -> Data {
    try JSONEncoder().encode(
      CLITree(
        formatVersion: 1, source: "fixture", executableVersion: "fixture-1", coverage: .complete,
        omissions: [],
        commands: [
          .init(
            id: "run", path: [], description: "Must never execute while checking",
            argv: [.init(kind: .literal, value: "forbidden-target")])
        ], executableChecks: checks))
  }
}
