import ComputerMCPProcess
import ComputerMCPToolKit
import Foundation

/// Uses the registered executable and interpreter binding, with a complete sanitized environment.
internal struct DeliveryGit: Sendable {
  struct Result {
    var stdout: String
    var exitCode: Int32?
    var stderr: String
  }
  let executable: String
  let prefix: [String]
  let environment: [String: String]
  let timeout: Int
  private let runner = ManagedCommandRunner()

  init(environment tools: ToolEnvironment) throws {
    let command = try tools.registeredCommands.gitCLICommand()
    let invocation = try tools.registeredCommands.resolveCLIInvocation(command)
    executable = invocation.executable
    prefix = invocation.arguments
    var environment = tools.environment.merging(command.env) { _, value in value }
      .filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_TERMINAL_PROMPT"] = "0"
    self.environment = environment
    timeout = command.defaultTimeoutMs ?? tools.configuration.policy.defaultTimeoutMs
  }

  @discardableResult
  func run(_ arguments: [String], at directory: URL, accepting: Set<Int32> = [0]) throws -> Result {
    do {
      let pathOptions =
        ["add", "status", "diff"].contains(arguments.first ?? "") ? ["--literal-pathspecs"] : []
      let result = try runner.run(
        executable: executable, arguments: prefix + pathOptions + arguments,
        workingDirectory: directory, environment: environment,
        timeoutMilliseconds: timeout, maxOutputBytes: 1_048_576)
      guard !result.timedOut, let code = result.exitCode, accepting.contains(code),
        !result.stdoutTruncated
      else {
        throw DeliveryFailure(
          reason: .gitFailed, detail: "Git command failed: \(arguments.first ?? "git").",
          exitCode: result.exitCode, stderr: boundedDeliveryText(result.stderr))
      }
      return Result(
        stdout: result.stdout, exitCode: result.exitCode,
        stderr: boundedDeliveryText(result.stderr))
    } catch let failure as DeliveryFailure { throw failure } catch {
      throw DeliveryFailure(
        reason: .gitFailed, detail: boundedDeliveryText(error.localizedDescription))
    }
  }

  func revision(_ ref: String, at directory: URL) throws -> String? {
    let result = try run(
      ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], at: directory, accepting: [0, 1])
    return result.exitCode == 0
      ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
  }

  func isAncestor(_ commit: String, of ref: String, at directory: URL) throws -> Bool {
    try run(["merge-base", "--is-ancestor", commit, ref], at: directory, accepting: [0, 1]).exitCode
      == 0
  }
}
