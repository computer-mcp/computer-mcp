import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import Foundation
import Logging
import MCP

/// The SDK installs its pending waiter before entering transport.send.
package actor ManagedMCPRequest {
  @TaskLocal package static var current: ManagedMCPRequest?

  private var sending = false
  private var cancelled = false

  package init() {}

  func beginSend() throws {
    try checkCancellation()
    sending = true
  }

  func checkCancellation() throws {
    if cancelled { throw CancellationError() }
  }

  /// Before send, a refusal at the transport completes the SDK waiter itself.
  package func cancel() -> Bool {
    guard !cancelled else { return false }
    cancelled = true
    return sending
  }
}

/// MCP framing over the same owned-process primitive used by other stdio adapters.
package actor MCPChildProcessTransport: MCP.Transport {
  @TaskLocal package static var onCancellationWriteAuthorized: (@Sendable () -> Void)?

  package nonisolated let logger: Logger
  /// Finishes after process and host-service cleanup, including failed startup.
  package nonisolated let termination: AsyncStream<Void>
  private let terminated: AsyncStream<Void>.Continuation

  private let launcher: ExecutionLauncher
  private let server: MCPServerConfig
  private let command: String
  private let workingDirectory: URL
  /// The base of an unprepared launch's relative command and of the ownership scope,
  /// even when a prepared provider launches in its private scratch.
  private let registrationDirectory: URL
  private let environment: [String: String]
  private let hostProtocolMetadata: [String: String]
  private let hostContext: (any MCPHostEnvironment)?
  private let preparedExecution: PreparedExecutionContext?
  private let vendorSession: (any MCPHostSessionHandle)?
  private var hostSession: (any MCPHostSessionHandle)?
  private var process: ManagedLineProcess?
  private var ownership: MCPProcessOwnership?
  private var ownershipError = false
  private var reader: Task<Void, Never>?
  private var closeTask: Task<Void, Never>?
  private var closed = false
  private var initializationObserved = false
  private var observedHostServiceContract: String?
  private var vendorInitializeID: JSONValue?
  private var observedVendorExecution = false
  private let stream: AsyncThrowingStream<Data, Swift.Error>
  private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

  package init(
    launcher: ExecutionLauncher, server: MCPServerConfig, workingDirectory: URL,
    environment: [String: String],
    hostContext: (any MCPHostEnvironment)? = nil, logger: Logger? = nil,
    preparedExecution: PreparedExecutionContext? = nil,
    vendorSession: (any MCPHostSessionHandle)? = nil
  ) throws {
    guard let command = server.command, !command.isEmpty else {
      throw GatewayToolError.executionFailed("MCP server '\(server.id)' has no command.")
    }
    guard !server.hostServices || hostContext?.providesHostServices == true else {
      throw GatewayToolError.executionFailed(
        "The stdio registration requires scoped host services.")
    }
    // Host services bind to the provider's verified channel, never an inherited descriptor.
    guard !server.hostServices || preparedExecution != nil else {
      throw GatewayToolError.executionFailed(
        "Host services require a prepared provider execution.")
    }
    self.launcher = launcher
    self.server = server
    self.hostContext = hostContext
    self.preparedExecution = preparedExecution
    self.vendorSession = vendorSession
    guard vendorSession == nil || (preparedExecution != nil && !server.hostServices) else {
      throw GatewayToolError.executionFailed(
        "Private vendor execution requires its own provider channel.")
    }
    if let preparedExecution {
      guard preparedExecution.provider?.registrationID == server.id else {
        throw GatewayToolError.executionFailed(
          "Provider authority does not match the registration.")
      }
      if let project = preparedExecution.provider?.delegatingAuthorization?.invocation.projectID {
        guard hostContext?.launchMetadata.project.id == project else {
          throw GatewayToolError.executionFailed("Provider project does not match its host scope.")
        }
      }
      try preparedExecution.validateProviderLaunch()
    }
    self.command = command
    registrationDirectory =
      server.resolvedWorkingDirectory(base: workingDirectory)
      .standardizedFileURL
    self.workingDirectory =
      preparedExecution?.providerWorkingDirectory.map {
        URL(fileURLWithPath: $0.value).standardizedFileURL
      } ?? registrationDirectory
    self.environment = try MCPHostLaunchMetadata.launchEnvironment(
      inherited: environment, overrides: server.env, context: hostContext?.launchMetadata)
    hostProtocolMetadata = try MCPHostLaunchMetadata.launchEnvironment(
      inherited: [:], overrides: [:], context: hostContext?.launchMetadata)
    self.logger =
      logger
      ?? Logger(
        label: "computer-mcp.mcp-child-process", factory: { _ in SwiftLogNoOpLogHandler() })
    (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(16))
    (termination, terminated) = AsyncStream.makeStream()
  }

  package func connect() async throws {
    guard !closed else { throw MCPError.connectionClosed }
    try Task.checkCancellation()
    guard process == nil else { return }
    try preparedExecution?.validateProviderLaunch()
    let executable: String
    if let verified = preparedExecution?.providerExecutable {
      executable = verified.value
    } else {
      let inspection = ExecutableInspection.inspect(
        command, workingDirectory: registrationDirectory, environment: environment)
      guard !inspection.hasKnownFailure, let path = inspection.path else {
        throw GatewayToolError.executionFailed(
          "Could not start MCP server '\(server.id)': \(inspection.message)")
      }
      executable = path
    }
    let ownership = try MCPProcessOwnership.acquire(
      root: hostContext?.processOwnershipRoot ?? MCPProcessOwnership.defaultRoot,
      project: hostContext?.projectRoot
        ?? registrationDirectory,
      registration: server.id, artifact: hostContext?.pluginArtifacts[server.id],
      provider: preparedExecution?.provider)
    self.ownership = ownership
    let session: (any MCPHostSessionHandle)?
    do {
      if let vendorSession {
        session = vendorSession
      } else if server.hostServices, let hostContext, let preparedExecution {
        session = try hostContext.makeHostSession(server: server, execution: preparedExecution)
      } else {
        session = nil
      }
    } catch {
      try? ownership.finish(confirmed: true)
      throw error
    }
    let process: ManagedLineProcess
    do {
      let execution: PreparedExecutionContext?
      if let preparedExecution, let session {
        execution = try preparedExecution.withHostServiceChannel(session.providerChannel)
      } else {
        execution = preparedExecution
      }
      let configuration = ManagedLineProcess.Configuration(
        executable: executable,
        arguments: server.args + (vendorSession == nil ? [] : ["--host-vendor-execution"]),
        environment: environment,
        hostProtocolMetadata: hostProtocolMetadata,
        workingDirectory: workingDirectory,
        maximumMessageBytes: 16 * 1_024 * 1_024,
        ownershipHandle: try ownership.supervisorHandle())
      if let execution {
        process = try execution.withValue {
          try ManagedLineProcess(launcher: launcher, configuration: configuration)
        }
      } else {
        process = try ManagedLineProcess(launcher: launcher, configuration: configuration)
      }
    } catch {
      await session?.close()
      try? ownership.finish(confirmed: await session?.shutdownConfirmed() ?? true)
      throw error
    }
    self.hostSession = session
    self.process = process
    reader = Task { [continuation] in
      do {
        for try await line in process.inboundLines {
          try Task.checkCancellation()
          if line.isEmpty { continue }
          await self.observeInitialization(line)
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

  package func disconnect() async {
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
    let session = hostSession ?? vendorSession
    let task = Task { [process, session, ownership, terminated] in
      defer { terminated.finish() }
      await session?.close()
      await process?.close()
      let confirmed = await session?.shutdownConfirmed() ?? true
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

  package func shutdownConfirmed() async -> Bool {
    guard !ownershipError else { return false }
    guard await (hostSession ?? vendorSession)?.shutdownConfirmed() ?? true else { return false }
    guard let process else { return closed }
    return await process.snapshot().hasExited
  }

  package func send(_ data: Data) async throws {
    guard !closed, let process else { throw MCPError.connectionClosed }
    guard let line = String(data: data, encoding: .utf8) else {
      throw MCPError.invalidRequest("MCP stdio requires UTF-8 JSON.")
    }
    if vendorSession != nil, !observedVendorExecution, vendorInitializeID == nil,
      let request = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue,
      request["method"]?.stringValue == "initialize"
    {
      vendorInitializeID = request["id"]
    }
    if let request = ManagedMCPRequest.current {
      try await request.beginSend()
      try await process.sendLine(line) { try await request.checkCancellation() }
    } else {
      try await process.sendLine(line, onInputAuthorized: Self.onCancellationWriteAuthorized)
    }
  }

  package func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }

  /// The provider's advertised project service contract, from its initialization result.
  /// Nil before initialization or when the provider omits the marker.
  package var hostServiceContract: String? { observedHostServiceContract }

  package var vendorExecutionNegotiated: Bool { observedVendorExecution }
  package static let vendorExecutionCapability = "io.github.computer-mcp/vendor-execution-v1"

  private func observeInitialization(_ line: String) {
    guard !initializationObserved || vendorInitializeID != nil,
      let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue,
      let result = message["result"]?.objectValue, result["protocolVersion"] != nil,
      let capabilities = result["capabilities"]?.objectValue
    else { return }
    let experimental = capabilities["experimental"]?.objectValue
    if let vendorInitializeID, message["id"] == vendorInitializeID {
      observedVendorExecution = experimental?[Self.vendorExecutionCapability]?.boolValue == true
      self.vendorInitializeID = nil
    }
    if !initializationObserved {
      initializationObserved = true
      observedHostServiceContract = experimental?[MCPHostServiceContract.capabilityKey]?.stringValue
    }
  }
}
