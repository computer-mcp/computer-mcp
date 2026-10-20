import ComputerMCPConfiguration
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTunnels
import Foundation

package struct FixedOpenAITunnelClientResolver: OpenAITunnelClientResolving {
  package init() {}

  package func resolve(
    requestedPath: String?,
    configuration: GatewayConfiguration
  ) throws -> String {
    "/fake/tunnel-client"
  }
}

package struct ExecutableOpenAITunnelClientResolver: OpenAITunnelClientResolving {
  package init() {}

  package func resolve(
    requestedPath: String?,
    configuration: GatewayConfiguration
  ) throws -> String {
    "/bin/echo"
  }
}

package struct FixedOpenAITunnelHTTPProxyResolver: OpenAITunnelHTTPProxyResolving {
  package var value: String?

  package init(value: String? = nil) {
    self.value = value
  }

  package func systemHTTPProxy() -> String? {
    value
  }
}

package struct FixedOpenAITunnelPlanBuilder: OpenAITunnelPlanBuilding {
  package init() {}

  package func plan(
    profile: OpenAITunnelConfiguration,
    tunnelClientPath: String,
    force: Bool
  ) throws -> OpenAITunnelPlan {
    let command = "computer-mcp serve stdio"
    return OpenAITunnelPlan(
      initInvocation: OpenAITunnelInvocation(
        tunnelClient: tunnelClientPath,
        arguments: ["init", "--tunnel-id", profile.tunnelID] + (force ? ["--force"] : []),
        mcpCommand: command
      ),
      doctorInvocation: OpenAITunnelInvocation(
        tunnelClient: tunnelClientPath,
        arguments: ["doctor", "--profile", profile.tunnelClientProfile],
        mcpCommand: command
      ),
      runInvocation: OpenAITunnelInvocation(
        tunnelClient: tunnelClientPath,
        arguments: ["run", "--profile", profile.tunnelClientProfile],
        mcpCommand: command
      )
    )
  }
}

package final class OpenAITunnelCommandRunner: CommandRunning, @unchecked Sendable {
  private let output: String
  private let exitCode: Int32
  private let exitCodesByCommand: [String: Int32]
  private let lock = NSLock()
  private var environment: [String: String] = [:]
  private var arguments: [String] = []
  private var argumentsHistory: [[String]] = []

  package init(
    output: String = "ok",
    exitCode: Int32 = 0,
    exitCodesByCommand: [String: Int32] = [:]
  ) {
    self.output = output
    self.exitCode = exitCode
    self.exitCodesByCommand = exitCodesByCommand
  }

  package var lastEnvironment: [String: String] {
    lock.lock()
    defer { lock.unlock() }
    return environment
  }

  package var lastArguments: [String] {
    lock.lock()
    defer { lock.unlock() }
    return arguments
  }

  package var allArguments: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return argumentsHistory
  }

  package func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult {
    lock.lock()
    self.environment = environment
    self.arguments = arguments
    argumentsHistory.append(arguments)
    lock.unlock()
    let effectiveExitCode = arguments.first.flatMap { exitCodesByCommand[$0] } ?? exitCode
    return CommandResult(
      executable: executable,
      arguments: arguments,
      exitCode: effectiveExitCode,
      timedOut: false,
      stdout: output,
      stderr: "",
      stdoutTruncated: false,
      stderrTruncated: false
    )
  }

  package func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult {
    fatalError("Unused by tunnel supervisor tests.")
  }
}

package final class TestOpenAITunnelProcessManager: OpenAITunnelProcessManaging, @unchecked Sendable
{
  private let output: String
  private let lock = NSLock()
  private var sessions = 0
  private var environment: [String: String] = [:]
  private var arguments: [String] = []
  private var cancelled: [String] = []
  private var running = true
  private var exitCode: Int32?
  private var readCount = 0
  private let exitAfterReadCount: Int?

  package init(output: String = "", exitAfterReadCount: Int? = nil) {
    self.output = output
    self.exitAfterReadCount = exitAfterReadCount
  }

  package var spawnCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return sessions
  }

  package var lastEnvironment: [String: String] {
    lock.lock()
    defer { lock.unlock() }
    return environment
  }

  package var lastArguments: [String] {
    lock.lock()
    defer { lock.unlock() }
    return arguments
  }

  package var cancelledSessionIDs: [String] {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  package func finish(exitCode: Int32) {
    lock.lock()
    running = false
    self.exitCode = exitCode
    lock.unlock()
  }

  package func spawn(
    executable: String,
    arguments: [String],
    environment: [String: String],
    maxOutputBytes: Int
  ) throws -> String {
    lock.lock()
    sessions += 1
    self.environment = environment
    self.arguments = arguments
    running = true
    exitCode = nil
    readCount = 0
    let id = "session-\(sessions)"
    lock.unlock()
    return id
  }

  package func read(
    sessionID: String,
    stdoutCursor: Int64,
    stderrCursor: Int64,
    maxReadBytes: Int
  ) throws -> ShellSessionSnapshot {
    lock.lock()
    readCount += 1
    if let exitAfterReadCount, readCount >= exitAfterReadCount {
      running = false
      exitCode = 7
    }
    let isRunning = running
    let exitCode = exitCode
    lock.unlock()
    let data = Data(output.utf8)
    let pageData = data.dropFirst(min(Int(stdoutCursor), data.count))
      .prefix(maxReadBytes)
    return ShellSessionSnapshot(
      sessionID: sessionID,
      processID: 42,
      isRunning: isRunning,
      exitCode: exitCode,
      signal: nil,
      timedOut: false,
      cancelled: false,
      startedAt: Date(timeIntervalSince1970: 1_000),
      finishedAt: nil,
      launchError: nil,
      streamErrors: [],
      stdout: ShellStreamRead(
        requestedCursor: stdoutCursor,
        startCursor: stdoutCursor,
        nextCursor: stdoutCursor + Int64(pageData.count),
        endCursor: Int64(data.count),
        missedBytes: false,
        truncated: false,
        encoding: .utf8,
        text: String(decoding: pageData, as: UTF8.self),
        base64: nil
      ),
      stderr: ShellStreamRead(
        requestedCursor: stderrCursor,
        startCursor: stderrCursor,
        nextCursor: stderrCursor,
        endCursor: stderrCursor,
        missedBytes: false,
        truncated: false,
        encoding: .utf8,
        text: "",
        base64: nil
      )
    )
  }

  package func cancel(sessionID: String) throws {
    lock.lock()
    cancelled.append(sessionID)
    if running {
      exitCode = 0
    }
    running = false
    lock.unlock()
  }
}
