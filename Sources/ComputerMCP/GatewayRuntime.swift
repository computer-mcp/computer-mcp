import CryptoKit
import Foundation

package final class GatewayRuntime: GatewayToolServing, @unchecked Sendable {
  private let configuration: GatewayConfiguration
  private let context: ExecutionContext
  private let grant: ProfileGrant
  private let policyEvaluator: GatewayPolicyEvaluator
  private let database: GatewayDatabase?
  private let workspaces: [String: RegisteredWorkspace]
  private let workspaceOrder: [String]
  private let workspaceAccesses: [String: ResolvedWorkspaceAccess]
  private let providerRouters: [String: GatewayProviderRouter]
  private let shutdownState = GatewayRuntimeShutdownState()

  package init(
    configuration: GatewayConfiguration,
    context: ExecutionContext? = nil,
    database: GatewayDatabase? = nil,
    registeredWorkspaces: [RegisteredWorkspace]? = nil,
    bookmarkService: any WorkspaceBookmarkServicing = WorkspaceBookmarkService(),
    policyEvaluator: GatewayPolicyEvaluator = GatewayPolicyEvaluator()
  ) throws {
    let effectiveContext = context ?? configuration.executionContext()
    let persistedProfiles = try database?.profiles() ?? []

    let persistedWorkspaces = try database?.workspaces() ?? []
    let configuredWorkspaces =
      registeredWorkspaces
      ?? (persistedWorkspaces.isEmpty ? configuration.manifestWorkspaces : persistedWorkspaces)

    var workspaceByID: [String: RegisteredWorkspace] = [:]
    var accessByID: [String: ResolvedWorkspaceAccess] = [:]
    var providerRouterByID: [String: GatewayProviderRouter] = [:]
    let commandRunner = ProcessCommandRunner()
    let mcpClient = MCPProxyClient()
    let codexToolDispatcher = CodexDynamicToolDispatcher()

    for workspace in configuredWorkspaces {
      guard workspaceByID[workspace.id] == nil else {
        throw GatewayRuntimeError.duplicateWorkspaceID(workspace.id)
      }
      let access = try bookmarkService.resolve(workspace)
      var workspaceConfiguration = configuration
      workspaceConfiguration.workspaceDirectory = access.rootURL.standardizedFileURL
      let shellManager = SubprocessShellRuntime()
      let processManager = SubprocessProcessRegistry(
        shellManager: shellManager,
        maxSessions: configuration.policy.maxShellSessions,
        terminationGraceMilliseconds: configuration.policy.shellTerminationGraceMs
      )
      workspaceByID[workspace.id] = access.workspace
      accessByID[workspace.id] = access
      let registry = GatewayToolRegistry(
        configuration: workspaceConfiguration,
        commandRunner: commandRunner,
        processManager: processManager,
        shellManager: shellManager,
        mcpClient: mcpClient
      )
      var additionalProviders: [any GatewayToolProvider] = [
        ComputerUseGatewayProvider()
      ]
      if configuration.codex.enabled {
        additionalProviders.append(
          CodexGatewayProvider(
            configuration: configuration.codex,
            workspaceURL: access.rootURL,
            owner: CodexRuntimeOwner(
              workspaceID: workspace.id,
              profileID: effectiveContext.profileID.rawValue,
              caller: effectiveContext.caller.rawValue,
              transport: effectiveContext.transportTrace?.transport,
              socketConnectionID: effectiveContext.transportTrace?.socketConnectionID,
              tunnelInstanceID: effectiveContext.transportTrace?.tunnelInstanceID,
              tunnelProfileID: effectiveContext.transportTrace?.tunnelProfileID
            ),
            database: database,
            dynamicToolDispatcher: codexToolDispatcher,
            maxOutputBytes: configuration.policy.maxOutputBytes
          )
        )
      }
      providerRouterByID[workspace.id] = try GatewayProviderRouter(
        registry: registry,
        additionalProviders: additionalProviders
      )
      if access.workspace != workspace {
        try database?.saveWorkspace(access.workspace)
      }
    }

    let persistedGrant = persistedProfiles.first(where: { $0.id == effectiveContext.profileID })
    let configuredGrant = configuration.profiles
      .first(where: { $0.id == effectiveContext.profileID })?
      .grant
    let baseGrant: ProfileGrant
    if let configuredGrant {
      baseGrant = configuredGrant
    } else if effectiveContext.profileID == .chatGPTObserve
      || effectiveContext.profileID == .cloudflareObserve
    {
      var readOnlyCapabilities: Set<String> = ["workspace.list", "workspace.describe"]
      if let firstWorkspaceID = configuredWorkspaces.first?.id,
        let providerRouter = providerRouterByID[firstWorkspaceID]
      {
        readOnlyCapabilities.formUnion(
          try providerRouter.listTools()
            .filter {
              $0.annotations?.readOnlyHint == true && !$0.name.hasPrefix("codex.")
            }
            .map(\.name)
        )
      }
      baseGrant = ProfileGrant(
        id: effectiveContext.profileID,
        capabilityIDs: readOnlyCapabilities,
        workspaceIDs: Set(workspaceByID.keys),
        allowedCallers: [effectiveContext.caller]
      )
    } else {
      baseGrant = configuration.profileGrant(for: effectiveContext.profileID)
    }
    let effectiveGrant =
      persistedGrant.map(baseGrant.applyingPersistedRuntimeState)
      ?? baseGrant
    try effectiveGrant.validate()

    self.configuration = configuration
    self.context = effectiveContext
    self.grant = effectiveGrant
    self.policyEvaluator = policyEvaluator
    self.database = database
    self.workspaces = workspaceByID
    self.workspaceOrder = configuredWorkspaces.map(\.id)
    self.workspaceAccesses = accessByID
    self.providerRouters = providerRouterByID
    codexToolDispatcher.attach(self)
  }

  deinit {
    for access in workspaceAccesses.values {
      access.close()
    }
  }

  package func shutdown() async {
    guard shutdownState.begin() else { return }
    for workspaceID in workspaceOrder {
      await providerRouters[workspaceID]?.shutdown()
    }
    for access in workspaceAccesses.values {
      access.close()
    }
  }

  package func listTools() throws -> [MCPTool] {
    try listTools(context: context)
  }

  package func listTools(context: ExecutionContext) throws -> [MCPTool] {
    let catalog = GatewayCapabilityCatalog()
    let coreTools = Self.coreTools(databaseEnabled: database != nil)
    let routedTools =
      try firstProviderRouter?.listTools().map { tool in
        Self.addWorkspaceID(
          to: tool,
          descriptor: try firstProviderRouter?.capability(named: tool.name)
            ?? catalog.descriptor(for: tool)
        )
      } ?? []
    return (coreTools + routedTools).filter { tool in
      let descriptor =
        (try? firstProviderRouter?.capability(named: tool.name))
        ?? catalog.descriptor(for: tool)
      return isVisible(descriptor, context: context)
    }
  }

  package func capabilityDescriptor(named name: String) throws -> CapabilityDescriptor {
    try descriptor(named: name)
  }

  package func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    try callTool(name: name, arguments: arguments, context: contextForCall())
  }

  package func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    try await callToolAsync(name: name, arguments: arguments, context: contextForCall())
  }

  func callToolFromCodex(
    name: String,
    arguments: JSONValue,
    requestID: String,
    workspaceID: String?
  ) async throws -> JSONValue {
    var callContext = context
    callContext.requestID = requestID
    callContext.workspaceID = workspaceID
    let targetDescriptor = try descriptor(named: name)
    if targetDescriptor.risk == .destructive {
      var prepareContext = callContext
      prepareContext.requestID = "\(requestID):prepare"
      let prepared = try await performAsync(
        name: "operations.prepare",
        arguments: [
          "tool": .string(name),
          "arguments": arguments,
        ],
        context: prepareContext,
        bypassOperationTicket: false,
        operationLinkage: nil
      )
      guard
        let ticketID = prepared.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["ticket_id"]?.stringValue
      else {
        throw GatewayToolError.executionFailed(
          "codex.app.operation_ticket_missing: Computer MCP could not bind the approved operation."
        )
      }
      return try await performAsync(
        name: "operations.commit",
        arguments: [
          "ticket_id": .string(ticketID),
          "tool": .string(name),
          "arguments": arguments,
        ],
        context: callContext,
        bypassOperationTicket: false,
        operationLinkage: nil
      )
    }
    return try await callToolAsync(
      name: name,
      arguments: arguments,
      context: callContext
    )
  }

  func preflightCodexTool(
    name: String,
    arguments: JSONValue,
    requestID: String,
    workspaceID: String?
  ) throws -> CapabilityDescriptor {
    let descriptor = try descriptor(named: name)
    var callContext = context
    callContext.requestID = requestID
    callContext.workspaceID = workspaceID
    let routed = try route(
      descriptor: descriptor,
      arguments: arguments.objectValue ?? [:],
      context: callContext
    )
    try authorize(descriptor, context: routed.context)
    if descriptor.risk == .destructive {
      for operationTool in ["operations.prepare", "operations.commit"] {
        let operationDescriptor = try self.descriptor(named: operationTool)
        try authorize(operationDescriptor, context: routed.context)
      }
    }
    return Self.effectiveCodexToolDescriptor(
      descriptor,
      arguments: routed.arguments
    )
  }

  private static func effectiveCodexToolDescriptor(
    _ descriptor: CapabilityDescriptor,
    arguments: [String: JSONValue]
  ) -> CapabilityDescriptor {
    guard let defaultDryRun = reviewedDryRunCapabilities[descriptor.id] else {
      return descriptor
    }
    let dryRun: Bool
    if let supplied = arguments["dry_run"] {
      guard let value = supplied.boolValue else { return descriptor }
      dryRun = value
    } else {
      dryRun = defaultDryRun
    }
    guard dryRun else { return descriptor }
    var effective = descriptor
    effective.risk = .readOnly
    return effective
  }

  // These builtins have reviewed implementations whose dry-run path does not mutate state.
  // Configured and downstream tools are intentionally excluded because their contracts are
  // not owned by the gateway.
  private static let reviewedDryRunCapabilities: [String: Bool] = [
    "archive.create": true,
    "archive.extract": true,
    "file.append": false,
    "file.chmod": false,
    "file.copy": false,
    "file.download": true,
    "file.insert_text": false,
    "file.mkdir": false,
    "file.move": false,
    "file.remove_xattr": false,
    "file.replace_lines": false,
    "file.replace_text": false,
    "file.symlink": false,
    "file.touch": false,
    "file.trash": false,
    "file.write": false,
    "file.write_files": true,
    "git.add": false,
    "git.branch_create": true,
    "git.branch_delete": true,
    "git.branch_rename": true,
    "git.branch_switch": true,
    "git.clean": true,
    "git.commit": false,
    "git.restore_worktree": true,
    "git.stash_push": false,
    "git.tag_create": true,
    "git.tag_delete": true,
    "git.unstage": false,
    "json.write": true,
    "plist.write": true,
  ]

  package func callToolForMCPAsync(
    name: String,
    arguments: JSONValue?
  ) async throws -> JSONValue {
    var callContext = contextForCall()
    let object = arguments?.objectValue ?? [:]
    if let workspaceID = object["workspace_id"]?.stringValue {
      callContext.workspaceID = workspaceID
    } else if callContext.workspaceID == nil, workspaceOrder.count == 1 {
      callContext.workspaceID = workspaceOrder[0]
    }
    do {
      return try await callToolAsync(
        name: name,
        arguments: arguments,
        context: callContext
      )
    } catch {
      return Self.attachExecutionMetadata(
        to: Self.errorEnvelope(error),
        context: callContext,
        capabilityID: name,
        operationLinkage: Self.operationLinkageFromArguments(
          name: name,
          arguments: object
        )
      )
    }
  }

  package func callTool(
    name: String,
    arguments: JSONValue?,
    context: ExecutionContext
  ) throws -> JSONValue {
    try perform(
      name: name,
      arguments: arguments?.objectValue ?? [:],
      context: context,
      bypassOperationTicket: false,
      operationLinkage: nil
    )
  }

  package func callToolAsync(
    name: String,
    arguments: JSONValue?,
    context: ExecutionContext
  ) async throws -> JSONValue {
    try await performAsync(
      name: name,
      arguments: arguments?.objectValue ?? [:],
      context: context,
      bypassOperationTicket: false,
      operationLinkage: nil
    )
  }

  private func perform(
    name: String,
    arguments: [String: JSONValue],
    context originalContext: ExecutionContext,
    bypassOperationTicket: Bool,
    operationLinkage initialOperationLinkage: OperationAuditLinkage?
  ) throws -> JSONValue {
    let start = ContinuousClock.now
    var auditContext = originalContext
    var inputDigest = try? Self.inputDigest(tool: name, arguments: arguments)
    var operationLinkage =
      initialOperationLinkage
      ?? Self.operationLinkageFromArguments(name: name, arguments: arguments)

    do {
      let descriptor = try descriptor(named: name)
      let routed = try route(
        descriptor: descriptor,
        arguments: arguments,
        context: originalContext
      )
      auditContext = routed.context
      inputDigest = try Self.inputDigest(tool: name, arguments: routed.arguments)
      try authorize(descriptor, context: routed.context)
      if descriptor.risk == .destructive && !bypassOperationTicket {
        throw Self.invalid(
          code: "operations.ticket_required",
          message:
            "Destructive capability '\(name)' requires operations.prepare followed by operations.commit."
        )
      }

      let rawResult: JSONValue
      switch name {
      case "workspace.list":
        rawResult = try resultEnvelope(workspaceList(context: routed.context))
      case "workspace.describe":
        rawResult = try resultEnvelope(workspaceDescribe(arguments: routed.arguments))
      case "policy.probe":
        rawResult = try resultEnvelope(
          policyProbe(arguments: routed.arguments, context: routed.context)
        )
      case "operations.prepare":
        let preparation = try prepareOperation(
          arguments: routed.arguments,
          context: routed.context
        )
        operationLinkage = OperationAuditLinkage(ticketID: preparation.ticketID)
        rawResult = try resultEnvelope(preparation.result)
      case "operations.commit":
        let invocation = try beginOperationCommit(
          arguments: routed.arguments,
          context: routed.context
        )
        operationLinkage = invocation.linkage
        rawResult = try executeCommittedOperation(invocation)
      default:
        guard let registryWorkspaceID = routed.registryWorkspaceID else {
          throw GatewayRuntimeError.noWorkspaces
        }
        guard let providerRouter = providerRouters[registryWorkspaceID] else {
          throw GatewayRuntimeError.workspaceNotFound(registryWorkspaceID)
        }
        rawResult = try providerRouter.callTool(
          name: name,
          arguments: .object(routed.arguments)
        )
      }
      let result = Self.attachExecutionMetadata(
        to: rawResult,
        context: routed.context,
        capabilityID: descriptor.id,
        operationLinkage: operationLinkage
      )

      try recordAudit(
        context: routed.context,
        capabilityID: descriptor.id,
        decision: .allowed,
        errorCode: nil,
        duration: start.duration(to: .now),
        inputDigest: inputDigest,
        output: result,
        operationLinkage: operationLinkage
      )
      return result
    } catch {
      let auditOutput = Self.attachExecutionMetadata(
        to: Self.errorEnvelope(error),
        context: auditContext,
        capabilityID: name,
        operationLinkage: operationLinkage
      )
      try? recordAudit(
        context: auditContext,
        capabilityID: name,
        decision: Self.auditDecision(for: error),
        errorCode: Self.auditErrorCode(for: error),
        duration: start.duration(to: .now),
        inputDigest: inputDigest,
        output: auditOutput,
        operationLinkage: operationLinkage
      )
      throw error
    }
  }

  private func performAsync(
    name: String,
    arguments: [String: JSONValue],
    context originalContext: ExecutionContext,
    bypassOperationTicket: Bool,
    operationLinkage initialOperationLinkage: OperationAuditLinkage?
  ) async throws -> JSONValue {
    let start = ContinuousClock.now
    var auditContext = originalContext
    var inputDigest = try? Self.inputDigest(tool: name, arguments: arguments)
    var operationLinkage =
      initialOperationLinkage
      ?? Self.operationLinkageFromArguments(name: name, arguments: arguments)

    do {
      let descriptor = try descriptor(named: name)
      let routed = try route(
        descriptor: descriptor,
        arguments: arguments,
        context: originalContext
      )
      auditContext = routed.context
      inputDigest = try Self.inputDigest(tool: name, arguments: routed.arguments)
      try authorize(descriptor, context: routed.context)
      if descriptor.risk == .destructive && !bypassOperationTicket {
        throw Self.invalid(
          code: "operations.ticket_required",
          message:
            "Destructive capability '\(name)' requires operations.prepare followed by operations.commit."
        )
      }

      let rawResult: JSONValue
      switch name {
      case "workspace.list":
        rawResult = try resultEnvelope(workspaceList(context: routed.context))
      case "workspace.describe":
        rawResult = try resultEnvelope(workspaceDescribe(arguments: routed.arguments))
      case "policy.probe":
        rawResult = try resultEnvelope(
          policyProbe(arguments: routed.arguments, context: routed.context)
        )
      case "operations.prepare":
        let preparation = try prepareOperation(
          arguments: routed.arguments,
          context: routed.context
        )
        operationLinkage = OperationAuditLinkage(ticketID: preparation.ticketID)
        rawResult = try resultEnvelope(preparation.result)
      case "operations.commit":
        let invocation = try beginOperationCommit(
          arguments: routed.arguments,
          context: routed.context
        )
        operationLinkage = invocation.linkage
        rawResult = try await executeCommittedOperationAsync(invocation)
      default:
        guard let registryWorkspaceID = routed.registryWorkspaceID else {
          throw GatewayRuntimeError.noWorkspaces
        }
        guard let providerRouter = providerRouters[registryWorkspaceID] else {
          throw GatewayRuntimeError.workspaceNotFound(registryWorkspaceID)
        }
        rawResult = try await providerRouter.callToolAsync(
          name: name,
          arguments: .object(routed.arguments)
        )
      }
      let result = Self.attachExecutionMetadata(
        to: rawResult,
        context: routed.context,
        capabilityID: descriptor.id,
        operationLinkage: operationLinkage
      )

      try recordAudit(
        context: routed.context,
        capabilityID: descriptor.id,
        decision: .allowed,
        errorCode: nil,
        duration: start.duration(to: .now),
        inputDigest: inputDigest,
        output: result,
        operationLinkage: operationLinkage
      )
      return result
    } catch {
      let auditOutput = Self.attachExecutionMetadata(
        to: Self.errorEnvelope(error),
        context: auditContext,
        capabilityID: name,
        operationLinkage: operationLinkage
      )
      try? recordAudit(
        context: auditContext,
        capabilityID: name,
        decision: Self.auditDecision(for: error),
        errorCode: Self.auditErrorCode(for: error),
        duration: start.duration(to: .now),
        inputDigest: inputDigest,
        output: auditOutput,
        operationLinkage: operationLinkage
      )
      throw error
    }
  }

  private func prepareOperation(
    arguments: [String: JSONValue],
    context: ExecutionContext
  ) throws -> PreparedOperation {
    guard let database else {
      throw Self.invalid(
        code: "operations.persistence_unavailable",
        message: "Operation tickets require the Gateway Database."
      )
    }
    let toolName = try Self.requiredString("tool", in: arguments)
    guard toolName != "operations.prepare", toolName != "operations.commit" else {
      throw Self.invalid(
        code: "operations.invalid_target",
        message: "Operation tools cannot target themselves."
      )
    }
    let targetArguments = arguments["arguments"]?.objectValue ?? [:]
    let targetDescriptor = try descriptor(named: toolName)
    guard targetDescriptor.risk == .destructive else {
      throw Self.invalid(
        code: "operations.not_required",
        message: "Capability '\(toolName)' does not require an operation ticket."
      )
    }
    let routed = try route(
      descriptor: targetDescriptor,
      arguments: targetArguments,
      context: context
    )
    try authorize(targetDescriptor, context: routed.context)
    let now = Date()
    let ttlMilliseconds = min(
      max(arguments["ttl_ms"]?.intValue ?? 30_000, 1_000),
      300_000
    )
    let stateDigest = try currentStateDigest(
      tool: toolName,
      arguments: routed.arguments,
      context: routed.context
    )
    if let expectedStateDigest = arguments["state_digest"]?.stringValue {
      guard let stateDigest else {
        throw Self.invalid(
          code: "operations.state_binding_unavailable",
          message: "The target does not support a deterministic current-state binding."
        )
      }
      guard expectedStateDigest == stateDigest else {
        throw Self.invalid(
          code: "operations.state_digest_mismatch",
          message: "The supplied state_digest does not match the target's current state."
        )
      }
    }
    let ticket = OperationTicket(
      capabilityID: toolName,
      caller: routed.context.caller,
      profileID: routed.context.profileID,
      principalID: Self.principalID(for: routed.context),
      workspaceID: routed.context.workspaceID,
      inputDigest: try Self.inputDigest(tool: toolName, arguments: routed.arguments),
      stateDigest: stateDigest,
      prepareRequestID: routed.context.requestID,
      createdAt: now,
      expiresAt: now.addingTimeInterval(Double(ttlMilliseconds) / 1_000)
    )
    try database.saveOperationTicket(ticket)
    return PreparedOperation(
      ticketID: ticket.id,
      result: .object([
        "ticket_id": .string(ticket.id),
        "tool": .string(toolName),
        "workspace_id": ticket.workspaceID.map(JSONValue.string) ?? .null,
        "state_digest": ticket.stateDigest.map(JSONValue.string) ?? .null,
        "expires_at": .string(Self.iso8601(ticket.expiresAt)),
        "single_use": .bool(true),
      ])
    )
  }

  private func policyProbe(
    arguments: [String: JSONValue],
    context: ExecutionContext
  ) throws -> JSONValue {
    let capabilityID = try Self.requiredString("capability_id", in: arguments)
    guard capabilityID != "policy.probe" else {
      throw Self.invalid(
        code: "policy.invalid_probe_target",
        message: "policy.probe cannot target itself."
      )
    }
    let targetArguments = arguments["arguments"]?.objectValue ?? [:]
    let targetDescriptor = try descriptor(named: capabilityID)
    let routed = try route(
      descriptor: targetDescriptor,
      arguments: targetArguments,
      context: context
    )
    try authorize(targetDescriptor, context: routed.context)
    return .object([
      "capability_id": .string(capabilityID),
      "decision": .string("allowed"),
      "risk": .string(targetDescriptor.risk.rawValue),
      "workspace_id": routed.context.workspaceID.map(JSONValue.string) ?? .null,
    ])
  }

  private func beginOperationCommit(
    arguments: [String: JSONValue],
    context: ExecutionContext
  ) throws -> OperationInvocation {
    guard let database else {
      throw Self.invalid(
        code: "operations.persistence_unavailable",
        message: "Operation tickets require the Gateway Database."
      )
    }
    let ticketID = try Self.requiredString("ticket_id", in: arguments)
    let toolName = try Self.requiredString("tool", in: arguments)
    let targetArguments = arguments["arguments"]?.objectValue ?? [:]
    guard let ticket = try database.operationTicket(id: ticketID) else {
      throw Self.invalid(code: "operations.ticket_unknown", message: "Unknown operation ticket.")
    }
    let principalID = Self.principalID(for: context)
    guard ticket.capabilityID == toolName,
      ticket.caller == context.caller,
      ticket.profileID == context.profileID,
      ticket.principalID == principalID
    else {
      throw Self.invalid(
        code: "operations.ticket_context_mismatch",
        message: "The operation ticket is not bound to this principal, profile, and tool."
      )
    }
    let targetDescriptor = try descriptor(named: toolName)
    let routed = try route(
      descriptor: targetDescriptor,
      arguments: targetArguments,
      context: context
    )
    guard routed.context.workspaceID == ticket.workspaceID,
      try Self.inputDigest(tool: toolName, arguments: routed.arguments) == ticket.inputDigest
    else {
      throw Self.invalid(
        code: "operations.ticket_arguments_mismatch",
        message: "The committed arguments or workspace do not match the prepared operation."
      )
    }
    if let expectedStateDigest = ticket.stateDigest {
      let observedStateDigest = try currentStateDigest(
        tool: toolName,
        arguments: routed.arguments,
        context: routed.context
      )
      guard observedStateDigest == expectedStateDigest else {
        do {
          try database.failPreparedOperationTicket(
            id: ticketID,
            principalID: principalID,
            failureCode: "operations.ticket_state_changed"
          )
        } catch {
          throw Self.operationTicketError(error)
        }
        throw Self.invalid(
          code: "operations.ticket_state_changed",
          message: "The target state changed after the operation was prepared."
        )
      }
    }
    let invocationID = UUID().uuidString
    do {
      _ = try database.beginOperationTicket(
        id: ticketID,
        principalID: principalID,
        invocationID: invocationID,
        parentRequestID: context.requestID
      )
    } catch {
      throw Self.operationTicketError(error)
    }
    var targetContext = routed.context
    targetContext.requestID = invocationID
    return OperationInvocation(
      ticketID: ticketID,
      invocationID: invocationID,
      parentRequestID: context.requestID,
      toolName: toolName,
      arguments: routed.arguments,
      targetContext: targetContext
    )
  }

  private func executeCommittedOperation(
    _ invocation: OperationInvocation
  ) throws -> JSONValue {
    let result: JSONValue
    do {
      result = try perform(
        name: invocation.toolName,
        arguments: invocation.arguments,
        context: invocation.targetContext,
        bypassOperationTicket: true,
        operationLinkage: invocation.linkage
      )
    } catch {
      if let database {
        _ = try? database.finishOperationTicket(
          id: invocation.ticketID,
          invocationID: invocation.invocationID,
          state: .failed,
          failureCode: "operations.target_failed"
        )
      }
      throw error
    }
    if let database {
      _ = try database.finishOperationTicket(
        id: invocation.ticketID,
        invocationID: invocation.invocationID,
        state: .succeeded
      )
    }
    return result
  }

  private func executeCommittedOperationAsync(
    _ invocation: OperationInvocation
  ) async throws -> JSONValue {
    let result: JSONValue
    do {
      result = try await performAsync(
        name: invocation.toolName,
        arguments: invocation.arguments,
        context: invocation.targetContext,
        bypassOperationTicket: true,
        operationLinkage: invocation.linkage
      )
    } catch {
      if let database {
        _ = try? database.finishOperationTicket(
          id: invocation.ticketID,
          invocationID: invocation.invocationID,
          state: .failed,
          failureCode: "operations.target_failed"
        )
      }
      throw error
    }
    if let database {
      _ = try database.finishOperationTicket(
        id: invocation.ticketID,
        invocationID: invocation.invocationID,
        state: .succeeded
      )
    }
    return result
  }

  private func workspaceList(context: ExecutionContext) -> JSONValue {
    let rows = workspaceOrder.compactMap { id -> JSONValue? in
      guard let workspace = workspaces[id],
        grant.capabilityIDs.contains("*") || grant.workspaceIDs.contains(id)
      else {
        return nil
      }
      return .object([
        "id": .string(workspace.id),
        "display_name": .string(workspace.displayName),
        "bookmark_stale": .bool(workspace.bookmarkIsStale),
        "selected": .bool(context.workspaceID == id),
      ])
    }
    return .object(["workspaces": .array(rows)])
  }

  private func workspaceDescribe(arguments: [String: JSONValue]) throws -> JSONValue {
    let id = try Self.requiredString("workspace_id", in: arguments)
    guard let workspace = workspaces[id] else {
      throw GatewayRuntimeError.workspaceNotFound(id)
    }
    return .object([
      "id": .string(workspace.id),
      "display_name": .string(workspace.displayName),
      "root_path": .string(workspace.rootPath),
      "bookmark_backed": .bool(workspace.bookmarkData != nil),
      "bookmark_stale": .bool(workspace.bookmarkIsStale),
      "created_at": .string(Self.iso8601(workspace.createdAt)),
      "updated_at": .string(Self.iso8601(workspace.updatedAt)),
    ])
  }

  private func route(
    descriptor: CapabilityDescriptor,
    arguments: [String: JSONValue],
    context: ExecutionContext
  ) throws -> RoutedCall {
    var cleanArguments = arguments
    let argumentWorkspaceID: String?
    if let value = cleanArguments.removeValue(forKey: "workspace_id") {
      guard let string = value.stringValue, !string.isEmpty else {
        throw Self.invalid(
          code: "workspace.invalid_id",
          message: "workspace_id must be a non-empty string."
        )
      }
      argumentWorkspaceID = string
      if descriptor.id == "workspace.describe" {
        cleanArguments["workspace_id"] = value
      }
    } else {
      argumentWorkspaceID = nil
    }
    if let argumentWorkspaceID, let contextWorkspaceID = context.workspaceID,
      argumentWorkspaceID != contextWorkspaceID
    {
      throw Self.invalid(
        code: PolicyDenialCode.workspaceDenied.rawValue,
        message: "workspace_id does not match the bound execution context."
      )
    }

    var routedContext = context
    routedContext.workspaceID = argumentWorkspaceID ?? context.workspaceID
    if routedContext.workspaceID == nil,
      descriptor.workspaceRequirement == .required,
      workspaceOrder.count == 1
    {
      routedContext.workspaceID = workspaceOrder[0]
    }
    if descriptor.workspaceRequirement == .required, routedContext.workspaceID == nil {
      throw Self.invalid(
        code: PolicyDenialCode.workspaceRequired.rawValue,
        message:
          workspaceOrder.isEmpty
          ? "Register and grant a workspace before calling this capability."
          : "An explicit workspace_id is required when multiple workspaces are registered."
      )
    }

    let registryWorkspaceID = routedContext.workspaceID ?? workspaceOrder.first
    if let registryWorkspaceID, workspaces[registryWorkspaceID] == nil {
      throw GatewayRuntimeError.workspaceNotFound(registryWorkspaceID)
    }
    return RoutedCall(
      arguments: cleanArguments,
      context: routedContext,
      registryWorkspaceID: registryWorkspaceID
    )
  }

  private func authorize(
    _ descriptor: CapabilityDescriptor,
    context: ExecutionContext
  ) throws {
    let decision = policyEvaluator.evaluate(
      capability: descriptor,
      context: context,
      grant: grant,
      registeredWorkspaceIDs: Set(workspaceOrder)
    )
    guard case .allow = decision else {
      if case .deny(let code, let message) = decision {
        throw Self.invalid(code: code.rawValue, message: message)
      }
      throw Self.invalid(code: "policy.denied", message: "The capability was denied.")
    }
    if descriptor.id.hasPrefix("shell.") && !configuration.policy.shellEnabled {
      throw Self.invalid(
        code: PolicyDenialCode.fullShellDisabled.rawValue,
        message: "Full Shell is disabled by the active gateway manifest."
      )
    }
  }

  private func isVisible(
    _ descriptor: CapabilityDescriptor,
    context: ExecutionContext
  ) -> Bool {
    guard context.profileID == grant.id else {
      return false
    }
    if !grant.allowedCallers.contains(context.caller) {
      return false
    }
    if context.caller.isRemote && descriptor.localOnly {
      return false
    }
    guard grant.capabilityIDs.contains("*") || grant.capabilityIDs.contains(descriptor.id) else {
      return false
    }
    if descriptor.risk == .fullShell {
      return grant.fullShellEnabled
        && (!descriptor.id.hasPrefix("shell.") || configuration.policy.shellEnabled)
    }
    return true
  }

  private func descriptor(named name: String) throws -> CapabilityDescriptor {
    if let tool = Self.coreTools(databaseEnabled: database != nil)
      .first(where: { $0.name == name })
    {
      return GatewayCapabilityCatalog().descriptor(for: tool)
    }
    if let firstProviderRouter {
      return try firstProviderRouter.capability(named: name)
    }
    throw GatewayToolError.unknownTool(name)
  }

  private var firstProviderRouter: GatewayProviderRouter? {
    workspaceOrder.first.flatMap { providerRouters[$0] }
  }

  private func contextForCall() -> ExecutionContext {
    var callContext = context
    callContext.requestID = UUID().uuidString
    return callContext
  }

  private func recordAudit(
    context: ExecutionContext,
    capabilityID: String,
    decision: AuditDecision,
    errorCode: String?,
    duration: Duration,
    inputDigest: String?,
    output: JSONValue?,
    operationLinkage: OperationAuditLinkage?
  ) throws {
    guard let database else {
      return
    }
    let outputData = try output.map { try Self.encoder.encode($0) }
    try database.recordAudit(
      AuditEvent(
        requestID: context.requestID,
        invocationID: operationLinkage?.invocationID,
        parentRequestID: capabilityID == "operations.commit"
          ? nil : operationLinkage?.parentRequestID,
        ticketID: operationLinkage?.ticketID,
        caller: context.caller,
        transport: context.transportTrace?.transport,
        socketConnectionID: context.transportTrace?.socketConnectionID,
        tunnelInstanceID: context.transportTrace?.tunnelInstanceID,
        tunnelProfileID: context.transportTrace?.tunnelProfileID,
        profileID: context.profileID,
        workspaceID: context.workspaceID,
        capabilityID: capabilityID,
        decision: decision,
        errorCode: errorCode,
        durationMilliseconds: Int(duration.components.seconds * 1_000)
          + Int(duration.components.attoseconds / 1_000_000_000_000_000),
        inputDigest: inputDigest,
        outputDigest: outputData.map(Self.digest),
        outputByteCount: outputData?.count,
        outputTruncated: nil
      )
    )
  }

  private func resultEnvelope(_ value: JSONValue) throws -> JSONValue {
    let data = try Self.encoder.encode(value)
    return .object([
      "content": .array([
        .object([
          "type": .string("text"),
          "text": .string(String(decoding: data, as: UTF8.self)),
        ])
      ]),
      "structuredContent": .object(["result": value]),
      "isError": .bool(false),
    ])
  }

  private static func errorEnvelope(_ error: Error) -> JSONValue {
    let code = auditErrorCode(for: error) ?? "gateway.execution_failed"
    let message =
      (error as? any LocalizedError)?.errorDescription
      ?? String(describing: error)
    let payload = JSONValue.object([
      "code": .string(code),
      "message": .string(message),
    ])
    return .object([
      "content": .array([
        .object([
          "type": .string("text"),
          "text": .string("\(code): \(message)"),
        ])
      ]),
      "structuredContent": .object(["error": payload]),
      "isError": .bool(true),
    ])
  }

  private static func attachExecutionMetadata(
    to result: JSONValue,
    context: ExecutionContext,
    capabilityID: String,
    operationLinkage: OperationAuditLinkage?
  ) -> JSONValue {
    guard var object = result.objectValue else {
      return result
    }
    var executionObject: [String: JSONValue] = [
      "request_id": .string(context.requestID),
      "caller": .string(context.caller.rawValue),
      "profile_id": .string(context.profileID.rawValue),
      "workspace_id": context.workspaceID.map(JSONValue.string) ?? .null,
      "capability_id": .string(capabilityID),
    ]
    if let transport = context.transportTrace?.transport {
      executionObject["transport"] = .string(transport)
    }
    if let socketConnectionID = context.transportTrace?.socketConnectionID {
      executionObject["socket_connection_id"] = .string(socketConnectionID)
    }
    if let tunnelInstanceID = context.transportTrace?.tunnelInstanceID {
      executionObject["tunnel_instance_id"] = .string(tunnelInstanceID)
    }
    if let tunnelProfileID = context.transportTrace?.tunnelProfileID {
      executionObject["tunnel_profile_id"] = .string(tunnelProfileID)
    }
    if let invocationID = operationLinkage?.invocationID {
      executionObject["invocation_id"] = .string(invocationID)
    }
    if capabilityID != "operations.commit",
      let parentRequestID = operationLinkage?.parentRequestID
    {
      executionObject["parent_request_id"] = .string(parentRequestID)
    }
    if let ticketID = operationLinkage?.ticketID {
      executionObject["ticket_id"] = .string(ticketID)
    }
    let execution = JSONValue.object(executionObject)

    if var structuredContent = object["structuredContent"]?.objectValue {
      if capabilityID == "operations.commit",
        let targetExecution = structuredContent["gateway_execution"]
      {
        structuredContent["target_execution"] = targetExecution
      }
      structuredContent["gateway_execution"] = execution
      object["structuredContent"] = .object(structuredContent)
    }

    var metadata = object["_meta"]?.objectValue ?? [:]
    if capabilityID == "operations.commit",
      let targetExecution = metadata["computer_mcp"]
    {
      metadata["computer_mcp_target"] = targetExecution
    }
    metadata["computer_mcp"] = execution
    object["_meta"] = .object(metadata)
    return .object(object)
  }

  private static func coreTools(databaseEnabled: Bool) -> [MCPTool] {
    var tools = [
      MCPTool(
        name: "workspace.list",
        description: "List workspaces registered and granted to the active profile.",
        inputSchema: .object(["type": .string("object"), "additionalProperties": .bool(false)]),
        annotations: .init(
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false
        )
      ),
      MCPTool(
        name: "workspace.describe",
        description: "Describe one registered workspace by stable workspace_id.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "workspace_id": .object([
              "type": .string("string"),
              "description": .string("Stable workspace id returned by workspace.list."),
            ])
          ]),
          "required": .array([.string("workspace_id")]),
          "additionalProperties": .bool(false),
        ]),
        annotations: .init(
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false
        )
      ),
      MCPTool(
        name: "policy.probe",
        description:
          "Evaluate whether the active Gateway profile and workspace would authorize one capability without executing it. Policy denials return their stable error code and are audited.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "capability_id": .object([
              "type": .string("string"),
              "description": .string("Exact Gateway capability id to evaluate."),
            ]),
            "arguments": .object([
              "type": .string("object"),
              "description": .string(
                "Optional target arguments used only for workspace routing and policy evaluation."
              ),
              "additionalProperties": .bool(true),
            ]),
            "workspace_id": .object([
              "type": .string("string"),
              "description": .string("Optional stable workspace id for the policy context."),
            ]),
          ]),
          "required": .array([.string("capability_id")]),
          "additionalProperties": .bool(false),
        ]),
        annotations: .init(
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: false
        )
      ),
    ]
    if databaseEnabled {
      tools.append(
        MCPTool(
          name: "operations.prepare",
          description:
            "Prepare a short-lived single-use ticket for an irreversible gateway operation without executing it.",
          inputSchema: operationSchema(commit: false),
          annotations: .init(
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: false
          )
        )
      )
      tools.append(
        MCPTool(
          name: "operations.commit",
          description:
            "Execute exactly the irreversible operation and arguments bound to a prepared ticket.",
          inputSchema: operationSchema(commit: true),
          annotations: .init(
            readOnlyHint: false,
            destructiveHint: true,
            idempotentHint: false,
            openWorldHint: false
          )
        )
      )
    }
    return tools
  }

  private static func operationSchema(commit: Bool) -> JSONValue {
    var properties: [String: JSONValue] = [
      "tool": .object(["type": .string("string")]),
      "arguments": .object([
        "type": .string("object"),
        "additionalProperties": .bool(true),
      ]),
      "workspace_id": .object(["type": .string("string")]),
    ]
    var required = ["tool", "arguments"]
    if commit {
      properties["ticket_id"] = .object(["type": .string("string")])
      required.insert("ticket_id", at: 0)
    } else {
      properties["ttl_ms"] = .object([
        "type": .string("integer"),
        "minimum": .number(1_000),
        "maximum": .number(300_000),
      ])
      properties["state_digest"] = .object(["type": .string("string")])
    }
    return .object([
      "type": .string("object"),
      "properties": .object(properties),
      "required": .array(required.map(JSONValue.string)),
      "additionalProperties": .bool(false),
    ])
  }

  private static func addWorkspaceID(
    to tool: MCPTool,
    descriptor: CapabilityDescriptor
  ) -> MCPTool {
    guard descriptor.workspaceRequirement != .none,
      case .object(var schema) = tool.inputSchema
    else {
      return tool
    }
    var properties = schema["properties"]?.objectValue ?? [:]
    properties["workspace_id"] = .object([
      "type": .string("string"),
      "description": .string("Stable workspace id returned by workspace.list."),
    ])
    schema["properties"] = .object(properties)
    return MCPTool(
      name: tool.name,
      title: tool.title,
      description: tool.description,
      inputSchema: .object(schema),
      outputSchema: tool.outputSchema,
      annotations: tool.annotations,
      meta: tool.meta
    )
  }

  private func currentStateDigest(
    tool: String,
    arguments: [String: JSONValue],
    context: ExecutionContext
  ) throws -> String? {
    if tool == "codex.worktree.remove.perform",
      let id = arguments["managed_worktree_id"]?.stringValue,
      let worktree = try database?.codexManagedWorktree(id: id),
      worktree.sourceWorkspaceID == context.workspaceID
    {
      let data = try Self.encoder.encode(
        JSONValue.object([
          "tool": .string(tool),
          "managed_worktree": worktree.json,
        ])
      )
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    guard let workspaceID = context.workspaceID,
      let rootURL = workspaceAccesses[workspaceID]?.rootURL.standardizedFileURL
    else {
      return nil
    }

    var paths = Self.operationStatePaths(in: arguments)
    if tool.hasPrefix("git.") {
      paths.formUnion([".git/HEAD", ".git/index", ".git/refs"])
    }
    if paths.isEmpty {
      paths.insert(".")
    }

    var records: [JSONValue] = []
    for path in paths.sorted() {
      let url = try Self.operationStateURL(path: path, rootURL: rootURL)
      records.append(contentsOf: try Self.operationStateRecords(url: url, rootURL: rootURL))
    }
    let data = try Self.encoder.encode(
      JSONValue.object([
        "tool": .string(tool),
        "records": .array(records),
      ])
    )
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func operationStatePaths(
    in arguments: [String: JSONValue]
  ) -> Set<String> {
    let pathKeys: Set<String> = [
      "archive_path", "destination", "destinations", "output_path", "path", "paths",
      "source", "sources", "target", "targets",
    ]
    var result = Set<String>()
    for (key, value) in arguments where pathKeys.contains(key) || key.hasSuffix("_path") {
      if let path = value.stringValue, !path.isEmpty {
        result.insert(path)
      }
      for path in value.arrayValue?.compactMap(\.stringValue) ?? [] where !path.isEmpty {
        result.insert(path)
      }
    }
    return result
  }

  private static func operationStateURL(path: String, rootURL: URL) throws -> URL {
    do {
      return try WorkspacePathResolver.resolve(path, relativeTo: rootURL)
    } catch {
      throw invalid(
        code: "operations.state_path_escape",
        message: "Cannot bind operation state outside the registered workspace."
      )
    }
  }

  private static func operationStateRecords(url: URL, rootURL: URL) throws -> [JSONValue] {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else {
      return [
        .object([
          "path": .string(operationRelativePath(url, rootURL: rootURL)),
          "exists": .bool(false),
        ])
      ]
    }

    var urls = [url]
    var isDirectory = ObjCBool(false)
    var enumerationError: Error?
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { _, error in
          enumerationError = error
          return false
        }
      )
    {
      for case let childURL as URL in enumerator {
        urls.append(childURL)
        guard urls.count <= 20_000 else {
          throw invalid(
            code: "operations.state_too_large",
            message: "Operation state binding exceeds 20,000 filesystem entries."
          )
        }
      }
    }
    if let enumerationError {
      throw invalid(
        code: "operations.state_unreadable",
        message:
          "Could not enumerate operation target state: \(enumerationError.localizedDescription)"
      )
    }

    var totalRegularFileBytes = 0
    var records: [JSONValue] = []
    for itemURL in urls.sorted(by: { $0.path < $1.path }) {
      let attributes = try fileManager.attributesOfItem(atPath: itemURL.path)
      let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? "unknown"
      let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
      let modified =
        (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        ?? 0
      var record: [String: JSONValue] = [
        "path": .string(operationRelativePath(itemURL, rootURL: rootURL)),
        "exists": .bool(true),
        "type": .string(type),
        "size": .number(Double(size)),
        "modified_at": .number(modified),
      ]
      if type == FileAttributeType.typeRegular.rawValue {
        totalRegularFileBytes += size
        guard size <= 512 * 1_024 * 1_024,
          totalRegularFileBytes <= 1_024 * 1_024 * 1_024
        else {
          throw invalid(
            code: "operations.state_too_large",
            message:
              "Operation state binding exceeds the 512 MiB per-file or 1 GiB aggregate limit."
          )
        }
        record["content_sha256"] = .string(try operationFileDigest(itemURL))
      } else if type == FileAttributeType.typeSymbolicLink.rawValue {
        record["destination"] = .string(
          try fileManager.destinationOfSymbolicLink(atPath: itemURL.path)
        )
      }
      records.append(.object(record))
    }
    return records
  }

  private static func operationFileDigest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func operationRelativePath(_ url: URL, rootURL: URL) -> String {
    if url.path == rootURL.path {
      return "."
    }
    return String(url.path.dropFirst(rootURL.path.count + 1))
  }

  private static func principalID(for context: ExecutionContext) -> String {
    let value = "\(context.caller.rawValue):\(context.profileID.rawValue)"
    return SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func operationLinkageFromArguments(
    name: String,
    arguments: [String: JSONValue]
  ) -> OperationAuditLinkage? {
    guard name == "operations.commit",
      let ticketID = arguments["ticket_id"]?.stringValue,
      !ticketID.isEmpty
    else {
      return nil
    }
    return OperationAuditLinkage(ticketID: ticketID)
  }

  private static func operationTicketError(_ error: Error) -> GatewayToolError {
    guard let databaseError = error as? GatewayDatabaseError else {
      return invalid(
        code: "operations.ticket_lifecycle_failed",
        message: error.localizedDescription
      )
    }
    switch databaseError {
    case .operationTicketUnknown:
      return invalid(code: "operations.ticket_unknown", message: databaseError.localizedDescription)
    case .operationTicketPrincipalMismatch:
      return invalid(
        code: "operations.ticket_context_mismatch",
        message: databaseError.localizedDescription
      )
    case .operationTicketExpired:
      return invalid(
        code: "operations.ticket_expired_or_used",
        message: databaseError.localizedDescription
      )
    case .operationTicketUnavailable:
      return invalid(
        code: "operations.ticket_expired_or_used",
        message: databaseError.localizedDescription
      )
    case .invalidOperationTicketTransition, .invalidStoredValue:
      return invalid(
        code: "operations.ticket_lifecycle_failed",
        message: databaseError.localizedDescription
      )
    }
  }

  private static func inputDigest(
    tool: String,
    arguments: [String: JSONValue]
  ) throws -> String {
    let data = try encoder.encode(
      JSONValue.object([
        "tool": .string(tool),
        "arguments": .object(arguments),
      ])
    )
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func requiredString(
    _ name: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard let value = object[name]?.stringValue, !value.isEmpty else {
      throw invalid(
        code: "arguments.missing",
        message: "Missing required string argument: \(name)"
      )
    }
    return value
  }

  private static func invalid(code: String, message: String) -> GatewayToolError {
    .invalidArguments("[\(code)] \(message)")
  }

  static func auditDecision(for error: Error) -> AuditDecision {
    if let computerUseError = error as? ComputerUseGatewayProviderError,
      case .service(.permissionRequired) = computerUseError
    {
      return .denied
    }

    guard case .invalidArguments(let message) = error as? GatewayToolError else {
      return .failed
    }
    let deniedPrefixes = [
      "[policy.",
      "[operations.state_path_escape]",
      "[operations.ticket_",
      "[codex.app.override_denied]",
      "[codex.app.danger_full_access_denied]",
      "[codex.app.workspace_override_denied]",
      "[mcp.tool_not_approved]",
    ]
    return deniedPrefixes.contains(where: message.hasPrefix) ? .denied : .failed
  }

  static func auditErrorCode(for error: Error) -> String? {
    if let computerUseError = error as? ComputerUseGatewayProviderError {
      return computerUseError.code
    }
    guard let gatewayError = error as? GatewayToolError else {
      return nil
    }
    switch gatewayError {
    case .unknownTool:
      return "gateway.tool_unknown"
    case .unknownCLI:
      return "cli.provider_unknown"
    case .unknownMCPServer:
      return "mcp.server_unknown"
    case .disabled:
      return "gateway.capability_disabled"
    case .executionFailed:
      return "gateway.execution_failed"
    case .invalidArguments(let message):
      guard message.first == "[",
        let end = message.firstIndex(of: "]")
      else {
        return "gateway.invalid_arguments"
      }
      return String(message[message.index(after: message.startIndex)..<end])
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

private struct PreparedOperation {
  var ticketID: String
  var result: JSONValue
}

private struct OperationAuditLinkage {
  var ticketID: String
  var invocationID: String?
  var parentRequestID: String?

  init(
    ticketID: String,
    invocationID: String? = nil,
    parentRequestID: String? = nil
  ) {
    self.ticketID = ticketID
    self.invocationID = invocationID
    self.parentRequestID = parentRequestID
  }
}

private struct OperationInvocation {
  var ticketID: String
  var invocationID: String
  var parentRequestID: String
  var toolName: String
  var arguments: [String: JSONValue]
  var targetContext: ExecutionContext

  var linkage: OperationAuditLinkage {
    OperationAuditLinkage(
      ticketID: ticketID,
      invocationID: invocationID,
      parentRequestID: parentRequestID
    )
  }
}

private struct RoutedCall {
  var arguments: [String: JSONValue]
  var context: ExecutionContext
  var registryWorkspaceID: String?
}

private final class GatewayRuntimeShutdownState: @unchecked Sendable {
  private let lock = NSLock()
  private var started = false

  func begin() -> Bool {
    lock.withLock {
      guard !started else { return false }
      started = true
      return true
    }
  }
}

package enum GatewayRuntimeError: Error, LocalizedError, Equatable {
  case noWorkspaces
  case duplicateWorkspaceID(String)
  case workspaceNotFound(String)

  package var errorDescription: String? {
    switch self {
    case .noWorkspaces:
      return "No registered workspace is available."
    case .duplicateWorkspaceID(let id):
      return "Duplicate registered workspace id: \(id)"
    case .workspaceNotFound(let id):
      return "Unknown registered workspace id: \(id)"
    }
  }
}
