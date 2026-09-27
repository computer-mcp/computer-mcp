import CryptoKit
import Darwin
import Foundation

package final class GatewayRuntime: GatewayToolServing, @unchecked Sendable {
  private let configuration: GatewayConfiguration
  private let context: ExecutionContext
  private let grant: ProfileGrant
  private let requiresPersistedGrant: Bool
  private let persistedWorkspaceRegistrations: [String: RegisteredWorkspace]
  private let policyEvaluator: GatewayPolicyEvaluator
  private let database: GatewayDatabase?
  private let workspaces: [String: RegisteredWorkspace]
  private let workspaceOrder: [String]
  private let workspaceAccesses: [String: ResolvedWorkspaceAccess]
  private let workspaceErrors: [String: WorkspaceBookmarkError]
  private let providerRouters: [String: GatewayProviderRouter]
  private let lifetime: GatewayRuntimeLifetime
  let ownedWork = GatewayOwnedWork()
  let generationID = UUID()
  private let authenticatedSessionFactory:
    @Sendable (String, GatewayTransportTrace?) throws -> GatewayRuntime
  private static let construction = BlockingOperationExecutor(
    label: "computer-mcp.gateway-construction", serial: false)
  private static let admission = BlockingOperationExecutor(
    label: "computer-mcp.gateway-admission", serial: false)
  private static func performAdmission<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    let target = MCPContinuationTarget.current
    let owner = GatewayOwnerRouting.selection
    return try await admission.perform {
      try GatewayOwnerRouting.$selection.withValue(owner) {
        try MCPContinuationTarget.$current.withValue(target, operation: operation)
      }
    }
  }

  private let hostToolDirectory = MCPHostToolDirectory()
  package let pluginOrigins: [IntegrationRegistration: PluginContributionOrigin]
  package let pluginDiagnostics: [PluginResolutionDiagnostic]
  package let pluginIssues: [PluginStoreIssue]

  /// Synchronous construction starts discovery. Async callers use `make` to join failed startup cleanup.
  package convenience init(
    configuration: GatewayConfiguration,
    context: ExecutionContext? = nil,
    database: GatewayDatabase? = nil,
    registeredWorkspaces: [RegisteredWorkspace]? = nil,
    bookmarkService: any WorkspaceBookmarkServicing = WorkspaceBookmarkService(),
    policyEvaluator: GatewayPolicyEvaluator = GatewayPolicyEvaluator(),
    mcpClient: any DownstreamMCPClient = MCPProxyClient(),
    plugins: [ResolvedPlugin]? = nil,
    bundledPlugins: BundledPlugins = .current,
    terminalSessions: GatewayTerminalSessions = GatewayTerminalSessions()
  ) throws {
    try self.init(
      configuration: configuration, context: context, database: database,
      registeredWorkspaces: registeredWorkspaces, bookmarkService: bookmarkService,
      policyEvaluator: policyEvaluator, mcpClient: mcpClient, plugins: plugins,
      bundledPlugins: bundledPlugins, terminalSessions: terminalSessions,
      lifetime: GatewayRuntimeLifetime())
  }

  package static func make(
    configuration: GatewayConfiguration,
    context: ExecutionContext? = nil,
    database: GatewayDatabase? = nil,
    registeredWorkspaces: [RegisteredWorkspace]? = nil,
    bookmarkService: any WorkspaceBookmarkServicing = WorkspaceBookmarkService(),
    policyEvaluator: GatewayPolicyEvaluator = GatewayPolicyEvaluator(),
    mcpClient: any DownstreamMCPClient = MCPProxyClient(),
    plugins: [ResolvedPlugin]? = nil,
    bundledPlugins: BundledPlugins = .current,
    terminalSessions: GatewayTerminalSessions = GatewayTerminalSessions()
  ) async throws -> GatewayRuntime {
    try Task.checkCancellation()
    let lifetime = GatewayRuntimeLifetime()
    do {
      let runtime = try await construction.perform {
        try GatewayRuntime(
          configuration: configuration, context: context, database: database,
          registeredWorkspaces: registeredWorkspaces, bookmarkService: bookmarkService,
          policyEvaluator: policyEvaluator, mcpClient: mcpClient, plugins: plugins,
          bundledPlugins: bundledPlugins, terminalSessions: terminalSessions, lifetime: lifetime)
      }
      try Task.checkCancellation()
      return runtime
    } catch {
      await lifetime.beginShutdown().value
      throw error
    }
  }

  private init(
    configuration: GatewayConfiguration, context: ExecutionContext?, database: GatewayDatabase?,
    registeredWorkspaces: [RegisteredWorkspace]?, bookmarkService: any WorkspaceBookmarkServicing,
    policyEvaluator: GatewayPolicyEvaluator, mcpClient: any DownstreamMCPClient,
    plugins: [ResolvedPlugin]?, bundledPlugins: BundledPlugins,
    terminalSessions: GatewayTerminalSessions, lifetime: GatewayRuntimeLifetime
  ) throws {
    let initializationConfiguration = configuration
    self.lifetime = lifetime
    var initialized = false
    defer { if !initialized { _ = lifetime.beginShutdown() } }
    var sourceConfiguration = configuration
    let pluginState = try (database?.pluginStoreSnapshot() ?? PluginStoreSnapshot())
      .includingBundledDefaults(bundledPlugins.packages.map(\.manifest))
    let artifactLeases = try Self.retainPluginArtifacts(
      state: pluginState, plugins: plugins, database: database)
    lifetime.onShutdown {
      for lease in artifactLeases { lease.close() }
    }
    sourceConfiguration.knownPluginMCPServerIDs.formUnion(pluginState.knownMCPRegistrationIDs)
    let resolved =
      try plugins == nil ? PluginHost.resolve(pluginState, bundled: bundledPlugins) : nil
    let composition = try GatewayPluginComposition(
      configuration: sourceConfiguration, plugins: plugins ?? resolved?.plugins ?? [])
    let configuration = composition.runtimeConfiguration
    guard configuration.codex?.enabled != true else {
      throw ConfigurationError.invalid(
        "Embedded Codex execution requires migration. Use config migrate-codex and the independent Codex plugin before starting this gateway."
      )
    }
    pluginOrigins = composition.origins
    pluginDiagnostics = composition.diagnostics
    pluginIssues = resolved?.issues ?? []
    let effectiveContext = context ?? configuration.executionContext()
    let configuredGrant = configuration.profiles.first { $0.id == effectiveContext.profileID }?
      .grant
    let persistedProfiles = try database?.profiles() ?? []
    let persistedGrant = persistedProfiles.first(where: { $0.id == effectiveContext.profileID })
    let mcpGrant = configuredGrant ?? configuration.profileGrant(for: effectiveContext.profileID)
    let derivesObserveGrant =
      configuredGrant == nil
      && (effectiveContext.profileID == .chatGPTObserve
        || effectiveContext.profileID == .cloudflareObserve)
    let scopedMCPClient = AuthorizedMCPClient(
      base: mcpClient,
      policy: MCPToolAccessPolicy(
        configuration: configuration,
        grant: persistedGrant.map(mcpGrant.applyingPersistedRuntimeState) ?? mcpGrant,
        derivesObserveGrant: derivesObserveGrant),
      policyProvider: {
        let persisted = try database?.profiles().first { $0.id == effectiveContext.profileID }
        guard persistedGrant == nil || persisted != nil else {
          throw GatewayToolError.disabled("The profile authorization was revoked.")
        }
        return MCPToolAccessPolicy(
          configuration: configuration,
          grant: persisted.map(mcpGrant.applyingPersistedRuntimeState) ?? mcpGrant,
          derivesObserveGrant: derivesObserveGrant && (persisted?.authorizationRevision ?? 0) == 0)
      })

    let persistedWorkspaces = try database?.workspaces() ?? []
    let configuredWorkspaces =
      registeredWorkspaces
      ?? (persistedWorkspaces.isEmpty ? configuration.manifestWorkspaces : persistedWorkspaces)

    var workspaceByID: [String: RegisteredWorkspace] = [:]
    var accessByID: [String: ResolvedWorkspaceAccess] = [:]
    var errorByID: [String: WorkspaceBookmarkError] = [:]
    var providerRouterByID: [String: GatewayProviderRouter] = [:]
    let commandRunner = ProcessCommandRunner()

    for workspace in configuredWorkspaces {
      guard workspaceByID[workspace.id] == nil else {
        throw GatewayRuntimeError.duplicateWorkspaceID(workspace.id)
      }
      workspaceByID[workspace.id] = workspace
      let access: ResolvedWorkspaceAccess
      do {
        access = try bookmarkService.resolve(workspace)
      } catch let error as WorkspaceBookmarkError {
        errorByID[workspace.id] = error
        continue
      }
      lifetime.onShutdown { access.close() }
      var workspaceConfiguration = configuration
      workspaceConfiguration.workspaceDirectory = access.rootURL.standardizedFileURL
      let shellManager = SubprocessShellRuntime(
        ownedWork: ownedWork, workspaceID: workspace.id, sessions: terminalSessions,
        scope: try .workspace(
          context: effectiveContext, workspace: access.workspace, root: access.rootURL,
          registered: registeredWorkspaces != nil || !persistedWorkspaces.isEmpty))
      let processManager = SubprocessProcessRegistry(
        shellManager: shellManager,
        maxSessions: configuration.policy.maxShellSessions,
        terminationGraceMilliseconds: configuration.policy.shellTerminationGraceMs
      )
      workspaceByID[workspace.id] = access.workspace
      accessByID[workspace.id] = access
      var hostContext = MCPHostContext(
        runtimeID: generationID, context: effectiveContext, workspaceID: workspace.id,
        rootURL: access.rootURL, readOnly: !mcpGrant.permitsRisk(.workspaceWrite),
        tools: hostToolDirectory,
        managedWorkspaceRoot: database?.fileURL?.deletingLastPathComponent()
          .appendingPathComponent("Managed Worktrees", isDirectory: true),
        processOwnershipRoot: database?.mcpProcessOwnershipRoot, executionDatabase: database)
      hostContext.ownedWork = ownedWork
      for (registration, origin) in composition.origins where registration.kind == .mcp {
        if let lease = artifactLeases.first(where: {
          $0.identity.url.appendingPathComponent("package").path == origin.source.root.path
        }) {
          hostContext.pluginArtifacts[registration.id] = lease.identity
        }
      }
      let registry = GatewayToolRegistry(
        configuration: workspaceConfiguration,
        commandRunner: commandRunner,
        processManager: processManager,
        shellManager: shellManager,
        mcpClient: scopedMCPClient,
        hostContext: hostContext
      )
      let registryCleanup = lifetime.onShutdown { await registry.shutdown() }
      let additionalProviders: [any GatewayToolProvider] = [
        ComputerUseGatewayProvider()
      ]
      let router = try GatewayProviderRouter(
        registry: registry,
        additionalProviders: additionalProviders,
        reservedToolNames: Set(Self.coreTools(databaseEnabled: true).map(\.name)),
        retainsContinuation: { [ownedWork, workspaceID = workspace.id] reference in
          ownedWork.continuations.retainsContinuation(
            workspaceID: workspaceID, reference: reference)
        }
      )
      providerRouterByID[workspace.id] = router
      lifetime.replaceShutdown(registryCleanup) { await router.shutdown() }
      if access.workspace != workspace {
        try database?.saveWorkspace(access.workspace, replacing: workspace)
      }
    }

    let baseGrant: ProfileGrant
    if let configuredGrant {
      baseGrant = configuredGrant
    } else if effectiveContext.profileID == .chatGPTObserve
      || effectiveContext.profileID == .cloudflareObserve
    {
      var readOnlyCapabilities: Set<String> = ["workspace.list", "workspace.describe"]
      // The observe risk boundary independently limits this to host-classified read-only targets.
      readOnlyCapabilities.insert("mcp.tools.call")
      if let providerRouter = configuredWorkspaces.lazy.compactMap({ providerRouterByID[$0.id] })
        .first
      {
        readOnlyCapabilities.formUnion(
          try providerRouter.listTools()
            .filter {
              try providerRouter.capability(named: $0.name).risk == .readOnly
                && !$0.name.hasPrefix("codex.")
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
    var effectiveGrant =
      persistedGrant.map(baseGrant.applyingPersistedRuntimeState)
      ?? baseGrant
    if persistedGrant?.authorizationRevision == 0, let database {
      if effectiveGrant.capabilityIDs.contains("*") {
        effectiveGrant.workspaceIDs = Set(workspaceByID.keys)
      }
      try database.saveProfile(effectiveGrant, expectedRevision: 0)
      effectiveGrant =
        try database.profiles().first { $0.id == effectiveGrant.id } ?? effectiveGrant
    }
    try effectiveGrant.validate()

    self.configuration = configuration
    self.context = effectiveContext
    self.grant = effectiveGrant
    self.authenticatedSessionFactory = { principalID, trace in
      var bound = effectiveContext
      bound.trustedPrincipalID = principalID
      bound.transportTrace = trace
      return try GatewayRuntime(
        configuration: initializationConfiguration, context: bound, database: database,
        registeredWorkspaces: registeredWorkspaces, bookmarkService: bookmarkService,
        policyEvaluator: policyEvaluator, mcpClient: mcpClient, plugins: plugins,
        bundledPlugins: bundledPlugins, terminalSessions: terminalSessions)
    }
    self.requiresPersistedGrant = persistedGrant != nil
    self.persistedWorkspaceRegistrations = Dictionary(
      uniqueKeysWithValues: persistedWorkspaces.map { ($0.id, $0) })
    self.policyEvaluator = policyEvaluator
    self.database = database
    self.workspaces = workspaceByID
    self.workspaceOrder = configuredWorkspaces.map(\.id)
    self.workspaceAccesses = accessByID
    self.workspaceErrors = errorByID
    self.providerRouters = providerRouterByID
    hostToolDirectory.attach(self)
    initialized = true
  }

  /// Catalog and calls borrow this runtime but cannot widen its bound workspace or recurse.
  func hostToolCatalog(workspaceID: String, origin: String) throws -> [MCPTool] {
    try validateHostOrigin(workspaceID: workspaceID, origin: origin)
    var bound = context
    bound.workspaceID = workspaceID
    let currentGrant = try currentHostGrant()
    return try listTools().filter { tool in
      guard !tool.name.hasPrefix("codex."), let descriptor = try? descriptor(named: tool.name),
        !descriptor.localOnly,
        descriptor.mcpReference.map({ !hostServiceRegistrations.contains($0.serverID) }) ?? true
      else { return false }
      return policyEvaluator.evaluate(
        capability: descriptor, context: bound, grant: currentGrant,
        registeredWorkspaceIDs: Set(workspaceOrder)
      ).isAllowed
    }
  }

  func callHostTool(
    name: String, arguments: [String: JSONValue], workspaceID: String,
    origin: String, requestID: String
  ) async throws -> JSONValue {
    var bound = context
    bound.workspaceID = workspaceID
    bound.requestID = requestID
    var dispatched = false
    let started = ContinuousClock.now
    do {
      try validateHostOrigin(workspaceID: workspaceID, origin: origin)
      try validateHostTarget(name: name, arguments: arguments, context: bound, depth: 0)
      if name == "workspace.list" {
        let rows = workspaceList(context: bound).objectValue?["workspaces"]?.arrayValue ?? []
        let result = Self.attachExecutionMetadata(
          to: try resultEnvelope(
            .object([
              "workspaces": .array(
                rows.filter {
                  $0.objectValue?["id"] == .string(workspaceID)
                })
            ])), context: bound, capabilityID: name, operationLinkage: nil)
        try recordAudit(
          context: bound, capabilityID: name, decision: .allowed, errorCode: nil,
          duration: started.duration(to: .now),
          inputDigest: try Self.inputDigest(tool: name, arguments: arguments),
          output: result, operationLinkage: nil)
        return result
      }
      dispatched = true
      return try await callToolAsync(name: name, arguments: .object(arguments), context: bound)
    } catch {
      let result = Self.attachExecutionMetadata(
        to: Self.errorEnvelope(error), context: bound, capabilityID: name, operationLinkage: nil)
      if !dispatched {
        try? recordAudit(
          context: bound, capabilityID: name, decision: Self.auditDecision(for: error),
          errorCode: Self.auditErrorCode(for: error), duration: started.duration(to: .now),
          inputDigest: try? Self.inputDigest(tool: name, arguments: arguments), output: result,
          operationLinkage: nil)
      }
      return result
    }
  }

  private var hostServiceRegistrations: Set<String> {
    Set(configuration.mcp.servers.filter { $0.enabled && $0.hostServices }.map(\.id))
  }

  private func validateHostOrigin(workspaceID: String, origin: String) throws {
    guard !lifetime.isClosing, hostServiceRegistrations.contains(origin),
      workspaces[workspaceID] != nil
    else {
      throw Self.invalid(
        code: "policy.host_scope_unavailable",
        message: "The originating host scope is no longer available.")
    }
    try validateExecutionWorkspace(workspaceID)
  }

  private func currentRegisteredWorkspace(_ workspaceID: String) throws -> RegisteredWorkspace? {
    guard persistedWorkspaceRegistrations[workspaceID] != nil, let database else { return nil }
    guard let current = try database.workspace(id: workspaceID), current.id == workspaceID else {
      throw Self.invalid(
        code: "policy.workspace_denied",
        message: "The registered workspace changed or was removed.")
    }
    return current
  }

  private func validateExecutionWorkspace(_ workspaceID: String) throws {
    guard let current = try currentRegisteredWorkspace(workspaceID) else { return }
    guard current.createdAt == persistedWorkspaceRegistrations[workspaceID]?.createdAt,
      current.rootPath == workspaces[workspaceID]?.rootPath
    else {
      throw Self.invalid(
        code: "policy.workspace_denied",
        message: "The registered workspace changed or was removed.")
    }
  }

  private func currentHostGrant() throws -> ProfileGrant {
    guard let database else { return grant }
    guard let persisted = try database.profiles().first(where: { $0.id == grant.id }) else {
      // Configuration and builtin grants do not require a database record. A runtime
      // initialized with persisted authority must not recover it after revocation.
      guard requiresPersistedGrant else { return grant }
      throw Self.invalid(
        code: "policy.host_grant_revoked",
        message: "The persisted host profile is no longer available.")
    }
    return grant.applyingPersistedRuntimeState(persisted)
  }

  private func validateHostTarget(
    name: String, arguments: [String: JSONValue], context: ExecutionContext, depth: Int
  ) throws {
    guard depth < 8, !name.hasPrefix("codex."), !name.hasPrefix("host.") else {
      throw Self.invalid(
        code: "policy.host_recursion_denied",
        message: "A host callback cannot enter a domain runtime recursively.")
    }
    let target = try descriptor(
      named: name, workspaceID: arguments["workspace_id"]?.stringValue ?? context.workspaceID)
    guard !target.localOnly,
      target.mcpReference.map({ !hostServiceRegistrations.contains($0.serverID) }) ?? true,
      !(name.hasPrefix("mcp.")
        && arguments["server"]?.stringValue.map(hostServiceRegistrations.contains) == true)
    else {
      throw Self.invalid(
        code: "policy.host_recursion_denied",
        message:
          "Host administration and callback-enabled MCP registrations are not callback targets.")
    }
    let descriptor = try invocationDescriptor(named: name, arguments: arguments, context: context)
    let routed = try route(descriptor: descriptor, arguments: arguments, context: context)
    try authorize(descriptor, context: routed.context)
    let current = try currentHostGrant()
    let decision = policyEvaluator.evaluate(
      capability: descriptor, context: routed.context, grant: current,
      registeredWorkspaceIDs: Set(workspaceOrder))
    guard case .allow = decision else {
      throw Self.invalid(
        code: "policy.host_grant_revoked",
        message: "The host grant no longer permits this callback.")
    }
    if name == "policy.probe" || name == "operations.prepare" || name == "operations.commit"
      || name == "runtime.owners.call"
    {
      let key = name == "policy.probe" ? "capability_id" : "tool"
      let target = try Self.requiredString(key, in: arguments)
      guard arguments["arguments"] == nil || arguments["arguments"]?.objectValue != nil else {
        throw Self.invalid(
          code: "policy.invalid_target_arguments",
          message: "Nested target arguments must be an object.")
      }
      try validateHostTarget(
        name: target, arguments: arguments["arguments"]?.objectValue ?? [:],
        context: routed.context, depth: depth + 1)
    }
  }

  private func beginHostInvocation(
    descriptor: CapabilityDescriptor, name: String, arguments: [String: JSONValue],
    context: ExecutionContext, linkage: OperationAuditLinkage?, authorizationRevision: Int64
  ) throws -> MCPHostInvocation? {
    guard let reference = descriptor.mcpReference,
      hostServiceRegistrations.contains(reference.serverID)
    else { return nil }
    let invocation = MCPHostInvocation(
      reference: reference, admittedCapability: descriptor, upstreamName: name,
      upstreamArguments: arguments,
      arguments: name == "mcp.tools.call" ? arguments["arguments"]?.objectValue ?? [:] : arguments,
      context: context, ticketID: linkage?.ticketID, ticketInvocationID: linkage?.invocationID,
      parentRequestID: linkage?.parentRequestID, authorizationRevision: authorizationRevision)
    try hostToolDirectory.begin(invocation)
    return invocation
  }

  func requireHostInvocation(
    workspaceID: String, origin: String, methods: Set<String>,
    matching: (MCPHostInvocation) -> Bool = { _ in true }
  ) throws -> MCPHostInvocation {
    try requireHostInvocation(workspaceID: workspaceID, origin: origin) {
      methods.contains($0.reference.toolName) && matching($0)
    }
  }

  func requireHostInvocation(workspaceID: String, origin: String, id: UUID) throws
    -> MCPHostInvocation
  {
    try requireHostInvocation(workspaceID: workspaceID, origin: origin, includingRetainedWork: true)
    {
      $0.id == id
    }
  }

  private func requireHostInvocation(
    workspaceID: String, origin: String, includingRetainedWork: Bool = false,
    matching: (MCPHostInvocation) -> Bool
  ) throws -> MCPHostInvocation {
    try validateHostOrigin(workspaceID: workspaceID, origin: origin)
    let matches = hostToolDirectory.active(
      workspaceID: workspaceID, origin: origin, includingRetainedWork: includingRetainedWork
    ).filter(matching)
    guard matches.count == 1, let invocation = matches.first else {
      throw Self.invalid(
        code: "policy.host_invocation_required",
        message: "Host service requires one matching live gateway invocation.")
    }
    // Rediscovery can deadlock a parent waiting on this callback. The admitted
    // effect stays immutable; every active or retained context rechecks the grant.
    let descriptor = invocation.admittedCapability
    guard descriptor.mcpReference == invocation.reference,
      policyEvaluator.evaluate(
        capability: descriptor, context: invocation.context,
        grant: try currentHostGrant(), registeredWorkspaceIDs: Set(workspaceOrder)
      ).isAllowed
    else {
      throw Self.invalid(
        code: "policy.host_grant_revoked", message: "The live invocation is no longer authorized.")
    }
    return invocation
  }

  func makeHostServices(context: MCPHostContext, origin: String) throws -> MCPBoundHostServices? {
    guard let database else { return nil }
    try validateHostOrigin(workspaceID: context.workspace.id, origin: origin)
    return MCPBoundHostServices(
      database: database, directory: hostToolDirectory, context: context, origin: origin)
  }

  deinit {
    _ = lifetime.beginShutdown()
  }

  package func shutdown() async {
    ownedWork.closeAdmission()
    hostToolDirectory.attach(nil)
    await lifetime.beginShutdown().value
  }

  /// The generation owner calls this synchronously before releasing its routing lock.
  func beginRetirementIfDrained() -> Task<Void, Never>? {
    guard ownedWork.closeAdmissionIfDrained() else { return nil }
    hostToolDirectory.attach(nil)
    return lifetime.beginShutdown()
  }

  package func authenticatedSession(
    principalID: String, transportTrace: GatewayTransportTrace?
  ) throws -> GatewayRuntime {
    try authenticatedSessionFactory(principalID, transportTrace)
  }

  package func listTools() throws -> [MCPTool] {
    try listTools(context: context)
  }

  package func toolChanges() -> AsyncStream<Void> {
    guard let database else {
      return firstProviderRouter?.toolChanges() ?? AsyncStream { $0.finish() }
    }
    let sources = [firstProviderRouter?.toolChanges(), database.profileChanges(for: grant.id)]
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let tasks = sources.enumerated().compactMap { index, source -> Task<Void, Never>? in
      guard let source else { return nil }
      return Task { [weak self] in
        for await _ in source {
          guard !Task.isCancelled else { break }
          if index == 1 { try? await self?.refreshTools() }
          continuation.yield(())
        }
      }
    }
    continuation.onTermination = { _ in
      for task in tasks { task.cancel() }
    }
    return stream
  }

  package func refreshTools() async throws {
    for workspaceID in workspaceOrder { try await providerRouters[workspaceID]?.refreshTools() }
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

  struct ContinuationLookup: Sendable {
    let workspaceID: String
    let reference: MCPToolReference
    let observation: MCPContinuationDirectory.Lookup
  }

  var unambiguousWorkspaceID: String? {
    context.workspaceID ?? (workspaceOrder.count == 1 ? workspaceOrder.first : nil)
  }

  func callOwnedTool(
    owner: GatewayOwnerSelection, name: String, arguments: JSONValue
  ) async throws -> JSONValue {
    guard owner.runtimeID == generationID,
      let record = ownedWork.snapshot.first(where: {
        $0.id == owner.ownershipID && $0.workspaceID == owner.workspaceID && $0.kind != .invocation
      }), var object = arguments.objectValue,
      !name.hasPrefix("runtime.owners.")
    else { throw GatewayOwnerSelection.unavailable() }
    if let workspace = object["workspace_id"], workspace != .string(owner.workspaceID) {
      throw GatewayOwnerSelection.unavailable()
    }
    object["workspace_id"] = .string(owner.workspaceID)
    var targetName = name
    var targetArguments = object
    if name == "operations.prepare" || name == "operations.commit" {
      targetName = try Self.requiredString("tool", in: object)
      guard !targetName.hasPrefix("runtime.owners."),
        let nested = object["arguments"]?.objectValue,
        nested["workspace_id"] == nil || nested["workspace_id"] == .string(owner.workspaceID)
      else { throw GatewayOwnerSelection.unavailable() }
      targetArguments = nested
    }
    var target: MCPContinuationTarget?
    if let connectionID = record.connectionID {
      let lookup: ContinuationLookup
      if let native = try continuationLookup(
        name: name, arguments: .object(object), workspaceID: owner.workspaceID)
      {
        lookup = native
      } else if targetName.hasPrefix("mcp."),
        let server = targetArguments["server"]?.stringValue, server == record.registrationID
      {
        lookup = .init(
          workspaceID: owner.workspaceID, reference: .init(serverID: server, toolName: targetName),
          observation: .init())
      } else {
        throw GatewayOwnerSelection.unavailable()
      }
      guard lookup.reference.serverID == record.registrationID else {
        throw GatewayOwnerSelection.unavailable()
      }
      if targetName == "mcp.requests.read" || targetName == "mcp.requests.cancel" {
        guard record.kind == .mcpRequest,
          targetArguments["request_id"] == .string(record.resourceID)
        else {
          throw GatewayOwnerSelection.unavailable()
        }
      }
      let matches = lookup.observation.matches.filter { $0.connectionID == connectionID }
      if lookup.observation.applicable && matches.isEmpty {
        throw GatewayOwnerSelection.unavailable()
      }
      if record.kind == .mcpResource, lookup.observation.applicable {
        let identity = try JSONDecoder().decode(JSONValue.self, from: Data(record.resourceID.utf8))
        guard
          matches.contains(where: {
            identity.objectValue?["kind"] == .string($0.resource.kind)
              && identity.objectValue?["id"] == $0.resource.id.json
          })
        else { throw GatewayOwnerSelection.unavailable() }
      }
      target = MCPContinuationTarget(
        workspaceID: owner.workspaceID, reference: lookup.reference, connectionID: connectionID,
        instanceID: ownedWork.continuations.entry(connectionID: connectionID)?.instanceID,
        resources: Dictionary(uniqueKeysWithValues: matches.map { ($0.resource, $0.acquiredBy) }),
        selectedOwnershipID: record.id)
    } else {
      let key: String
      switch targetName {
      case "shell.read", "shell.write", "shell.cancel": key = "session_id"
      case "process.read", "process.cancel": key = "process_id"
      default: throw GatewayOwnerSelection.unavailable()
      }
      guard record.kind == .shell, targetArguments[key] == .string(record.resourceID) else {
        throw GatewayOwnerSelection.unavailable()
      }
    }
    let reservation = try ownedWork.admitInvocation(
      workspaceID: owner.workspaceID, resourceID: name)
    defer { reservation.finish() }
    return try await GatewayOwnerRouting.$selection.withValue(owner) {
      try await MCPContinuationTarget.$current.withValue(target) {
        try await callToolAsync(name: name, arguments: .object(object))
      }
    }
  }

  private func executionOwners(arguments: [String: JSONValue], context: ExecutionContext) throws
    -> JSONValue
  {
    guard let workspaceID = context.workspaceID,
      Set(arguments.keys).isSubset(of: ["server", "after", "limit"]),
      arguments["server"] == nil || arguments["server"]?.stringValue != nil,
      arguments["after"] == nil || arguments["after"]?.stringValue != nil,
      let limit = arguments["limit"]?.int64Value ?? (arguments["limit"] == nil ? 50 : nil),
      (1...100).contains(limit)
    else {
      throw GatewayToolError.invalidArguments("Supply a workspace and a page limit from 1 to 100.")
    }
    let after = arguments["after"]?.stringValue ?? ""
    if !after.isEmpty {
      let parts = after.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 2, parts.allSatisfy({ UUID(uuidString: String($0)) != nil }) else {
        throw GatewayToolError.invalidArguments("Invalid execution owner cursor.")
      }
    }
    let server = arguments["server"]?.stringValue
    var selected: [(GatewayRuntime, GatewayOwnedWork.Record, GatewayOwnerSelection)] = []
    let candidates = GatewayOwnerRouting.runtimes.isEmpty ? [self] : GatewayOwnerRouting.runtimes
    for runtime in candidates {
      guard runtime.context.principalID == context.principalID,
        runtime.context.profileID == context.profileID, runtime.context.caller == context.caller,
        let grant = try? runtime.currentHostGrant(),
        grant.workspaceIDs.contains("*") || grant.workspaceIDs.contains(workspaceID),
        grant.allowedCallers.contains(context.caller),
        (try? runtime.validateExecutionWorkspace(workspaceID)) != nil
      else { continue }
      let policy = MCPToolAccessPolicy(
        configuration: runtime.configuration, grant: grant, derivesObserveGrant: false)
      let visibleServers = Set(
        runtime.configuration.mcp.servers.filter { policy.isVisible($0) }.map(\.id))
      for record in runtime.ownedWork.snapshot
      where record.kind != .invocation && record.workspaceID == workspaceID {
        if let server, record.registrationID != server { continue }
        if let registration = record.registrationID {
          guard visibleServers.contains(registration) else { continue }
        } else {
          guard record.kind == .shell, grant.fullShellEnabled, grant.permitsRisk(.fullShell) else {
            continue
          }
        }
        let owner = GatewayOwnerSelection(
          runtimeID: runtime.generationID, workspaceID: workspaceID, ownershipID: record.id)
        guard owner.cursor > after else { continue }
        selected.append((runtime, record, owner))
        selected.sort { $0.2.cursor < $1.2.cursor }
        if selected.count > Int(limit) + 1 { selected.removeLast() }
      }
    }
    var rows: [JSONValue] = []
    var bytes = 0
    var last: String?
    for (runtime, record, owner) in selected.prefix(Int(limit)) {
      var row: [String: JSONValue] = [
        "owner": owner.json, "kind": .string(record.kind.rawValue),
        "uncertain": .bool(record.uncertain),
        "current": .bool(runtime.generationID == generationID),
        "server": record.registrationID.map(JSONValue.string) ?? .null,
        "connection_id": record.connectionID.map { .string($0.uuidString) } ?? .null,
      ]
      if record.resourceID.utf8.count <= 4_096 { row["resource_id"] = .string(record.resourceID) }
      let value = JSONValue.object(row)
      let size = try Self.encoder.encode(value).count
      guard bytes + size <= 131_072 else { break }
      bytes += size
      rows.append(value)
      last = owner.cursor
    }
    return .object([
      "owners": .array(rows),
      "next_cursor": rows.count < selected.count ? last.map(JSONValue.string) ?? .null : .null,
      "live_directory": .bool(true),
    ])
  }

  private func selectedOwnerCall(arguments: [String: JSONValue], context: ExecutionContext)
    async throws -> JSONValue
  {
    guard Set(arguments.keys).isSubset(of: ["owner", "tool", "arguments"]) else {
      throw GatewayOwnerSelection.unavailable()
    }
    let owner = try GatewayOwnerSelection(arguments["owner"])
    guard owner.workspaceID == context.workspaceID else {
      throw GatewayOwnerSelection.unavailable()
    }
    let name = try Self.requiredString("tool", in: arguments)
    let target = arguments["arguments"] ?? .object([:])
    if let call = GatewayOwnerRouting.call { return try await call(owner, name, target) }
    return try await callOwnedTool(owner: owner, name: name, arguments: target)
  }

  /// Resolves cached routing and accepted ownership without starting a provider.
  func continuationLookup(name: String, arguments: JSONValue?, workspaceID: String?) throws
    -> ContinuationLookup?
  {
    var name = name
    var arguments = arguments?.objectValue ?? [:]
    if name == "operations.prepare" || name == "operations.commit" {
      name = try Self.requiredString("tool", in: arguments)
      arguments = arguments["arguments"]?.objectValue ?? [:]
    }
    guard let workspaceID = arguments["workspace_id"]?.stringValue ?? workspaceID,
      let router = providerRouters[workspaceID]
    else { return nil }
    let reference: MCPToolReference
    let nativeArguments: JSONValue
    if name == "mcp.tools.call" {
      reference = try .init(
        serverID: Self.requiredString("server", in: arguments),
        toolName: Self.requiredString("tool", in: arguments))
      nativeArguments = arguments["arguments"] ?? .object([:])
    } else {
      guard let nativeReference = router.continuationReference(named: name) else { return nil }
      reference = nativeReference
      arguments.removeValue(forKey: "workspace_id")
      nativeArguments = .object(arguments)
    }
    return try ContinuationLookup(
      workspaceID: workspaceID, reference: reference,
      observation: ownedWork.continuations.lookup(
        workspaceID: workspaceID, registrationID: reference.serverID,
        tool: reference.toolName, arguments: nativeArguments))
  }

  package func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    try callTool(name: name, arguments: arguments, context: contextForCall())
  }

  package func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    try await callToolAsync(name: name, arguments: arguments, context: contextForCall())
  }

  private func effectiveOperationDescriptor(
    _ descriptor: CapabilityDescriptor,
    arguments: [String: JSONValue]
  ) -> CapabilityDescriptor {
    guard descriptor.mcpReference == nil,
      configuration.builtin.enabled.contains(descriptor.id),
      !configuration.tools.contains(where: { $0.name == descriptor.id }),
      let defaultDryRun = Self.reviewedDryRunCapabilities[descriptor.id]
    else {
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
    let callContext = contextForMCP(arguments: arguments)
    do {
      return try await callToolAsync(name: name, arguments: arguments, context: callContext)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return routingErrorForMCP(error, name: name, arguments: arguments, context: callContext)
    }
  }

  func routingErrorForMCP(
    _ error: any Error, name: String, arguments: JSONValue?, context: ExecutionContext? = nil,
    recordFailure: Bool = false
  ) -> JSONValue {
    let context = context ?? contextForMCP(arguments: arguments)
    let linkage = Self.operationLinkageFromArguments(
      name: name, arguments: arguments?.objectValue ?? [:])
    let result = Self.attachExecutionMetadata(
      to: Self.errorEnvelope(error), context: context, capabilityID: name, operationLinkage: linkage
    )
    if recordFailure {
      try? recordAudit(
        context: context, capabilityID: name, decision: Self.auditDecision(for: error),
        errorCode: Self.auditErrorCode(for: error), duration: .zero,
        inputDigest: try? Self.inputDigest(tool: name, arguments: arguments?.objectValue ?? [:]),
        output: result, operationLinkage: linkage)
    }
    return result
  }

  private func contextForMCP(arguments: JSONValue?) -> ExecutionContext {
    var callContext = contextForCall()
    let object = arguments?.objectValue ?? [:]
    if let workspaceID = object["workspace_id"]?.stringValue {
      callContext.workspaceID = workspaceID
    } else if callContext.workspaceID == nil, workspaceOrder.count == 1 {
      callContext.workspaceID = workspaceOrder[0]
    }
    return callContext
  }

  package func callTool(
    name: String,
    arguments: JSONValue?,
    context: ExecutionContext
  ) throws -> JSONValue {
    let ownership = try ownedWork.admitInvocation(
      workspaceID: arguments?.objectValue?["workspace_id"]?.stringValue ?? context.workspaceID,
      resourceID: name)
    defer { ownership.finish() }
    return try perform(
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
    let ownership = try ownedWork.admitInvocation(
      workspaceID: arguments?.objectValue?["workspace_id"]?.stringValue ?? context.workspaceID,
      resourceID: name)
    defer { ownership.finish() }
    return try await performAsync(
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
      let descriptor = try invocationDescriptor(
        named: name, arguments: arguments, context: originalContext)
      let routed = try route(
        descriptor: descriptor,
        arguments: arguments,
        context: originalContext
      )
      auditContext = routed.context
      inputDigest = try Self.inputDigest(tool: name, arguments: routed.arguments)
      let authorizedGrant = try authorize(descriptor, context: routed.context)
      if !bypassOperationTicket, name != "operations.commit", name != "operations.prepare",
        authorizedGrant.confirmationPolicy.requiresConfirmation(
          for: effectiveOperationDescriptor(descriptor, arguments: routed.arguments).risk)
      {
        let pending = try prepareOperation(
          arguments: ["tool": .string(name), "arguments": .object(routed.arguments)],
          context: routed.context)
        throw Self.invalid(
          code: "operations.approval_required",
          message:
            "Pending local approval ticket \(pending.ticketID) for '\(name)'. After local approval, call operations.commit with this ticket, tool and the exact original arguments. No operation was executed."
        )
      }

      let rawResult: JSONValue
      switch name {
      case "workspace.list":
        rawResult = try resultEnvelope(workspaceList(context: routed.context))
      case "runtime.owners.list":
        rawResult = try resultEnvelope(
          executionOwners(arguments: routed.arguments, context: routed.context))
      case "runtime.owners.call":
        throw GatewayToolError.invalidArguments(
          "Execution owner calls require asynchronous dispatch.")
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
        let hostInvocation = try beginHostInvocation(
          descriptor: descriptor, name: name, arguments: routed.arguments,
          context: routed.context, linkage: operationLinkage,
          authorizationRevision: authorizedGrant.authorizationRevision)
        defer { hostToolDirectory.end(hostInvocation) }
        rawResult = try MCPInvocationAdmission.$current.withValue(
          MCPInvocationAdmission(descriptor: descriptor, hostInvocationID: hostInvocation?.id)
        ) {
          try providerRouter.callTool(
            name: name,
            arguments: .object(routed.arguments),
            expectedCapability: name == "mcp.tools.call" ? nil : descriptor
          )
        }
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
      let descriptor = try await Self.performAdmission {
        try self.invocationDescriptor(named: name, arguments: arguments, context: originalContext)
      }
      let routed = try route(
        descriptor: descriptor,
        arguments: arguments,
        context: originalContext
      )
      auditContext = routed.context
      inputDigest = try Self.inputDigest(tool: name, arguments: routed.arguments)
      let authorizedGrant = try authorize(descriptor, context: routed.context)
      if !bypassOperationTicket, name != "operations.commit", name != "operations.prepare",
        authorizedGrant.confirmationPolicy.requiresConfirmation(
          for: effectiveOperationDescriptor(descriptor, arguments: routed.arguments).risk)
      {
        let pending = try await Self.performAdmission {
          try self.prepareOperation(
            arguments: ["tool": .string(name), "arguments": .object(routed.arguments)],
            context: routed.context)
        }
        throw Self.invalid(
          code: "operations.approval_required",
          message:
            "Pending local approval ticket \(pending.ticketID) for '\(name)'. After local approval, call operations.commit with this ticket, tool and the exact original arguments. No operation was executed."
        )
      }

      let rawResult: JSONValue
      switch name {
      case "workspace.list":
        rawResult = try resultEnvelope(workspaceList(context: routed.context))
      case "runtime.owners.list":
        rawResult = try resultEnvelope(
          executionOwners(arguments: routed.arguments, context: routed.context))
      case "runtime.owners.call":
        rawResult = try await selectedOwnerCall(
          arguments: routed.arguments, context: routed.context)
      case "workspace.describe":
        rawResult = try resultEnvelope(workspaceDescribe(arguments: routed.arguments))
      case "policy.probe":
        rawResult = try await Self.performAdmission {
          try self.resultEnvelope(
            self.policyProbe(arguments: routed.arguments, context: routed.context))
        }
      case "operations.prepare":
        let preparation = try await Self.performAdmission {
          try self.prepareOperation(arguments: routed.arguments, context: routed.context)
        }
        operationLinkage = OperationAuditLinkage(ticketID: preparation.ticketID)
        rawResult = try resultEnvelope(preparation.result)
      case "operations.commit":
        let invocation = try await Self.performAdmission {
          try self.beginOperationCommit(arguments: routed.arguments, context: routed.context)
        }
        operationLinkage = invocation.linkage
        rawResult = try await executeCommittedOperationAsync(invocation)
      default:
        guard let registryWorkspaceID = routed.registryWorkspaceID else {
          throw GatewayRuntimeError.noWorkspaces
        }
        guard let providerRouter = providerRouters[registryWorkspaceID] else {
          throw GatewayRuntimeError.workspaceNotFound(registryWorkspaceID)
        }
        let hostInvocation = try beginHostInvocation(
          descriptor: descriptor, name: name, arguments: routed.arguments,
          context: routed.context, linkage: operationLinkage,
          authorizationRevision: authorizedGrant.authorizationRevision)
        defer { hostToolDirectory.end(hostInvocation) }
        rawResult = try await MCPInvocationAdmission.$current.withValue(
          MCPInvocationAdmission(descriptor: descriptor, hostInvocationID: hostInvocation?.id)
        ) {
          try await providerRouter.callToolAsync(
            name: name,
            arguments: .object(routed.arguments),
            expectedCapability: name == "mcp.tools.call" ? nil : descriptor
          )
        }
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
    let targetDescriptor = try invocationDescriptor(
      named: toolName, arguments: targetArguments, context: context)
    let effectiveRisk = effectiveOperationDescriptor(
      targetDescriptor, arguments: targetArguments
    ).risk
    guard effectiveRisk != .readOnly else {
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
    let currentGrant = try authorize(targetDescriptor, context: routed.context)
    let requiresApproval = currentGrant.confirmationPolicy.requiresConfirmation(for: effectiveRisk)
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
      inputDigest: try operationInputDigest(
        descriptor: targetDescriptor, arguments: routed.arguments),
      stateDigest: stateDigest,
      state: requiresApproval ? .pendingApproval : .prepared,
      prepareRequestID: routed.context.requestID,
      createdAt: now,
      expiresAt: now.addingTimeInterval(Double(ttlMilliseconds) / 1_000),
      authorizationRevision: currentGrant.authorizationRevision,
      reviewSummary: try Self.operationReviewSummary(
        GatewayOwnerRouting.selection.map {
          ["execution_owner": $0.json, "arguments": .object(routed.arguments)]
        } ?? routed.arguments)
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
        "state": .string(ticket.state.rawValue),
        "requires_local_approval": .bool(requiresApproval),
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
    let targetDescriptor = try invocationDescriptor(
      named: capabilityID, arguments: targetArguments, context: context)
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
      "effective_risk": .string(
        effectiveOperationDescriptor(targetDescriptor, arguments: routed.arguments).risk
          .rawValue),
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
    let targetDescriptor = try invocationDescriptor(
      named: toolName, arguments: targetArguments, context: context)
    let routed = try route(
      descriptor: targetDescriptor,
      arguments: targetArguments,
      context: context
    )
    let currentGrant = try authorize(targetDescriptor, context: routed.context)
    guard ticket.authorizationRevision == currentGrant.authorizationRevision else {
      throw Self.invalid(
        code: "operations.authorization_changed",
        message: "Authorization changed after this operation was prepared.")
    }
    guard routed.context.workspaceID == ticket.workspaceID,
      try operationInputDigest(descriptor: targetDescriptor, arguments: routed.arguments)
        == ticket.inputDigest
    else {
      throw Self.invalid(
        code: "operations.ticket_arguments_mismatch",
        message:
          "The committed arguments, provider identity or workspace do not match the prepared operation."
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
    let current = try? currentHostGrant()
    let rows = workspaceOrder.compactMap { id -> JSONValue? in
      guard let workspace = workspaces[id],
        current?.workspaceIDs.contains("*") == true || current?.workspaceIDs.contains(id) == true
      else {
        return nil
      }
      return .object([
        "id": .string(workspace.id),
        "display_name": .string(workspace.displayName),
        "bookmark_stale": .bool(workspace.bookmarkIsStale),
        "access": WorkspaceAccessReport(workspace: workspace, error: workspaceErrors[id]).json,
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
      "access": WorkspaceAccessReport(workspace: workspace, error: workspaceErrors[id]).json,
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

    let registryWorkspaceID =
      routedContext.workspaceID
      ?? workspaceOrder.first { providerRouters[$0] != nil }
    if let registryWorkspaceID, workspaces[registryWorkspaceID] == nil {
      throw GatewayRuntimeError.workspaceNotFound(registryWorkspaceID)
    }
    return RoutedCall(
      arguments: cleanArguments,
      context: routedContext,
      registryWorkspaceID: registryWorkspaceID
    )
  }

  @discardableResult
  private func authorize(
    _ descriptor: CapabilityDescriptor,
    context: ExecutionContext
  ) throws -> ProfileGrant {
    if descriptor.mcpReference != nil || descriptor.id.hasPrefix("mcp.")
      || descriptor.id.hasPrefix("runtime.owners.")
    {
      guard context.caller == self.context.caller,
        context.profileID == self.context.profileID,
        context.principalID == self.context.principalID
      else {
        throw Self.invalid(
          code: PolicyDenialCode.callerDenied.rawValue,
          message:
            "Runtime-owned calls must retain their gateway connection's caller and provenance.")
      }
    }
    let authorizedGrant = try currentHostGrant()
    let decision = policyEvaluator.evaluate(
      capability: descriptor,
      context: context,
      grant: authorizedGrant,
      registeredWorkspaceIDs: Set(workspaceOrder)
    )
    guard case .allow = decision else {
      if case .deny(let code, let message) = decision {
        throw Self.invalid(code: code.rawValue, message: message)
      }
      throw Self.invalid(code: "policy.denied", message: "The capability was denied.")
    }
    if let workspaceID = context.workspaceID {
      if descriptor.id.hasPrefix("runtime.owners.") {
        // Directory access uses the current registration; the selected target separately
        // validates its original execution scope, including registration lifetime and root.
        _ = try currentRegisteredWorkspace(workspaceID)
      } else {
        try validateExecutionWorkspace(workspaceID)
      }
    }
    if let workspaceID = context.workspaceID, let error = workspaceErrors[workspaceID],
      !Self.coreTools(databaseEnabled: database != nil).contains(where: { $0.name == descriptor.id }
      )
    {
      throw Self.invalid(code: error.code, message: error.localizedDescription)
    }
    if descriptor.id.hasPrefix("shell.") && !configuration.policy.shellEnabled {
      throw Self.invalid(
        code: PolicyDenialCode.fullShellDisabled.rawValue,
        message: "Full Shell is disabled by the active gateway manifest."
      )
    }
    return authorizedGrant
  }

  private func isVisible(
    _ descriptor: CapabilityDescriptor,
    context: ExecutionContext
  ) -> Bool {
    guard let grant = try? currentHostGrant() else { return false }
    if context.workspaceID != nil,
      !policyEvaluator.evaluate(
        capability: descriptor, context: context, grant: grant,
        registeredWorkspaceIDs: Set(workspaceOrder)
      ).isAllowed
    {
      return false
    }
    guard context.profileID == grant.id else {
      return false
    }
    if !grant.allowedCallers.contains(context.caller) {
      return false
    }
    if context.caller.isRemote && descriptor.localOnly {
      return false
    }
    guard grant.grants(descriptor) else {
      return false
    }
    guard grant.permitsRisk(descriptor.risk) else { return false }
    if descriptor.risk == .fullShell {
      return grant.fullShellEnabled
        && (!descriptor.id.hasPrefix("shell.") || configuration.policy.shellEnabled)
    }
    return true
  }

  private func descriptor(named name: String, workspaceID: String? = nil) throws
    -> CapabilityDescriptor
  {
    if let tool = Self.coreTools(databaseEnabled: database != nil)
      .first(where: { $0.name == name })
    {
      return GatewayCapabilityCatalog().descriptor(for: tool)
    }
    if let router = workspaceID.flatMap({ providerRouters[$0] }) ?? firstProviderRouter {
      return try router.capability(named: name)
    }
    throw GatewayToolError.unknownTool(name)
  }

  private func invocationDescriptor(
    named name: String, arguments: [String: JSONValue], context: ExecutionContext
  ) throws -> CapabilityDescriptor {
    if name == "mcp.connections.close", MCPContinuationTarget.current?.selectedOwnershipID == nil {
      throw Self.invalid(
        code: "mcp.connection_owner_required",
        message:
          "Select a live execution owner with runtime.owners.call before closing its connection.")
    }
    let workspaceID = arguments["workspace_id"]?.stringValue ?? context.workspaceID
    var descriptor = try descriptor(named: name, workspaceID: workspaceID)
    if name == "mcp.tools.call" {
      let serverID = try Self.requiredString("server", in: arguments)
      let toolName = try Self.requiredString("tool", in: arguments)
      let reference = MCPToolReference(serverID: serverID, toolName: toolName)
      descriptor.mcpReference = reference
      descriptor.equivalentCapabilityIDs = configuration.mcpCapabilityIDs(for: reference)
      descriptor.risk = configuration.mcpRisk(for: reference)
      // Denial must not reveal whether an out-of-scope registration or selection exists.
      guard try currentHostGrant().grants(descriptor) else {
        throw Self.invalid(
          code: PolicyDenialCode.capabilityDenied.rawValue,
          message: "The profile does not grant this downstream MCP tool.")
      }
      guard let server = configuration.mcp.servers.first(where: { $0.id == serverID }) else {
        throw GatewayToolError.unknownMCPServer(serverID)
      }
      guard server.permitsTool(toolName) else {
        throw Self.invalid(
          code: "mcp.tool_not_approved",
          message: "The host has not approved this downstream MCP tool.")
      }
      if server.hostServices { descriptor.workspaceRequirement = .required }
    }
    guard let reference = descriptor.mcpReference else { return descriptor }
    let routed = try route(descriptor: descriptor, arguments: arguments, context: context)
    // Check caller and workspace authority before querying a downstream catalog.
    try authorize(descriptor, context: routed.context)
    guard let workspaceID = routed.registryWorkspaceID,
      let router = providerRouters[workspaceID]
    else { throw GatewayRuntimeError.noWorkspaces }
    descriptor.risk = try router.downstreamRisk(for: reference)
    return descriptor
  }

  private var firstProviderRouter: GatewayProviderRouter? {
    workspaceOrder.lazy.compactMap { self.providerRouters[$0] }.first
  }

  private func contextForCall() -> ExecutionContext {
    var callContext = context
    callContext.requestID = UUID().uuidString
    if let trace = MCPRuntimeAdapter.requestTrace { callContext.transportTrace = trace }
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
        principalDigest: AuditEvent.verifiedPrincipalDigest(context.trustedPrincipalID),
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
    if let owner = GatewayOwnerRouting.selection { executionObject["execution_owner"] = owner.json }
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
      if capabilityID == "operations.commit" || capabilityID == "runtime.owners.call",
        let targetExecution = structuredContent["gateway_execution"]
      {
        structuredContent["target_execution"] = targetExecution
      }
      structuredContent["gateway_execution"] = execution
      object["structuredContent"] = .object(structuredContent)
    }

    var metadata = object["_meta"]?.objectValue ?? [:]
    if capabilityID == "operations.commit" || capabilityID == "runtime.owners.call",
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
        description:
          "List workspaces registered and granted to the active profile. This remote tool cannot "
          + "register authorization roots; use the owner-only local 'computer-mcp workspace add' "
          + "command and never operate the Computer MCP UI through Computer Use.",
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
    tools.append(contentsOf: GatewayOwnerRouting.tools)
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
      meta: tool.meta,
      mcpReference: tool.mcpReference
    )
  }

  private func currentStateDigest(
    tool: String,
    arguments: [String: JSONValue],
    context: ExecutionContext
  ) throws -> String? {
    let reviewedTargets: Set<String> = [
      "archive.create", "archive.extract", "file.append", "file.chmod", "file.copy",
      "file.download", "file.insert_text", "file.mkdir", "file.move", "file.remove_xattr",
      "file.replace_lines", "file.replace_text", "file.symlink", "file.touch", "file.trash",
      "file.write", "file.write_files", "git.add", "git.branch_create", "git.branch_delete",
      "git.branch_rename", "git.branch_switch", "git.clean", "git.commit",
      "git.restore_worktree", "git.stash_push", "git.tag_create", "git.tag_delete", "git.unstage",
      "json.write", "plist.write",
    ]
    guard reviewedTargets.contains(tool), configuration.builtin.enabled.contains(tool),
      !configuration.tools.contains(where: { $0.name == tool }),
      try invocationDescriptor(named: tool, arguments: arguments, context: context).mcpReference
        == nil
    else { return nil }
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
      if tool == "file.remove_xattr", let name = arguments["name"]?.stringValue {
        let count = getxattr(url.path, name, nil, 0, 0, 0)
        if count == -1, errno == ENOATTR {
          records.append(.object(["xattr": .string(name), "present": .bool(false)]))
        } else {
          guard count >= 0, count <= 1_048_576 else {
            throw Self.invalid(
              code: "operations.state_unavailable",
              message: "Cannot bind the extended attribute within its byte limit.")
          }
          var value = Data(count: count)
          let read = value.withUnsafeMutableBytes {
            getxattr(url.path, name, $0.baseAddress, count, 0, 0)
          }
          guard read == count else {
            throw Self.invalid(
              code: "operations.state_changed",
              message: "The extended attribute changed while binding approval state.")
          }
          records.append(
            .object([
              "xattr": .string(name), "present": .bool(true),
              "sha256": .string(Self.digest(value)),
            ]))
        }
      }
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
        "size": .integer(Int64(size)),
        "modified_at": .number(modified),
        "permissions": .integer(Int64((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0)),
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
    let value = context.principalID
    return SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  static func operationReviewSummary(_ arguments: [String: JSONValue]) throws -> String {
    func exceedsBudget() -> GatewayToolError {
      invalid(
        code: "operations.review_too_large",
        message:
          "This request exceeds the local approval preview budget; split it into reviewable operations."
      )
    }
    var remainingEntries = 1_000
    func validate(_ value: JSONValue, depth: Int) throws {
      guard depth <= 12, remainingEntries > 0 else { throw exceedsBudget() }
      remainingEntries -= 1
      switch value {
      case .object(let object):
        var displayedKeys = Set<String>()
        for (key, child) in object {
          guard key.utf8.count <= 256 else { throw exceedsBudget() }
          let displayedKey = HostApprovalRedactor.redactString(key, maximumCharacters: 256)
          guard displayedKeys.insert(displayedKey).inserted else {
            throw invalid(
              code: "operations.review_ambiguous",
              message: "Redaction would merge distinct argument names; simplify the request.")
          }
          try validate(child, depth: depth + 1)
        }
      case .array(let children):
        for child in children { try validate(child, depth: depth + 1) }
      case .string(let text):
        guard text.utf8.count <= 8_192 else { throw exceedsBudget() }
      case .number, .integer, .bool, .null: break
      }
    }
    let value = JSONValue.object(arguments)
    try validate(value, depth: 0)
    guard try encoder.encode(value).count <= 16_384 else { throw exceedsBudget() }
    // Approval previews may redact secrets but must never silently omit or truncate arguments.
    let data = try encoder.encode(HostApprovalRedactor.redact(value))
    guard data.count <= 16_384 else { throw exceedsBudget() }
    return String(decoding: data, as: UTF8.self)
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

  private func operationInputDigest(
    descriptor: CapabilityDescriptor, arguments: [String: JSONValue]
  ) throws -> String {
    var binding: [String: JSONValue] = [
      "capability": try .encoded(descriptor), "arguments": .object(arguments),
    ]
    if let owner = GatewayOwnerRouting.selection { binding["execution_owner"] = owner.json }
    if let reference = descriptor.mcpReference {
      guard let server = configuration.mcp.servers.first(where: { $0.id == reference.serverID })
      else {
        throw Self.invalid(
          code: "operations.provider_unavailable", message: "The operation provider is unavailable."
        )
      }
      // Registration launch/authentication inputs and plugin provenance are approval identity.
      // Only their digest is stored; credentials never become a review or audit preview.
      binding["registration"] = try .encoded(server)
      if let origin = pluginOrigins[.init(kind: .mcp, id: reference.serverID)] {
        binding["plugin"] = try .encoded(origin)
      }
    } else if descriptor.risk == .fullShell {
      binding["execution_configuration"] = try .encoded(configuration.cli)
      binding["shell_policy"] = .bool(configuration.policy.shellEnabled)
    }
    return MCPExecutionRecord.digest(.object(binding))
  }

  private static func inputDigest(
    tool: String,
    arguments: [String: JSONValue]
  ) throws -> String {
    var input: [String: JSONValue] = ["tool": .string(tool), "arguments": .object(arguments)]
    if let owner = GatewayOwnerRouting.selection { input["execution_owner"] = owner.json }
    let data = try encoder.encode(JSONValue.object(input))
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

private struct PreparedOperation: Sendable {
  var ticketID: String
  var result: JSONValue
}

private struct OperationAuditLinkage: Sendable {
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

private struct OperationInvocation: Sendable {
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

private struct RoutedCall: Sendable {
  var arguments: [String: JSONValue]
  var context: ExecutionContext
  var registryWorkspaceID: String?
}

/// Retains each acquired resource until one shared cleanup task has joined it, including failed initialization.
private final class GatewayRuntimeLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private var cleanup: [@Sendable () async -> Void] = []
  private var shutdown: Task<Void, Never>?
  var isClosing: Bool { lock.withLock { shutdown != nil } }

  @discardableResult
  func onShutdown(_ operation: @escaping @Sendable () async -> Void) -> Int {
    lock.withLock {
      precondition(shutdown == nil)
      cleanup.append(operation)
      return cleanup.count - 1
    }
  }

  func replaceShutdown(_ index: Int, with operation: @escaping @Sendable () async -> Void) {
    lock.withLock {
      precondition(shutdown == nil)
      cleanup[index] = operation
    }
  }

  func beginShutdown() -> Task<Void, Never> {
    lock.withLock {
      if let shutdown { return shutdown }
      let operations = cleanup.reversed()
      cleanup.removeAll()
      let task = Task {
        for operation in operations { await operation() }
      }
      shutdown = task
      return task
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
