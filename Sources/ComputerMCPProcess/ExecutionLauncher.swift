import ComputerMCPSandbox
import Foundation

/// Constructs the entire child environment before handing an admitted command to an OS backend.
/// Callers supply authorization separately; a mode is a launch instruction, not a permission grant.
package struct ExecutionLauncher: Sendable {
  package var supportsRecovery: Bool { platform.supportsRecovery }
  package var bootSessionID: String? { platform.bootSessionID }
  package var hostSystemReadPaths: [SandboxPath] { platform.hostSystemReadPaths }

  private let platform: any ExecutionPlatform

  package init(platform: any ExecutionPlatform = UnsupportedExecutionPlatform()) {
    self.platform = platform
  }

  package func interrupt(_ members: [ExecutionMember]) async throws {
    try await platform.interrupt(members)
  }

  package func start(
    executable: SandboxPath, arguments: [String], directory: SandboxPath,
    environment: ExecutionEnvironment, mode: ExecutionMode,
    method: ExecutionLaunchMethod = .subprocess,
    input: Int32 = 0, output: Int32 = 1, error: Int32 = 2,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void = { _ in }
  ) async throws -> any ExecutionOwnership {
    try Task.checkCancellation()
    guard arguments.allSatisfy({ !$0.contains("\0") }),
      [input, output, error].allSatisfy({ $0 >= 0 })
    else {
      throw ExecutionEnvironmentError.invalidConfiguration(
        "Invalid arguments or stream descriptors")
    }
    let sandbox: SandboxConfiguration?
    switch mode {
    case .sandbox(let configuration):
      guard directory == configuration.worktree else {
        throw ExecutionEnvironmentError.invalidConfiguration(
          "Sandbox working directory must be its worktree")
      }
      sandbox = configuration
    case .fullAccess:
      sandbox = nil
    }
    let command = try ExecutionCommand(
      executable: executable, arguments: arguments, directory: directory,
      environment: environment.variables(sandbox: sandbox))
    return try await platform.start(
      command, sandbox: sandbox, method: method,
      input: input, output: output, error: error, bindOwnership: bindOwnership)
  }

  package func run(
    executable: SandboxPath, arguments: [String], directory: SandboxPath,
    environment: ExecutionEnvironment, mode: ExecutionMode,
    method: ExecutionLaunchMethod = .subprocess,
    input: Int32 = 0, output: Int32 = 1, error: Int32 = 2,
    deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(120)),
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void = { _ in }
  ) async throws -> ExecutionExit {
    let ownership = try await start(
      executable: executable, arguments: arguments, directory: directory,
      environment: environment, mode: mode, method: method,
      input: input, output: output, error: error, bindOwnership: bindOwnership)
    return try await ownership.wait(until: deadline)
  }

}
