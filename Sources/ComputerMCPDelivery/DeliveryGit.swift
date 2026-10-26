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
  private let identityEnvironment: [String: String]
  private let home: PrivateProcessHome
  let timeout: Int
  private let runner = ManagedCommandRunner()
  private var worktree: (root: URL, directory: URL)?

  /// Pins repository discovery even if the worktree's gitfile disappears.
  func pinned(to root: URL, directory: URL) -> Self {
    var git = self
    git.worktree = (root, directory)
    return git
  }

  init(environment tools: ToolEnvironment) throws {
    let command = try tools.registeredCommands.gitCLICommand()
    let invocation = try tools.registeredCommands.resolveCLIInvocation(command)
    executable = invocation.executable
    prefix = invocation.arguments
    home = try PrivateProcessHome()
    let sourceEnvironment = tools.environment.merging(command.env) { _, value in value }
    self.environment = HostGitConfiguration.environment(
      sourceEnvironment, home: home.url)
    identityEnvironment = HostGitConfiguration.identityEnvironment(sourceEnvironment)
    timeout = command.defaultTimeoutMs ?? tools.configuration.policy.defaultTimeoutMs
  }

  @discardableResult
  func run(
    _ arguments: [String], at directory: URL, accepting: Set<Int32> = [0],
    input: Data = Data(), additionalProgramOptions: [String] = []
  ) throws -> Result {
    do {
      let command = arguments.drop(while: { $0 == "--no-optional-locks" }).first ?? ""
      let pathOptions =
        ["add", "status", "diff", "restore", "ls-files", "ls-tree"].contains(command)
        ? ["--literal-pathspecs"] : []
      let binding =
        worktree.map { ["--git-dir=\($0.directory.path)", "--work-tree=\($0.root.path)"] }
        ?? []
      var programOptions = try self.programOptions(at: directory) + additionalProgramOptions
      if ["commit", "merge", "rebase"].contains(command) {
        for key in ["user.name", "user.email"] {
          let identity = try runner.runData(
            executable: executable,
            invocation: .init(
              arguments: prefix + binding + HostGitConfiguration.arguments
                + ["config", "--null", "--get", key], standardInput: Data()),
            workingDirectory: directory, environment: identityEnvironment,
            timeoutMilliseconds: timeout, maxOutputBytes: 65_536)
          guard !identity.timedOut, !identity.stdoutTruncated,
            identity.exitCode == 0 || identity.exitCode == 1
          else {
            throw DeliveryFailure(reason: .gitFailed, detail: "Cannot read Git author identity.")
          }
          if identity.exitCode == 0 {
            programOptions += ["-c", "\(key)=\(String(identity.stdoutString.dropLast()))"]
          }
        }
      }
      let result = try runner.runData(
        executable: executable,
        invocation: .init(
          arguments: prefix + binding + pathOptions + HostGitConfiguration.arguments
            + programOptions
            + [
              "-c", "gc.auto=0", "-c", "maintenance.auto=false", "-c", "submodule.recurse=false",
              "-c", "notes.rewrite.rebase=false", "-c", "rebase.updateRefs=false",
              "-c", "rebase.autoStash=false", "-c", "rerere.enabled=false",
            ]
            + arguments, standardInput: input),
        workingDirectory: directory, environment: environment,
        timeoutMilliseconds: timeout, maxOutputBytes: 1_048_576)
      guard !result.timedOut, let code = result.exitCode, accepting.contains(code),
        !result.stdoutTruncated
      else {
        throw DeliveryFailure(
          reason: .gitFailed, detail: "Git command failed: \(command).",
          exitCode: result.exitCode, stderr: boundedDeliveryText(result.stderrString))
      }
      return Result(
        stdout: result.stdoutString, exitCode: result.exitCode,
        stderr: boundedDeliveryText(result.stderrString))
    } catch let failure as DeliveryFailure { throw failure } catch {
      throw DeliveryFailure(
        reason: .gitFailed, detail: boundedDeliveryText(error.localizedDescription))
    }
  }

  func programOptions(at directory: URL) throws -> [String] {
    let binding =
      worktree.map { ["--git-dir=\($0.directory.path)", "--work-tree=\($0.root.path)"] } ?? []
    let keys = try runner.runData(
      executable: executable,
      invocation: .init(
        arguments: prefix + binding + HostGitConfiguration.arguments
          + ["config", "--null", "--name-only", "--list", "--no-includes"], standardInput: Data()),
      workingDirectory: directory, environment: environment,
      timeoutMilliseconds: timeout, maxOutputBytes: 1_048_576)
    guard keys.exitCode == 0, !keys.timedOut, !keys.stdoutTruncated else {
      throw DeliveryFailure(
        reason: .gitFailed, detail: "Cannot inspect Git program configuration.")
    }
    return try HostGitConfiguration.overrides(for: keys.stdoutString)
  }

  func revision(_ ref: String, at directory: URL) throws -> String? {
    let result = try run(
      [
        "--no-optional-locks", "rev-parse", "--verify", "--quiet", "--end-of-options",
        "\(ref)^{commit}",
      ], at: directory,
      accepting: [0, 1])
    return result.exitCode == 0
      ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
  }

  func isAncestor(_ commit: String, of ref: String, at directory: URL) throws -> Bool {
    try run(
      ["--no-optional-locks", "merge-base", "--is-ancestor", commit, ref], at: directory,
      accepting: [0, 1]
    ).exitCode
      == 0
  }

  func requireNoFilters(merging revision: String, at directory: URL) throws {
    guard let target = try self.revision(revision, at: directory) else {
      throw DeliveryFailure(
        reason: .gitFailed, detail: "Merge target does not resolve to a commit.")
    }
    var paths = Set<String>()
    for source in ["HEAD", target] {
      let output = try run(["ls-tree", "-rz", "--name-only", source], at: directory).stdout
      paths.formUnion(output.split(separator: "\0").map(String.init))
    }
    let input = Data((paths.sorted().joined(separator: "\0") + "\0").utf8)
    for source in [nil, "HEAD", target] as [String?] {
      let arguments =
        ["check-attr", "-z"] + (source.map { ["--source=\($0)"] } ?? []) + ["--stdin", "filter"]
      let fields = try run(arguments, at: directory, input: input).stdout.split(
        separator: "\0", omittingEmptySubsequences: false)
      for index in stride(from: 2, to: fields.count, by: 3) {
        guard fields[index] == "unspecified" || fields[index] == "unset" else {
          throw DeliveryFailure(
            reason: .gitFailed,
            detail: "Host merge refuses repositories whose attributes assign a filter.")
        }
      }
    }
  }

  func requireRegularOriginalHead(at directory: URL) throws {
    // Merge and rebase follow symbolic ORIG_HEAD updates into the target ref.
    guard
      try run(
        ["--no-optional-locks", "symbolic-ref", "--quiet", "ORIG_HEAD"], at: directory,
        accepting: [0, 1]
      ).exitCode == 1
    else {
      throw DeliveryFailure(
        reason: .origHeadSymbolic,
        detail: "Symbolic ORIG_HEAD retained before merge or rebase: \(directory.path)")
    }
  }

  func blobID(_ content: Data, at directory: URL) throws -> String {
    try run(["--no-optional-locks", "hash-object", "--stdin"], at: directory, input: content)
      .stdout.trimmingCharacters(in: .newlines)
  }

}
