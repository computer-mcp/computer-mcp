import Foundation

/// Validation-owned profile identifier used in release evidence artifacts.
public struct GatewayProfileID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init?(rawValue: String) {
    guard !rawValue.isEmpty, rawValue.utf8.count <= 128,
      rawValue.utf8.allSatisfy({
        ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
          || $0 == 45 || $0 == 95
      })
    else { return nil }
    self.rawValue = rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let decoded = Self(rawValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid Validation profile id."
      )
    }
    self = decoded
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let chatGPTObserve = Self(rawValue: "chatgpt-observe")!
  public static let chatGPTOperate = Self(rawValue: "chatgpt-operate")!
  public static let cloudflareObserve = Self(rawValue: "cloudflare-observe")!
  public static let cloudflareOperate = Self(rawValue: "cloudflare-operate")!
  public static let localAdmin = Self(rawValue: "local-admin")!
  public static let builtIns: [Self] = [
    .chatGPTObserve, .chatGPTOperate, .cloudflareObserve, .cloudflareOperate, .localAdmin,
  ]
}

public enum GatewayCallerKind: String, Codable, Hashable, Sendable {
  case secureTunnel = "secure-tunnel"
  case cloudflareTunnel = "cloudflare-tunnel"
  case localApp = "local-app"
  case localCLI = "local-cli"
  case localMCP = "local-mcp"

  public var isRemote: Bool {
    self == .secureTunnel || self == .cloudflareTunnel
  }
}

public enum GatewaySocketClientIdentity: Equatable, Sendable {
  case localMCP
  case localCLI
  case secureTunnel(
    credentialFile: URL,
    tunnelInstanceID: String,
    tunnelProfileID: String
  )
}

/// Parameters used to launch the shipped `computer-mcp bridge` subprocess.
public struct GatewaySocketConfiguration: Equatable, Sendable {
  public var socketURL: URL
  public var tunnelCredentialFile: URL?
  public var clientIdentity: GatewaySocketClientIdentity
  public var bridgeExecutableURL: URL?

  public init(
    socketURL: URL,
    tunnelCredentialFile: URL? = nil,
    clientIdentity: GatewaySocketClientIdentity = .localMCP,
    bridgeExecutableURL: URL? = nil
  ) {
    self.socketURL = socketURL.standardizedFileURL
    self.tunnelCredentialFile = tunnelCredentialFile
    self.clientIdentity = clientIdentity
    self.bridgeExecutableURL = bridgeExecutableURL
  }
}

public enum AuditDecision: String, Codable, Sendable {
  case allowed
  case denied
  case failed
}

/// Bounded audit DTO decoded from `computer-mcp audit export`.
public struct AuditEvent: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var occurredAt: Date
  public var requestID: String
  public var mcpRequestID: String?
  public var invocationID: String?
  public var parentRequestID: String?
  public var ticketID: String?
  public var caller: GatewayCallerKind
  public var transport: String?
  public var socketConnectionID: String?
  public var tunnelInstanceID: String?
  public var tunnelProfileID: String?
  public var profileID: GatewayProfileID
  public var workspaceID: String?
  public var capabilityID: String
  public var decision: AuditDecision
  public var errorCode: String?
  public var durationMilliseconds: Int?
  public var inputDigest: String?
  public var outputDigest: String?
  public var outputByteCount: Int?
  public var outputTruncated: Bool?

  public init(
    id: String = UUID().uuidString,
    occurredAt: Date = Date(),
    requestID: String,
    mcpRequestID: String? = nil,
    invocationID: String? = nil,
    parentRequestID: String? = nil,
    ticketID: String? = nil,
    caller: GatewayCallerKind,
    transport: String? = nil,
    socketConnectionID: String? = nil,
    tunnelInstanceID: String? = nil,
    tunnelProfileID: String? = nil,
    profileID: GatewayProfileID,
    workspaceID: String? = nil,
    capabilityID: String,
    decision: AuditDecision,
    errorCode: String? = nil,
    durationMilliseconds: Int? = nil,
    inputDigest: String? = nil,
    outputDigest: String? = nil,
    outputByteCount: Int? = nil,
    outputTruncated: Bool? = nil
  ) {
    self.id = id
    self.occurredAt = occurredAt
    self.requestID = requestID
    self.mcpRequestID = mcpRequestID
    self.invocationID = invocationID
    self.parentRequestID = parentRequestID
    self.ticketID = ticketID
    self.caller = caller
    self.transport = transport
    self.socketConnectionID = socketConnectionID
    self.tunnelInstanceID = tunnelInstanceID
    self.tunnelProfileID = tunnelProfileID
    self.profileID = profileID
    self.workspaceID = workspaceID
    self.capabilityID = capabilityID
    self.decision = decision
    self.errorCode = errorCode
    self.durationMilliseconds = durationMilliseconds
    self.inputDigest = inputDigest
    self.outputDigest = outputDigest
    self.outputByteCount = outputByteCount
    self.outputTruncated = outputTruncated
  }
}

