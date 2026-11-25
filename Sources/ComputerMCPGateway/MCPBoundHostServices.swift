import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPProcess
import ComputerMCPToolKit
import ComputerMCPWorktrees
import Crypto
import Foundation
import MCP

/// Private `projects-v1` services on the inherited MCP channel. Durable authority stays
/// with the host; an active forwarded invocation, not plugin-supplied identity, selects
/// scope. The host lifecycle library performs every Git effect.
actor MCPBoundHostServices {
  private let database: GatewayDatabase
  private let directory: MCPHostToolDirectory
  private let context: MCPHostContext
  private let origin: String
  private let operations: HostOperationStore
  private let canonicalRoot: String
  private var closed = false

  init(
    database: GatewayDatabase, directory: MCPHostToolDirectory, context: MCPHostContext,
    origin: String
  ) {
    self.database = database
    self.directory = directory
    self.context = context
    self.origin = origin
    operations = HostOperationStore(connection: database.connection)
    canonicalRoot =
      URL(fileURLWithPath: context.launchMetadata.project.rootPath).standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }

  nonisolated static let tools: [MCP.Tool] = {
    let identifier: JSONValue = .object([
      "type": .string("string"), "minLength": .number(36), "maxLength": .number(36),
    ])
    let text: JSONValue = .object([
      "type": .string("string"), "minLength": .number(1), "maxLength": .number(1024),
    ])
    let nullableText: JSONValue = .object([
      "anyOf": .array([text, .object(["type": .string("null")])])
    ])
    func tool(
      _ name: String, _ description: String, _ properties: [String: JSONValue],
      _ required: [String], read: Bool = false, destructive: Bool = false
    ) -> MCP.Tool {
      let schema = JSONValue.object([
        "type": .string("object"), "properties": .object(properties),
        "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false),
      ])
      return MCP.Tool(
        name: name, description: description, inputSchema: schema.sdkValue,
        annotations: .init(
          readOnlyHint: read, destructiveHint: destructive, idempotentHint: false,
          openWorldHint: false),
        outputSchema: .object([
          "type": .string("object"), "properties": .object(["result": .object([:])]),
          "required": .array([.string("result")]), "additionalProperties": .bool(false),
        ]))
    }
    return [
      tool(
        "host.invocations.describe",
        "Inspect exactly one of this channel's invocation or a durable host operation.",
        ["invocation_id": identifier, "operation_id": identifier], [], read: true),
      tool(
        "host.projects.worktree_add",
        "Create a host worktree for the live projects.provision invocation's reserved operation.",
        [
          "invocation_id": identifier, "operation_id": identifier, "name": text,
          "branch": nullableText, "base": nullableText,
        ], ["invocation_id", "operation_id", "name"]),
      tool(
        "host.projects.worktree_list",
        "List host and foreign worktrees for the live projects.list invocation.",
        ["invocation_id": identifier], ["invocation_id"], read: true),
      tool(
        "host.projects.worktree_remove",
        "Remove the selected host worktree for the live projects.remove invocation's reserved operation.",
        [
          "invocation_id": identifier, "operation_id": identifier,
          "force": .object(["type": .string("boolean")]),
        ], ["invocation_id", "operation_id"], destructive: true),
      tool(
        "host.diagnostics.snapshot",
        "Return bounded audit metadata for the currently executing diagnostic request's immutable scope.",
        [
          "limit": .object([
            "type": .string("integer"), "minimum": .number(1), "maximum": .number(1000),
          ])
        ], ["limit"], read: true),
    ]
  }()

  private struct Reply {
    var result: JSONValue
    var isError = false
    var errorCode: String?
  }

  /// Audit attribution for one call. Calls may interleave across lifecycle suspension.
  private final class Scope: @unchecked Sendable {
    var invocation: MCPHostInvocation?
    var operationLease: GatewayOwnedWork.Lease?
  }

  func call(name: String, arguments: [String: JSONValue]) async throws -> MCP.CallTool.Result {
    // The private services borrow the live call's authorizations.
    let lifetime = GatewayHostCallbackLifetime(revoke: { _ in })
    return try await lifetime.run {
      try await self.dispatch(name: name, arguments: arguments, lifetime: lifetime)
    }
  }

  private func dispatch(
    name: String, arguments: [String: JSONValue], lifetime: GatewayHostCallbackLifetime
  ) async throws -> MCP.CallTool.Result {
    try Task.checkCancellation()
    guard !closed else { throw MCPError.connectionClosed }
    let started = ContinuousClock.now
    let scope = Scope()
    defer { scope.operationLease?.finish() }
    guard let tool = Self.tools.first(where: { $0.name == name }) else {
      // Retired and unknown methods are not part of this contract under any spelling.
      return refusal(
        code: "host.unknown_method",
        message: "The method is not part of the \(MCPHostServiceContract.identifier) contract.",
        name: name, arguments: arguments, started: started, scope: scope)
    }
    do {
      guard let properties = tool.inputSchema.objectValue?["properties"]?.objectValue,
        Set(arguments.keys).isSubset(of: Set(properties.keys)),
        (tool.inputSchema.objectValue?["required"]?.arrayValue ?? []).allSatisfy({
          $0.stringValue.map { arguments[$0] != nil } ?? false
        }), try JSONEncoder().encode(arguments).count <= 65_536
      else {
        throw MCPHostServiceError.denied("Host service arguments do not match the declared schema.")
      }
      try validateSourceIdentity()
      let reply: Reply
      switch name {
      case "host.invocations.describe": reply = try describe(arguments, scope: scope)
      case "host.projects.worktree_add":
        reply = try await mutate(.projectProvision, arguments, scope: scope, lifetime: lifetime)
      case "host.projects.worktree_remove":
        reply = try await mutate(.projectRemoval, arguments, scope: scope, lifetime: lifetime)
      case "host.projects.worktree_list": reply = try await list(arguments, scope: scope)
      default: reply = Reply(result: try snapshot(arguments, scope: scope))
      }
      let payload = JSONValue.object(["result": reply.result])
      guard try JSONEncoder().encode(payload).count <= 524_288 else {
        throw MCPHostServiceError.denied(
          "Host result exceeds its byte bound; request a smaller limit.")
      }
      try audit(
        name: name, decision: reply.isError ? .failed : .allowed, errorCode: reply.errorCode,
        start: started, arguments: arguments, result: payload, scope: scope)
      return try .init(content: [], structuredContent: payload.sdkValue, isError: reply.isError)
    } catch {
      let message = SensitiveValueRedactor.redactString(
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription,
        maximumCharacters: 1024)
      return refusal(
        code: MCPHostOperations.code(for: error), message: message, name: name,
        arguments: arguments, started: started, scope: scope)
    }
  }

  var cleanupConfirmed: Bool { closed }

  func close() { closed = true }

  private func refusal(
    code: String, message: String, name: String, arguments: [String: JSONValue],
    started: ContinuousClock.Instant, scope: Scope
  ) -> MCP.CallTool.Result {
    try? audit(
      name: name, decision: .denied, errorCode: code, start: started, arguments: arguments,
      result: nil, scope: scope)
    return .init(
      content: [.text(text: code + ": " + message, annotations: nil, _meta: nil)],
      structuredContent: .object([
        "error": .object(["code": .string(code), "message": .string(message)])
      ]), isError: true)
  }

  private var owner: MCPHostServiceOwner {
    .init(
      projectID: context.launchMetadata.project.id,
      profileID: context.launchMetadata.profileID.rawValue,
      caller: context.launchMetadata.caller.rawValue,
      transport: context.launchMetadata.transportTrace?.transport,
      socketConnectionID: context.launchMetadata.transportTrace?.socketConnectionID,
      tunnelInstanceID: context.launchMetadata.transportTrace?.tunnelInstanceID,
      tunnelProfileID: context.launchMetadata.transportTrace?.tunnelProfileID,
      principalID: context.launchMetadata.principalID)
  }

  private func validateSourceIdentity() throws {
    guard
      URL(fileURLWithPath: context.launchMetadata.project.rootPath).standardizedFileURL
        .resolvingSymlinksInPath()
        .path == canonicalRoot
    else {
      throw MCPHostServiceError.denied("The source directory identity changed.")
    }
  }

  private func invocation(
    _ action: MCPHostServiceAction, scope: Scope,
    matching: (MCPHostInvocation) -> Bool = { _ in true }
  ) throws -> MCPHostInvocation {
    let invocation = try directory.resolve().requireHostInvocation(
      projectID: context.launchMetadata.project.id, origin: origin,
      action: action, providerExecution: context.providerExecution, matching: matching)
    try requireCall(invocation)
    scope.invocation = invocation
    return invocation
  }

  private func requireCall(_ invocation: MCPHostInvocation) throws {
    if let execution = context.providerExecution {
      try execution.validateProviderLaunch()
      guard let admitted = invocation.providerExecution,
        try MCPProviderSessionAuthority(admitted) == MCPProviderSessionAuthority(execution)
      else {
        throw MCPHostServiceError.denied("The invocation belongs to another provider authority.")
      }
      try admitted.validateProviderLaunch()
    }
    try directory.requireRecord(invocation)
    guard let admission = invocation.admission,
      admission.verifiedClientID == context.verifiedPrincipalID,
      admission.action?.reservesOperation != true || admission.verifiedClientID?.isEmpty == false,
      admission.projectID == context.launchMetadata.project.id,
      admission.profileID == context.launchMetadata.profileID,
      admission.caller == context.launchMetadata.caller,
      admission.reference.serverID == origin
    else { throw MCPHostServiceError.denied("The live call does not match this host channel.") }
  }

  private func snapshot(_ args: [String: JSONValue], scope: Scope) throws -> JSONValue {
    guard let limit = args["limit"]?.intValue, (1...1000).contains(limit) else {
      throw MCPHostServiceError.denied("Diagnostic limit must be 1...1000.")
    }
    _ = try invocation(.diagnosticsSnapshot, scope: scope) {
      ($0.arguments["limit"]?.intValue ?? 100) >= limit
    }
    var execution = ExecutionContext(
      caller: context.launchMetadata.caller, profileID: context.launchMetadata.profileID,
      transportTrace: context.launchMetadata.transportTrace,
      trustedPrincipalID: context.verifiedPrincipalID)
    execution.projectID = context.launchMetadata.project.id
    let audits = try database.hostDiagnosticAudits(context: execution, limit: limit)
    return .object([
      "owner": try JSONValue.encoded(owner),
      "recent_tool_audits": .array(
        audits.map { audit in
          .object([
            "id": .string(audit.id), "request_id": .string(audit.requestID),
            "project_id": .string(context.launchMetadata.project.id),
            "profile_id": .string(audit.profileID.rawValue),
            "caller": .string(audit.caller.rawValue),
            "capability_id": .string(audit.capabilityID),
            "decision": .string(audit.decision.rawValue),
            "occurred_at": .string(ISO8601DateFormatter().string(from: audit.occurredAt)),
            "mcp_request_id": audit.mcpRequestID.map(JSONValue.string) ?? .null,
            "parent_request_id": audit.parentRequestID.map(JSONValue.string) ?? .null,
            "ticket_id": audit.ticketID.map(JSONValue.string) ?? .null,
            "invocation_id": audit.invocationID.map(JSONValue.string) ?? .null,
            "transport": audit.transport.map(JSONValue.string) ?? .null,
            "socket_connection_id": audit.socketConnectionID.map(JSONValue.string) ?? .null,
            "tunnel_instance_id": audit.tunnelInstanceID.map(JSONValue.string) ?? .null,
            "tunnel_profile_id": audit.tunnelProfileID.map(JSONValue.string) ?? .null,
            "error_code": audit.errorCode.map(JSONValue.string) ?? .null,
            "duration_milliseconds": audit.durationMilliseconds.map { .integer(Int64($0)) }
              ?? .null,
            "output_byte_count": audit.outputByteCount.map { .integer(Int64($0)) } ?? .null,
            "output_truncated": audit.outputTruncated.map(JSONValue.bool) ?? .null,
            "input_digest": audit.inputDigest.map(JSONValue.string) ?? .null,
            "output_digest": audit.outputDigest.map(JSONValue.string) ?? .null,
          ])
        }),
    ])
  }

  private static func identifier(_ key: String, in args: [String: JSONValue]) throws -> UUID? {
    guard let value = args[key] else { return nil }
    guard let text = value.stringValue, let id = UUID(uuidString: text) else {
      throw MCPHostServiceError.denied("\(key) must be a host UUID.")
    }
    return id
  }

  private func describe(_ args: [String: JSONValue], scope: Scope) throws -> Reply {
    let invocationID = try Self.identifier("invocation_id", in: args)
    let operationID = try Self.identifier("operation_id", in: args)
    guard (invocationID == nil) != (operationID == nil) else {
      throw MCPHostServiceError.denied("Provide exactly one of invocation_id or operation_id.")
    }
    if let invocationID {
      let runtime = try directory.resolve()
      let active: MCPHostInvocation
      do {
        active = try runtime.requireHostInvocation(
          projectID: context.launchMetadata.project.id, origin: origin, id: invocationID,
          providerExecution: context.providerExecution)
      } catch {
        // After the live invocation ends only its operation projection survives.
        guard let operation = try operations.operation(invocationID: invocationID) else {
          throw error
        }
        return Reply(result: MCPHostOperations.envelope(try inspect(operation, scope: scope)))
      }
      try requireCall(active)
      scope.invocation = active
      return Reply(result: try projection(active, runtime: runtime))
    }
    guard let operation = try operations.operation(id: operationID!) else {
      throw MCPHostOperationError.notFound
    }
    return Reply(result: MCPHostOperations.envelope(try inspect(operation, scope: scope)))
  }

  private func projection(_ active: MCPHostInvocation, runtime: GatewayRuntime) throws
    -> JSONValue
  {
    let plugin = runtime.pluginOrigins[.init(kind: .mcp, id: origin)]
    let operation = try operations.operation(invocationID: active.id)
    return .object([
      "format_version": .integer(1), "invocation_id": .string(active.id.uuidString),
      "generation_id": .string(context.launchMetadata.runtimeID.uuidString),
      "registration_id": .string(origin),
      "plugin_id": plugin.map { .string($0.pluginID) } ?? .null,
      "contribution_id": plugin.map { .string($0.componentID) } ?? .null,
      "principal_id": .string(active.context.principalID),
      "profile_id": .string(active.context.profileID.rawValue),
      "caller": .string(active.context.caller.rawValue),
      "project_id": .string(context.launchMetadata.project.id),
      "request_id": .string(active.context.requestID),
      "authorization_revision": .integer(active.authorizationRevision),
      "capability_id": .string(active.upstreamName), "tool": .string(active.reference.toolName),
      "risk": .string(active.admittedCapability.risk.rawValue),
      "host_action": active.admittedCapability.hostServiceAction.map { .string($0.rawValue) }
        ?? .null,
      "arguments_digest": .string(try MCPHostInvocation.argumentsDigest(active.arguments)),
      "ticket_id": .null,
      "operation": operation.map(MCPHostOperations.envelope) ?? .null,
    ])
  }

  /// Operation inspection never replays effects. It needs a currently authorized live
  /// call on this channel from the same verified client and provider, in the captured
  /// source or the surviving selected project, and current source Project write.
  private func inspect(_ operation: HostOperationRecord, scope: Scope) throws
    -> HostOperationRecord
  {
    let admission = operation.binding.admission
    let projectID = context.launchMetadata.project.id
    let runtime = try directory.resolve()
    let plugin = runtime.pluginOrigins[.init(kind: .mcp, id: origin)]
    guard admission.reference.serverID == origin,
      let client = admission.verifiedClientID, client == context.verifiedPrincipalID,
      admission.actingPrincipal
        == .plugin(plugin.map { .package($0.pluginID) } ?? .localServer(origin)),
      operation.binding.pluginID == plugin?.pluginID,
      operation.binding.contributionID == plugin?.componentID,
      projectID == admission.sourceProjectID || projectID == admission.projectID,
      let source = try database.project(id: admission.sourceProjectID),
      source.createdAt == operation.binding.sourceRegisteredAt
    else { throw MCPHostOperationError.notFound }
    if projectID != admission.sourceProjectID {
      guard try database.project(id: projectID)?.createdAt == operation.binding.projectRegisteredAt
      else { throw MCPHostOperationError.notFound }
    }
    let live = directory.active(
      projectID: projectID, origin: origin, includingRetainedWork: true,
      provider: context.providerExecution
    ).filter { $0.admission?.verifiedClientID == client }
    guard let carrier = live.first else {
      throw MCPHostServiceError.denied("Inspection requires a live call on this channel.")
    }
    let current = try runtime.requireHostInvocation(
      projectID: projectID, origin: origin, id: carrier.id,
      providerExecution: context.providerExecution)
    try requireCall(current)
    try current.providerExecution?.validateProviderLaunch()
    scope.invocation = current
    guard let clientID = current.admission?.authorizationID,
      let provider = current.providerExecution?.provider
    else { throw MCPHostOperationError.notFound }
    let permitted = try runtime.permissionRuntime.store.transactionWithDatabase { _, ledger in
      // Inspection acquires no authority and cannot consume a retry or create a request.
      var evaluation = ledger
      for id in [clientID, provider.providerAuthorization.id] {
        do {
          try evaluation.checkProjectWriteAuthority(
            id, projectID: admission.sourceProjectID,
            connectionID: id == clientID ? current.context.controlSession?.id : nil, now: Date())
        } catch { return false }
      }
      return true
    }
    guard permitted else { throw MCPHostOperationError.notFound }
    return operation
  }

  private func mutate(
    _ action: MCPHostServiceAction, _ args: [String: JSONValue], scope: Scope,
    lifetime: GatewayHostCallbackLifetime
  ) async throws -> Reply {
    guard let invocationID = try Self.identifier("invocation_id", in: args),
      let operationID = try Self.identifier("operation_id", in: args)
    else {
      throw MCPHostServiceError.denied("Lifecycle calls require host invocation and operation IDs.")
    }
    var lifecycle = args
    lifecycle.removeValue(forKey: "invocation_id")
    lifecycle.removeValue(forKey: "operation_id")
    var requested = try MCPHostOperations.normalizedArguments(action, lifecycle)
    let active = try invocation(action, scope: scope) { $0.id == invocationID }
    guard let operation = try operations.operation(id: operationID) else {
      throw MCPHostOperationError.notFound
    }
    if action == .projectProvision {
      for field in ["branch", "base"] where lifecycle[field] == nil || lifecycle[field] == .null {
        requested[field] = operation.binding.arguments[field]
      }
    }
    // The admission binds the full dispatched argument digest; the normalized fields
    // are the captured selection the callback must repeat exactly.
    guard operation.binding.admission == active.admission, operation.binding.action == action,
      operation.binding.arguments == requested
    else {
      throw MCPHostOperationError.conflict(
        "The operation's identity, arguments or captured scope do not match this call.")
    }
    // Repeated callbacks report the recorded state and never start or resume work.
    guard operation.state == .reserved else { return reply(operation) }
    let runtime = try directory.resolve()
    guard let service = context.worktrees as? GatewayWorktreeService,
      let sourceID = active.admission?.sourceProjectID
    else { throw MCPHostServiceError.denied("Durable lifecycle services are unavailable.") }
    let authorized: GatewayWorktreeInvocation
    let claimed: (record: HostOperationRecord, claimed: Bool)
    do {
      guard try database.project(id: sourceID)?.createdAt == operation.binding.sourceRegisteredAt
      else { throw WorktreeError.identityChanged("Source registration changed.") }
      // The reservation bound an admitted basis; the claim rechecks it and admits nothing.
      authorized = try Self.callAuthority(active, action: action, service: service)
      scope.operationLease = try runtime.ownedWork.admitInvocation(
        projectID: context.launchMetadata.project.id, resourceID: operationID.uuidString)
      // The claim and channel cancellation share a gate. After the claim, the
      // callback receiver must be able to leave so the channel can retire its writer.
      claimed = try lifetime.claimOperation {
        try runtime.withHostMutation(active) { host in
          try database.withHostAuthority(host) { sql in
            try HostOperationStore.claim(operationID, in: sql)
          }
        }
      }
    } catch {
      // The reservation cannot begin under changed scope or expired authority.
      let failed = try operations.finish(
        operationID, from: [.reserved], to: .failed, error: MCPHostOperations.failure(error))
      return reply(failed)
    }
    guard claimed.claimed else { return reply(claimed.record) }
    let effect: GitWorktreeOperation =
      action == .projectProvision
      ? .add(
        name: requested["name"]!.stringValue!, branch: requested["branch"]?.stringValue,
        base: requested["base"]?.stringValue)
      : .remove(force: requested["force"]?.boolValue ?? false)
    let store = operations
    let fallback = claimed.record
    // Run the synchronous Git effect off the actor so the channel can close during drain.
    let settled = await Task.detached { () -> Result<HostOperationRecord, any Error> in
      Result {
        try Self.run(
          effect, operationID: operationID, lifecycle: authorized, service: service,
          store: store, fallback: fallback)
      }
    }.value
    return reply(try settled.get())
  }

  private static func run(
    _ effect: GitWorktreeOperation, operationID: UUID, lifecycle: GatewayWorktreeInvocation,
    service: GatewayWorktreeService, store: HostOperationStore,
    fallback: HostOperationRecord
  ) throws -> HostOperationRecord {
    do {
      let outcome = try InvocationExecution.$current.withValue(lifecycle) {
        try service.perform(effect, operationID: operationID)
      }
      switch outcome {
      case .created(let result, let worktreeID):
        return try store.finish(
          operationID, from: [.running], to: .completed,
          result: MCPHostOperations.created(result, worktreeID: worktreeID))
      case .removed(let result, let worktreeID):
        return try store.finish(
          operationID, from: [.running], to: .completed,
          result: MCPHostOperations.removed(result, worktreeID: worktreeID))
      case .listed, .merged, .deletedBranch:
        throw MCPHostServiceError.denied("The lifecycle returned an unexpected outcome.")
      }
    } catch {
      let current = try store.operation(id: operationID) ?? fallback
      return try MCPHostOperations.settle(
        current, outcome: MCPHostOperations.journalOutcome(current, database: service.database),
        cause: MCPHostOperations.failure(error), store: store)
    }
  }

  private func reply(_ operation: HostOperationRecord) -> Reply {
    Reply(
      result: MCPHostOperations.envelope(operation),
      isError: operation.state == .failed || operation.state == .recoveryRequired,
      errorCode: operation.error?.code)
  }

  private func list(_ args: [String: JSONValue], scope: Scope) async throws -> Reply {
    guard let invocationID = try Self.identifier("invocation_id", in: args) else {
      throw MCPHostServiceError.denied("A host invocation identity is required.")
    }
    let active = try invocation(.projectList, scope: scope) { $0.id == invocationID }
    guard case .listed(let items) = try await list(active)
    else { throw MCPHostServiceError.denied("The lifecycle returned an unexpected outcome.") }
    return Reply(result: MCPHostOperations.inventory(items))
  }

  /// Listing reads under the live call's authorization and the provider's own.
  private func list(_ invocation: MCPHostInvocation) async throws -> GatewayWorktreeOutcome {
    guard let service = context.worktrees as? GatewayWorktreeService,
      let action = invocation.admission?.action
    else { throw MCPHostServiceError.denied("Durable lifecycle services are unavailable.") }
    let lifecycle = try Self.callAuthority(invocation, action: action, service: service)
    return try await Task.detached {
      try InvocationExecution.$current.withValue(lifecycle) { try service.perform(.list) }
    }.value
  }

  /// Lifecycle phases authorize through the call's own authorizations: the delegating
  /// client's call authorization and the provider execution's. Each phase rechecks them,
  /// and only an invalidation of either ends a claimed effect.
  private static func callAuthority(
    _ invocation: MCPHostInvocation, action: MCPHostServiceAction,
    service: GatewayWorktreeService
  ) throws -> GatewayWorktreeInvocation {
    guard let authorizationID = invocation.admission?.authorizationID else {
      throw PermissionModelError.invalidAuthorization
    }
    try service.runtime.service.validateAuthorization(authorizationID)
    guard
      let authorization = try service.runtime.store.readWithDatabase({ _, ledger in
        ledger.authorizations[authorizationID]
      })
    else { throw PermissionModelError.invalidAuthorization }
    return GatewayWorktreeInvocation(
      authorization: authorization,
      additionalAuthorizationIDs: invocation.providerExecution?.provider?.authorizationIDs ?? [],
      hostAction: action)
  }

  private static func digest(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
  }

  private func audit(
    name: String, decision: AuditDecision, errorCode: String?, start: ContinuousClock.Instant,
    arguments: [String: JSONValue], result: JSONValue?, scope: Scope
  ) throws {
    let duration = start.duration(to: .now)
    let invocation = scope.invocation
    let trace = invocation?.context.transportTrace ?? context.launchMetadata.transportTrace
    try database.recordAudit(
      .init(
        requestID: "host-service:" + UUID().uuidString,
        invocationID: invocation?.id.uuidString,
        parentRequestID: invocation?.context.requestID,
        caller: context.launchMetadata.caller,
        principalDigest: AuditEvent.verifiedPrincipalDigest(context.verifiedPrincipalID),
        transport: trace?.transport,
        socketConnectionID: trace?.socketConnectionID,
        tunnelInstanceID: trace?.tunnelInstanceID,
        tunnelProfileID: trace?.tunnelProfileID, profileID: context.launchMetadata.profileID,
        projectID: context.launchMetadata.project.id, capabilityID: name, decision: decision,
        errorCode: errorCode,
        durationMilliseconds: Int(duration.components.seconds * 1000),
        inputDigest: try Self.digest(.object(arguments)), outputDigest: try result.map(Self.digest))
    )
  }
}
