import ComputerMCPValidation
import Foundation
import MCP

private struct GatewayClientCallTimeoutError: Error, LocalizedError, Sendable {
  let toolName: String
  let seconds: Int

  var errorDescription: String? {
    "Gateway tool '\(toolName)' exceeded the validation deadline of \(seconds) seconds; the session was disconnected."
  }
}

private enum GatewayOperationOutcome<Value: Sendable>: Sendable {
  case result(Result<Value, any Error>)
  case deadline
  case cancelled
}

typealias ValidationLocalApprovalResolver = @Sendable (_ ticketID: String) async throws -> JSONValue

enum ValidationOperationApproval {
  static func resolve(
    _ prepared: JSONValue,
    using resolver: ValidationLocalApprovalResolver?
  ) async throws {
    guard let object = prepared.objectValue,
      let ticketID = object["ticket_id"]?.stringValue, !ticketID.isEmpty,
      let state = object["state"]?.stringValue
    else {
      throw ValidationProcessError.launchFailed("Preparation returned no ticket identity or state.")
    }
    switch state {
    case "prepared", "approved":
      return
    case "pending_approval":
      guard let resolver else {
        throw ValidationProcessError.launchFailed(
          "Operation ticket \(ticketID) requires local approval; its target was not executed.")
      }
      let approval = try await resolver(ticketID)
      guard approval.objectValue?["id"]?.stringValue == ticketID,
        approval.objectValue?["state"]?.stringValue == "approved"
      else {
        throw ValidationProcessError.launchFailed(
          "Local approval did not approve the exact operation ticket \(ticketID); its target was not executed."
        )
      }
    default:
      throw ValidationProcessError.launchFailed(
        "Operation ticket \(ticketID) is \(state), not eligible for execution.")
    }
  }
}

extension JSONValue {
  fileprivate var sdkValue: MCP.Value {
    switch self {
    case .string(let value): return .string(value)
    case .number(let value):
      let rounded = value.rounded()
      if rounded.isFinite, rounded == value,
        rounded >= Double(Int.min), rounded < -Double(Int.min)
      {
        return .int(Int(rounded))
      }
      return .double(value)
    case .bool(let value): return .bool(value)
    case .object(let value): return .object(value.mapValues(\.sdkValue))
    case .array(let value): return .array(value.map(\.sdkValue))
    case .null: return .null
    }
  }

  fileprivate init(sdkValue: MCP.Value) {
    switch sdkValue {
    case .null: self = .null
    case .bool(let value): self = .bool(value)
    case .int(let value): self = .number(Double(value))
    case .double(let value): self = .number(value)
    case .string(let value): self = .string(value)
    case .data: self = .string(sdkValue.description)
    case .array(let value): self = .array(value.map(JSONValue.init(sdkValue:)))
    case .object(let value): self = .object(value.mapValues(JSONValue.init(sdkValue:)))
    }
  }

  fileprivate static func sdkToolResult(
    content: [MCP.Tool.Content],
    structuredContent: MCP.Value?,
    isError: Bool?,
    meta: MCP.Metadata?
  ) throws -> JSONValue {
    var value: [String: JSONValue] = [
      "content": .array(try content.map(JSONValue.encoded)),
      "isError": isError.map(JSONValue.bool) ?? .null,
    ]
    if let structuredContent { value["structuredContent"] = JSONValue(sdkValue: structuredContent) }
    if let meta { value["_meta"] = .object(meta.fields.mapValues(JSONValue.init(sdkValue:))) }
    return .object(value)
  }
}

extension GatewaySocketCatalogTool {
  fileprivate init(sdkTool: MCP.Tool) {
    self.init(
      name: sdkTool.name,
      title: sdkTool.title,
      description: sdkTool.description,
      inputSchema: JSONValue(sdkValue: sdkTool.inputSchema),
      outputSchema: sdkTool.outputSchema.map(JSONValue.init(sdkValue:)),
      readOnlyHint: sdkTool.annotations.readOnlyHint,
      destructiveHint: sdkTool.annotations.destructiveHint,
      idempotentHint: sdkTool.annotations.idempotentHint,
      openWorldHint: sdkTool.annotations.openWorldHint,
      meta: sdkTool._meta.map { .object($0.fields.mapValues(JSONValue.init(sdkValue:))) }
    )
  }