public struct RegisteredWorkspace: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var displayName: String
  public var rootPath: String
  public var bookmarkData: Data?
  public var bookmarkIsStale: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: String = UUID().uuidString,
    displayName: String,
    rootPath: String,
    bookmarkData: Data? = nil,
    bookmarkIsStale: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.displayName = displayName
    self.rootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    self.bookmarkData = bookmarkData
    self.bookmarkIsStale = bookmarkIsStale
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct MCPToolAnnotations: Codable, Equatable, Sendable {
  public let readOnlyHint: Bool?
  public let destructiveHint: Bool?
  public let idempotentHint: Bool?
  public let openWorldHint: Bool?

  public init(
    readOnlyHint: Bool? = nil,
    destructiveHint: Bool? = nil,
    idempotentHint: Bool? = nil,
    openWorldHint: Bool? = nil
  ) {
    self.readOnlyHint = readOnlyHint
    self.destructiveHint = destructiveHint
    self.idempotentHint = idempotentHint
    self.openWorldHint = openWorldHint
  }

  public var json: JSONValue {
    var value: [String: JSONValue] = [:]
    if let readOnlyHint { value["readOnlyHint"] = .bool(readOnlyHint) }
    if let destructiveHint { value["destructiveHint"] = .bool(destructiveHint) }
    if let idempotentHint { value["idempotentHint"] = .bool(idempotentHint) }
    if let openWorldHint { value["openWorldHint"] = .bool(openWorldHint) }
    return .object(value)
  }
}

public struct MCPTool: Codable, Equatable, Sendable {
  public let name: String
  public let title: String
  public let description: String
  public let inputSchema: JSONValue
  public let outputSchema: JSONValue?
  public let annotations: MCPToolAnnotations?
  public let meta: JSONValue?

  public init(
    name: String,
    title: String? = nil,
    description: String,
    inputSchema: JSONValue,
    outputSchema: JSONValue? = nil,
    annotations: MCPToolAnnotations? = nil,
    meta: JSONValue? = nil
  ) {
    self.name = name
    self.title = title ?? name
    self.description = description
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
    self.annotations = annotations
    self.meta = meta
  }

  public var json: JSONValue {
    var value: [String: JSONValue] = [
      "name": .string(name),
      "title": .string(title),
      "description": .string(description),
      "inputSchema": inputSchema,
    ]
    if let outputSchema { value["outputSchema"] = outputSchema }
    if let annotations { value["annotations"] = annotations.json }
    if let meta { value["_meta"] = meta }
    return .object(value)
  }
}

public struct GatewaySocketCatalogTool: Codable, Equatable, Sendable {
  public let name: String
  public let title: String?
  public let description: String?
  public let inputSchema: JSONValue
  public let outputSchema: JSONValue?
  public let readOnlyHint: Bool?
  public let destructiveHint: Bool?
  public let idempotentHint: Bool?
  public let openWorldHint: Bool?
  public let meta: JSONValue?

  public init(
    name: String,
    title: String? = nil,
    description: String? = nil,
    inputSchema: JSONValue,
    outputSchema: JSONValue? = nil,
    readOnlyHint: Bool? = nil,
    destructiveHint: Bool? = nil,
    idempotentHint: Bool? = nil,
    openWorldHint: Bool? = nil,
    meta: JSONValue? = nil
  ) {
    self.name = name
    self.title = title
    self.description = description
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
    self.readOnlyHint = readOnlyHint
    self.destructiveHint = destructiveHint
    self.idempotentHint = idempotentHint
    self.openWorldHint = openWorldHint
    self.meta = meta
  }

  public var gatewayToolJSON: JSONValue {
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

public struct GatewaySocketCatalogReport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let generatedAt: String
  public let socketPath: String
  public let protocolVersion: String
  public let serverName: String
  public let serverVersion: String
  public let toolCount: Int
  public let tools: [GatewaySocketCatalogTool]

  public init(
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
    self.tools = tools
    self.toolCount = tools.count
  }

  public var toolNames: [String] { tools.map(\.name) }

  public func encodedJSON(prettyPrinted: Bool = true) throws -> Data {
    try ValidationJSONCoding.encode(self, prettyPrinted: prettyPrinted)
  }
}

public struct GatewayCallReport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let generatedAt: String
  public let transport: String
  public let endpoint: String
  public let protocolVersion: String
  public let serverName: String
  public let serverVersion: String
  public let requestID: String
  public let toolName: String
  public let result: JSONValue

  public init(
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

  public func encodedJSON(prettyPrinted: Bool = true) throws -> Data {
    try ValidationJSONCoding.encode(self, prettyPrinted: prettyPrinted)
  }

  public var gatewayRequestID: String? {
    result.objectValue?["structuredContent"]?.objectValue?["gateway_execution"]?
      .objectValue?["request_id"]?.stringValue
  }
}
