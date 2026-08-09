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
  private var stdoutReader: MCPLineDelimitedOutputReader?
  private var stderrReader: MCPDiscardingOutputReader?
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

    let stdoutReader = MCPLineDelimitedOutputReader(
      handle: stdout.fileHandleForReading,
      continuation: continuation
    )
    let stderrReader = MCPDiscardingOutputReader(handle: stderr.fileHandleForReading)
    self.stdoutReader = stdoutReader
    self.stderrReader = stderrReader
    stdoutReader.start()
    stderrReader.start()
  }

  func disconnect() async {
    guard isConnected else {
      return
    }

    isConnected = false
    stdoutReader?.stop()
    stderrReader?.stop()
    stdoutReader = nil
    stderrReader = nil
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

/// Drains child-process stdout without blocking a Swift cooperative-executor thread.
private final class MCPLineDelimitedOutputReader: @unchecked Sendable {
  private let handle: FileHandle
  private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
  private let lock = NSLock()
  private var buffer = Data()
  private var stopped = false

  init(
    handle: FileHandle,
    continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
  ) {
    self.handle = handle
    self.continuation = continuation
  }

  func start() {
    handle.readabilityHandler = { [weak self] handle in
      self?.consumeAvailableData(from: handle)
    }
  }

  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
    handle.readabilityHandler = nil
  }

  private func consumeAvailableData(from handle: FileHandle) {
    let chunk = handle.availableData
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    guard !chunk.isEmpty else {
      stopped = true
      lock.unlock()
      handle.readabilityHandler = nil
      continuation.finish()
      return
    }

    buffer.append(chunk)
    var messages: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      var line = buffer[..<newline]
      if line.last == 0x0D {
        line = line.dropLast()
      }
      buffer.removeSubrange(...newline)
      if !line.isEmpty {
        messages.append(Data(line))
      }
    }
    lock.unlock()

    for message in messages {
      continuation.yield(message)
    }
  }
}

/// Keeps an untrusted provider's stderr pipe drained without occupying a Swift task thread.
private final class MCPDiscardingOutputReader: @unchecked Sendable {
  private let handle: FileHandle

  init(handle: FileHandle) {
    self.handle = handle
  }

  func start() {
    handle.readabilityHandler = { handle in
      _ = handle.availableData
    }
  }

  func stop() {
    handle.readabilityHandler = nil
  }
}
