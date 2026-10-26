import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// Checks once at file-access creation that in-project Git administration uses `.git` paths.
enum ProjectGitLayout {
  static func validate(
    project: URL, environment: [String: String],
    invocation configuredInvocation: (executable: String, arguments: [String])? = nil
  ) throws {
    var marker = stat()
    if lstat(project.appendingPathComponent(".git").path, &marker) == 0 {
      if marker.st_mode & S_IFMT == S_IFLNK {
        throw unsupported("The project's .git entry is a symbolic link.")
      }
    } else if errno != ENOENT && errno != ENOTDIR {
      throw invalid()
    }
    let home = try PrivateProcessHome()
    defer { withExtendedLifetime(home) {} }
    var isolated = HostGitConfiguration.environment(environment, home: home.url)
    isolated["LC_ALL"] = "C"
    let invocation: (executable: String, arguments: [String])
    if let configured = configuredInvocation {
      invocation = configured
    } else {
      let git = ExecutableInspection.inspect(
        "git", workingDirectory: project, environment: isolated)
      guard !git.hasKnownFailure, let executable = git.path else { throw invalid() }
      invocation = (executable, [])
    }
    let runner = ProcessCommandRunner(environment: [:])
    func run(
      _ arguments: [String], allowNonRepository: Bool = false, allowMissing: Bool = false
    ) throws -> String? {
      let result = try runner.runIsolated(
        executable: invocation.executable,
        arguments: invocation.arguments + HostGitConfiguration.arguments + arguments,
        workingDirectory: project, environment: isolated, timeoutMilliseconds: 10_000,
        maxOutputBytes: 65_536)
      guard !result.timedOut, !result.stdoutTruncated else { throw invalid() }
      guard result.exitCode == 0 else {
        if allowMissing, result.exitCode == 1 { return nil }
        if allowNonRepository, result.exitCode == 128,
          result.stderr.hasPrefix("fatal: not a git repository (or any")
        {
          return nil
        }
        throw invalid()
      }
      guard result.stdout.last == "\n", !result.stdout.contains("\0") else { throw invalid() }
      return String(result.stdout.dropLast())
    }
    guard
      let paths = try run(
        ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
        allowNonRepository: true)
    else {
      return
    }
    let directories = paths.split(separator: "\n", omittingEmptySubsequences: false)
    guard directories.count == 2 else { throw invalid() }
    let resolved = try directories.map { try resolve(String($0)) }
    for (kind, directory) in zip(["Git directory", "Git common directory"], resolved) {
      guard ProjectPathResolver.contains(directory, in: project) else { continue }
      let parts = directory.pathComponents.dropFirst(project.pathComponents.count)
      if !parts.contains(where: { $0.precomposedStringWithCanonicalMapping.lowercased() == ".git" })
      {
        let relative = parts.isEmpty ? "." : parts.joined(separator: "/")
        throw unsupported(
          "The project's \(kind) is inside the work tree at '\(relative)' without a .git path component."
        )
      }
    }
    if try run(["config", "--no-includes", "--get", "core.worktree"], allowMissing: true) != nil {
      // Let Git apply core.worktree's path semantics, including relative paths and links.
      guard let worktree = try run(["rev-parse", "--path-format=absolute", "--show-toplevel"])
      else {
        throw invalid()
      }
      _ = try resolve(worktree)
    }
  }

  private static func resolve(_ path: String) throws -> URL {
    guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { throw invalid() }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
  }

  private static func invalid() -> GatewayToolError {
    .invalidArguments("Cannot safely resolve the project's Git layout.")
  }

  private static func unsupported(_ layout: String) -> GatewayToolError {
    .invalidArguments(
      "[policy.project_denied] \(layout) The project must use a standard Git layout for in-process write tools."
    )
  }
}
