import CryptoKit
import Foundation
import MCP

package struct ControlSocketSnapshot: Codable, Equatable, Sendable {
  package let state: AppGatewayServiceState
  package let socketPath: String
  package let processIdentifier: Int32
  package let startedAt: Date?
  package let connectionCount: Int
  package let lastError: String?
}

package struct ControlSocketCallError: Error, LocalizedError, Sendable {
  package let code: String
  package let message: String

  package init(code: String, message: String) {
    self.code = code
    self.message = message
  }

  package var errorDescription: String? { "\(code): \(message)" }
}

package actor ControlSocketService {
  package nonisolated let socketConfiguration: GatewaySocketConfiguration

  private let controlPlane: AppControlPlaneService
  private var server: GatewaySocketServer?
  private var state: AppGatewayServiceState = .stopped
  private var startedAt: Date?
  private var lastError: String?

  package init(
    controlPlane: AppControlPlaneService,
    socketURL: URL
  ) {
    self.controlPlane = controlPlane
    self.socketConfiguration = GatewaySocketConfiguration(
      socketURL: socketURL,
      clientIdentity: .localCLI
    )
  }

  package func start() async throws {
    guard state != .running && state != .starting else { return }
    state = .starting
    lastError = nil
    do {
      let controlPlane = controlPlane
      let server = GatewaySocketServer(
        configuration: socketConfiguration,
        responseObserver: { data, identity in
          try? await controlPlane.correlateMCPResponse(data, identity: identity)
        },
        serverFactory: { identity in
          guard identity.origin == .localCLI else {
            throw GatewaySocketError.authenticationFailed(
              "the control socket accepts only the embedded CLI"
            )
          }
          let registry = ControlToolRegistry(controlPlane: controlPlane, identity: identity)
          return await MCPRuntimeAdapter.makeGatewayServer(
            configuration: GatewayConfiguration(
              server: ServerConfig(name: "computer-mcp-control")
            ),
            registry: registry
          )
        }
      )
      try await server.start()
      self.server = server
      startedAt = Date()
      state = .running
    } catch {
      server = nil
      startedAt = nil
      lastError = String(describing: error)
      state = .failed
      throw error
    }
  }

  package func stop() async {
    guard state != .stopped && state != .stopping else { return }
    state = .stopping
    let activeServer = server
    server = nil
    await activeServer?.stop()
    startedAt = nil
    lastError = nil
    state = .stopped
  }

  package func snapshot() async -> ControlSocketSnapshot {
    ControlSocketSnapshot(
      state: state,
      socketPath: socketConfiguration.socketURL.path,
      processIdentifier: getpid(),
      startedAt: startedAt,
      connectionCount: await server?.connectionCount() ?? 0,
      lastError: lastError
    )
  }
}

package actor AppControlPlaneServiceClient {
  package let socketURL: URL

  package init(socketURL: URL) {
    self.socketURL = socketURL.standardizedFileURL
  }

  package static func live() throws -> AppControlPlaneServiceClient {
    AppControlPlaneServiceClient(
      socketURL: try AppControlPlaneServiceDirectories.standard().controlSocket)
  }

  package func call(
    _ toolName: String,
    arguments: JSONValue = .object([:])
  ) async throws -> JSONValue {
    let session = try await GatewayClientSession.connectSocket(
      configuration: GatewaySocketConfiguration(
        socketURL: socketURL,
        clientIdentity: .localCLI
      )
    )
    do {
      let report = try await session.call(toolName: toolName, arguments: arguments)
      await session.disconnect()
      if report.result.objectValue?["isError"]?.boolValue == true {
        let error = report.result.objectValue?["structuredContent"]?
          .objectValue?["error"]?.objectValue
        throw ControlSocketCallError(
          code: error?["code"]?.stringValue ?? "control.operation_failed",
          message: error?["message"]?.stringValue ?? "The App control operation failed."
        )
      }
      return report.result.objectValue?["structuredContent"] ?? report.result
    } catch {
      await session.disconnect()
      throw error
    }
  }
}

private struct ControlWorkspaceSummary: Encodable {
  let id: String
  let displayName: String
  let rootPath: String
  let bookmarkIsStale: Bool
  let createdAt: Date
  let updatedAt: Date

