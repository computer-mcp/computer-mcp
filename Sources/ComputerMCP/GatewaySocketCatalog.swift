import Foundation
import MCP

internal struct GatewaySocketCatalogTool: Codable, Equatable, Sendable {
  internal let name: String
  internal let title: String?
  internal let description: String?
  internal let inputSchema: JSONValue
  internal let outputSchema: JSONValue?
  internal let readOnlyHint: Bool?
  internal let destructiveHint: Bool?
  internal let idempotentHint: Bool?
  internal let openWorldHint: Bool?
  internal let meta: JSONValue?

  init(tool: MCP.Tool) {
    self.name = tool.name
    self.title = tool.title
    self.description = tool.description
    self.inputSchema = JSONValue(sdkValue: tool.inputSchema)
    self.outputSchema = tool.outputSchema.map(JSONValue.init(sdkValue:))
    self.readOnlyHint = tool.annotations.readOnlyHint
    self.destructiveHint = tool.annotations.destructiveHint
    self.idempotentHint = tool.annotations.idempotentHint
    self.openWorldHint = tool.annotations.openWorldHint
    self.meta = tool._meta.map {
      .object($0.fields.mapValues(JSONValue.init(sdkValue:)))
    }
  }

  internal var gatewayToolJSON: JSONValue {
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
    ).json
  }
}

internal struct GatewaySocketCatalogReport: Codable, Equatable, Sendable {
  internal let schemaVersion: Int
  internal let generatedAt: String
  internal let socketPath: String
  internal let protocolVersion: String
  internal let serverName: String
  internal let serverVersion: String
  internal let toolCount: Int
  internal let tools: [GatewaySocketCatalogTool]

  internal init(
    schemaVersion: Int = 1,
    generatedAt: String,
    socketPath: String,
    protocolVersion: String,
    serverName: String,
    serverVersion: String,
    tools: [GatewaySocketCatalogTool]
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.socketPath = socketPath
    self.protocolVersion = protocolVersion
    self.serverName = serverName
    self.serverVersion = serverVersion
    self.toolCount = tools.count
    self.tools = tools
  }

  internal var toolNames: [String] {
    tools.map(\.name)
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
}

internal struct GatewaySocketCatalogInspector: Sendable {
  internal func inspect(
    socketURL: URL,
    generatedAt: Date = Date()
  ) async throws -> GatewaySocketCatalogReport {
    try await inspect(
      configuration: GatewaySocketConfiguration(socketURL: socketURL),
      generatedAt: generatedAt
    )
  }

  internal func inspect(
    configuration: GatewaySocketConfiguration,
    generatedAt: Date = Date()
  ) async throws -> GatewaySocketCatalogReport {
    let transport = GatewaySocketTransport(
      configuration: configuration
    )
    let client = Client(name: "computer-mcp-client", version: "1")

    do {
      let initialization = try await client.connect(transport: transport)
      var cursor: String?
      var sdkTools: [MCP.Tool] = []
      repeat {
        let page = try await client.listTools(cursor: cursor)
        sdkTools.append(contentsOf: page.tools)
        cursor = page.nextCursor
      } while cursor != nil
      await client.disconnect()

      let tools =
        sdkTools
        .map(GatewaySocketCatalogTool.init(tool:))
        .sorted { $0.name < $1.name }
      return GatewaySocketCatalogReport(
        generatedAt: Self.timestamp(generatedAt),
        socketPath: configuration.socketURL.standardizedFileURL.path,
        protocolVersion: initialization.protocolVersion,
        serverName: initialization.serverInfo.name,
        serverVersion: initialization.serverInfo.version,
        tools: tools
      )
    } catch {
      await client.disconnect()
      throw error
    }
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}
