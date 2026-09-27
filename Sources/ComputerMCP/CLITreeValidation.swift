import Foundation

package struct CLITreeDiagnostic: Codable, Equatable, Sendable {
  package let code: String
  /// RFC 6901 JSON Pointer; the empty string denotes the document root.
  package let path: String
  package var severity = "error"
  package let message: String

  static func pointer(_ components: [String]) -> String {
    components.map {
      "/"
        + $0.replacingOccurrences(of: "~", with: "~0")
        .replacingOccurrences(of: "/", with: "~1")
    }.joined()
  }

  static func document(_ error: any Error) -> Self {
    if case CLITreeError.document(let issue) = error { return issue }
    let context: DecodingError.Context
    let code: String
    var missing: String?
    switch error {
    case DecodingError.keyNotFound(let key, let value):
      context = value
      code = "clitree.document.missing_field"
      missing = key.stringValue
    case DecodingError.typeMismatch(_, let value), DecodingError.valueNotFound(_, let value):
      context = value
      code = "clitree.document.type"
    case DecodingError.dataCorrupted(let value):
      context = value
      code = "clitree.document.encoding"
    default:
      return .init(code: "clitree.document.invalid", path: "", message: error.localizedDescription)
    }
    let components = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
    let path = pointer(components + (missing.map { [$0] } ?? []))
    return .init(
      code: code, path: path,
      message: "Field is missing, has the wrong type, or contains an unsupported value.")
  }
}

package struct CLITreeValidationReport: Encodable, Sendable {
  package let formatVersion = 1
  package var diagnostics: [CLITreeDiagnostic] = []
  package var tree: Summary?
  package var executableCheckCount = 0
  package var checkedExecutable = false
  package var valid: Bool { !diagnostics.contains { $0.severity == "error" } }

  package struct Summary: Codable, Sendable {
    let source: String
    let executableVersion: String
    let coverage: String
    let commandCount: Int
    enum CodingKeys: String, CodingKey {
      case source, coverage
      case executableVersion = "executable_version"
      case commandCount = "command_count"
    }
  }

  private enum CodingKeys: String, CodingKey {
    case valid, diagnostics, tree
    case formatVersion = "format_version"
    case executableCheckCount = "executable_check_count"
    case checkedExecutable = "checked_executable"
  }

  package func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(formatVersion, forKey: .formatVersion)
    try c.encode(valid, forKey: .valid)
    try c.encode(diagnostics, forKey: .diagnostics)
    try c.encodeIfPresent(tree, forKey: .tree)
    try c.encode(executableCheckCount, forKey: .executableCheckCount)
    try c.encode(checkedExecutable, forKey: .checkedExecutable)
  }
}

/// Authoring tools use the same parser and compatibility assertions as runtime admission.
package enum CLITreeValidation {
  package static func validate(data: Data, expectedVersion: String? = nil)
    -> CLITreeValidationReport
  {
    validation(data, expectedVersion: expectedVersion).0
  }

  package static func validate(file: URL, expectedVersion: String? = nil) -> CLITreeValidationReport
  {
    do { return validate(data: try read(file), expectedVersion: expectedVersion) } catch {
      return readFailure()
    }
  }

  package static func check(
    file: URL, executable: String, workingDirectory: URL, expectedVersion: String? = nil
  ) async -> CLITreeValidationReport {
    let data: Data
    do { data = try read(file) } catch { return readFailure() }
    return await check(
      data: data, executable: executable, workingDirectory: workingDirectory,
      expectedVersion: expectedVersion)
  }

  static func check(
    data: Data, executable: String, workingDirectory: URL, expectedVersion: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async -> CLITreeValidationReport {
    var (report, tree) = validation(data, expectedVersion: expectedVersion)
    guard report.valid, let tree else { return report }
    guard !tree.executableChecks.isEmpty else {
      report.diagnostics.append(
        .init(
          code: "clitree.check.missing", path: "/executable_checks",
          message: "Declare exact executable checks before checking compatibility."))
      return report
    }
    let execution = CLIProcessExecution(inheritsEnvironment: false)
    do {
      let identity = try CLIExecutableIdentity.capture(
        executable: executable, cwd: workingDirectory, environment: environment)
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      for (index, check) in tree.executableChecks.enumerated() {
        try Task.checkCancellation()
        let path = "/executable_checks/\(index)"
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let milliseconds = remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000
        guard milliseconds > 0 else {
          report.diagnostics.append(
            .init(
              code: "clitree.check.timeout", path: path,
              message: "Compatibility checks exceeded five seconds."))
          break
        }
        let result = try await execution.runAsync(
          executable: identity.executable,
          invocation: .init(arguments: check.args, standardInput: Data()), cwd: workingDirectory,
          environment: environment, timeoutMilliseconds: Int(milliseconds),
          maxOutputBytes: 4_194_304)
        guard check.matches(result), ContinuousClock.now < deadline else {
          report.diagnostics.append(
            .init(
              code: "clitree.check.mismatch", path: path,
              message: "Executable check failed or returned incomplete or different output."))
          break
        }
        guard
          try CLIExecutableIdentity.capture(
            executable: executable, cwd: workingDirectory, environment: environment) == identity
        else {
          report.diagnostics.append(
            .init(
              code: "clitree.check.identity_changed", path: path,
              message: "Executable or interpreter changed during compatibility checks."))
          break
        }
        report.executableCheckCount += 1
      }
      report.checkedExecutable = report.valid
    } catch is CancellationError {
      report.diagnostics.append(
        .init(
          code: "clitree.check.cancelled", path: "/executable_checks",
          message: "Compatibility checks were cancelled."))
    } catch {
      report.diagnostics.append(
        .init(
          code: "clitree.check.unavailable", path: "/executable_checks",
          message: "Executable compatibility could not be checked."))
    }
    await execution.shutdown()
    return report
  }

  private static func validation(_ data: Data, expectedVersion: String?) -> (
    CLITreeValidationReport, CLITree?
  ) {
    var report = CLITreeValidationReport()
    do {
      let tree = try CLITree.parse(data)
      report.tree = .init(
        source: tree.source, executableVersion: tree.executableVersion,
        coverage: tree.coverage.rawValue, commandCount: tree.commands.count)
      if let expectedVersion, expectedVersion != tree.executableVersion {
        report.diagnostics.append(
          .init(
            code: "clitree.version.mismatch", path: "/executable_version",
            message: "Tree version differs from the expected version."))
      }
      if tree.executableChecks.isEmpty {
        report.diagnostics.append(
          .init(
            code: "clitree.check.undeclared", path: "/executable_checks", severity: "warning",
            message:
              "No executable compatibility checks are declared; version metadata alone does not prove compatibility."
          ))
      }
      return (report, tree)
    } catch {
      report.diagnostics.append(.document(error))
      return (report, nil)
    }
  }

  private static func read(_ file: URL) throws -> Data {
    let url = file.standardizedFileURL
    return try PluginPackageFiles(root: url.deletingLastPathComponent()).read(
      url.lastPathComponent, maximumBytes: 4_194_304)
  }

  private static func readFailure() -> CLITreeValidationReport {
    .init(diagnostics: [
      .init(
        code: "clitree.document.unreadable", path: "",
        message: "Read requires a regular file within its source directory, no larger than 4 MiB.")
    ])
  }
}
