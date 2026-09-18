import Darwin
import Foundation

public struct CommandResult: Codable, Equatable, Sendable {
  public var executable: String
  public var arguments: [String]
  public var exitCode: Int32?
  public var timedOut: Bool
  public var stdout: String
  public var stderr: String
  public var stdoutTruncated: Bool
  public var stderrTruncated: Bool
  public var cleanupError: String? = nil
}

public protocol CommandRunning: Sendable {
  func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult
}

public enum ValidationProcessError: Error, LocalizedError, Equatable, Sendable {
  case executableUnavailable(String)
  case launchFailed(String)
  case timedOut(String)
  case nonzeroExit(executable: String, code: Int32, stderr: String)
  case cleanupFailed(primary: String?, detail: String)

  public var errorDescription: String? {
    switch self {
    case .executableUnavailable(let name):
      return "Required executable is unavailable: \(name)"
    case .launchFailed(let message):
      return "Could not launch Validation subprocess: \(message)"
    case .timedOut(let executable):
      return "Validation subprocess timed out: \(executable)"
    case .nonzeroExit(let executable, let code, let stderr):
      return "Validation subprocess failed (\(code)): \(executable): \(stderr)"
    case .cleanupFailed(let primary, let detail):
      return (primary.map { "\($0)\n" } ?? "") + "Validation cleanup failed: \(detail)"
    }
  }
}

public struct ProcessCommandRunner: CommandRunning, Sendable {
  public init() {}

  public func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    defer {
      for pipe in [stdoutPipe, stderrPipe] {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
      }
    }
    let stdout = try ValidationPipeCapture(
      handle: stdoutPipe.fileHandleForReading, limit: max(1, maxOutputBytes))
    let stderr = try ValidationPipeCapture(
      handle: stderrPipe.fileHandleForReading, limit: max(1, maxOutputBytes))
    do {
      try process.run()
    } catch {
      try? stdoutPipe.fileHandleForWriting.close()
      try? stderrPipe.fileHandleForWriting.close()
      throw ValidationProcessError.launchFailed(error.localizedDescription)
    }
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForWriting.close()
    let deadline = ContinuousClock.now + .milliseconds(max(1, timeoutMilliseconds))
    var cleanupError: String?
    while process.isRunning && ContinuousClock.now < deadline {
      do {
        try stdout.drain()
        try stderr.drain()
      } catch {
        cleanupError = error.localizedDescription
        break
      }
      usleep(5_000)
    }
    let timedOut = process.isRunning && ContinuousClock.now >= deadline
    do { try ValidationProcessCleanup.stop(process) } catch {
      cleanupError = error.localizedDescription
    }
    let drainDeadline = ContinuousClock.now + .seconds(1)
    do {
      while (!stdout.reachedEOF || !stderr.reachedEOF) && ContinuousClock.now < drainDeadline {
        try stdout.drain()
        try stderr.drain()
        if !stdout.reachedEOF || !stderr.reachedEOF { usleep(5_000) }
      }
      if !stdout.reachedEOF || !stderr.reachedEOF {
        cleanupError = cleanupError ?? "Output pipes did not reach EOF before the drain deadline."
      }
    } catch { cleanupError = error.localizedDescription }
    return CommandResult(
      executable: executable,
      arguments: arguments,
      exitCode: process.isRunning ? nil : process.terminationStatus,
      timedOut: timedOut,
      stdout: String(decoding: stdout.data, as: UTF8.self),
      stderr: String(decoding: stderr.data, as: UTF8.self),
      stdoutTruncated: stdout.truncated,
      stderrTruncated: stderr.truncated,
      cleanupError: cleanupError
    )
  }
}

public enum ValidationProductLocator {
  public static func computerMCPExecutable() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    if let configured = environment["COMPUTER_MCP_EXECUTABLE"], !configured.isEmpty {
      return try requireExecutable(URL(fileURLWithPath: configured))
    }

    let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let sibling = currentExecutable.deletingLastPathComponent().appendingPathComponent(
      "computer-mcp")
    if FileManager.default.isExecutableFile(atPath: sibling.path) {
      return sibling
    }

    var candidate = URL(fileURLWithPath: #filePath).standardizedFileURL
    while candidate.path != "/" {
      let rootProduct = candidate.appendingPathComponent(".build/debug/computer-mcp")
      if FileManager.default.isExecutableFile(atPath: rootProduct.path) {
        return rootProduct
      }
      candidate.deleteLastPathComponent()
    }

    let installed = URL(fileURLWithPath: "/Applications/Computer MCP.app")
      .appendingPathComponent("Contents/Resources/computer-mcp")
    if FileManager.default.isExecutableFile(atPath: installed.path) {
      return installed
    }
    throw ValidationProcessError.executableUnavailable("computer-mcp")
  }

  private static func requireExecutable(_ url: URL) throws -> URL {
    let standardized = url.standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: standardized.path) else {
      throw ValidationProcessError.executableUnavailable(standardized.path)
    }
    return standardized
  }
}

public struct ValidationProductCommand: Sendable {
  public var executableURL: URL
  public var runner: any CommandRunning

  public init(
    executableURL: URL? = nil,
    runner: any CommandRunning = ProcessCommandRunner()
  ) throws {
    self.executableURL = try executableURL ?? ValidationProductLocator.computerMCPExecutable()
    self.runner = runner
  }

  public func run(
    _ arguments: [String],
    timeoutMilliseconds: Int = 120_000,
    maxOutputBytes: Int = 32 * 1_024 * 1_024
  ) throws -> Data {
    let result = try runner.run(
      executable: executableURL.path,
      arguments: arguments,
      workingDirectory: nil,
      environment: [:],
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes
    )
    if let cleanupError = result.cleanupError {
      let primary =
        result.timedOut
        ? ValidationProcessError.timedOut(executableURL.path).localizedDescription
        : result.exitCode == 0
          ? nil
          : "Validation subprocess exited with code \(result.exitCode.map(String.init) ?? "unknown")."
      throw ValidationProcessError.cleanupFailed(primary: primary, detail: cleanupError)
    }
    if result.timedOut {
      throw ValidationProcessError.timedOut(executableURL.path)
    }
    guard result.exitCode == 0 else {
      throw ValidationProcessError.nonzeroExit(
        executable: executableURL.path,
        code: result.exitCode ?? -1,
        stderr: String(result.stderr.prefix(4_096))
      )
    }
    guard !result.stdoutTruncated else {
      throw ValidationProcessError.nonzeroExit(
        executable: executableURL.path,
        code: 0,
        stderr: "bounded stdout exceeded \(maxOutputBytes) bytes"
      )
    }
    return Data(result.stdout.utf8)
  }
}
