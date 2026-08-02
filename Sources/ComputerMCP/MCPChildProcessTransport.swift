import Darwin
import Foundation
import Logging
import MCP

actor MCPChildProcessTransport: MCP.Transport {
  nonisolated let logger: Logger

  private let server: MCPServerConfig
  private let command: String
  private var isConnected = false
  private var process: Process?
  private var stdin: Pipe?
  private var stdoutTask: Task<Void, Never>?
  private var stderrTask: Task<Void, Never>?
  private let stream: AsyncThrowingStream<Data, Swift.Error>
  private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

  init(server: MCPServerConfig, logger: Logger? = nil) throws {
    guard let command = server.command, !command.isEmpty else {
      throw GatewayToolError.executionFailed("MCP server '\(server.id)' has no command.")
    }
    self.server = server
    self.command = command
    self.logger =
      logger
      ?? Logger(
        label: "computer-mcp.mcp-child-process",
        factory: {
          _ in SwiftLogNoOpLogHandler()
        })

    var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
    self.stream = AsyncThrowingStream { continuation = $0 }
    self.continuation = continuation
  }

  func connect() async throws {
    guard !isConnected else {
      return
    }

    let process = Process()
    configure(process: process, executable: command, arguments: server.args)
    if let cwd = server.cwd {
      process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    }
    process.environment = ProcessInfo.processInfo.environment.merging(server.env) { _, new in new }

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      throw GatewayToolError.executionFailed(
        "Could not configure MCP server '\(server.id)' stdin for safe provider exit."
      )
    }
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()
    } catch {
      throw GatewayToolError.executionFailed(
        "Could not start MCP server '\(server.id)': \(error.localizedDescription)")
    }

    self.process = process
    self.stdin = stdin
    isConnected = true

    stdoutTask = Task { [handle = stdout.fileHandleForReading, continuation] in
      var buffer = Data()
      while !Task.isCancelled {
        let chunk = handle.availableData
        if chunk.isEmpty {
          continuation.finish()
          return
        }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
          var line = buffer[..<newline]
          if line.last == 0x0D {
            line = line.dropLast()
          }
          buffer.removeSubrange(...newline)
          if !line.isEmpty {
            continuation.yield(Data(line))
          }
        }
      }
      continuation.finish()
    }

    stderrTask = Task { [handle = stderr.fileHandleForReading] in
      while !Task.isCancelled {
        if handle.availableData.isEmpty {
          return
        }
      }
    }
  }

  func disconnect() async {
    guard isConnected else {
      return
    }

    isConnected = false
    stdoutTask?.cancel()
    stderrTask?.cancel()
    stdoutTask = nil
    stderrTask = nil
    try? stdin?.fileHandleForWriting.close()
    stdin = nil
    if let process, process.isRunning {
      process.terminate()
    }
    process = nil
    continuation.finish()
  }

  func send(_ data: Data) async throws {
    guard isConnected, let stdin else {
      throw GatewayToolError.executionFailed("MCP server '\(server.id)' is not connected.")
    }
    var message = data
    message.append(0x0A)
    try stdin.fileHandleForWriting.write(contentsOf: message)
  }

  func receive() -> AsyncThrowingStream<Data, Swift.Error> {
    stream
  }
}
