import CryptoKit
import Darwin
import Foundation
import MCP

/// Private services on the inherited MCP channel. Durable authority stays with the
/// host; an active forwarded invocation, not plugin-supplied identity, selects scope.
actor MCPBoundHostServices {
  private let database: GatewayDatabase
  private let directory: MCPHostToolDirectory
  private let context: MCPHostContext
  private let origin: String
  private let now: @Sendable () -> Date
  private let commandRunner: any CommandRunning
  private let canonicalRoot: String
  private var closed = false
  private var auditInvocation: MCPHostInvocation?
  private struct IssuedClaim {
    let claim: CodexElevationClaim
    let runtimeID: String
    let invocationID: UUID
    let requestedThreadID: String?
  }
  private var claims: [String: IssuedClaim] = [:]
  private var consumedGrants: [String: Set<String>] = [:]
  private var registrations: [String: UUID] = [:]
  private var removalInvocations: [String: UUID] = [:]

  init(
    database: GatewayDatabase, directory: MCPHostToolDirectory, context: MCPHostContext,
    origin: String, now: @escaping @Sendable () -> Date = { Date() },
    commandRunner: any CommandRunning = ProcessCommandRunner()
  ) {
    self.database = database
    self.directory = directory
    self.context = context
    self.origin = origin
    self.now = now
    self.commandRunner = commandRunner
    canonicalRoot =
      URL(fileURLWithPath: context.workspace.rootPath).standardizedFileURL.resolvingSymlinksInPath()
      .path
  }

  nonisolated static let tools: [MCP.Tool] = {
    let identifier: JSONValue = .object([
      "type": .string("string"), "minLength": .number(1), "maxLength": .number(1024),
    ])
    let optionalID = identifier
    let worktree: JSONValue = .object(["type": .string("object")])
    func tool(
      _ name: String, _ description: String, _ properties: [String: JSONValue],
      _ required: [String], read: Bool = false
    ) -> MCP.Tool {
      let schema = JSONValue.object([
        "type": .string("object"), "properties": .object(properties),
        "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false),
      ])
      return MCP.Tool(
        name: name, description: description, inputSchema: schema.sdkValue,
        annotations: .init(
          readOnlyHint: read, destructiveHint: false, idempotentHint: false, openWorldHint: false),
        outputSchema: .object([
          "type": .string("object"), "properties": .object(["result": .object([:])]),
          "required": .array([.string("result")]), "additionalProperties": .bool(false),
        ]))
    }
    return [
      tool(
        "host.elevation.claim",
        "Claim an already locally approved grant for the matching live start invocation. Does not create or approve grants.",
        [
          "runtime_id": identifier,
          "action": .object([
            "type": .string("string"),
            "enum": .array([.string("thread-start"), .string("turn-start")]),
          ]), "thread_id": optionalID,
        ], ["runtime_id", "action"]),
      tool(
        "host.elevation.commit",
        "Activate this connection's claim while its original gateway invocation remains authorized.",
        [
          "claim_id": identifier, "runtime_id": identifier, "thread_id": identifier,
          "turn_id": optionalID,
        ], ["claim_id", "runtime_id", "thread_id"]),
      tool(
        "host.elevation.invalidate_claim", "Invalidate only a claim issued to this connection.",
        ["claim_id": identifier, "reason": identifier], ["claim_id", "reason"]),
      tool(
        "host.elevation.invalidate",
        "Invalidate consumed runtime grants or this connection's grants for its live thread-release invocation.",
        [
          "runtime_ids": .object([
            "type": .string("array"), "items": identifier, "maxItems": .number(128),
            "uniqueItems": .bool(true),
          ]), "thread_id": optionalID, "reason": identifier,
        ], ["runtime_ids", "reason"]),
      tool(
        "host.workspaces.register",
        "Atomically register the verified derived directory and its source profile grant during provisioning.",
        ["worktree": worktree], ["worktree"]),
      tool(
        "host.workspaces.authorize_removal",
        "Validate the exact live destructive operation ticket before the adapter changes its worktree.",
        ["worktree": worktree], ["worktree"]),
      tool(
        "host.workspaces.unregister",
        "Remove only the unchanged host registration owned by this worktree receipt, during removal or rollback.",
        ["worktree": worktree], ["worktree"]),
      tool(
        "host.diagnostics.snapshot",
        "Return bounded audits and grant metadata for the currently executing diagnostic request's immutable scope.",
        [
          "limit": .object([
            "type": .string("integer"), "minimum": .number(1), "maximum": .number(1000),
          ])
        ], ["limit"], read: true),
    ]
  }()

  func call(name: String, arguments: [String: JSONValue]) throws -> MCP.CallTool.Result {
    guard !closed else { throw MCPError.connectionClosed }
    // Rollback/removal authority lasts only for its forwarded invocation.
    // Elevation records remain owned until their database cleanup is confirmed.
    let live = Set(directory.active(workspaceID: context.workspace.id, origin: origin).map(\.id))
    registrations = registrations.filter { live.contains($0.value) }
    removalInvocations = removalInvocations.filter { live.contains($0.value) }
    let started = ContinuousClock.now
    auditInvocation = nil
    defer { auditInvocation = nil }
    do {
      guard let tool = Self.tools.first(where: { $0.name == name }),
        let properties = tool.inputSchema.objectValue?["properties"]?.objectValue,
        Set(arguments.keys).isSubset(of: Set(properties.keys)),
        (tool.inputSchema.objectValue?["required"]?.arrayValue ?? []).allSatisfy({
          $0.stringValue.map { arguments[$0] != nil } ?? false
        }), try JSONEncoder().encode(arguments).count <= 65_536
      else {
        throw MCPHostServiceError.denied("Host service arguments do not match the declared schema.")
      }
      try validateSourceIdentity()
      let result: JSONValue
      switch name {
      case "host.elevation.claim": result = try claim(arguments)
      case "host.elevation.commit": result = try commit(arguments)
      case "host.elevation.invalidate_claim": result = try invalidateClaim(arguments)
      case "host.elevation.invalidate": result = try invalidate(arguments)
      case "host.workspaces.register": result = try register(arguments)
      case "host.workspaces.authorize_removal": result = try authorizeRemoval(arguments)
      case "host.workspaces.unregister": result = try unregister(arguments)
      case "host.diagnostics.snapshot": result = try snapshot(arguments)
      default: throw MCPHostServiceError.denied("Unknown host service.")
      }
      let payload = JSONValue.object(["result": result])
      guard try JSONEncoder().encode(payload).count <= 524_288 else {
        throw MCPHostServiceError.denied(
          "Host result exceeds its byte bound; request a smaller limit.")
      }
      try audit(
        name: name, decision: .allowed, start: started, arguments: arguments, result: payload)
      return try .init(content: [], structuredContent: payload.sdkValue, isError: false)
    } catch {
      let message = CodexApprovalRedactor.redactString(
        error.localizedDescription, maximumCharacters: 1024)
      try? audit(name: name, decision: .denied, start: started, arguments: arguments, result: nil)
      return .init(
        content: [.text(text: message, annotations: nil, _meta: nil)],
        structuredContent: .object([
          "error": .object(["code": .string("host.service_denied"), "message": .string(message)])
        ]), isError: true)
    }
  }

  var cleanupConfirmed: Bool { closed && claims.isEmpty && consumedGrants.isEmpty }

  func close() {
    closed = true
    for (id, issued) in claims {
      do {
        try database.invalidateCodexElevationClaim(
          issued.claim, reason: "Owning plugin connection closed.", now: now())
        claims.removeValue(forKey: id)
      } catch {
        // Keep the exact owned record available for a bounded caller retry.
      }
    }
    for (id, runtimeIDs) in consumedGrants {
      do {
        try invalidateOwnedGrant(
          id: id, runtimeIDs: runtimeIDs, reason: "Owning plugin connection closed.")
        consumedGrants.removeValue(forKey: id)
      } catch {
        // A failed invalidation must not become a successful retirement.
      }
    }
    registrations.removeAll()
    removalInvocations.removeAll()
  }

  private var owner: CodexRuntimeOwner {
    .init(
      workspaceID: context.workspace.id, profileID: context.profileID.rawValue,
      caller: context.caller.rawValue, transport: context.transportTrace?.transport,
      socketConnectionID: context.transportTrace?.socketConnectionID,
      tunnelInstanceID: context.transportTrace?.tunnelInstanceID,
      tunnelProfileID: context.transportTrace?.tunnelProfileID)
  }

  private func validateSourceIdentity() throws {
    guard
      URL(fileURLWithPath: context.workspace.rootPath).standardizedFileURL.resolvingSymlinksInPath()
        .path == canonicalRoot
    else {
      throw MCPHostServiceError.denied("The source directory identity changed.")
    }
  }

  private func invocation(
    _ methods: Set<String>, matching: (MCPHostInvocation) -> Bool = { _ in true }
  ) throws -> MCPHostInvocation {
    let invocation = try directory.resolve().requireHostInvocation(
      workspaceID: context.workspace.id, origin: origin,
      methods: methods, matching: matching)
    auditInvocation = invocation
    return invocation
  }

  private func startInvocation(action: CodexElevationAction, threadID: String?) throws
    -> MCPHostInvocation
  {
    guard !context.readOnly else {
      throw MCPHostServiceError.denied("Read-only host scope cannot consume elevation.")
    }
    let method = action == .threadStart ? "thread/start" : "turn/start"
    let direct = action == .threadStart ? "codex.app.thread.start" : "codex.app.turn.start"
    return try invocation([direct, "codex.app.methods.call"]) { invocation in
      let raw = invocation.reference.toolName == "codex.app.methods.call"
      guard !raw || invocation.arguments["method"] == .string(method) else { return false }
      let arguments =
        raw ? invocation.arguments["params"]?.objectValue ?? [:] : invocation.arguments
      if action == .threadStart { return threadID == nil }
      return arguments[raw ? "threadId" : "thread_id"] == threadID.map(JSONValue.string)
    }
  }

  private func claim(_ args: [String: JSONValue]) throws -> JSONValue {
    guard claims.count < 128, consumedGrants.count < 128 else {
      throw MCPHostServiceError.denied("Host claim bound reached.")
    }
    let runtime = try Self.string("runtime_id", args)
    guard let action = CodexElevationAction(rawValue: try Self.string("action", args)) else {
      throw MCPHostServiceError.denied("Unknown elevation action.")
    }
    let thread = try Self.optional("thread_id", args)
    let current = try startInvocation(action: action, threadID: thread)
    guard !claims.values.contains(where: { $0.invocationID == current.id }) else {
      throw MCPHostServiceError.denied("This invocation already holds a claim.")
    }
    guard let connection = owner.elevationConnectionID else { return .null }
    guard
      let claim = try database.claimCodexElevationGrant(
        workspaceID: context.workspace.id,
        canonicalRoot: canonicalRoot, profileID: context.profileID.rawValue,
        requestingCaller: context.caller.rawValue,
        requestingConnectionID: connection, threadID: thread, runtimeID: runtime, action: action,
        now: now())
    else { return .null }
    claims[claim.id] = IssuedClaim(
      claim: claim, runtimeID: runtime, invocationID: current.id, requestedThreadID: thread)
    return .object([
      "id": .string(claim.id), "action": .string(claim.action.rawValue), "grant": claim.grant.json,
    ])
  }

  private func commit(_ args: [String: JSONValue]) throws -> JSONValue {
    let id = try Self.string("claim_id", args)
    let runtime = try Self.string("runtime_id", args)
    let thread = try Self.string("thread_id", args)
    let turn = try Self.optional("turn_id", args)
    guard let issued = claims[id], issued.runtimeID == runtime else {
      throw MCPHostServiceError.denied("The claim is not owned by this connection/runtime.")
    }
    let current = try startInvocation(
      action: issued.claim.action, threadID: issued.requestedThreadID)
    guard current.id == issued.invocationID,
      issued.requestedThreadID == nil || issued.requestedThreadID == thread,
      issued.claim.action == .threadStart || turn != nil
    else {
      throw MCPHostServiceError.denied("The originating invocation or activation response changed.")
    }
    try database.reconcileCodexElevationGrants(now: now())
    let record = try database.commitCodexElevationClaim(
      issued.claim, runtimeID: runtime,
      threadID: thread, turnID: turn, now: now())
    claims.removeValue(forKey: id)
    consumedGrants[record.id, default: []].insert(runtime)
    return record.json
  }

  private func invalidateClaim(_ args: [String: JSONValue]) throws -> JSONValue {
    let id = try Self.string("claim_id", args)
    guard let issued = claims[id] else {
      throw MCPHostServiceError.denied("No matching claim belongs to this connection.")
    }
    try database.invalidateCodexElevationClaim(
      issued.claim, reason: Self.string("reason", args), now: now())
    claims.removeValue(forKey: id)
    return .object(["invalidated": .bool(true)])
  }

  private func invalidate(_ args: [String: JSONValue]) throws -> JSONValue {
    guard let values = args["runtime_ids"]?.arrayValue, values.count <= 128 else {
      throw MCPHostServiceError.denied("Invalid runtime selector.")
    }
    let runtimes = try Set(
      values.map { value -> String in
        guard let id = value.stringValue, Self.valid(id) else {
          throw MCPHostServiceError.denied("Invalid runtime identity.")
        }
        return id
      })
    let thread = try Self.optional("thread_id", args)
    let reason = try Self.string("reason", args)
    guard !runtimes.isEmpty || thread != nil else {
      throw MCPHostServiceError.denied("An exact runtime or thread selector is required.")
    }
    var count = 0
    if let thread {
      _ = try invocation(["codex.app.thread.release"]) {
        $0.arguments["thread_id"] == .string(thread)
      }
      guard let connection = owner.elevationConnectionID else {
        throw MCPHostServiceError.denied("Thread release requires a bound connection.")
      }
      count += try database.invalidateCodexElevationGrants(
        workspaceID: context.workspace.id, profileID: context.profileID.rawValue,
        requestingConnectionID: connection, requestingCaller: context.caller.rawValue,
        threadID: thread, reason: reason, now: now())
    }
    for (id, owned) in consumedGrants {
      guard let record = try database.codexElevationGrant(id: id),
        (!runtimes.isEmpty && !runtimes.isDisjoint(with: owned))
          || (thread != nil && record.threadID == thread)
      else { continue }
      guard record.state.isEffective else {
        consumedGrants.removeValue(forKey: id)
        continue
      }
      try invalidateOwnedGrant(id: id, runtimeIDs: owned, reason: reason)
      consumedGrants.removeValue(forKey: id)
      count += 1
    }
    return .object(["invalidated": .number(Double(count))])
  }

  private func invalidateOwnedGrant(id: String, runtimeIDs: Set<String>, reason: String) throws {
    _ = try database.updateCodexElevationGrant(id: id) { grant in
      guard grant.workspaceID == context.workspace.id,
        grant.profileID == context.profileID.rawValue,
        grant.requestingCaller == context.caller.rawValue,
        grant.requestingConnectionID == owner.elevationConnectionID,
        !runtimeIDs.isDisjoint(with: grant.consumedRuntimeIDs)
      else { throw MCPHostServiceError.denied("Grant ownership changed.") }
      guard grant.state.isEffective else { return }
      grant.state = .invalidated
      grant.resolvedAt = now()
      grant.updatedAt = now()
      grant.resolutionReason = CodexApprovalRedactor.redactString(reason, maximumCharacters: 512)
      grant.inFlightClaimID = nil
      grant.inFlightAction = nil
    }
  }

  private func snapshot(_ args: [String: JSONValue]) throws -> JSONValue {
    guard let limit = args["limit"]?.intValue, (1...1000).contains(limit) else {
      throw MCPHostServiceError.denied("Diagnostic limit must be 1...1000.")
    }
    _ = try invocation(["codex.diagnostics.snapshot"]) {
      ($0.arguments["limit"]?.intValue ?? 100) >= limit
    }
    var execution = ExecutionContext(
      caller: context.caller, profileID: context.profileID, transportTrace: context.transportTrace)
    execution.workspaceID = context.workspace.id
    let audits = try database.hostDiagnosticAudits(context: execution, limit: limit)
    let grants = try CodexElevationGrantService.visibleGrants(
      owner: owner, database: database, limit: limit, now: now()
    ).filter {
      $0.profileID == context.profileID.rawValue && $0.requestingCaller == context.caller.rawValue
        && $0.requestingConnectionID == owner.elevationConnectionID
    }
    return .object([
      "owner": try JSONValue.encoded(owner),
      "recent_tool_audits": .array(
        audits.map { audit in
          .object([
            "id": .string(audit.id), "request_id": .string(audit.requestID),
            "workspace_id": .string(context.workspace.id),
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
            "duration_milliseconds": audit.durationMilliseconds.map { .number(Double($0)) }
              ?? .null,
            "output_byte_count": audit.outputByteCount.map { .number(Double($0)) } ?? .null,
            "output_truncated": audit.outputTruncated.map(JSONValue.bool) ?? .null,
            "input_digest": audit.inputDigest.map(JSONValue.string) ?? .null,
            "output_digest": audit.outputDigest.map(JSONValue.string) ?? .null,
          ])
        }),
      "elevation_grants": .array(
        grants.map { grant in
          var value = grant.json.objectValue ?? [:]
          // Diagnostic readers must not learn an activation handle currently in flight.
          value["in_flight_claim_id"] = grant.inFlightClaimID == nil ? .null : .string("in-flight")
          return .object(value)
        }),
    ])
  }

  private func register(_ args: [String: JSONValue]) throws -> JSONValue {
    let record = try derived(args)
    let active = try provisionInvocation(record)
    guard !context.readOnly, registrations.count < 128 else {
      throw MCPHostServiceError.denied("Derived registration is unavailable in this scope.")
    }
    try verifyGit(record)
    let registration: MCPDerivedWorkspaceRegistration
    if let old = try database.derivedWorkspaceRegistration(id: record.workspaceID) {
      try verifyOwnership(old, record)
      registration = old
    } else {
      registration = MCPDerivedWorkspaceRegistration(
        origin: origin, receiptID: record.id,
        sourceWorkspaceID: context.workspace.id, sourceRoot: canonicalRoot,
        receiptDigest: try record.digest(),
        profileID: context.profileID, caller: context.caller,
        workspace: .init(
          id: record.workspaceID, displayName: record.branch, rootPath: record.path,
          createdAt: now(), updatedAt: now()))
    }
    try database.registerDerivedWorkspace(registration)
    registrations[record.id] = active.id
    return .object(["registered": .bool(true), "workspace_id": .string(record.workspaceID)])
  }

  private func authorizeRemoval(_ args: [String: JSONValue]) throws -> JSONValue {
    let record = try derived(args)
    let active = try invocation(["codex.worktree.remove.perform"]) {
      $0.arguments["managed_worktree_id"] == .string(record.id)
        && $0.arguments["expected_revision"]?.intValue == record.revision
        && $0.arguments["confirm_remove"] == .bool(true)
    }
    guard record.state == "removal_planned" || record.state == "removing" else {
      throw MCPHostServiceError.denied("No reviewed removal state is present.")
    }
    if let old = try database.derivedWorkspaceRegistration(id: record.workspaceID) {
      try verifyOwnership(old, record)
    } else {
      guard record.state == "removing", try database.workspace(id: record.workspaceID) == nil else {
        throw MCPHostServiceError.denied(
          "No owned registration or metadata-only recovery is available.")
      }
    }
    try requireTicket(active)
    if record.state == "removing" { try verifyRemovedGit(record) } else { try verifyGit(record) }
    removalInvocations[record.id] = active.id
    return .object(["authorized": .bool(true)])
  }

  private func unregister(_ args: [String: JSONValue]) throws -> JSONValue {
    let record = try derived(args)
    let old = try database.derivedWorkspaceRegistration(id: record.workspaceID)
    if let old {
      try verifyOwnership(old, record)
    } else {
      guard try database.workspace(id: record.workspaceID) == nil else {
        throw MCPHostServiceError.denied(
          "The identity belongs to an independent workspace registration.")
      }
      if record.state == "provisioning", registrations[record.id] == nil {
        _ = try provisionInvocation(record)
        // This no-op confirms that a failed registration did not create host ownership.
        return .object(["unregistered": .bool(true)])
      }
    }
    let live = directory.active(workspaceID: context.workspace.id, origin: origin)
    if record.state == "provisioning" {
      // Exact rollback can remove the registration we just created even after revocation.
      guard let id = registrations[record.id], live.contains(where: { $0.id == id }) else {
        throw MCPHostServiceError.denied(
          "Rollback is not part of the registration's active invocation.")
      }
    } else {
      guard record.state == "removing", let id = removalInvocations[record.id],
        let active = live.first(where: { $0.id == id }),
        active.arguments["expected_revision"]?.intValue == record.revision - 1
      else {
        throw MCPHostServiceError.denied("Removal was not authorized by this active invocation.")
      }
      auditInvocation = active
      try requireTicket(active)
      try verifyRemovedGit(record)
    }
    if let old { try database.unregisterDerivedWorkspace(old) }
    return .object(["unregistered": .bool(true), "workspace_id": .string(record.workspaceID)])
  }

  private func provisionInvocation(_ record: DerivedIdentity) throws -> MCPHostInvocation {
    guard record.state == "provisioning" else {
      throw MCPHostServiceError.denied("Registration requires a provisioning receipt.")
    }
    return try invocation(["codex.worktree.provision.perform"]) {
      $0.arguments["plan_id"] == .string(record.id)
        && $0.arguments["expected_revision"]?.intValue == record.revision - 1
        && $0.arguments["confirm_provision"] == .bool(true)
    }
  }

  private func requireTicket(_ invocation: MCPHostInvocation) throws {
    guard let id = invocation.ticketID, let ticket = try database.operationTicket(id: id),
      ticket.state == .executing, ticket.invocationID == invocation.ticketInvocationID,
      ticket.parentRequestID == invocation.parentRequestID,
      ticket.workspaceID == context.workspace.id, ticket.profileID == context.profileID,
      ticket.caller == context.caller, ticket.capabilityID == invocation.upstreamName
    else {
      throw MCPHostServiceError.denied("This operation has no matching executing host ticket.")
    }
  }

  private func derived(_ args: [String: JSONValue]) throws -> DerivedIdentity {
    guard let object = args["worktree"]?.objectValue else {
      throw MCPHostServiceError.denied("A worktree receipt is required.")
    }
    let record = try DerivedIdentity(object)
    guard let root = context.managedWorkspaceRoot,
      record.sourceWorkspaceID == context.workspace.id, record.sourceRoot == canonicalRoot,
      record.profileID == context.profileID.rawValue, record.caller == context.caller.rawValue,
      record.workspaceID == "codex-worktree-" + record.id,
      UUID(uuidString: record.id)?.uuidString.lowercased() == record.id
    else {
      throw MCPHostServiceError.denied("The derived receipt does not match this host scope.")
    }
    let component = SHA256.hash(data: Data(context.workspace.id.utf8)).prefix(12).map {
      String(format: "%02x", $0)
    }.joined()
    let target = URL(fileURLWithPath: root).appendingPathComponent(component)
      .appendingPathComponent(record.id).standardizedFileURL
    guard record.path == target.path else {
      throw MCPHostServiceError.denied(
        "Derived path differs from the host-selected root and receipt identity.")
    }
    return record
  }

  private func verifyOwnership(_ old: MCPDerivedWorkspaceRegistration, _ record: DerivedIdentity)
    throws
  {
    guard old.origin == origin, old.sourceWorkspaceID == context.workspace.id,
      old.profileID == context.profileID, old.caller == context.caller,
      old.receiptID == record.id, old.receiptDigest == (try record.digest())
    else {
      throw MCPHostServiceError.denied(
        "The persisted registration is owned by another receipt or source.")
    }
  }

  private func validateManagedParents(_ record: DerivedIdentity, targetExists: Bool) throws {
    guard let root = context.managedWorkspaceRoot else {
      throw MCPHostServiceError.denied("Managed workspace root unavailable.")
    }
    let directory = URL(fileURLWithPath: record.path, isDirectory: true)
    let base = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
    var cursor = targetExists ? directory : directory.deletingLastPathComponent()
    while cursor.path.count >= base.path.count {
      let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw MCPHostServiceError.denied("Derived directories must not contain links.")
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: cursor.path)
      guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
        throw MCPHostServiceError.denied("Derived directory ownership differs.")
      }
      if cursor.path == base.path { break }
      cursor.deleteLastPathComponent()
    }
    guard
      directory.resolvingSymlinksInPath().path.hasPrefix(base.resolvingSymlinksInPath().path + "/")
    else {
      throw MCPHostServiceError.denied("Derived directory escaped its host root.")
    }
  }

  private func gitOutput(_ args: [String], at url: URL) throws -> String {
    let result = try commandRunner.run(
      executable: "/usr/bin/git", arguments: args, workingDirectory: url,
      environment: ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"], timeoutMilliseconds: 5_000,
      maxOutputBytes: 16_384)
    guard result.exitCode == 0, !result.timedOut, !result.stdoutTruncated, !result.stderrTruncated
    else {
      throw MCPHostServiceError.denied("Git directory verification failed.")
    }
    return result.stdout
  }

  private func gitPath(_ args: [String], at url: URL) throws -> String {
    let value = try gitOutput(args, at: url).trimmingCharacters(in: .newlines)
    return (value.hasPrefix("/") ? URL(fileURLWithPath: value) : url.appendingPathComponent(value))
      .standardizedFileURL.resolvingSymlinksInPath().path
  }

  private func verifySourceGit(_ record: DerivedIdentity) throws {
    let source = URL(fileURLWithPath: canonicalRoot)
    guard try gitPath(["rev-parse", "--show-toplevel"], at: source) == canonicalRoot,
      try gitPath(["rev-parse", "--git-common-dir"], at: source) == record.gitCommonDirectory
    else {
      throw MCPHostServiceError.denied("The source repository identity changed.")
    }
  }

  private func verifyGit(_ record: DerivedIdentity) throws {
    try validateManagedParents(record, targetExists: true)
    try verifySourceGit(record)
    let directory = URL(fileURLWithPath: record.path, isDirectory: true)
    guard
      try gitPath(["rev-parse", "--show-toplevel"], at: directory)
        == directory.resolvingSymlinksInPath().path,
      try gitPath(["rev-parse", "--git-common-dir"], at: directory) == record.gitCommonDirectory
    else {
      throw MCPHostServiceError.denied(
        "The target is not the exact source repository's derived worktree.")
    }
  }

  private func verifyRemovedGit(_ record: DerivedIdentity) throws {
    try validateManagedParents(record, targetExists: false)
    var info = stat()
    guard lstat(record.path, &info) != 0, errno == ENOENT else {
      throw MCPHostServiceError.denied(
        "Metadata-only cleanup refuses an existing or unverified path.")
    }
    try verifySourceGit(record)
    let inventory = try gitOutput(
      ["worktree", "list", "--porcelain", "-z"], at: URL(fileURLWithPath: canonicalRoot))
    let present = inventory.split(separator: "\0").contains { field in
      guard field.hasPrefix("worktree ") else { return false }
      let path = String(field.dropFirst("worktree ".count))
      return URL(fileURLWithPath: path).standardizedFileURL.path == record.path
    }
    guard !present else {
      throw MCPHostServiceError.denied("Git still registers this worktree; cleanup cannot proceed.")
    }
  }

  private struct DerivedIdentity: Encodable {
    let id: String
    let workspaceID: String
    let sourceWorkspaceID: String
    let sourceRoot: String
    let gitCommonDirectory: String
    let path: String
    let branch: String
    let parentLeaseID: String
    let profileID: String
    let caller: String
    let revision: Int
    let state: String
    init(_ value: [String: JSONValue]) throws {
      id = try string("id", value)
      workspaceID = try string("workspace_id", value)
      sourceWorkspaceID = try string("source_workspace_id", value)
      sourceRoot = try string("source_repository_root", value, maximum: 16_384)
      gitCommonDirectory = try string("git_common_directory", value, maximum: 16_384)
      path = try string("path", value, maximum: 16_384)
      branch = try string("branch", value)
      parentLeaseID = try string("parent_lease_id", value)
      profileID = try string("profile_id", value)
      caller = try string("caller", value)
      state = try string("state", value)
      guard let number = value["revision"]?.intValue, (1...1_000_000).contains(number) else {
        throw MCPHostServiceError.denied("Invalid receipt revision.")
      }
      revision = number
    }
    func digest() throws -> String {
      var value = try JSONValue.encoded(self).objectValue!
      value.removeValue(forKey: "revision")
      value.removeValue(forKey: "state")
      return try MCPBoundHostServices.digest(.object(value))
    }
  }

  private static func valid(_ value: String, maximum: Int = 1024) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum && !value.contains("\0")
  }
  private static func string(_ key: String, _ object: [String: JSONValue], maximum: Int = 1024)
    throws -> String
  {
    guard let value = object[key]?.stringValue, valid(value, maximum: maximum) else {
      throw MCPHostServiceError.denied("Invalid " + key + ".")
    }
    return value
  }
  private static func optional(_ key: String, _ object: [String: JSONValue]) throws -> String? {
    guard object[key] != nil else { return nil }
    return try string(key, object)
  }
  private static func digest(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
  }
  private func audit(
    name: String, decision: AuditDecision, start: ContinuousClock.Instant,
    arguments: [String: JSONValue], result: JSONValue?
  ) throws {
    let duration = start.duration(to: .now)
    try database.recordAudit(
      .init(
        requestID: "host-service:" + UUID().uuidString,
        invocationID: auditInvocation?.ticketInvocationID,
        parentRequestID: auditInvocation?.context.requestID, ticketID: auditInvocation?.ticketID,
        caller: context.caller, transport: context.transportTrace?.transport,
        socketConnectionID: context.transportTrace?.socketConnectionID,
        tunnelInstanceID: context.transportTrace?.tunnelInstanceID,
        tunnelProfileID: context.transportTrace?.tunnelProfileID, profileID: context.profileID,
        workspaceID: context.workspace.id, capabilityID: name, decision: decision,
        errorCode: decision == .allowed ? nil : "host.service_denied",
        durationMilliseconds: Int(duration.components.seconds * 1000),
        inputDigest: try Self.digest(.object(arguments)), outputDigest: try result.map(Self.digest))
    )
  }
}
