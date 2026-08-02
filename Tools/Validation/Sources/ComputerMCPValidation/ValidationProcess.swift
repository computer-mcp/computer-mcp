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
    }
  }
}

private final class ValidationDataBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Data()

  func replace(with data: Data) {
    lock.lock()
    value = data
    lock.unlock()
  }

  func snapshot() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return value
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
    let stdout = ValidationDataBox()
    let stderr = ValidationDataBox()
    let outputDone = DispatchGroup()
    outputDone.enter()
    Thread.detachNewThread {
      stdout.replace(with: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
      outputDone.leave()
    }
    outputDone.enter()
    Thread.detachNewThread {
      stderr.replace(with: stderrPipe.fileHandleForReading.readDataToEndOfFile())
      outputDone.leave()
    }

    let terminated = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in terminated.signal() }
    do {
      try process.run()
    } catch {
      try? stdoutPipe.fileHandleForWriting.close()
      try? stderrPipe.fileHandleForWriting.close()
      throw ValidationProcessError.launchFailed(error.localizedDescription)
    }
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForWriting.close()
    let wait = terminated.wait(timeout: .now() + .milliseconds(max(1, timeoutMilliseconds)))
    let timedOut = wait == .timedOut
    if timedOut {
      process.terminate()
      _ = terminated.wait(timeout: .now() + .seconds(5))
    }
    outputDone.wait()

    let outputLimit = max(1, maxOutputBytes)
    let stdoutData = stdout.snapshot()
    let stderrData = stderr.snapshot()
    return CommandResult(
      executable: executable,
      arguments: arguments,
      exitCode: process.isRunning ? nil : process.terminationStatus,
      timedOut: timedOut,
      stdout: String(decoding: stdoutData.prefix(outputLimit), as: UTF8.self),
      stderr: String(decoding: stderrData.prefix(outputLimit), as: UTF8.self),
      stdoutTruncated: stdoutData.count > outputLimit,
      stderrTruncated: stderrData.count > outputLimit
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
