import Foundation
import MCP

internal struct GatewayCallReport: Codable, Equatable, Sendable {
  internal let schemaVersion: Int
  internal let generatedAt: String
  internal let transport: String
  internal let endpoint: String
  internal let protocolVersion: String
  internal let serverName: String
  internal let serverVersion: String
  internal let requestID: String
  internal let toolName: String
  internal let result: JSONValue

  internal init(
    schemaVersion: Int = 1,
    generatedAt: String,
    transport: String,
    endpoint: String,
    protocolVersion: String,
    serverName: String,
    serverVersion: String,
    requestID: String,
    toolName: String,
    result: JSONValue
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.transport = transport
    self.endpoint = endpoint
    self.protocolVersion = protocolVersion
    self.serverName = serverName
    self.serverVersion = serverVersion
    self.requestID = requestID
    self.toolName = toolName
    self.result = result
  }

  internal func encodedJSON(prettyPrinted: Bool = true) throws -> Data {
    let encoder = CanonicalJSONCoding.encoder(
      outputFormatting:
        prettyPrinted
        ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        : [.sortedKeys, .withoutEscapingSlashes]
    )
    return try encoder.encode(self)
  }

  internal var gatewayRequestID: String? {
    result.objectValue?["structuredContent"]?.objectValue?["gateway_execution"]?
      .objectValue?["request_id"]?.stringValue
  }
}

internal struct GatewayCallInspector: Sendable {
  internal func callSocket(
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

  internal func callSocket(
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

  internal func callHTTP(
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

internal actor GatewayClientSession {
  private struct HTTPDisconnectContext: Sendable {
    let endpoint: URL
    let accessToken: String?
    let transport: HTTPClientTransport
  }

  private let client: Client
  private let transportName: String
  private let endpoint: String
  private var initialization: Initialize.Result?
  private var httpDisconnectContext: HTTPDisconnectContext?

  private init(transportName: String, endpoint: String) {
    self.client = Client(name: "computer-mcp-client", version: "1")
    self.transportName = transportName
    self.endpoint = endpoint
  }

  internal static func connectSocket(socketURL: URL) async throws -> GatewayClientSession {
    try await connectSocket(
      configuration: GatewaySocketConfiguration(socketURL: socketURL)
    )
  }

  internal static func connectSocket(
    configuration: GatewaySocketConfiguration
  ) async throws -> GatewayClientSession {
    let session = GatewayClientSession(
      transportName: "gateway_socket",
      endpoint: configuration.socketURL.standardizedFileURL.path
    )
    let transport = GatewaySocketTransport(
      configuration: configuration
    )
    try await session.connect(transport: transport)
    return session
  }

  internal static func connectHTTP(
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
        guard let accessToken, !accessToken.isEmpty else {
          return request
        }
        var authenticated = request
        authenticated.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return authenticated
      }
    )
    try await session.connect(transport: transport)
    await session.setHTTPDisconnectContext(
      endpoint: endpoint,
      accessToken: accessToken,
      transport: transport
    )
    return session
  }

  internal func call(
    toolName: String,
    arguments: JSONValue = .object([:]),
    generatedAt: Date = Date()
  ) async throws -> GatewayCallReport {
    guard let initialization else {
      throw ConfigurationError.invalid("MCP client session is not connected.")
    }
    guard let argumentObject = arguments.objectValue else {
      throw ConfigurationError.invalid(
        "MCP tool arguments must be a JSON object."
      )
    }

    let context: RequestContext<CallTool.Result> = try await client.callTool(
      name: toolName,
      arguments: argumentObject.mapValues(\.sdkValue)
    )
    let callResult = try await context.value
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
        content: callResult.content,
        structuredContent: callResult.structuredContent,
        isError: callResult.isError,
        meta: callResult._meta
      )
    )
  }

  internal func listToolNames() async throws -> [String] {
    try await listTools().map(\.name)
  }

  internal func listTools() async throws -> [GatewaySocketCatalogTool] {
    guard initialization != nil else {
      throw ConfigurationError.invalid("MCP client session is not connected.")
    }
    var cursor: String?
    var tools: [GatewaySocketCatalogTool] = []
    repeat {
      let page = try await client.listTools(cursor: cursor)
      tools.append(contentsOf: page.tools.map(GatewaySocketCatalogTool.init(tool:)))
      cursor = page.nextCursor
    } while cursor != nil
    return tools.sorted { $0.name < $1.name }
  }

  internal func disconnect() async {
    await terminateHTTPSession()
    initialization = nil
    await client.disconnect()
  }

  private func setHTTPDisconnectContext(
    endpoint: URL,
    accessToken: String?,
    transport: HTTPClientTransport
  ) {
    httpDisconnectContext = HTTPDisconnectContext(
      endpoint: endpoint,
      accessToken: accessToken,
      transport: transport
    )
  }

  private func terminateHTTPSession() async {
    guard let context = httpDisconnectContext else { return }
    httpDisconnectContext = nil
    guard let sessionID = await context.transport.sessionID else { return }

    var request = URLRequest(url: context.endpoint)
    request.httpMethod = "DELETE"
    request.setValue(sessionID, forHTTPHeaderField: HTTPHeaderName.sessionID)
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let protocolVersion = initialization?.protocolVersion {
      request.setValue(protocolVersion, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
    }
    if let accessToken = context.accessToken, !accessToken.isEmpty {
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: HTTPHeaderName.authorization)
    }
    _ = try? await URLSession.shared.data(for: request)
  }

  private func connect(transport: any Transport) async throws {
    initialization = try await client.connect(transport: transport)
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}