  init(_ workspace: RegisteredWorkspace) {
    self.id = workspace.id
    self.displayName = workspace.displayName
    self.rootPath = workspace.rootPath
    self.bookmarkIsStale = workspace.bookmarkIsStale
    self.createdAt = workspace.createdAt
    self.updatedAt = workspace.updatedAt
  }
}

private final class ControlToolRegistry: GatewayToolServing, @unchecked Sendable {
  private enum ControlArgumentType {
    case boolean
    case object
    case string

    var schema: JSONValue {
      switch self {
      case .boolean:
        return .object(["type": .string("boolean")])
      case .object:
        return .object(["type": .string("object")])
      case .string:
        return .object(["type": .string("string")])
      }
    }

    func accepts(_ value: JSONValue) -> Bool {
      switch self {
      case .boolean:
        return value.boolValue != nil
      case .object:
        return value.objectValue != nil
      case .string:
        return value.stringValue != nil
      }
    }

    var description: String {
      switch self {
      case .boolean: "a Boolean"
      case .object: "an object"
      case .string: "a string"
      }
    }
  }

  private struct ControlToolContract {
    let name: String
    let arguments: [String: ControlArgumentType]
    let requiredArguments: Set<String>
    let readOnly: Bool

    init(
      _ name: String,
      arguments: [String: ControlArgumentType] = [:],
      required: Set<String> = [],
      readOnly: Bool
    ) {
      self.name = name
      self.arguments = arguments
      self.requiredArguments = required
      self.readOnly = readOnly
    }

    var inputSchema: JSONValue {
      var schema: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object(arguments.mapValues(\.schema)),
        "additionalProperties": .bool(false),
      ]
      if !requiredArguments.isEmpty {
        schema["required"] = .array(requiredArguments.sorted().map(JSONValue.string))
      }
      return .object(schema)
    }

