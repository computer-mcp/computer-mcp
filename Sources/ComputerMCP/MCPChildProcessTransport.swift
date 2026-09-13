import Foundation
import Logging
import MCP

/// MCP framing over the same owned-process primitive used by other stdio adapters.
actor MCPChildProcessTransport: MCP.Transport {
  nonisolated let logger: Logger
  /// Finishes after process and host-service cleanup, including failed startup.
  nonisolated let termination: AsyncStream<Void>
  private let terminated: AsyncStream<Void>.Continuation

  private let server: MCPServerConfig
  private let command: String
  private let workingDirectory: URL
  private let environment: [String: String]
  private let hostContext: MCPHostContext?
  private var hostSession: MCPHostSession?
  private var process: ManagedLineProcess?
  private var ownership: MCPProcessOwnership?
  private var ownershipError = false
  private var reader: Task<Void, Never>?
  private var closeTask: Task<Void, Never>?
  private var closed = false
  private let stream: AsyncThrowingStream<Data, Swift.Error>
  private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

  init(
    server: MCPServerConfig, workingDirectory: URL, environment: [String: String],
    hostContext: MCPHostContext? = nil, logger: Logger? = nil
  ) throws {
    guard let command = server.command, !command.isEmpty else {
      throw GatewayToolError.executionFailed("MCP server '\(server.id)' has no command.")
    }
    guard !server.hostServices || hostContext?.tools != nil else {
      throw GatewayToolError.executionFailed(
        "The stdio registration requires scoped host services.")
    }
    self.server = server
    self.hostContext = hostContext
    self.command = command
    self.workingDirectory =
      server.resolvedWorkingDirectory(base: workingDirectory)
      .standardizedFileURL
    self.environment = try MCPHostContext.launchEnvironment(
      inherited: environment, overrides: server.env, context: hostContext)
    self.logger =
      logger
      ?? Logger(
        label: "computer-mcp.mcp-child-process", factory: { _ in SwiftLogNoOpLogHandler() })
    (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(16))
    (termination, terminated) = AsyncStream.makeStream()
  }

  func connect() async throws {
    guard !closed else { throw MCPError.connectionClosed }
    try Task.checkCancellation()
    guard process == nil else { return }
    let inspection = ExecutableInspection.inspect(
      command, workingDirectory: workingDirectory, environment: environment)
    guard !inspection.hasKnownFailure, let executable = inspection.path else {
      throw GatewayToolError.executionFailed(
        "Could not start MCP server '\(server.id)': \(inspection.message)")
    }
    let ownership = try MCPProcessOwnership.acquire(
      root: hostContext?.processOwnershipRoot
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(
          "computer-mcp-mcp-processes", isDirectory: true),
      workspace: hostContext.map { URL(fileURLWithPath: $0.workspace.rootPath) }
        ?? workingDirectory,
      registration: server.id)
    self.ownership = ownership
    let session =
      try server.hostServices
      ? hostContext.map { try MCPHostSession(context: $0, server: server) } : nil
    var environment = environment
    if session != nil { environment[MCPHostContext.descriptorEnvironmentKey] = "3" }
    let process: ManagedLineProcess
    do {
      process = try ManagedLineProcess(
        configuration: .init(
          executable: executable, arguments: server.args, environment: environment,
          workingDirectory: workingDirectory,
          maximumMessageBytes: 16 * 1_024 * 1_024,
          inheritedDescriptors: session.map { [3: $0.childHandle] } ?? [:],
          ownershipHandle: try ownership.supervisorHandle()))
    } catch {
      await session?.close()
      try? ownership.finish(confirmed: await session?.shutdownConfirmed() ?? true)
      throw error
    }
    try? session?.childHandle.close()
    self.hostSession = session
    self.process = process
    reader = Task { [continuation] in
      do {
        for try await line in process.inboundLines {
          try Task.checkCancellation()
          if line.isEmpty { continue }
          switch continuation.yield(Data(line.utf8)) {
          case .enqueued: break
          case .dropped: throw ManagedLineProcessError.bufferOverflow
          case .terminated: throw MCPError.connectionClosed
          @unknown default: throw MCPError.connectionClosed
          }
        }
        continuation.finish(throwing: MCPError.connectionClosed)
      } catch {
        continuation.finish(throwing: error)
      }
      await self.closeProcess()
    }
  }

  func disconnect() async {
    await closeProcess()
    await reader?.value
  }

  private func closeProcess() async {
    if let closeTask {
      await closeTask.value
      return
    }
    closed = true
    continuation.finish()
    reader?.cancel()
    let task = Task { [process, hostSession, ownership, terminated] in
      defer { terminated.finish() }
      await hostSession?.close()
      await process?.close()
      let confirmed = await hostSession?.shutdownConfirmed() ?? true
      let exited = await process?.snapshot().hasExited ?? true
      do {
        try ownership?.finish(confirmed: confirmed && exited, hostServicesConfirmed: confirmed)
      } catch {
        self.ownershipError = true
      }
    }
    closeTask = task
    await task.value
  }

  func shutdownConfirmed() async -> Bool {
    guard !ownershipError else { return false }
    guard await hostSession?.shutdownConfirmed() ?? true else { return false }
    guard let process else { return closed }
    return await process.snapshot().hasExited
  }

  func send(_ data: Data) async throws {
    guard !closed, let process else { throw MCPError.connectionClosed }
    guard let line = String(data: data, encoding: .utf8) else {
      throw MCPError.invalidRequest("MCP stdio requires UTF-8 JSON.")
    }
    try await process.sendLine(line)
  }

  func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }
}
