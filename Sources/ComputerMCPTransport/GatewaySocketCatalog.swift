import ComputerMCPCore
import Foundation
import MCP

package struct GatewaySocketCatalogTool: Codable, Equatable, Sendable {
  package let name: String
  package let title: String?
  package let description: String?
  package let inputSchema: JSONValue
  package let outputSchema: JSONValue?
  package let readOnlyHint: Bool?
  package let destructiveHint: Bool?
  package let idempotentHint: Bool?
  package let openWorldHint: Bool?
  package let meta: JSONValue?

  package init(tool: MCP.Tool) {
    self.name = tool.name
    self.title = tool.title
    self.description = tool.description
    self.inputSchema = Self.jsonValue(tool.inputSchema)
    self.outputSchema = tool.outputSchema.map(Self.jsonValue)
    self.readOnlyHint = tool.annotations.readOnlyHint
    self.destructiveHint = tool.annotations.destructiveHint
    self.idempotentHint = tool.annotations.idempotentHint
    self.openWorldHint = tool.annotations.openWorldHint
    self.meta = tool._meta.map {
      .object($0.fields.mapValues(Self.jsonValue))
    }
  }

  private static func jsonValue(_ value: MCP.Value) -> JSONValue {
    switch value {
    case .null:
      return .null
    case .bool(let value):
      return .bool(value)
    case .int(let value):
      return .integer(Int64(value))
    case .double(let value):
      return .number(value)
    case .string(let value):
      return .string(value)
    case .data:
      return .string(value.description)
    case .array(let value):
      return .array(value.map(jsonValue))
    case .object(let value):
      return .object(value.mapValues(jsonValue))
    }
  }

  package var gatewayToolJSON: JSONValue {
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

package struct GatewaySocketCatalogReport: Codable, Equatable, Sendable {
  package let schemaVersion: Int
  package let generatedAt: String
  package let socketPath: String
  package let protocolVersion: String
  package let serverName: String
  package let serverVersion: String
  package let toolCount: Int
  package let tools: [GatewaySocketCatalogTool]

  package init(
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

  package var toolNames: [String] {
    tools.map(\.name)
  }

  package func encodedJSON(prettyPrinted: Bool = true) throws -> Data {
    let encoder = CanonicalJSONCoding.encoder(
      outputFormatting:
        prettyPrinted
        ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        : [.sortedKeys, .withoutEscapingSlashes]
    )
    return try encoder.encode(self)
  }
}

package struct GatewaySocketCatalogInspector: Sendable {
  package init() {}

  package func inspect(
    socketURL: URL,
    generatedAt: Date = Date()
  ) async throws -> GatewaySocketCatalogReport {
    try await inspect(
      configuration: GatewaySocketConfiguration(socketURL: socketURL),
      generatedAt: generatedAt
    )
  }

  package func inspect(
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
