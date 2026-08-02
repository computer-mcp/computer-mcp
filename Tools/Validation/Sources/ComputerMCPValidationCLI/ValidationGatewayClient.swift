import ComputerMCPValidation
import Foundation
import MCP

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
  private let stderrDrain: Task<Void, Never>?
  private var initialization: Initialize.Result?

  private init(
    transportName: String,
    endpoint: String,
    bridgeProcess: Process? = nil,
    bridgePipes: [Pipe] = [],
    stderrDrain: Task<Void, Never>? = nil
  ) {
    self.transportName = transportName
    self.endpoint = endpoint
    self.bridgeProcess = bridgeProcess
    self.bridgePipes = bridgePipes
    self.stderrDrain = stderrDrain
  }

  static func connectSocket(socketURL: URL) async throws -> GatewayClientSession {
    try await connectSocket(configuration: GatewaySocketConfiguration(socketURL: socketURL))
  }

  static func connectSocket(
    configuration: GatewaySocketConfiguration
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
    do {
      try process.run()
    } catch {
      throw ValidationProcessError.launchFailed(error.localizedDescription)
    }
    let drain = Task.detached {
      _ = error.fileHandleForReading.readDataToEndOfFile()
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
      stderrDrain: drain
    )
    do {
      try await session.connect(transport: transport)
      return session
    } catch {
      await session.disconnect()
      throw error
    }
  }

  static func connectHTTP(
    endpoint: URL,
    accessToken: String? = nil,
    streaming: Bool = true
  ) async throws -> GatewayClientSession {
    let session = GatewayClientSession(
      transportName: streaming ? "streamable_http" : "http",
      endpoint: endpoint.absoluteString
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
    try await session.connect(transport: transport)
    return session
  }

  func call(
    toolName: String,
    arguments: JSONValue = .object([:]),
    generatedAt: Date = Date()
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

  func listTools() async throws -> [GatewaySocketCatalogTool] {
    guard initialization != nil else {
      throw ValidationProcessError.launchFailed("MCP session is not connected.")
    }
    var cursor: String?
    var tools: [GatewaySocketCatalogTool] = []
    repeat {
      let page = try await client.listTools(cursor: cursor)
      tools.append(contentsOf: page.tools.map(GatewaySocketCatalogTool.init(sdkTool:)))
      cursor = page.nextCursor
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

  func disconnect() async {
    initialization = nil
    await client.disconnect()
    if let bridgeProcess, bridgeProcess.isRunning {
      bridgeProcess.terminate()
      bridgeProcess.waitUntilExit()
    }
    stderrDrain?.cancel()
  }

  private func connect(transport: any Transport) async throws {
    initialization = try await client.connect(transport: transport)
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
      await session.disconnect()
      return report
    } catch {
      await session.disconnect()
      throw error
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
      await session.disconnect()
      return report
    } catch {
      await session.disconnect()
      throw error
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
      await session.disconnect()
      return report
    } catch {
      await session.disconnect()
      throw error
    }
  }
}