  var validationTool: MCPTool {
    MCPTool(
      name: name,
      title: title,
      description: description ?? "",
      inputSchema: inputSchema,
      outputSchema: outputSchema,
      annotations: MCPToolAnnotations(
        readOnlyHint: readOnlyHint,
        destructiveHint: destructiveHint,
        idempotentHint: idempotentHint,
        openWorldHint: openWorldHint
      ),
      meta: meta
    )
  }
}

actor GatewayClientSession {
  private let client = Client(name: "computer-mcp-validation", version: "1.0.0")
  private let transportName: String
  private let endpoint: String
  private let bridgeProcess: Process?
  private let bridgePipes: [Pipe]
  private let stderrDrain: Task<Void, Error>?
  private let localApprovalResolver: ValidationLocalApprovalResolver?
  private var cleanupTask: Task<Void, Error>?
  private var initialization: Initialize.Result?

  private init(
    transportName: String,
    endpoint: String,
    bridgeProcess: Process? = nil,
    bridgePipes: [Pipe] = [],
    stderrDrain: Task<Void, Error>? = nil,
    localApprovalResolver: ValidationLocalApprovalResolver? = nil
  ) {
    self.transportName = transportName
    self.endpoint = endpoint
    self.bridgeProcess = bridgeProcess
    self.bridgePipes = bridgePipes
    self.stderrDrain = stderrDrain
    self.localApprovalResolver = localApprovalResolver
  }

  static func connectSocket(socketURL: URL) async throws -> GatewayClientSession {
    try await connectSocket(configuration: GatewaySocketConfiguration(socketURL: socketURL))
  }

  static func connectSocket(
    configuration: GatewaySocketConfiguration,
    timeoutSeconds: Int = 30,
    localApprovalResolver: ValidationLocalApprovalResolver? = nil
  ) async throws -> GatewayClientSession {
    let executable =
      try configuration.bridgeExecutableURL
      ?? ValidationProductLocator.computerMCPExecutable()
    let process = Process()
    process.executableURL = executable
    var arguments = ["bridge", "--socket", configuration.socketURL.path]
    switch configuration.clientIdentity {
    case .localMCP:
      arguments += ["--client-identity", "local-mcp"]
    case .localCLI:
      arguments += ["--client-identity", "local-cli"]
    case .secureTunnel(let credentialFile, _, let tunnelProfileID):
      arguments += [
        "--tunnel-credential-file", credentialFile.path,
        "--tunnel-profile-id", tunnelProfileID,
      ]
    }
    process.arguments = arguments
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    let capture = try ValidationPipeCapture(handle: error.fileHandleForReading, limit: 0)
    do {
      try process.run()
    } catch let launchError {
      for pipe in [input, output, error] {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
      }
      throw ValidationProcessError.launchFailed(launchError.localizedDescription)
    }
    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
    try? error.fileHandleForWriting.close()
    let drain = Task.detached {
      defer { capture.close() }
      while !Task.isCancelled && !capture.reachedEOF {
        try capture.drain()
        do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
      }
    }
    let transport = StdioTransport(
      input: .init(rawValue: output.fileHandleForReading.fileDescriptor),
      output: .init(rawValue: input.fileHandleForWriting.fileDescriptor)
    )
    let session = GatewayClientSession(
      transportName: "bridge_stdio",
      endpoint: configuration.socketURL.path,
      bridgeProcess: process,
      bridgePipes: [input, output, error],
      stderrDrain: drain,
      localApprovalResolver: localApprovalResolver
    )
    do {
      try await session.connect(transport: transport, timeoutSeconds: timeoutSeconds)
      return session
    } catch {
      throw await session.disconnect(after: error)
    }
  }

  static func connectHTTP(
    endpoint: URL,
    accessToken: String? = nil,
    streaming: Bool = true,
    localApprovalResolver: ValidationLocalApprovalResolver? = nil
  ) async throws -> GatewayClientSession {
    let session = GatewayClientSession(
      transportName: streaming ? "streamable_http" : "http",
      endpoint: endpoint.absoluteString,
      localApprovalResolver: localApprovalResolver
    )
    let transport = HTTPClientTransport(
      endpoint: endpoint,
      streaming: streaming,
      requestModifier: { request in
        guard let accessToken, !accessToken.isEmpty else { return request }
        var request = request
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
      }
    )
    do {
      try await session.connect(transport: transport)
      return session
    } catch {
      throw await session.disconnect(after: error)
    }
  }

  func call(
    toolName: String,
    arguments: JSONValue = .object([:]),
    generatedAt: Date = Date(),
    timeoutSeconds: Int = 90
  ) async throws -> GatewayCallReport {
    guard timeoutSeconds > 0 else {
      throw ValidationProcessError.launchFailed("Gateway call timeout must be positive.")
    }
    return try await bounded(label: toolName, timeoutSeconds: timeoutSeconds) {
      try await self.performCall(toolName: toolName, arguments: arguments, generatedAt: generatedAt)
    }
  }

  func resolvePreparedOperation(_ prepared: JSONValue) async throws {
    try await ValidationOperationApproval.resolve(prepared, using: localApprovalResolver)
  }

  private func performCall(
    toolName: String,
    arguments: JSONValue,
    generatedAt: Date
  ) async throws -> GatewayCallReport {
    guard let initialization else {
      throw ValidationProcessError.launchFailed("MCP session is not connected.")
    }
    guard let arguments = arguments.objectValue else {
      throw ValidationProcessError.launchFailed("MCP tool arguments must be an object.")
    }
    let context: RequestContext<CallTool.Result> = try await client.callTool(
      name: toolName,
      arguments: arguments.mapValues(\.sdkValue)
    )
    let result = try await context.value
    return GatewayCallReport(
      generatedAt: Self.timestamp(generatedAt),
      transport: transportName,
      endpoint: endpoint,
      protocolVersion: initialization.protocolVersion,
      serverName: initialization.serverInfo.name,
      serverVersion: initialization.serverInfo.version,
      requestID: context.requestID.description,
      toolName: toolName,
      result: try JSONValue.sdkToolResult(
        content: result.content,
        structuredContent: result.structuredContent,
        isError: result.isError,
        meta: result._meta
      )
    )
  }

  func listToolNames() async throws -> [String] {
    try await listTools().map(\.name)
  }

  func listTools(timeoutSeconds: Int = 90) async throws -> [GatewaySocketCatalogTool] {
    guard timeoutSeconds > 0 else {
      throw ValidationProcessError.launchFailed("Gateway catalog timeout must be positive.")
    }
    return try await bounded(label: "tools/list", timeoutSeconds: timeoutSeconds) {
      try await self.performListTools()
    }
  }

  private func performListTools() async throws -> [GatewaySocketCatalogTool] {
    guard initialization != nil else {
      throw ValidationProcessError.launchFailed("MCP session is not connected.")
    }
    var cursor: String?
    var seenCursors = Set<String>()
    var tools: [GatewaySocketCatalogTool] = []
    repeat {
      let page = try await client.listTools(cursor: cursor)
      tools.append(contentsOf: page.tools.map(GatewaySocketCatalogTool.init(sdkTool:)))
      cursor = page.nextCursor
      if let cursor, !seenCursors.insert(cursor).inserted {
        throw ValidationProcessError.launchFailed("Gateway catalog returned a repeated cursor.")
      }
    } while cursor != nil
    return tools.sorted { $0.name < $1.name }
  }

  func catalogReport(generatedAt: Date = Date()) async throws -> GatewaySocketCatalogReport {
    guard let initialization else {
      throw ValidationProcessError.launchFailed("MCP session is not connected.")
    }
    return GatewaySocketCatalogReport(
      generatedAt: Self.timestamp(generatedAt),
      socketPath: endpoint,
      protocolVersion: initialization.protocolVersion,
      serverName: initialization.serverInfo.name,
      serverVersion: initialization.serverInfo.version,
      tools: try await listTools()
    )
  }

  func disconnect() async throws {
    initialization = nil
    if let cleanupTask { return try await cleanupTask.value }
    let task = Task.detached { [client, bridgeProcess, bridgePipes, stderrDrain] in
      await client.disconnect()
      if let input = bridgePipes.first { try? input.fileHandleForWriting.close() }
      var cleanupError: (any Error)?
      do {
        if let bridgeProcess { try ValidationProcessCleanup.stop(bridgeProcess) }
      } catch { cleanupError = error }
      stderrDrain?.cancel()
      do { try await stderrDrain?.value } catch { cleanupError = cleanupError ?? error }
      for pipe in bridgePipes {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
      }
      if let cleanupError { throw cleanupError }
    }
    cleanupTask = task
    try await task.value
  }

  func disconnect(after primary: any Error) async -> any Error {
    do {
      try await disconnect()
      return primary
    } catch {
      return ValidationProcessError.cleanupFailed(
        primary: primary.localizedDescription, detail: error.localizedDescription)
    }
  }

  private func connect(transport: any Transport, timeoutSeconds: Int = 30) async throws {
    initialization = try await bounded(label: "initialize", timeoutSeconds: timeoutSeconds) {
      [client] in
      try await client.connect(transport: transport)
    }
  }

  private func bounded<Value: Sendable>(
    label: String, timeoutSeconds: Int,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: GatewayOperationOutcome<Value>.self) { group in
      group.addTask {
        do { return .result(.success(try await operation())) } catch {
          return .result(.failure(error))
        }
      }
      group.addTask {
        do {
          try await Task.sleep(for: .seconds(timeoutSeconds))
          return .deadline
        } catch { return .cancelled }
      }
      defer { group.cancelAll() }
      switch try await group.next()! {
      case .result(let result):
        if Task.isCancelled { throw await disconnect(after: CancellationError()) }
        return try result.get()
      case .deadline:
        throw await disconnect(
          after: GatewayClientCallTimeoutError(toolName: label, seconds: timeoutSeconds))
      case .cancelled:
        throw await disconnect(after: CancellationError())
      }
    }
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }
}

