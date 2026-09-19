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

private final class ControlSocketCallCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<JSONValue, any Error>?

  init(_ continuation: CheckedContinuation<JSONValue, any Error>) {
    self.continuation = continuation
  }

  func resume(with result: Result<JSONValue, any Error>) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    lock.unlock()
    continuation.resume(with: result)
  }
}

package actor ControlSocketService {
  package nonisolated let socketConfiguration: GatewaySocketConfiguration

  private let controlPlane: AppControlPlaneService
  private let gatewayService: AppGatewayService
  private var server: GatewaySocketServer?
  private var state: AppGatewayServiceState = .stopped
  private var startedAt: Date?
  private var lastError: String?

  package init(
    controlPlane: AppControlPlaneService,
    gatewayService: AppGatewayService,
    socketURL: URL
  ) {
    self.controlPlane = controlPlane
    self.gatewayService = gatewayService
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
      let gatewayService = gatewayService
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
          let registry = ControlToolRegistry(
            controlPlane: controlPlane,
            gatewayService: gatewayService,
            operations: AppControlPlaneOperations(
              controlPlane: controlPlane,
              gatewayService: gatewayService
            ),
            identity: identity
          )
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
    arguments: JSONValue = .object([:]),
    timeout: Duration? = nil
  ) async throws -> JSONValue {
    guard let timeout else {
      return try await performCall(toolName, arguments: arguments)
    }
    return try await withCheckedThrowingContinuation { continuation in
      let completion = ControlSocketCallCompletion(continuation)
      Task {
        do {
          completion.resume(
            with: .success(try await self.performCall(toolName, arguments: arguments))
          )
        } catch {
          completion.resume(with: .failure(error))
        }
      }
      Task {
        try? await Task.sleep(for: timeout)
        completion.resume(
          with: .failure(
            ControlSocketCallError(
              code: "control.timeout",
              message: "The App control operation timed out."
            )
          )
        )
      }
    }
  }

  private func performCall(
    _ toolName: String,
    arguments: JSONValue
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
  let access: JSONValue?

  init(_ workspace: RegisteredWorkspace, access: JSONValue? = nil) {
    self.id = workspace.id
    self.displayName = workspace.displayName
    self.rootPath = workspace.rootPath
    self.bookmarkIsStale = workspace.bookmarkIsStale
    self.createdAt = workspace.createdAt
    self.updatedAt = workspace.updatedAt
    self.access = access
  }
}

private final class ControlToolRegistry: GatewayToolServing, @unchecked Sendable {
  private enum ControlArgumentType {
    case boolean
    case integer
    case object
    case string
    case strings

    var schema: JSONValue {
      switch self {
      case .boolean:
        return .object(["type": .string("boolean")])
      case .integer:
        return .object(["type": .string("integer")])
      case .object:
        return .object(["type": .string("object")])
      case .string:
        return .object(["type": .string("string")])
      case .strings:
        return .object(["type": .string("array"), "items": .object(["type": .string("string")])])
      }
    }

    func accepts(_ value: JSONValue) -> Bool {
      switch self {
      case .boolean:
        return value.boolValue != nil
      case .integer:
        return value.intValue != nil
      case .object:
        return value.objectValue != nil
      case .string:
        return value.stringValue != nil
      case .strings:
        return value.arrayValue?.allSatisfy { $0.stringValue != nil } == true
      }
    }

    var description: String {
      switch self {
      case .boolean: "a Boolean"
      case .integer: "an integer"
      case .object: "an object"
      case .string: "a string"
      case .strings: "an array of strings"
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
  private let gatewayService: AppGatewayService
  private let operations: AppControlPlaneOperations
  private let identity: GatewaySocketConnectionIdentity

  init(
    controlPlane: AppControlPlaneService,
    gatewayService: AppGatewayService,
    operations: AppControlPlaneOperations,
    identity: GatewaySocketConnectionIdentity
  ) {
    self.controlPlane = controlPlane
    self.gatewayService = gatewayService
    self.operations = operations
    self.identity = identity
  }

  func listTools() throws -> [MCPTool] {
    let contractIDs = Set(Self.toolContracts.map(\.name))
    let capabilityIDs = Set(AppControlCapabilityCatalog.all.map(\.id))
    guard contractIDs == capabilityIDs else {
      throw GatewayToolError.executionFailed(
        "The App control capability catalog and control-socket contracts have drifted."
      )
    }
    return try Self.toolContracts.map { contract in
      guard let capability = AppControlCapabilityCatalog.byID[contract.name],
        capability.readOnly == contract.readOnly
      else {
        throw GatewayToolError.executionFailed(
          "The App control capability metadata for '\(contract.name)' is inconsistent."
        )
      }
      return MCPTool(
        name: contract.name,
        description:
          capability.summary
          + " Available only through the current-user owner-only control socket.",
        inputSchema: contract.inputSchema,
        annotations: .init(
          readOnlyHint: contract.readOnly,
          destructiveHint: capability.destructive,
          idempotentHint: capability.idempotent,
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
    var digestArguments = rawArguments
    if name == "mcp.credential.set", var object = rawArguments.objectValue {
      object["token"] = .string("<redacted>")
      digestArguments = .object(object)
    }
    let inputDigest = try Self.digest(
      .object(["tool": .string(name), "arguments": digestArguments])
    )
    do {
      guard let contract = Self.toolContractsByName[name] else {
        throw GatewayToolError.unknownTool(name)
      }
      let object = try contract.validate(arguments)
      let payload: JSONValue
      switch name {
      case "app.capabilities":
        payload = .object([
          "schema_version": .number(1),
          "capabilities": try encodedPayload(AppControlCapabilityCatalog.all),
        ])
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
      case "app.start":
        payload = try encodedPayload(try await operations.startGateway())
      case "app.stop":
        payload = try encodedPayload(try await operations.stopGateway())
      case "app.restart":
        payload = try encodedPayload(try await operations.restartGateway())
      case "app.launch_at_login":
        payload = try encodedPayload(
          try await controlPlane.setLaunchAtLoginEnabled(
            object["enabled"]?.boolValue ?? true
          )
        )
      case "readiness":
        let rawJourney = try requiredString("journey", in: object)
        guard let journey = ProductJourney(rawValue: rawJourney) else {
          throw GatewayToolError.invalidArguments(
            "Invalid journey '\(rawJourney)'; expected local, chatgpt, or cloudflare."
          )
        }
        payload = try encodedPayload(
          try await controlPlane.readinessSnapshot(
            journey: journey,
            gateway: gatewayService.snapshot()
          )
        )
      case "config.path":
        payload = .object(["path": .string(controlPlane.directories.manifest.path)])
      case "config.show":
        payload = .object([
          "path": .string(controlPlane.directories.manifest.path),
          "schema_version": .number(1),
          "toml": .string(try await controlPlane.activeConfiguration().exportedTOML()),
        ])
      case "config.export":
        payload = .object([
          "path": .string(controlPlane.directories.manifest.path),
          "schema_version": .number(1),
          "toml": .string(try await controlPlane.effectiveConfigurationForExport().exportedTOML()),
        ])
      case "config.validate", "config.import":
        payload = try await configurationOperation(name: name, arguments: object)
      case "config.history":
        payload = try encodedPayload(
          try await controlPlane.configurationHistory(
            limit: try boundedLimit(object["limit"], default: 50, maximum: 200)
          )
        )
      case "config.rollback":
        payload = try encodedPayload(
          try await operations.rollbackManifest(
            to: requiredString("revision_id", in: object)
          )
        )
      case "workspace.list":
        payload = try encodedPayload(
          try await controlPlane.workspaceAccessReports().map {
            ControlWorkspaceSummary($0.workspace, access: $0.json)
          }
        )
      case "workspace.add":
        let path = try requiredString("path", in: object)
        let workspace = try await operations.registerWorkspace(
          at: URL(fileURLWithPath: path).standardizedFileURL,
          displayName: object["display_name"]?.stringValue
        )
        payload = try encodedPayload(ControlWorkspaceSummary(workspace))
      case "workspace.deduplicate":
        if object["apply"]?.boolValue == true {
          payload = try encodedPayload(
            try await operations.applyWorkspaceDeduplication(
              expectedPlanDigest: try requiredString("expected_plan_digest", in: object),
              allowMetadataConflicts: object["allow_metadata_conflicts"]?.boolValue ?? false
            )
          )
        } else {
          payload = try encodedPayload(try await controlPlane.workspaceDeduplicationPlan())
        }
      case "workspace.remove":
        let id = try requiredString("id", in: object)
        try await operations.removeWorkspace(id: id)
        payload = .object(["removed": .string(id)])
      case "workspace.enable", "profile.grant":
        let profile = try requiredProfile(in: object)
        let workspaceID = try requiredString("workspace_id", in: object)
        let grant = try await operations.setWorkspaceEnabled(
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
      case "profile.activate":
        payload = try encodedPayload(
          try await operations.activateProfile(requiredProfile(in: object))
        )
      case "profile.shell":
        let profile = try requiredProfile(in: object)
        let grant = try await operations.setFullShellEnabled(
          object["enabled"]?.boolValue ?? true,
          profileID: profile
        )
        payload = try encodedPayload(grant)
      case "profile.permissions":
        guard !Set(object.keys).subtracting(["profile", "expected_revision"]).isEmpty else {
          throw GatewayToolError.invalidArguments("Provide at least one permission setting.")
        }
        let mode: GatewayPermissionMode? = try optionalChoice("mode", in: object)
        let confirmation: GatewayConfirmationPolicy? = try optionalChoice(
          "confirmation_policy", in: object)
        let callerNames = optionalStringSet("allowed_callers", in: object)
        let callers = try callerNames.map { names in
          try Set(
            names.map { name in
              guard let caller = GatewayCallerKind(rawValue: name) else {
                throw GatewayToolError.invalidArguments("Unknown caller '\(name)'.")
              }
              return caller
            })
        }
        payload = try encodedPayload(
          try await operations.updateProfilePermissions(
            profileID: requiredProfile(in: object), mode: mode, confirmationPolicy: confirmation,
            fullShellEnabled: object["full_shell_enabled"]?.boolValue,
            capabilityIDs: optionalStringSet("capabilities", in: object),
            workspaceIDs: optionalStringSet("workspaces", in: object),
            mcpServerIDs: optionalStringSet("mcp_servers", in: object), allowedCallers: callers,
            expectedRevision: object["expected_revision"]?.intValue.map(Int64.init)))
      case "provider.list":
        payload = try encodedPayload(try await controlPlane.providerStates())
      case "provider.doctor":
        payload = try encodedPayload(
          try await operations.refreshProvider(id: object["id"]?.stringValue)
        )
      case "permissions.status":
        payload = try encodedPayload(await controlPlane.computerUsePermissions())
      case "approvals.list":
        payload = try encodedPayload(
          try await controlPlane.operationApprovals(
            limit: boundedLimit(object["limit"], default: 100, maximum: 500)))
      case "approvals.approve", "approvals.deny":
        payload = try encodedPayload(
          try await controlPlane.resolveOperationApproval(
            id: requiredString("id", in: object), approved: name == "approvals.approve",
            resolver: .localCLI))
      case "mcp.credential.status":
        payload = try encodedPayload(
          try await controlPlane.mcpCredentialStatus(id: requiredString("id", in: object)))
      case "mcp.credential.set", "mcp.credential.remove":
        try await controlPlane.changeMCPCredential(
          id: requiredString("id", in: object),
          expectedBindingDigest: requiredString("expected_binding_digest", in: object),
          token: name == "mcp.credential.set" ? requiredString("token", in: object) : nil)
        payload = .object(["updated": .bool(true)])
      case "mcp.doctor":
        payload = try encodedPayload(
          try await controlPlane.doctorMCPRegistration(
            id: requiredString("id", in: object),
            workspaceID: requiredString("workspace_id", in: object)))
      case "mcp.process.recover":
        try await controlPlane.recoverMCPProcessReceipt(
          id: requiredString("id", in: object),
          workspaceID: requiredString("workspace_id", in: object),
          receiptID: requiredString("receipt_id", in: object),
          expectedReceiptDigest: requiredString("expected_receipt_digest", in: object),
          expectedCurrentDigest: requiredString("expected_current_digest", in: object))
        payload = .object(["recovered": .bool(true)])
      case "mcp.list", "mcp.show":
        let snapshot = try await controlPlane.mcpRegistrations()
        if name == "mcp.show" {
          let id = try requiredString("id", in: object)
          guard let entry = snapshot.registrations.first(where: { $0.id == id }) else {
            throw GatewayToolError.unknownMCPServer(id)
          }
          payload = try encodedPayload(
            MCPRegistrationSnapshot(
              currentDigest: snapshot.currentDigest, registrations: [entry]))
        } else {
          payload = try encodedPayload(snapshot)
        }
      case "mcp.add", "mcp.configure", "mcp.enable", "mcp.disable", "mcp.remove":
        let change: MCPRegistrationChange
        switch name {
        case "mcp.add", "mcp.configure":
          let server = try JSONDecoder().decode(
            MCPServerConfig.self, from: JSONEncoder().encode(object["registration"] ?? .null))
          change = name == "mcp.add" ? .add(server) : .configure(server)
        case "mcp.enable", "mcp.disable":
          change = .enabled(id: try requiredString("id", in: object), name == "mcp.enable")
        default:
          change = .remove(id: try requiredString("id", in: object))
        }
        payload = try encodedPayload(
          try await operations.changeMCPRegistration(
            change, apply: object["apply"]?.boolValue ?? false,
            expectedCurrentDigest: object["expected_current_digest"]?.stringValue))
      case "plugin.list":
        payload = try encodedPayload(try await controlPlane.pluginSnapshot())
      case "plugin.doctor":
        payload = try encodedPayload(
          try await controlPlane.doctorPlugin(id: requiredString("id", in: object)))
      case "plugin.search":
        let kind = object["kind"]?.stringValue.flatMap(IntegrationKind.init(rawValue:))
        if object["kind"] != nil && kind == nil {
          throw GatewayToolError.invalidArguments("kind must be mcp, cli, or skills.")
        }
        let pageNumber = object["page"]?.numberValue ?? 1
        guard let page = Int(exactly: pageNumber), (1...100_000).contains(page) else {
          throw PluginCatalogError.invalidQuery
        }
        payload = try encodedPayload(
          try await controlPlane.searchPlugins(
            query: object["query"]?.stringValue ?? "", kind: kind, page: page,
            refresh: object["refresh"]?.boolValue ?? false))
      case "plugin.artifacts":
        guard let number = object["repository_id"]?.numberValue,
          let repositoryID = Int64(exactly: number), GitHubPluginArtifact.validID(repositoryID),
          let page = Int(exactly: object["page"]?.numberValue ?? 1), (1...1_000).contains(page)
        else { throw PluginCatalogError.invalidQuery }
        payload = try encodedPayload(
          try await controlPlane.pluginReleaseArtifacts(
            repository: requiredString("repository", in: object), repositoryID: repositoryID,
            tag: object["tag"]?.stringValue, page: page))
      case "plugin.show":
        let id = try requiredString("id", in: object)
        let snapshot = try await controlPlane.pluginSnapshot()
        guard
          snapshot.state.settings[id] != nil
            || snapshot.bundled.contains(where: { $0.manifest.id == id })
            || snapshot.issues.contains(where: { $0.pluginID == id })
        else {
          throw GatewayToolError.invalidArguments("Unknown plugin '\(id)'.")
        }
        payload = try encodedPayload(
          PluginHostSnapshot(filtering: snapshot, pluginID: id))
      case "plugin.register", "plugin.configure", "plugin.enable", "plugin.disable",
        "plugin.select", "plugin.remove", "plugin.install", "plugin.install_release",
        "plugin.uninstall", "plugin.recover":
        guard let revision = object["expected_revision"]?.numberValue,
          revision >= 0, revision <= 9_007_199_254_740_991, let expected = Int64(exactly: revision)
        else {
          throw GatewayToolError.invalidArguments(
            "expected_revision must be a nonnegative exact JSON integer.")
        }
        let change: PluginHostChange
        switch name {
        case "plugin.register":
          let path = try requiredString("path", in: object)
          guard path.hasPrefix("/"), !path.contains("\0") else {
            throw GatewayToolError.invalidArguments(
              "A development package path must be absolute and NUL-free.")
          }
          change = .registerDevelopment(URL(fileURLWithPath: path))
        case "plugin.configure":
          let settings = try JSONDecoder().decode(
            PluginSettings.self,
            from: JSONEncoder().encode(object["settings"] ?? .object([:])))
          change = .settings(pluginID: try requiredString("id", in: object), settings)
        case "plugin.enable", "plugin.disable":
          change = .enabled(pluginID: try requiredString("id", in: object), name == "plugin.enable")
        case "plugin.select":
          change = .select(
            pluginID: try requiredString("id", in: object),
            installationID: object["installation_id"]?.stringValue)
        case "plugin.install":
          let path = try requiredString("archive", in: object)
          guard path.hasPrefix("/"), !path.contains("\0") else {
            throw GatewayToolError.invalidArguments(
              "An archive path must be absolute and NUL-free.")
          }
          change = .installArchive(
            archive: URL(fileURLWithPath: path), sha256: try requiredString("sha256", in: object),
            pluginID: try requiredString("id", in: object),
            version: try PluginVersion(requiredString("version", in: object)))
        case "plugin.install_release":
          let data = try JSONEncoder().encode(object["artifact"] ?? .null)
          guard data.count <= 262_144 else { throw PluginCatalogError.invalidResponse }
          let artifact: GitHubPluginArtifact
          do {
            artifact = try CanonicalJSONCoding.decoder().decode(
              GitHubPluginArtifact.self, from: data)
          } catch { throw PluginCatalogError.invalidResponse }
          try artifact.validate()
          change = .installRelease(artifact)
        case "plugin.uninstall":
          change = .uninstallArtifact(
            installationID: try requiredString("installation_id", in: object))
        case "plugin.recover":
          change = .recover
        default:
          change = .removeDevelopment(
            installationID: try requiredString("installation_id", in: object))
        }
        payload = try encodedPayload(
          try await operations.changePlugins(change, expectedRevision: expected))
      case "audit.list":
        payload = try encodedPayload(
          try await controlPlane.auditEvents(
            limit: try boundedLimit(object["limit"], default: 200, maximum: 1_000)
          )
        )
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
          try await operations.startOpenAITunnel(id: requiredString("id", in: object))
        )
      case "tunnel.openai.reconnect":
        payload = try encodedPayload(
          try await operations.reconnectOpenAITunnel(id: requiredString("id", in: object))
        )
      case "tunnel.openai.provision":
        payload = try encodedPayload(
          try await controlPlane.provisionOpenAITunnel(
            profileID: requiredString("id", in: object),
            force: object["force"]?.boolValue ?? false
          )
        )
      case "tunnel.openai.stop":
        payload = try encodedPayload(
          try await operations.stopOpenAITunnel(id: requiredString("id", in: object))
        )
      case "tunnel.openai.logs":
        payload = try encodedPayload(
          try await controlPlane.openAITunnelLogs(profileID: requiredString("id", in: object))
        )
      case "tunnel.openai.save":
        payload = try encodedPayload(
          try await operations.saveOpenAITunnelConfiguration(
            OpenAITunnelConfigurationInput(
              id: requiredString("id", in: object),
              tunnelClientProfile: requiredString("tunnel_client_profile", in: object),
              tunnelID: requiredString("tunnel_id", in: object),
              gatewayProfile: requiredProfile("gateway_profile", in: object),
              tunnelClientPath: object["tunnel_client_path"]?.stringValue,
              httpProxy: object["http_proxy"]?.stringValue,
              apiKey: object["api_key"]?.stringValue
            )
          )
        )
      case "tunnel.openai.remove":
        let id = try requiredString("id", in: object)
        try await operations.deleteOpenAITunnelConfiguration(id: id)
        payload = .object(["removed": .string(id)])
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
          try await operations.startCloudflareTunnel(id: requiredString("id", in: object))
        )
      case "tunnel.cloudflare.stop":
        payload = try encodedPayload(
          try await operations.stopCloudflareTunnel(id: requiredString("id", in: object))
        )
      case "tunnel.cloudflare.logs":
        payload = try encodedPayload(
          try await controlPlane.cloudflareTunnelLogs(
            profileID: requiredString("id", in: object)
          )
        )
      case "tunnel.cloudflare.save":
        payload = try encodedPayload(
          try await operations.saveCloudflareTunnelConfiguration(
            CloudflareTunnelConfigurationInput(
              id: requiredString("id", in: object),
              tunnelName: requiredString("tunnel_name", in: object),
              publicHostname: requiredString("public_hostname", in: object),
              gatewayProfile: requiredProfile("gateway_profile", in: object),
              localPort: object["local_port"]?.intValue ?? 8_765,
              metricsPort: object["metrics_port"]?.intValue ?? 20_241,
              cloudflaredPath: object["cloudflared_path"]?.stringValue,
              tunnelToken: object["tunnel_token"]?.stringValue,
              regenerateAccessToken: object["regenerate_access_token"]?.boolValue ?? false
            )
          )
        )
      case "tunnel.cloudflare.remove":
        let id = try requiredString("id", in: object)
        try await operations.deleteCloudflareTunnelConfiguration(id: id)
        payload = .object(["removed": .string(id)])
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
    let parsed = try await controlPlane.parseManifest(manifest)
    let canonical = try parsed.exportedTOML()
    let currentData = try Data(contentsOf: controlPlane.directories.manifest)
    guard let currentManifest = String(data: currentData, encoding: .utf8) else {
      throw ConfigurationError.invalid("The active manifest is not valid UTF-8.")
    }
    let currentDigest = Self.digest(currentData)
    let proposedDigest = Self.digest(Data(canonical.utf8))
    let gatewayWasRunning = await gatewayService.snapshot().state == .running
    var result: [String: JSONValue] = [
      "ok": .bool(true),
      "schema_version": .number(Double(parsed.schemaVersion)),
      "current_digest": .string(currentDigest),
      "proposed_digest": .string(proposedDigest),
      "changed": .bool(currentDigest != proposedDigest),
      "diff": Self.manifestDiff(current: currentManifest, proposed: canonical),
      "toml": .string(canonical),
      "transport_will_restart": .bool(gatewayWasRunning),
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
      let revision = try await operations.activateManifest(canonical, expectedDigest: expected)
      result["applied_revision"] = .string(revision.id)
      result["transport_restarted"] = .bool(gatewayWasRunning)
    }
    return .object(result)
  }

  private func requiredProfile(in object: [String: JSONValue]) throws -> GatewayProfileID {
    try requiredProfile("profile", in: object)
  }

  private func optionalChoice<T: RawRepresentable>(_ key: String, in object: [String: JSONValue])
    throws -> T?
  where T.RawValue == String {
    guard let raw = object[key]?.stringValue else { return nil }
    guard let value = T(rawValue: raw) else {
      throw GatewayToolError.invalidArguments("Invalid '\(key)' value '\(raw)'.")
    }
    return value
  }

  private func optionalStringSet(_ key: String, in object: [String: JSONValue]) -> Set<String>? {
    object[key]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
  }

  private func requiredProfile(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> GatewayProfileID {
    let rawValue = try requiredString(key, in: object)
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

  private func boundedLimit(
    _ value: JSONValue?,
    default defaultValue: Int,
    maximum: Int
  ) throws -> Int {
    let limit = value?.intValue ?? defaultValue
    guard (1...maximum).contains(limit) else {
      throw GatewayToolError.invalidArguments("limit must be between 1 and \(maximum).")
    }
    return limit
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
    if error is MCPHTTPAuthenticationError { return (.failed, "mcp.authentication") }
    if let error = error as? PluginCatalogError {
      return (.failed, error.code)
    }
    if let error = error as? PluginArchiveError {
      return (.failed, "plugin.archive.\(error.rawValue)")
    }
    if let error = error as? PluginStoreError {
      let code =
        switch error {
        case .staleRevision: "stale_revision"
        case .unknownInstallation: "unknown_installation"
        case .invalidState: "invalid_state"
        case .manifestChanged: "manifest_changed"
        case .installationBusy: "installation_busy"
        }
      return (.failed, "plugin.\(code)")
    }
    if let error = error as? PluginHostError {
      let code =
        switch error {
        case .changeInProgress: "change_in_progress"
        case .connectedClients: "connected_clients"
        case .invalidComposition: "invalid_composition"
        case .workerUnavailable: "worker_unavailable"
        }
      return (.failed, "plugin.\(code)")
    }
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
    ControlToolContract("mcp.list", readOnly: true),
    ControlToolContract(
      "mcp.credential.status", arguments: ["id": .string], required: ["id"], readOnly: true),
    ControlToolContract(
      "mcp.credential.set",
      arguments: ["id": .string, "expected_binding_digest": .string, "token": .string],
      required: ["id", "expected_binding_digest", "token"], readOnly: false),
    ControlToolContract(
      "mcp.credential.remove",
      arguments: ["id": .string, "expected_binding_digest": .string],
      required: ["id", "expected_binding_digest"], readOnly: false),
    ControlToolContract(
      "mcp.doctor", arguments: ["id": .string, "workspace_id": .string],
      required: ["id", "workspace_id"], readOnly: true),
    ControlToolContract(
      "mcp.process.recover",
      arguments: [
        "id": .string, "workspace_id": .string, "receipt_id": .string,
        "expected_receipt_digest": .string, "expected_current_digest": .string,
      ],
      required: [
        "id", "workspace_id", "receipt_id", "expected_receipt_digest", "expected_current_digest",
      ],
      readOnly: false),
    ControlToolContract("mcp.show", arguments: ["id": .string], required: ["id"], readOnly: true),
    ControlToolContract(
      "mcp.add",
      arguments: ["registration": .object, "apply": .boolean, "expected_current_digest": .string],
      required: ["registration"], readOnly: false),
    ControlToolContract(
      "mcp.configure",
      arguments: ["registration": .object, "apply": .boolean, "expected_current_digest": .string],
      required: ["registration"], readOnly: false),
    ControlToolContract(
      "mcp.enable",
      arguments: ["id": .string, "apply": .boolean, "expected_current_digest": .string],
      required: ["id"], readOnly: false),
    ControlToolContract(
      "mcp.disable",
      arguments: ["id": .string, "apply": .boolean, "expected_current_digest": .string],
      required: ["id"], readOnly: false),
    ControlToolContract(
      "mcp.remove",
      arguments: ["id": .string, "apply": .boolean, "expected_current_digest": .string],
      required: ["id"], readOnly: false),
    ControlToolContract(
      "plugin.artifacts",
      arguments: [
        "repository": .string, "repository_id": .integer, "tag": .string, "page": .integer,
      ],
      required: ["repository", "repository_id"], readOnly: true),
    ControlToolContract(
      "plugin.install_release", arguments: ["artifact": .object, "expected_revision": .integer],
      required: ["artifact", "expected_revision"], readOnly: false),
    ControlToolContract(
      "plugin.install",
      arguments: [
        "archive": .string, "sha256": .string, "id": .string, "version": .string,
        "expected_revision": .integer,
      ],
      required: ["archive", "sha256", "id", "version", "expected_revision"], readOnly: false),
    ControlToolContract(
      "plugin.uninstall", arguments: ["installation_id": .string, "expected_revision": .integer],
      required: ["installation_id", "expected_revision"], readOnly: false),
    ControlToolContract(
      "plugin.recover", arguments: ["expected_revision": .integer],
      required: ["expected_revision"], readOnly: false),
    ControlToolContract("plugin.list", readOnly: true),
    ControlToolContract(
      "plugin.doctor", arguments: ["id": .string], required: ["id"], readOnly: true),
    ControlToolContract(
      "plugin.search",
      arguments: ["query": .string, "kind": .string, "page": .integer, "refresh": .boolean],
      readOnly: true),
    ControlToolContract(
      "plugin.show", arguments: ["id": .string], required: ["id"], readOnly: true),
    ControlToolContract(
      "plugin.register", arguments: ["path": .string, "expected_revision": .integer],
      required: ["path", "expected_revision"], readOnly: false),
    ControlToolContract(
      "plugin.configure",
      arguments: ["id": .string, "settings": .object, "expected_revision": .integer],
      required: ["id", "settings", "expected_revision"], readOnly: false),
    ControlToolContract(
      "plugin.enable", arguments: ["id": .string, "expected_revision": .integer],
      required: ["id", "expected_revision"], readOnly: false),
    ControlToolContract(
      "plugin.disable", arguments: ["id": .string, "expected_revision": .integer],
      required: ["id", "expected_revision"], readOnly: false),
    ControlToolContract(
      "plugin.select",
      arguments: ["id": .string, "installation_id": .string, "expected_revision": .integer],
      required: ["id", "expected_revision"], readOnly: false),
    ControlToolContract(
      "plugin.remove", arguments: ["installation_id": .string, "expected_revision": .integer],
      required: ["installation_id", "expected_revision"], readOnly: false),
    ControlToolContract("app.capabilities", readOnly: true),
    ControlToolContract("app.status", readOnly: true),
    ControlToolContract("app.start", readOnly: false),
    ControlToolContract("app.stop", readOnly: false),
    ControlToolContract("app.restart", readOnly: false),
    ControlToolContract(
      "app.launch_at_login",
      arguments: ["enabled": .boolean],
      readOnly: false
    ),
    ControlToolContract(
      "readiness",
      arguments: ["journey": .string],
      required: ["journey"],
      readOnly: true
    ),
    ControlToolContract("config.path", readOnly: true),
    ControlToolContract("config.show", readOnly: true),
    ControlToolContract(
      "config.validate",
      arguments: ["toml": .string],
      readOnly: true
    ),
    ControlToolContract("config.export", readOnly: true),
    ControlToolContract(
      "config.history",
      arguments: ["limit": .integer],
      readOnly: true
    ),
    ControlToolContract(
      "config.rollback",
      arguments: ["revision_id": .string],
      required: ["revision_id"],
      readOnly: false
    ),
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
      "workspace.deduplicate",
      arguments: [
        "apply": .boolean,
        "expected_plan_digest": .string,
        "allow_metadata_conflicts": .boolean,
      ],
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
      "profile.activate",
      arguments: ["profile": .string],
      required: ["profile"],
      readOnly: false
    ),
    ControlToolContract(
      "profile.grant",
      arguments: ["profile": .string, "workspace_id": .string, "enabled": .boolean],
      required: ["profile", "workspace_id"],
      readOnly: false
    ),
    ControlToolContract(
      "profile.shell",
      arguments: ["profile": .string, "enabled": .boolean],
      required: ["profile"],
      readOnly: false
    ),
    ControlToolContract(
      "profile.permissions",
      arguments: [
        "profile": .string, "mode": .string, "confirmation_policy": .string,
        "full_shell_enabled": .boolean, "capabilities": .strings, "workspaces": .strings,
        "mcp_servers": .strings, "allowed_callers": .strings, "expected_revision": .integer,
      ],
      required: ["profile"], readOnly: false),
    ControlToolContract("provider.list", readOnly: true),
    ControlToolContract(
      "provider.doctor",
      arguments: ["id": .string],
      readOnly: true
    ),
    ControlToolContract("permissions.status", readOnly: true),
    ControlToolContract("approvals.list", arguments: ["limit": .integer], readOnly: true),
    ControlToolContract(
      "approvals.approve", arguments: ["id": .string], required: ["id"], readOnly: false),
    ControlToolContract(
      "approvals.deny", arguments: ["id": .string], required: ["id"], readOnly: false),
    ControlToolContract(
      "audit.list",
      arguments: ["limit": .integer],
      readOnly: true
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
    tunnelContract("tunnel.openai.reconnect", readOnly: false),
    ControlToolContract(
      "tunnel.openai.provision",
      arguments: ["id": .string, "force": .boolean],
      required: ["id"],
      readOnly: false
    ),
    tunnelContract("tunnel.openai.stop", readOnly: false),
    tunnelContract("tunnel.openai.logs", readOnly: true),
    ControlToolContract(
      "tunnel.openai.save",
      arguments: [
        "id": .string,
        "tunnel_client_profile": .string,
        "tunnel_id": .string,
        "gateway_profile": .string,
        "tunnel_client_path": .string,
        "http_proxy": .string,
        "api_key": .string,
      ],
      required: ["id", "tunnel_client_profile", "tunnel_id", "gateway_profile"],
      readOnly: false
    ),
    tunnelContract("tunnel.openai.remove", readOnly: false),
    ControlToolContract("tunnel.cloudflare.list", readOnly: true),
    tunnelContract("tunnel.cloudflare.doctor", readOnly: true),
    tunnelContract("tunnel.cloudflare.start", readOnly: false),
    tunnelContract("tunnel.cloudflare.stop", readOnly: false),
    tunnelContract("tunnel.cloudflare.logs", readOnly: true),
    ControlToolContract(
      "tunnel.cloudflare.save",
      arguments: [
        "id": .string,
        "tunnel_name": .string,
        "public_hostname": .string,
        "gateway_profile": .string,
        "local_port": .integer,
        "metrics_port": .integer,
        "cloudflared_path": .string,
        "tunnel_token": .string,
        "regenerate_access_token": .boolean,
      ],
      required: ["id", "tunnel_name", "public_hostname", "gateway_profile"],
      readOnly: false
    ),
    tunnelContract("tunnel.cloudflare.remove", readOnly: false),
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