    func validate(_ value: JSONValue?) throws -> [String: JSONValue] {
      let object: [String: JSONValue]
      if let value {
        guard let decoded = value.objectValue else {
          throw GatewayToolError.invalidArguments("Control arguments must be a JSON object.")
        }
        object = decoded
      } else {
        object = [:]
      }

      let unknownArguments = Set(object.keys).subtracting(arguments.keys).sorted()
      guard unknownArguments.isEmpty else {
        throw GatewayToolError.invalidArguments(
          "Unknown control argument\(unknownArguments.count == 1 ? "" : "s"): "
            + unknownArguments.joined(separator: ", ")
        )
      }

      let missingArguments = requiredArguments.subtracting(object.keys).sorted()
      guard missingArguments.isEmpty else {
        throw GatewayToolError.invalidArguments(
          "Missing required control argument\(missingArguments.count == 1 ? "" : "s"): "
            + missingArguments.joined(separator: ", ")
        )
      }

      for (name, value) in object {
        guard let type = arguments[name], type.accepts(value) else {
          throw GatewayToolError.invalidArguments(
            "Control argument '\(name)' must be \(arguments[name]?.description ?? "valid")."
          )
        }
      }
      return object
    }
  }

  private let controlPlane: AppControlPlaneService
  private let identity: GatewaySocketConnectionIdentity

  init(
    controlPlane: AppControlPlaneService,
    identity: GatewaySocketConnectionIdentity
  ) {
    self.controlPlane = controlPlane
    self.identity = identity
  }

  func listTools() throws -> [MCPTool] {
    Self.toolContracts.map { contract in
      MCPTool(
        name: contract.name,
        description: "Owner-only Computer MCP App control operation.",
        inputSchema: contract.inputSchema,
        annotations: .init(
          readOnlyHint: contract.readOnly,
          destructiveHint: !contract.readOnly,
          idempotentHint: true,
          openWorldHint: false
        )
      )
    }
  }

  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    throw GatewayToolError.invalidArguments("Control operations require async dispatch.")
  }

  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    let requestID = UUID().uuidString
    let startedAt = ContinuousClock.now
    let rawArguments = arguments ?? .object([:])
    let inputDigest = try Self.digest(
      .object(["tool": .string(name), "arguments": rawArguments])
    )
    do {
      guard let contract = Self.toolContractsByName[name] else {
        throw GatewayToolError.unknownTool(name)
      }
      let object = try contract.validate(arguments)
      let payload: JSONValue
      switch name {
      case "app.status":
        let snapshot = try await controlPlane.snapshot()
        let activeProfile = try await controlPlane.activeGatewayProfile()
        payload = .object([
          "version": .string(ComputerMCPCLI.version),
          "build": .string(ComputerMCPCLI.build),
          "pid": .number(Double(getpid())),
          "control_socket": .string(controlPlane.directories.controlSocket.path),
          "gateway_socket": .string(controlPlane.directories.gatewaySocket.path),
          "gateway_desired_running": .bool(try await controlPlane.gatewayDesiredRunning()),
          "active_profile": .string(activeProfile.rawValue),
          "workspace_count": .number(Double(try await controlPlane.workspaces().count)),
          "provider_count": .number(Double(try await controlPlane.providerCount())),
          "launch_at_login": .string(snapshot.launchAtLogin.rawValue),
          "openai_tunnel_count": .number(Double(snapshot.openAITunnelConfigurations.count)),
          "cloudflare_tunnel_count": .number(Double(snapshot.cloudflareProfiles.count)),
        ])
      case "config.path":
        payload = .object(["path": .string(controlPlane.directories.manifest.path)])
      case "config.show", "config.export":
        payload = .object([
          "path": .string(controlPlane.directories.manifest.path),
          "schema_version": .number(1),
          "toml": .string(try await controlPlane.activeConfiguration().exportedTOML()),
        ])
      case "config.validate", "config.import":
        payload = try await configurationOperation(name: name, arguments: object)
      case "workspace.list":
        payload = try encodedPayload(
          try await controlPlane.workspaces().map(ControlWorkspaceSummary.init)
        )
      case "workspace.add":
        let path = try requiredString("path", in: object)
        let workspace = try await controlPlane.registerWorkspace(
          at: URL(fileURLWithPath: path).standardizedFileURL,
          displayName: object["display_name"]?.stringValue
        )
        payload = try encodedPayload(ControlWorkspaceSummary(workspace))
      case "workspace.remove":
        let id = try requiredString("id", in: object)
        try await controlPlane.removeWorkspace(id: id)
        payload = .object(["removed": .string(id)])
      case "workspace.enable", "profile.grant":
        let profile = try requiredProfile(in: object)
        let workspaceID = try requiredString("workspace_id", in: object)
        let grant = try await controlPlane.setWorkspaceEnabled(
          object["enabled"]?.boolValue ?? true,
          workspaceID: workspaceID,
          profileID: profile
        )
        payload = try encodedPayload(grant)
      case "profile.list":
        payload = try encodedPayload(try await controlPlane.profileGrants())
      case "profile.show":
        let profile = try requiredProfile(in: object)
        guard let grant = try await controlPlane.profileGrants().first(where: { $0.id == profile })
        else { throw AppControlPlaneServiceError.unknownGatewayProfile(profile.rawValue) }
        payload = try encodedPayload(grant)
      case "tools.list":
        let tools = try await controlPlane.localAdminTools(
          transportTrace: localAdminTransportTrace
        )
        payload = .object(["tools": .array(tools.map(\.json))])
      case "tools.inspect":
        let toolName = try requiredString("name", in: object)
        let tools = try await controlPlane.localAdminTools(
          transportTrace: localAdminTransportTrace
        )
        guard let tool = tools.first(where: { $0.name == toolName }) else {
          throw GatewayToolError.unknownTool(toolName)
        }
        payload = tool.json
      case "tools.call":
        payload = try await controlPlane.callLocalAdminTool(
          name: requiredString("name", in: object),
          arguments: object["arguments"],
          transportTrace: localAdminTransportTrace
        )
      case "tunnel.openai.list":
        let snapshot = try await controlPlane.snapshot()
        payload = .object([
          "profiles": try encodedPayload(snapshot.openAITunnelConfigurations),
          "statuses": try encodedPayload(snapshot.openAITunnelStatuses),
        ])
      case "tunnel.openai.doctor":
        payload = try encodedPayload(
          try await controlPlane.doctorOpenAITunnel(profileID: requiredString("id", in: object))
        )
      case "tunnel.openai.start":
        payload = try encodedPayload(
          try await controlPlane.startOpenAITunnel(profileID: requiredString("id", in: object))
        )
      case "tunnel.openai.stop":
        payload = try encodedPayload(
          try await controlPlane.stopOpenAITunnel(profileID: requiredString("id", in: object))
        )
      case "tunnel.openai.logs":
        payload = try encodedPayload(
          try await controlPlane.openAITunnelLogs(profileID: requiredString("id", in: object))
        )
      case "tunnel.cloudflare.list":
        payload = .object([
          "profiles": try encodedPayload(try await controlPlane.cloudflareTunnelConfigurations()),
          "statuses": try encodedPayload(await controlPlane.cloudflareTunnelStatuses()),
        ])
      case "tunnel.cloudflare.doctor":
        payload = try encodedPayload(
          try await controlPlane.doctorCloudflareTunnel(
            profileID: requiredString("id", in: object)
          )
        )
      case "tunnel.cloudflare.start":
        payload = try encodedPayload(
          try await controlPlane.startCloudflareTunnel(
            profileID: requiredString("id", in: object)
          )
        )
      case "tunnel.cloudflare.stop":
        payload = try encodedPayload(
          try await controlPlane.stopCloudflareTunnel(
            profileID: requiredString("id", in: object)
          )
        )
      case "tunnel.cloudflare.logs":
        payload = try encodedPayload(
          try await controlPlane.cloudflareTunnelLogs(
            profileID: requiredString("id", in: object)
          )
        )
      default:
        throw GatewayToolError.unknownTool(name)
      }
      let result = Self.envelope(
        payload,
        requestID: requestID,
        capabilityID: name,
        identity: identity
      )
      let outputData = try Self.encodedJSON(result)
      try await controlPlane.recordControlAudit(
        AuditEvent(
          requestID: requestID,
          caller: .localCLI,
          transport: "control_socket",
          socketConnectionID: identity.connectionID,
          profileID: .localAdmin,
          capabilityID: name,
          decision: .allowed,
          durationMilliseconds: Self.milliseconds(startedAt.duration(to: .now)),
          inputDigest: inputDigest,
          outputDigest: Self.digest(outputData),
          outputByteCount: outputData.count,
          outputTruncated: false
        )
      )
      return result
    } catch {
      let disposition = Self.auditDisposition(for: error)
      let message = Self.errorMessage(error)
      let result = Self.envelope(
        .object([
          "error": .object([
            "code": .string(disposition.code),
            "message": .string(message),
          ])
        ]),
        requestID: requestID,
        capabilityID: name,
        identity: identity,
        isError: true
      )
      let outputData = try Self.encodedJSON(result)
      try? await controlPlane.recordControlAudit(
        AuditEvent(
          requestID: requestID,
          caller: .localCLI,
          transport: "control_socket",
          socketConnectionID: identity.connectionID,
          profileID: .localAdmin,
          capabilityID: name,
          decision: disposition.decision,
          errorCode: disposition.code,
          durationMilliseconds: Self.milliseconds(startedAt.duration(to: .now)),
          inputDigest: inputDigest,
          outputDigest: Self.digest(outputData),
          outputByteCount: outputData.count,
          outputTruncated: false
        )
      )
      return result
    }
  }

  private func configurationOperation(
    name: String,
    arguments: [String: JSONValue]
  ) async throws -> JSONValue {
    let manifest: String
    if let proposed = arguments["toml"]?.stringValue {
      manifest = proposed
    } else {
      manifest = try await controlPlane.activeConfiguration().exportedTOML()
    }
    let parsed = try GatewayConfiguration.load(
      text: manifest,
      baseURL: controlPlane.directories.configuration
    )
    let canonical = try parsed.exportedTOML()
    let currentData = try Data(contentsOf: controlPlane.directories.manifest)
    guard let currentManifest = String(data: currentData, encoding: .utf8) else {
      throw ConfigurationError.invalid("The active manifest is not valid UTF-8.")
    }
    let currentDigest = Self.digest(currentData)
    let proposedDigest = Self.digest(Data(canonical.utf8))
    var result: [String: JSONValue] = [
      "ok": .bool(true),
      "schema_version": .number(Double(parsed.schemaVersion)),
      "current_digest": .string(currentDigest),
      "proposed_digest": .string(proposedDigest),
      "changed": .bool(currentDigest != proposedDigest),
      "diff": Self.manifestDiff(current: currentManifest, proposed: canonical),
      "toml": .string(canonical),
      "transport_started": .bool(false),
    ]
    if name == "config.import", arguments["apply"]?.boolValue == true {
      guard
        let expected = arguments["expected_current_digest"]?.stringValue,
        !expected.isEmpty
      else {
        throw ConfigurationError.invalid(
          "config.import apply requires expected_current_digest from a prior preview."
        )
      }
      if expected != currentDigest {
        throw ConfigurationError.invalid(
          "The active manifest changed after preview; run config import again."
        )
      }
      let revision = try await controlPlane.activateManifest(canonical)
      result["applied_revision"] = .string(revision.id)
    }
    return .object(result)
  }

  private func requiredProfile(in object: [String: JSONValue]) throws -> GatewayProfileID {
    let rawValue = try requiredString("profile", in: object)
    guard let profile = GatewayProfileID(rawValue: rawValue) else {
      throw GatewayToolError.invalidArguments("Invalid profile ID '\(rawValue)'.")
    }
    return profile
  }

  private var localAdminTransportTrace: GatewayTransportTrace {
    GatewayTransportTrace(
      transport: "control_socket",
      socketConnectionID: identity.connectionID
    )
  }

  private func requiredString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard let value = object[key]?.stringValue, !value.isEmpty else {
      throw GatewayToolError.invalidArguments("Missing non-empty '\(key)'.")
    }
    return value
  }

  private func encodedPayload<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
    return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
  }

  private static func envelope(
    _ payload: JSONValue,
    requestID: String,
    capabilityID: String,
    identity: GatewaySocketConnectionIdentity,
    isError: Bool = false
  ) -> JSONValue {
    let execution = JSONValue.object([
      "request_id": .string(requestID),
      "caller": .string(GatewayCallerKind.localCLI.rawValue),
      "profile_id": .string(GatewayProfileID.localAdmin.rawValue),
      "workspace_id": .null,
      "capability_id": .string(capabilityID),
      "transport": .string("control_socket"),
      "socket_connection_id": .string(identity.connectionID),
    ])
    var structuredContent = payload.objectValue ?? ["result": payload]
    structuredContent["gateway_execution"] = execution
    return .object([
      "content": .array([
        .object(["type": .string("text"), "text": .string(payloadText(payload))])
      ]),
      "structuredContent": .object(structuredContent),
      "isError": .bool(isError),
      "_meta": .object(["computer_mcp": execution]),
    ])
  }

  private static func payloadText(_ payload: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? String(decoding: encoder.encode(payload), as: UTF8.self)) ?? "{}"
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func digest(_ value: JSONValue) throws -> String {
    digest(try encodedJSON(value))
  }

  private static func encodedJSON(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds * 1_000)
      + Int(duration.components.attoseconds / 1_000_000_000_000_000)
  }

  private static func auditDisposition(
    for error: Error
  ) -> (decision: AuditDecision, code: String) {
    if case .localAdminCannotBeSocketProfile = error as? AppControlPlaneServiceError {
      return (.denied, "policy.local_admin_remote")
    }
    if case .invalid(let message) = error as? ConfigurationError,
      message.contains("local-admin")
    {
      return (.denied, "policy.local_admin_remote")
    }
    if let gatewayError = error as? GatewayToolError {
      switch gatewayError {
      case .unknownTool:
        return (.failed, "control.tool_unknown")
      case .invalidArguments:
        return (.failed, "control.invalid_arguments")
      case .disabled:
        return (.denied, "control.operation_disabled")
      case .executionFailed, .unknownCLI, .unknownMCPServer:
        return (.failed, "control.operation_failed")
      }
    }
    if error is ConfigurationError {
      return (.failed, "configuration.invalid")
    }
    return (.failed, "control.operation_failed")
  }

  private static func errorMessage(_ error: Error) -> String {
    String(
      ((error as? any LocalizedError)?.errorDescription ?? String(describing: error))
        .prefix(2_048)
    )
  }

  private static func manifestDiff(current: String, proposed: String) -> JSONValue {
    let currentLines = current.split(separator: "\n", omittingEmptySubsequences: false).map(
      String.init)
    let proposedLines = proposed.split(separator: "\n", omittingEmptySubsequences: false).map(
      String.init)
    let changes = (0..<max(currentLines.count, proposedLines.count)).compactMap {
      index -> JSONValue? in
      let currentLine = currentLines.indices.contains(index) ? currentLines[index] : nil
      let proposedLine = proposedLines.indices.contains(index) ? proposedLines[index] : nil
      guard currentLine != proposedLine else { return nil }
      return .object([
        "line": .number(Double(index + 1)),
        "current": currentLine.map(JSONValue.string) ?? .null,
        "proposed": proposedLine.map(JSONValue.string) ?? .null,
      ])
    }
    return .object([
      "current_line_count": .number(Double(currentLines.count)),
      "proposed_line_count": .number(Double(proposedLines.count)),
      "changes": .array(changes),
    ])
  }

  private static let toolContracts: [ControlToolContract] = [
    ControlToolContract("app.status", readOnly: true),
    ControlToolContract("config.path", readOnly: true),
    ControlToolContract("config.show", readOnly: true),
    ControlToolContract(
      "config.validate",
      arguments: ["toml": .string],
      readOnly: true
    ),
    ControlToolContract("config.export", readOnly: true),
    ControlToolContract(
      "config.import",
      arguments: [
        "toml": .string,
        "apply": .boolean,
        "expected_current_digest": .string,
      ],
      required: ["toml"],
      readOnly: false
    ),
    ControlToolContract("workspace.list", readOnly: true),
    ControlToolContract(
      "workspace.add",
      arguments: ["path": .string, "display_name": .string],
      required: ["path"],
      readOnly: false
    ),
    ControlToolContract(
      "workspace.remove",
      arguments: ["id": .string],
      required: ["id"],
      readOnly: false
    ),
    ControlToolContract(
      "workspace.enable",
      arguments: ["workspace_id": .string, "profile": .string, "enabled": .boolean],
      required: ["workspace_id", "profile"],
      readOnly: false
    ),
    ControlToolContract("profile.list", readOnly: true),
    ControlToolContract(
      "profile.show",
      arguments: ["profile": .string],
      required: ["profile"],
      readOnly: true
    ),
    ControlToolContract(
      "profile.grant",
      arguments: ["profile": .string, "workspace_id": .string, "enabled": .boolean],
      required: ["profile", "workspace_id"],
      readOnly: false
    ),
    ControlToolContract("tools.list", readOnly: true),
    ControlToolContract(
      "tools.inspect",
      arguments: ["name": .string],
      required: ["name"],
      readOnly: true
    ),
    ControlToolContract(
      "tools.call",
      arguments: ["name": .string, "arguments": .object],
      required: ["name"],
      readOnly: false
    ),
    ControlToolContract("tunnel.openai.list", readOnly: true),
    tunnelContract("tunnel.openai.doctor", readOnly: true),
    tunnelContract("tunnel.openai.start", readOnly: false),
    tunnelContract("tunnel.openai.stop", readOnly: false),
    tunnelContract("tunnel.openai.logs", readOnly: true),
    ControlToolContract("tunnel.cloudflare.list", readOnly: true),
    tunnelContract("tunnel.cloudflare.doctor", readOnly: true),
    tunnelContract("tunnel.cloudflare.start", readOnly: false),
    tunnelContract("tunnel.cloudflare.stop", readOnly: false),
    tunnelContract("tunnel.cloudflare.logs", readOnly: true),
  ]

  private static let toolContractsByName = Dictionary(
    uniqueKeysWithValues: toolContracts.map { ($0.name, $0) }
  )

  private static func tunnelContract(_ name: String, readOnly: Bool) -> ControlToolContract {
    ControlToolContract(
      name,
      arguments: ["id": .string],
      required: ["id"],
      readOnly: readOnly
    )
  }
}