struct GatewaySocketCatalogInspector: Sendable {
  func inspect(
    socketURL: URL,
    generatedAt: Date = Date()
  ) async throws -> GatewaySocketCatalogReport {
    try await inspect(
      configuration: GatewaySocketConfiguration(socketURL: socketURL),
      generatedAt: generatedAt
    )
  }

  func inspect(
    configuration: GatewaySocketConfiguration,
    generatedAt: Date = Date()
  ) async throws -> GatewaySocketCatalogReport {
    let session = try await GatewayClientSession.connectSocket(configuration: configuration)
    do {
      let report = try await session.catalogReport(generatedAt: generatedAt)
      try await session.disconnect()
      return report
    } catch {
      throw await session.disconnect(after: error)
    }
  }
}

struct GatewayCallInspector: Sendable {
  func callSocket(
    socketURL: URL,
    toolName: String,
    arguments: JSONValue = .object([:]),
    generatedAt: Date = Date()
  ) async throws -> GatewayCallReport {
    try await callSocket(
      configuration: GatewaySocketConfiguration(socketURL: socketURL),
      toolName: toolName,
      arguments: arguments,
      generatedAt: generatedAt
    )
  }

  func callSocket(
    configuration: GatewaySocketConfiguration,
    toolName: String,
    arguments: JSONValue = .object([:]),
    generatedAt: Date = Date()
  ) async throws -> GatewayCallReport {
    let session = try await GatewayClientSession.connectSocket(configuration: configuration)
    do {
      let report = try await session.call(
        toolName: toolName,
        arguments: arguments,
        generatedAt: generatedAt
      )
      try await session.disconnect()
      return report
    } catch {
      throw await session.disconnect(after: error)
    }
  }

  func callHTTP(
    endpoint: URL,
    toolName: String,
    arguments: JSONValue = .object([:]),
    accessToken: String? = nil,
    streaming: Bool = true,
    generatedAt: Date = Date()
  ) async throws -> GatewayCallReport {
    let session = try await GatewayClientSession.connectHTTP(
      endpoint: endpoint,
      accessToken: accessToken,
      streaming: streaming
    )
    do {
      let report = try await session.call(
        toolName: toolName,
        arguments: arguments,
        generatedAt: generatedAt
      )
      try await session.disconnect()
      return report
    } catch {
      throw await session.disconnect(after: error)
    }
  }
}
