import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPEgress
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPPlugins
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPToolKit
import ComputerMCPTransport
import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

package final class GatewayRuntime: GatewayToolServing, @unchecked Sendable {
  private let configuration: GatewayConfiguration
  private let context: ExecutionContext
  private let requiresControlSession: Bool
  private let grant: ProfileGrant
  private let requiresPersistedGrant: Bool
  private let persistedProjectRegistrations: [String: ComputerMCPCore.RegisteredProject]
  private let policyEvaluator: GatewayPolicyEvaluator
  private let database: GatewayDatabase?
  private let projects: [String: ComputerMCPCore.RegisteredProject]
  private let projectOrder: [String]
  private let projectAccesses: [String: ResolvedProjectAccess]
  private let platform: PlatformServices
  private let projectErrors: [String: ProjectBookmarkError]
  private let providerRouters: [String: GatewayProviderRouter]
  private let unscopedRouter: GatewayProviderRouter?
  package let permissionRuntime: GatewayPermissionRuntime
  private let lifetime: GatewayRuntimeLifetime
  private let publication = GatewayRuntimePublication()
  private let configurationResolution: GatewayConfigurationResolution
  package let ownedWork = GatewayOwnedWork()
  package let generationID = UUID()
  private let generationInputs: GatewayDatabase.ConfigurationState?
  private let authenticatedSessionFactory:
    @Sendable (String, GatewayTransportTrace?, Bool, Bool) throws -> GatewayRuntime
  private static let construction = BlockingOperationExecutor(
    label: "computer-mcp.gateway-construction", serial: false)
  private static let admission = BlockingOperationExecutor(
    label: "computer-mcp.gateway-admission", serial: false)
  private static func performAdmission<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    let owner = GatewayOwnerRouting.selection
    let callback = GatewayHostToolScope.execution
    let callbackLifetime = GatewayHostToolScope.lifetime
    let projectID = GatewayHostToolScope.projectID
    return try await admission.perform {
      try GatewayOwnerRouting.$selection.withValue(owner) {
        try GatewayHostToolScope.$execution.withValue(callback) {
          try GatewayHostToolScope.$lifetime.withValue(callbackLifetime) {
            try GatewayHostToolScope.$projectID.withValue(projectID, operation: operation)
          }
        }
      }
    }
  }

  private let remoteManagement: (any GatewayManagementProvider)?
  private let hostToolDirectory = MCPHostToolDirectory()
  package let pluginOrigins: [IntegrationRegistration: PluginContributionOrigin]
  package let pluginDiagnostics: [PluginResolutionDiagnostic]
  package let pluginIssues: [PluginStoreIssue]

  /// Synchronous construction starts discovery. Async callers use `make` to join failed startup cleanup.
  package convenience init(
    configuration: GatewayConfiguration,
    context: ExecutionContext? = nil,
    database: GatewayDatabase? = nil,
    registeredProjects: [ComputerMCPCore.RegisteredProject]? = nil,
    platform: PlatformServices,
    policyEvaluator: GatewayPolicyEvaluator = GatewayPolicyEvaluator(),
    mcpClient: (any DownstreamMCPClient)? = nil,
    plugins: [ResolvedPlugin]? = nil,
    pluginState: PluginStoreSnapshot? = nil,
    bundledPlugins: BundledPlugins = .current,
    terminalSessions: GatewayTerminalSessions = GatewayTerminalSessions(),
    requiresControlSession: Bool = false,
    remoteManagement: (any GatewayManagementProvider)? = nil
  ) throws {
    try self.init(
      configuration: configuration, context: context, database: database,
      registeredProjects: registeredProjects, platform: platform,
      policyEvaluator: policyEvaluator,
      mcpClient: mcpClient ?? MCPProxyClient(launcher: platform.launcher), plugins: plugins,
      pluginState: pluginState,
      bundledPlugins: bundledPlugins, terminalSessions: terminalSessions,
      lifetime: GatewayRuntimeLifetime(), preparationState: nil, artifactStorage: nil,
      requiresControlSession: requiresControlSession, remoteManagement: remoteManagement)
  }

  package static func make(
    configuration: GatewayConfiguration,
    context: ExecutionContext? = nil,
    database: GatewayDatabase? = nil,
    registeredProjects: [ComputerMCPCore.RegisteredProject]? = nil,
    platform: PlatformServices,
    policyEvaluator: GatewayPolicyEvaluator = GatewayPolicyEvaluator(),
    mcpClient: (any DownstreamMCPClient)? = nil,
    plugins: [ResolvedPlugin]? = nil,
    pluginState: PluginStoreSnapshot? = nil,
    bundledPlugins: BundledPlugins = .current,
    terminalSessions: GatewayTerminalSessions = GatewayTerminalSessions(),
    requiresControlSession: Bool = false,
    remoteManagement: (any GatewayManagementProvider)? = nil
  ) async throws -> GatewayRuntime {
    try Task.checkCancellation()
    let lifetime = GatewayRuntimeLifetime()
    do {
      let runtime = try await construction.perform {
        try GatewayRuntime(
          configuration: configuration, context: context, database: database,
          registeredProjects: registeredProjects, platform: platform,
          policyEvaluator: policyEvaluator,
          mcpClient: mcpClient ?? MCPProxyClient(launcher: platform.launcher), plugins: plugins,
          pluginState: pluginState,
          bundledPlugins: bundledPlugins, terminalSessions: terminalSessions, lifetime: lifetime,
          preparationState: nil, artifactStorage: nil,
          requiresControlSession: requiresControlSession, remoteManagement: remoteManagement)
      }
      try Task.checkCancellation()
      return runtime
    } catch {
      await lifetime.beginShutdown().value
      throw error
    }
  }

  /// Discovery owns its resources, but candidate callbacks and invocations remain closed
  /// until the listener publishes the committed generation.
  package static func prepare(
    configuration: GatewayConfiguration, context: ExecutionContext,
    database: GatewayDatabase, state: GatewayDatabase.ConfigurationState,
    platform: PlatformServices,
    mcpClient: (any DownstreamMCPClient)? = nil,
    bundledPlugins: BundledPlugins = .current,
    terminalSessions: GatewayTerminalSessions = GatewayTerminalSessions(),
    artifactStorage: PluginInstallationStorage? = nil,
    requiresControlSession: Bool = false,
    remoteManagement: (any GatewayManagementProvider)? = nil
  ) async throws -> GatewayRuntimePreparation {
    try Task.checkCancellation()
    let lifetime = GatewayRuntimeLifetime()
    do {
      let runtime = try await construction.perform {
        try GatewayRuntime(
          configuration: configuration, context: context, database: database,
          registeredProjects: state.projects, platform: platform,
          policyEvaluator: GatewayPolicyEvaluator(),
          mcpClient: mcpClient ?? MCPProxyClient(launcher: platform.launcher),
          plugins: nil, pluginState: state.plugins, bundledPlugins: bundledPlugins,
          terminalSessions: terminalSessions, lifetime: lifetime,
          preparationState: state, artifactStorage: artifactStorage,
          requiresControlSession: requiresControlSession, remoteManagement: remoteManagement)
      }
      try Task.checkCancellation()
      return GatewayRuntimePreparation(
        runtime: runtime, resolution: runtime.configurationResolution)
    } catch {
      await lifetime.beginShutdown().value
      throw error
    }
  }

  /// The generation owner installs routing and calls this without suspending after its commit.
  package func requirePreparedPublication() throws {
    guard !lifetime.isClosing else { throw GatewaySocketError.notConnected }
  }

  /// A repaired project must retain the selected folder through candidate publication.
  package func requirePreparedProject(id: String, root: ProjectRootIdentity) throws {
    if let error = projectErrors[id] { throw error }
    guard let project = projects[id], let admitted = projectAccesses[id],
      admitted.isActive, admitted.rootIdentity == root
    else { throw ProjectBookmarkError.rootChanged(projectID: id) }
    let access = try platform.projectGrants.resolve(project)
    defer { access.close() }
    guard access.rootIdentity == root else {
      throw ProjectBookmarkError.rootChanged(projectID: id)
    }
  }

  package func publishPrepared() {
    publication.publish(
      revisionID: (try? database?.configurationRevisions(limit: 50))?.filter {
        $0.activatedAt != nil && $0.activationError == nil
      }.first?.id)
    hostToolDirectory.attach(self)
  }

  private init(
    configuration: GatewayConfiguration, context: ExecutionContext?, database: GatewayDatabase?,
    registeredProjects: [ComputerMCPCore.RegisteredProject]?, platform: PlatformServices,
    policyEvaluator: GatewayPolicyEvaluator, mcpClient: any DownstreamMCPClient,
    plugins: [ResolvedPlugin]?, pluginState: PluginStoreSnapshot?, bundledPlugins: BundledPlugins,
    terminalSessions: GatewayTerminalSessions, lifetime: GatewayRuntimeLifetime,
    preparationState: GatewayDatabase.ConfigurationState?,
    artifactStorage: PluginInstallationStorage?, requiresControlSession: Bool,
    remoteManagement: (any GatewayManagementProvider)?, initializeManifestProjects: Bool = true
  ) throws {
    let initializationConfiguration = configuration
    let database: GatewayDatabase? = try database ?? GatewayDatabase(inMemory: ())
    if preparationState == nil {
      try database!.bootstrapPermissionProfiles(
        Set(GatewayProfileID.builtIns + configuration.profiles.map(\.id)).map {
          configuration.profileGrant(for: $0)
        },
        declarations: configuration.profiles.map(\.grant))
      if initializeManifestProjects && registeredProjects == nil {
        try database!.registerManifestProjectsForStartup(configuration.manifestProjects)
      }
    }
    let capturedInputs = try preparationState ?? database!.configurationState()
    self.permissionRuntime = try database!.permissionRuntime(platform: platform)
    let permissionRuntime = self.permissionRuntime
    self.lifetime = lifetime
    self.requiresControlSession = requiresControlSession
    self.remoteManagement = remoteManagement
    var initialized = false
    defer { if !initialized { _ = lifetime.beginShutdown() } }
    var sourceConfiguration = configuration
    try pluginState?.validate()
    let pluginState = try (pluginState ?? database?.pluginStoreSnapshot() ?? PluginStoreSnapshot())
      .includingBundledDefaults(bundledPlugins.packages.map(\.manifest))
    let artifactLeases = try Self.retainPluginArtifacts(
      state: pluginState, plugins: plugins, database: database,
      directoryFactory: platform.pluginDirectories, transaction: artifactStorage)
    lifetime.onShutdown {
      for lease in artifactLeases { lease.close() }
    }
    sourceConfiguration.knownPluginMCPServerIDs.formUnion(pluginState.knownMCPRegistrationIDs)
    let resolved =
      try plugins == nil
      ? PluginHost.resolve(
        pluginState, bundled: bundledPlugins, applications: platform.applications) : nil
    let composition = try GatewayPluginComposition(
      configuration: sourceConfiguration, plugins: plugins ?? resolved?.plugins ?? [])
    let configuration = composition.runtimeConfiguration
    if preparationState == nil {
      try database!.permissionTransaction(localProviders: sourceConfiguration.mcp.servers) { _ in }
    }
    let providerSource: @Sendable (MCPServerConfig) throws -> MCPProviderExecutionSource = {
      [configuration, origins = composition.origins, database = database!, permissionRuntime] server
      in
      guard configuration.mcp.servers.first(where: { $0.id == server.id }) == server else {
        throw GatewayPermissionError.invalidBinding
      }
      let registration = IntegrationRegistration(kind: .mcp, id: server.id)
      let digest =
        try origins[registration]?.reviewedRequirements?.sourceDigest
        ?? GatewayProviderReview.digest(server)
      return MCPProviderExecutionSource(
        digest: digest,
        prepareDiscovery: {
          let source = try GatewayProviderSource.resolve(
            registration: registration, configuration: configuration,
            origins: origins, database: database)
          return try GatewaySynchronousOperation.run {
            try await permissionRuntime.prepareProvider(
              review: source.review, registrationID: server.id, authorization: nil,
              directory: nil, connectionID: nil, source: source,
              platformRules: Self.permissionPlatformRules(platform: platform, database: database))
          }
        })
    }
    let cliDiscovery: @Sendable (CLICommandConfig) throws -> CLIProviderDiscovery? = {
      [configuration, origins = composition.origins, database = database!, permissionRuntime]
      command in
      let registration = IntegrationRegistration(kind: .cli, id: command.id)
      guard origins[registration] != nil else { return nil }
      let source = try GatewayProviderSource.resolve(
        registration: registration, configuration: configuration, origins: origins,
        database: database)
      let approval = try permissionRuntime.store.readWithDatabase { database, ledger in
        try GatewayPermissionService.executionApproval(
          review: source.review, database: database, ledger: ledger)
      }
      return CLIProviderDiscovery(
        identity: "\(approval.sourceDigest):\(approval.revision):\(approval.epoch)",
        prepare: {
          try GatewaySynchronousOperation.run {
            try await permissionRuntime.prepareProvider(
              review: source.review, registrationID: command.id, authorization: nil,
              directory: nil, connectionID: nil, source: source,
              platformRules: Self.permissionPlatformRules(platform: platform, database: database),
              discoveryInScratch: true)
          }
        })
    }
    pluginOrigins = composition.origins
    pluginDiagnostics = composition.diagnostics
    pluginIssues = resolved?.issues ?? []
    let effectiveContext = context ?? configuration.executionContext()
    let configuredGrant = configuration.profiles.first { $0.id == effectiveContext.profileID }?
      .grant
    let persistedProfiles = capturedInputs.profiles
    let persistedGrant = persistedProfiles.first(where: { $0.id == effectiveContext.profileID })
    let mcpGrant = configuredGrant ?? configuration.profileGrant(for: effectiveContext.profileID)
    let serverPlugins = Dictionary(
      uniqueKeysWithValues: composition.origins.compactMap { registration, origin in
        registration.kind == .mcp ? (registration.id, origin.pluginID) : nil
      })
    let scopedMCPClient = AuthorizedMCPClient(
      base: mcpClient,
      policy: MCPToolAccessPolicy(
        configuration: configuration, grant: persistedGrant ?? mcpGrant,
        fullAccessConsented: false, pluginIDs: serverPlugins),
      policyProvider: { session in
        let persisted = try database?.profiles().first { $0.id == effectiveContext.profileID }
        guard persistedGrant == nil || persisted != nil else {
          throw GatewayToolError.disabled("The profile authorization was revoked.")
        }
        let effective =
          try session?.apply(to: persisted ?? mcpGrant, context: effectiveContext)
          ?? (persisted ?? mcpGrant)
        return MCPToolAccessPolicy(
          configuration: configuration, grant: effective,
          fullAccessConsented: session != nil && effective.fullAccess, pluginIDs: serverPlugins)
      })

    let persistedProjects = capturedInputs.projects
    let configuredProjects =
      registeredProjects
      ?? (initializeManifestProjects && persistedProjects.isEmpty
        ? configuration.manifestProjects : persistedProjects)

    var projectByID: [String: ComputerMCPCore.RegisteredProject] = [:]
    var accessByID: [String: ResolvedProjectAccess] = [:]
    var errorByID: [String: ProjectBookmarkError] = [:]
    var providerRouterByID: [String: GatewayProviderRouter] = [:]
    let commandRunner = ProcessCommandRunner(launcher: platform.launcher)
    var resolution = GatewayConfigurationResolution(localProviders: sourceConfiguration.mcp.servers)

    for project in configuredProjects {
      guard projectByID[project.id] == nil else {
        throw GatewayRuntimeError.duplicateProjectID(project.id)
      }
      projectByID[project.id] = project
      let access: ResolvedProjectAccess
      do {
        access = try platform.projectGrants.resolve(project)
      } catch let error as ProjectBookmarkError {
        errorByID[project.id] = error
        continue
      }
      lifetime.onShutdown { access.close() }
      var projectConfiguration = configuration
      projectConfiguration.projectDirectory = access.rootURL.standardizedFileURL
      let shellManager = ShellSessionRuntime(
        launcher: platform.launcher,
        ownedWork: ownedWork, projectID: project.id, sessions: terminalSessions,
        scope: .project(
          context: effectiveContext, project: access.project, root: access.rootIdentity,
          registered: registeredProjects != nil || !persistedProjects.isEmpty),
        recoveryKey: { ExecutionRecovery.key })
      let processManager = ManagedProcessRegistry(
        shellManager: shellManager,
        maxSessions: configuration.policy.maxShellSessions
      )
      projectByID[project.id] = access.project
      accessByID[project.id] = access
      var hostContext = MCPHostContext(
        runtimeID: generationID, context: effectiveContext, projectID: project.id,
        rootURL: access.rootURL,
        readOnly: !Self.allows(mcpGrant.permissions.state(for: .project(project.id)), .write),
        tools: hostToolDirectory,
        managedProjectRoot: database?.fileURL?.deletingLastPathComponent()
          .appendingPathComponent("Managed Worktrees", isDirectory: true),
        processOwnershipRoot: database?.mcpProcessOwnershipRoot, executionDatabase: database)
      if let database, database.worktreeStorage != nil {
        hostContext.worktrees = GatewayWorktreeService(
          database: database, runtime: permissionRuntime, platform: platform, projectID: project.id)
      }
      hostContext.ownedWork = ownedWork
      hostContext.providerSource = providerSource
      hostContext.cliDiscovery = cliDiscovery
      for (registration, origin) in composition.origins where registration.kind == .mcp {
        if let lease = artifactLeases.first(where: {
          $0.identity.url.appendingPathComponent("package").path == origin.source.root.path
        }) {
          hostContext.pluginArtifacts[registration.id] = lease.identity
        }
      }
      let registry = platform.toolProviders.makeProviders(
        configuration: projectConfiguration,
        commandRunner: commandRunner,
        processManager: processManager,
        shellManager: shellManager,
        mcpClient: scopedMCPClient,
        hostContext: hostContext
      )
      let registryCleanup = lifetime.onShutdown { await registry.shutdown() }
      let router = try GatewayProviderRouter(
        registry: registry,
        reservedToolNames: Set(
          Self.coreDefinitions(databaseEnabled: true, management: nil).map(\.tool.name)
        ).union(platform.managementToolNames),
        origins: composition.origins,
        retainsContinuation: { [ownedWork, projectID = project.id] reference in
          ownedWork.continuations.retainsContinuation(
            projectID: projectID, reference: reference)
        }
      )
      providerRouterByID[project.id] = router
      lifetime.replaceShutdown(registryCleanup) { await router.shutdown() }
      if access.project != project {
        if preparationState != nil {
          resolution.projects.append(.init(original: project, resolved: access.project))
        } else {
          try database?.saveProject(access.project, replacing: project)
        }
      }
    }

    let effectiveGrant =
      persistedGrant ?? configuredGrant
      ?? configuration.profileGrant(for: effectiveContext.profileID)
    var unscoped: GatewayProviderRouter?
    do {
      var unscopedConfiguration = configuration
      unscopedConfiguration.projectDirectory = URL(fileURLWithPath: "/", isDirectory: true)
      let shell = ShellSessionRuntime(
        launcher: platform.launcher, ownedWork: ownedWork, sessions: terminalSessions)
      let processes = ManagedProcessRegistry(
        shellManager: shell, maxSessions: configuration.policy.maxShellSessions)
      var hostContext = MCPHostContext(
        runtimeID: generationID, context: effectiveContext,
        projectID: "unscoped", rootURL: URL(fileURLWithPath: "/"), readOnly: true,
        tools: hostToolDirectory, processOwnershipRoot: database?.mcpProcessOwnershipRoot,
        executionDatabase: database)
      hostContext.ownedWork = ownedWork
      hostContext.providerSource = providerSource
      hostContext.cliDiscovery = cliDiscovery
      if let database, database.worktreeStorage != nil {
        hostContext.worktrees = GatewayWorktreeService(
          database: database, runtime: permissionRuntime, platform: platform, projectID: nil)
      }
      let registry = platform.toolProviders.makeProviders(
        configuration: unscopedConfiguration, commandRunner: commandRunner,
        processManager: processes, shellManager: shell, mcpClient: scopedMCPClient,
        hostContext: hostContext)
      let router = try GatewayProviderRouter(
        registry: registry,
        reservedToolNames: Set(
          Self.coreDefinitions(databaseEnabled: true, management: nil).map(\.tool.name)
        ).union(platform.managementToolNames), origins: composition.origins)
      lifetime.onShutdown { await router.shutdown() }
      unscoped = router
    }
    self.unscopedRouter = unscoped

    self.configurationResolution = resolution
    self.configuration = configuration
    self.context = effectiveContext
    self.grant = effectiveGrant
    self.authenticatedSessionFactory = { principalID, trace, sessionRequired, refreshDirectory in
      var bound = effectiveContext
      bound.trustedPrincipalID = principalID
      bound.transportTrace = trace
      bound.controlSession = nil
      return try GatewayRuntime(
        configuration: initializationConfiguration, context: bound, database: database,
        registeredProjects: refreshDirectory ? nil : registeredProjects, platform: platform,
        policyEvaluator: policyEvaluator, mcpClient: mcpClient, plugins: plugins,
        pluginState: pluginState,
        bundledPlugins: bundledPlugins, terminalSessions: terminalSessions,
        lifetime: GatewayRuntimeLifetime(), preparationState: nil, artifactStorage: nil,
        requiresControlSession: requiresControlSession || sessionRequired,
        remoteManagement: remoteManagement, initializeManifestProjects: false)
    }
    self.requiresPersistedGrant = persistedGrant != nil
    self.persistedProjectRegistrations = Dictionary(
      uniqueKeysWithValues: persistedProjects.map { ($0.id, $0) })
    self.policyEvaluator = policyEvaluator
    self.database = database
    self.projects = projectByID
    self.projectOrder = configuredProjects.map(\.id)
    self.projectAccesses = accessByID
    self.platform = platform
    self.projectErrors = errorByID
    self.providerRouters = providerRouterByID
    lifetime.bindExecutionOwner(
      stop: { [coordinator = permissionRuntime.coordinator] executionIDs in
        try? await coordinator.stopExecutions(executionIDs)
      },
      drain: { [ownedWork] in await ownedWork.joinInvocations() })
    self.generationInputs = GatewayDatabase.ConfigurationState(
      projects: capturedInputs.projects.map { projectByID[$0.id] ?? $0 },
      projectAliases: capturedInputs.projectAliases, profiles: capturedInputs.profiles,
      plugins: capturedInputs.plugins, profileSource: capturedInputs.profileSource,
      derivedProjects: capturedInputs.derivedProjects)
    if preparationState == nil {
      publication.publish(
        revisionID: (try? database?.configurationRevisions(limit: 50))?.filter {
          $0.activatedAt != nil && $0.activationError == nil
        }.first?.id)
      hostToolDirectory.attach(self)
    }
    initialized = true
  }

  /// Catalog and calls borrow this runtime but cannot widen its bound project or recurse.
  func hostToolCatalog(projectID: String, origin: String) throws -> [MCPTool] {
    try validateHostOrigin(projectID: projectID, origin: origin)
    guard let bound = try? hostCallContext(projectID: projectID, origin: origin) else {
      return []
    }
    let currentGrant = try currentHostGrant(context: bound)
    let invocationContext = InvocationContext(session: bound.controlSession)
    return try listTools(context: bound, invocationContext: invocationContext).filter { tool in
      guard
        let descriptor = try? descriptor(named: tool.name, invocationContext: invocationContext),
        !descriptor.localOnly,
        descriptor.mcpReference.map({ !hostServiceRegistrations.contains($0.serverID) }) ?? true
      else { return false }
      return policyEvaluator.evaluate(
        capability: descriptor, context: bound, grant: currentGrant,
        registeredProjectIDs: Set(projectOrder)
      ).isAllowed
    }
  }

  func callHostTool(
    name: String, arguments: [String: JSONValue], projectID: String,
    origin: String, requestID: String, providerExecution: PreparedExecutionContext? = nil
  ) async throws -> JSONValue {
    var bound = context
    bound.projectID = projectID
    bound.requestID = requestID
    var dispatched = false
    let started = ContinuousClock.now
    do {
      try validateHostOrigin(projectID: projectID, origin: origin)
      try providerExecution?.validateProviderLaunch()
      bound = try hostCallContext(
        projectID: projectID, origin: origin, providerExecution: providerExecution)
      bound.requestID = requestID
      let invocationContext = InvocationContext(session: bound.controlSession)
      try validateHostTarget(
        name: name, arguments: arguments, context: bound, depth: 0,
        invocationContext: invocationContext)
      dispatched = true
      let callbackLifetime = GatewayHostCallbackLifetime { [permissionRuntime] ids in
        permissionRuntime.coordinator.revokeInvocations(ids)
      }
      defer { callbackLifetime.finish() }
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await GatewayHostToolScope.$projectID.withValue(projectID) {
          try await GatewayHostToolScope.$execution.withValue(providerExecution) {
            try await GatewayHostToolScope.$lifetime.withValue(callbackLifetime) {
              try await callToolAsync(
                name: name, arguments: .object(arguments), context: bound,
                invocationContext: invocationContext)
            }
          }
        }
      } onCancel: {
        callbackLifetime.cancel()
      }
    } catch {
      let result = Self.executionErrorEnvelope(error, context: bound, capabilityID: name)
      if !dispatched {
        try? recordAudit(
          context: bound, capabilityID: name, decision: Self.auditDecision(for: error),
          errorCode: Self.auditErrorCode(for: error),
          refusal: error as? PluginCompatibilityRefusal, duration: started.duration(to: .now),
          inputDigest: try? Self.inputDigest(tool: name, arguments: arguments), output: result,
          authorization: nil)
      }
      return result
    }
  }

  private func hostCallContext(
    projectID: String, origin: String, providerExecution: PreparedExecutionContext? = nil
  ) throws -> ExecutionContext {
    var bound = context
    bound.projectID = projectID
    if requiresControlSession {
      let invocations = hostToolDirectory.active(
        projectID: projectID, origin: origin, includingRetainedWork: true,
        provider: providerExecution)
      let sessions = invocations.compactMap { $0.context.controlSession }
      guard !sessions.isEmpty, sessions.count == invocations.count,
        Set(sessions.map(\.id)).count == 1
      else {
        throw Self.invalid(
          code: "policy.host_invocation_required",
          message: "Host tools require an unambiguous live control session.")
      }
      bound.controlSession = sessions[0]
    }
    return bound
  }

  private var hostServiceRegistrations: Set<String> {
    Set(configuration.mcp.servers.filter { $0.enabled && $0.hostServices }.map(\.id))
  }

  private func validateHostOrigin(projectID: String, origin: String) throws {
    guard !lifetime.isClosing, hostServiceRegistrations.contains(origin),
      projects[projectID] != nil
    else {
      throw Self.invalid(
        code: "policy.host_scope_unavailable",
        message: "The originating host scope is no longer available.")
    }
    try validateExecutionProject(projectID)
  }

  private func currentRegisteredProject(_ projectID: String) throws -> ComputerMCPCore
    .RegisteredProject?
  {
    guard persistedProjectRegistrations[projectID] != nil, let database else { return nil }
    guard let current = try database.project(id: projectID), current.id == projectID else {
      throw Self.invalid(
        code: "policy.project_denied",
        message: "The registered project changed or was removed.")
    }
    return current
  }

  private func validateExecutionProject(_ projectID: String, requiresAccess: Bool = true) throws {
    let current = try currentRegisteredProject(projectID)
    if let current {
      guard current.createdAt == persistedProjectRegistrations[projectID]?.createdAt,
        current.rootPath == projects[projectID]?.rootPath
      else {
        throw Self.invalid(
          code: "policy.project_denied",
          message: "The registered project changed or was removed.")
      }
    }
    if requiresAccess, let project = current ?? projects[projectID],
      let error = projectAccessError(project)
    {
      throw Self.invalid(code: error.code, message: error.localizedDescription)
    }
  }

  private func projectAccessError(_ project: ComputerMCPCore.RegisteredProject)
    -> ProjectBookmarkError?
  {
    guard let admitted = projectAccesses[project.id] else {
      return projectErrors[project.id]
    }
    do {
      let current = try currentRegisteredProject(project.id) ?? project
      let access = try platform.projectGrants.resolve(current)
      defer { access.close() }
      guard admitted.isActive, access.rootIdentity == admitted.rootIdentity else {
        return .rootChanged(projectID: project.id)
      }
      return nil
    } catch let error as ProjectBookmarkError {
      return error
    } catch {
      return .bookmarkResolutionFailed(projectID: project.id)
    }
  }

  private func currentProfileGrant() throws -> ProfileGrant {
    let current: ProfileGrant
    if let database {
      if let persisted = try database.profiles().first(where: { $0.id == grant.id }) {
        current = persisted
      } else {
        guard !requiresPersistedGrant else {
          throw Self.invalid(
            code: "policy.host_grant_revoked",
            message: "The persisted host profile is no longer available.")
        }
        current = grant
      }
    } else {
      current = grant
    }
    return current
  }

  private func currentHostGrant(context: ExecutionContext) throws -> ProfileGrant {
    let current = try currentProfileGrant()
    guard let session = context.controlSession else {
      guard !requiresControlSession else {
        throw Self.invalid(
          code: "policy.control_session_required", message: "A live control session is required.")
      }
      return current
    }
    return try session.apply(to: current, context: context)
  }

  package func controlProfile(in persistedProfiles: [ProfileGrant]) -> GatewayControlProfile {
    let persisted = persistedProfiles.first { $0.id == grant.id }
    return GatewayControlProfile(
      grant: persisted ?? grant,
      persisted: persisted != nil || requiresPersistedGrant,
      configuredGrant: persisted == nil ? configuration.profileGrant(for: grant.id) : nil)
  }

  private func validateHostTarget(
    name: String, arguments: [String: JSONValue], context: ExecutionContext, depth: Int,
    invocationContext: InvocationContext
  ) throws {
    guard depth < 8, !name.hasPrefix("host.") else {
      throw Self.invalid(
        code: "policy.host_recursion_denied",
        message: "A host callback cannot enter a domain runtime recursively.")
    }
    let target = try descriptor(
      named: name, projectID: arguments["project_id"]?.stringValue ?? context.projectID,
      invocationContext: invocationContext)
    guard !target.localOnly,
      target.mcpReference == nil,
      !(target.requirement.contribution.map { contribution in
        switch contribution {
        case .mcp: return true
        case .cli(let selector):
          let id: String?
          switch selector {
          case .registered(let value): id = value
          case .argument(let key): id = arguments[key]?.stringValue
          case .catalog, .skill: id = nil
          }
          return id.map { pluginOrigins[.init(kind: .cli, id: $0)] != nil } ?? false
        case .skills: return false
        }
      } ?? false),
      !(name.hasPrefix("mcp.") && arguments["server"]?.stringValue != nil)
    else {
      throw Self.invalid(
        code: "policy.host_recursion_denied",
        message:
          "Host administration and provider routes are not callback targets.")
    }
    let descriptor = try invocationDescriptor(
      named: name, arguments: arguments, context: context, invocationContext: invocationContext)
    let routed = try route(descriptor: descriptor, arguments: arguments, context: context)
    try authorize(descriptor, context: routed.context)
    let current = try currentHostGrant(context: routed.context)
    let decision = policyEvaluator.evaluate(
      capability: descriptor, context: routed.context, grant: current,
      registeredProjectIDs: Set(projectOrder))
    guard case .allow = decision else {
      throw Self.invalid(
        code: "policy.host_grant_revoked",
        message: "The host grant no longer permits this callback.")
    }
    if name == "policy.probe" || name == "runtime.owners.call" {
      let key = name == "policy.probe" ? "capability_id" : "tool"
      let target = try Self.requiredString(key, in: arguments)
      guard arguments["arguments"] == nil || arguments["arguments"]?.objectValue != nil else {
        throw Self.invalid(
          code: "policy.invalid_target_arguments",
          message: "Nested target arguments must be an object.")
      }
      try validateHostTarget(
        name: target, arguments: arguments["arguments"]?.objectValue ?? [:],
        context: routed.context, depth: depth + 1, invocationContext: invocationContext)
    }
  }

  private func beginHostInvocation(
    descriptor: CapabilityDescriptor, name: String, arguments: [String: JSONValue],
    context: ExecutionContext, authorizationID: UUID, authorizationRevision: Int64,
    providerExecution: PreparedExecutionContext?
  ) throws -> MCPHostInvocation? {
    guard let reference = descriptor.mcpReference,
      hostServiceRegistrations.contains(reference.serverID)
    else { return nil }
    let downstream =
      name == "mcp.tools.call" ? arguments["arguments"]?.objectValue ?? [:] : arguments
    let id = UUID()
    let requestLeaseID = UUID()
    let recordStore = database?.hostCallRecordStore()
    if descriptor.hostServiceAction == .projectProvision
      || descriptor.hostServiceAction == .projectRemoval
    {
      guard recordStore != nil, context.trustedPrincipalID?.isEmpty == false else {
        throw Self.invalid(
          code: "policy.host_invocation_required",
          message: "Host actions require persistence and a verified client identity.")
      }
    }
    let admission: HostCallAdmission?
    if let projectID = context.projectID, recordStore != nil {
      let plugin = pluginOrigins[.init(kind: .mcp, id: reference.serverID)]
      admission = HostCallAdmission(
        id: id, generationID: generationID, verifiedClientID: context.trustedPrincipalID,
        actingPrincipal: .plugin(
          plugin.map { .package($0.pluginID) } ?? .localServer(reference.serverID)),
        profileID: context.profileID, caller: context.caller, projectID: projectID,
        sourceProjectID: try database?.derivedSourceID(for: projectID)
          ?? projectID,
        upstreamName: name, reference: reference, action: descriptor.hostServiceAction,
        argumentsDigest: try MCPHostInvocation.argumentsDigest(downstream),
        authorizationID: authorizationID, authorizationRevision: authorizationRevision,
        controlSessionID: context.controlSession?.id,
        controlSessionRevision: context.controlSession?.revision,
        requestID: context.requestID)
    } else {
      admission = nil
    }
    guard descriptor.hostServiceAction == nil || admission != nil else {
      throw Self.invalid(
        code: "policy.host_invocation_required",
        message: "Host actions require a project-bound call record.")
    }
    let invocation = MCPHostInvocation(
      id: id, requestLeaseID: requestLeaseID, admission: admission,
      reference: reference, admittedCapability: descriptor, upstreamName: name,
      arguments: downstream, context: context, authorizationRevision: authorizationRevision,
      providerExecution: providerExecution)
    do { try hostToolDirectory.begin(invocation, store: recordStore) } catch let error
      as HostCallRecordError
    {
      throw Self.invalid(code: error.code, message: error.localizedDescription)
    }
    return invocation
  }

  func requireHostInvocation(
    projectID: String, origin: String, action: MCPHostServiceAction,
    providerExecution: PreparedExecutionContext? = nil,
    matching: (MCPHostInvocation) -> Bool = { _ in true }
  ) throws -> MCPHostInvocation {
    try requireHostInvocation(
      projectID: projectID, origin: origin, providerExecution: providerExecution
    ) {
      $0.admittedCapability.hostServiceAction == action && matching($0)
    }
  }

  func requireHostInvocation(
    projectID: String, origin: String, id: UUID, providerExecution: PreparedExecutionContext? = nil
  ) throws
    -> MCPHostInvocation
  {
    try requireHostInvocation(
      projectID: projectID, origin: origin, includingRetainedWork: true,
      providerExecution: providerExecution
    ) {
      $0.id == id
    }
  }

  private func requireHostInvocation(
    projectID: String, origin: String, includingRetainedWork: Bool = false,
    providerExecution: PreparedExecutionContext? = nil,
    matching: (MCPHostInvocation) -> Bool
  ) throws -> MCPHostInvocation {
    try validateHostOrigin(projectID: projectID, origin: origin)
    let matches = hostToolDirectory.active(
      projectID: projectID, origin: origin, includingRetainedWork: includingRetainedWork,
      provider: providerExecution
    ).filter(matching)
    guard matches.count == 1, let invocation = matches.first else {
      throw Self.invalid(
        code: "policy.host_invocation_required",
        message: "Host service requires one matching live gateway invocation.")
    }
    try hostToolDirectory.requireRecord(invocation)
    guard invocation.admission?.generationID == generationID,
      invocation.admission?.sourceProjectID
        == (try database?.derivedSourceID(for: projectID) ?? projectID)
    else {
      throw Self.invalid(
        code: "policy.host_invocation_required", message: "The call belongs to another runtime.")
    }
    // Rediscovery can deadlock a parent waiting on this callback. The admitted
    // effect stays immutable; every active or retained context rechecks the grant.
    let descriptor = invocation.admittedCapability
    guard let authorizationID = invocation.admission?.authorizationID else {
      throw HostCallRecordError.mismatch
    }
    try permissionRuntime.service.validateAuthorization(authorizationID)
    guard descriptor.mcpReference == invocation.reference,
      policyEvaluator.evaluate(
        capability: descriptor, context: invocation.context,
        grant: try currentHostGrant(context: invocation.context),
        registeredProjectIDs: Set(projectOrder)
      ).isAllowed
    else {
      throw Self.invalid(
        code: "policy.host_grant_revoked", message: "The live invocation is no longer authorized.")
    }
    return invocation
  }

  /// Git and filesystem verification finish before this final, non-suspending
  /// authority boundary. Persistence compares the checked revision in its writer.
  func withHostMutation<Result>(
    _ invocation: MCPHostInvocation,
    operation: (HostCallAuthoritySnapshot) throws -> Result
  ) throws -> Result {
    func commit(_ current: ProfileGrant, _ consent: GatewayFullAccessConsent?) throws -> Result {
      try self.hostToolDirectory.withActiveRecord(invocation) {
        guard let admission = invocation.admission, let authorizationID = admission.authorizationID
        else { throw HostCallRecordError.mismatch }
        try self.permissionRuntime.service.validateAuthorization(authorizationID)
        try invocation.providerExecution?.validateProviderLaunch()
        try self.validateHostOrigin(
          projectID: admission.projectID,
          origin: invocation.reference.serverID)
        let origin = self.pluginOrigins[.init(kind: .mcp, id: invocation.reference.serverID)]
        guard admission.generationID == self.generationID,
          admission.actingPrincipal
            == .plugin(
              origin.map { .package($0.pluginID) }
                ?? .localServer(invocation.reference.serverID)),
          admission.sourceProjectID
            == (try self.database?.derivedSourceID(
              for: admission.projectID) ?? admission.projectID),
          self.policyEvaluator.evaluate(
            capability: invocation.admittedCapability,
            context: invocation.context, grant: current,
            registeredProjectIDs: Set(self.projectOrder)
          ).isAllowed
        else {
          throw Self.invalid(
            code: "policy.host_grant_revoked",
            message: "The live invocation is no longer authorized.")
        }
        return try operation(
          .init(
            context: invocation.context,
            profileRevision: current.authorizationRevision, consent: consent,
            authorizationID: authorizationID,
            providerAuthorizationIDs: invocation.providerExecution?.provider?.authorizationIDs ?? []
          ))
      }
    }
    for attempt in 0..<2 {
      do {
        let baseline = try currentProfileGrant()
        if let authority = invocation.context.controlSession {
          guard let session = authority as? GatewayControlSession else {
            throw Self.invalid(
              code: "policy.control_session_required",
              message: "Host mutations require a host-owned control session.")
          }
          return try session.withHostAuthorization(
            grant: baseline,
            context: invocation.context, operation: commit)
        }
        guard !requiresControlSession else {
          throw Self.invalid(
            code: "policy.control_session_required",
            message: "A live control session is required.")
        }
        return try commit(baseline, nil)
      } catch HostCallAuthorityConflict.profileRevision {
        if attempt == 1 { break }
      }
    }
    throw MCPHostServiceError.denied("The host profile changed before this callback committed.")
  }

  func makeHostServices(context: MCPHostContext, origin: String) throws -> MCPBoundHostServices? {
    guard let database else { return nil }
    try validateHostOrigin(projectID: context.launchMetadata.project.id, origin: origin)
    return MCPBoundHostServices(
      database: database, directory: hostToolDirectory, context: context, origin: origin,
      gitExecutable: platform.gitExecutable,
      commandRunner: ManagedCommandRunner(launcher: platform.launcher))
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
  package func beginRetirementIfDrained() -> Task<Void, Never>? {
    guard ownedWork.closeAdmissionIfDrained() else { return nil }
    hostToolDirectory.attach(nil)
    return lifetime.beginShutdown()
  }

  /// Profile grants are live authority; registration revisions select provider generations.
  package func hasCurrentProjectInputs() throws -> Bool {
    guard let database, let generationInputs else { return true }
    let current = try database.configurationState()
    return current.projects.count == generationInputs.projects.count
      && zip(current.projects, generationInputs.projects).allSatisfy(
        GatewayDatabase.sameStoredProject)
      && current.derivedProjects == generationInputs.derivedProjects
  }

  package func refreshedGeneration() async throws -> GatewayRuntime {
    guard let principal = context.trustedPrincipalID else {
      throw GatewaySocketError.notConnected
    }
    let runtime = try await Self.construction.perform {
      try self.authenticatedSessionFactory(
        principal, self.context.transportTrace, self.requiresControlSession, true)
    }
    do {
      guard try runtime.hasCurrentProjectInputs() else {
        throw GatewayDatabaseError.configurationChanged
      }
      return runtime
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  package func authenticatedSession(
    principalID: String, transportTrace: GatewayTransportTrace?,
    requiresControlSession: Bool = false
  ) throws -> GatewayRuntime {
    try publication.requirePublished()
    return try authenticatedSessionFactory(
      principalID, transportTrace, requiresControlSession, false)
  }

  package func makeControlSession() throws -> GatewayControlSession {
    try publication.requirePublished()
    guard let principalID = context.trustedPrincipalID, !principalID.isEmpty else {
      throw ConfigurationError.invalid("Control sessions require a verified principal.")
    }
    _ = try currentProfileGrant()
    _ = try publishPermissionEnvironment()
    let session = GatewayControlSession(
      principalID: principalID, profileID: context.profileID, caller: context.caller,
      database: database, profile: controlProfile(in: try database?.profiles() ?? []),
      permissionService: permissionRuntime.service)
    try session.restoreTrustedAccess()
    return session
  }

  package func listTools(context: InvocationContext) throws -> [MCPTool] {
    try listTools(context: contextForCall(context), invocationContext: context)
  }

  package func listToolsAsync(context: InvocationContext) async throws -> [MCPTool] {
    try await Self.performAdmission { try self.listTools(context: context) }
  }

  package func toolChanges(context: InvocationContext) -> AsyncStream<Void> {
    guard let database else {
      return firstProviderRouter?.toolChanges(context: context) ?? AsyncStream { $0.finish() }
    }
    let sources = [
      firstProviderRouter?.toolChanges(context: context), database.profileChanges(for: grant.id),
    ]
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let tasks = sources.enumerated().compactMap { index, source -> Task<Void, Never>? in
      guard let source else { return nil }
      return Task { [weak self] in
        for await _ in source {
          guard !Task.isCancelled else { break }
          if index == 1 { try? await self?.refreshTools(context: context) }
          continuation.yield(())
        }
      }
    }
    continuation.onTermination = { _ in
      for task in tasks { task.cancel() }
    }
    return stream
  }

  package func refreshTools(context: InvocationContext) async throws {
    for projectID in projectOrder {
      try await providerRouters[projectID]?.refreshTools(context: context)
    }
  }

  package func listTools(context: ExecutionContext, invocationContext: InvocationContext)
    throws -> [MCPTool]
  {
    guard let grant = try? currentHostGrant(context: context), grant.id == context.profileID,
      grant.allowedCallers.contains(context.caller),
      let subject = try? GatewayPermissionSubject(context: context)
    else { return [] }
    let coreDefinitions = Self.coreDefinitions(
      databaseEnabled: database != nil, management: remoteManagement)
    let routedDefinitions: [ToolDefinition] =
      try firstProviderRouter.map { router in
        try router.listTools(context: invocationContext).map { tool in
          let capability = try reviewedContribution(
            router.capability(named: tool.name, context: invocationContext))
          return ToolDefinition(
            tool: Self.toolWithRequirements(tool, descriptor: capability), capability: capability)
        }
      } ?? []
    let candidates = (coreDefinitions + routedDefinitions).filter {
      !(context.caller.isRemote && $0.capability.localOnly)
    }
    guard
      let visibility = try? permissionRuntime.service.canRequest(
        subject: subject,
        requirements: candidates.map { visibilityRequirement($0.capability) },
        connectionID: context.controlSession?.id)
    else { return [] }
    return zip(candidates, visibility).compactMap { definition, visible in
      visible ? Self.toolWithRequirements(definition.tool, descriptor: definition.capability) : nil
    }
  }

  package func capabilityDescriptor(named name: String) throws -> CapabilityDescriptor {
    try descriptor(named: name, invocationContext: .empty)
  }

  package struct ContinuationLookup: Sendable {
    package let projectID: String
    package let reference: MCPToolReference
    package let observation: MCPContinuationDirectory.Lookup
  }

  package var unambiguousProjectID: String? {
    context.projectID ?? (projectOrder.count == 1 ? projectOrder.first : nil)
  }

  package func callOwnedTool(
    owner: GatewayOwnerSelection, name: String, arguments: JSONValue,
    context: InvocationContext
  ) async throws -> JSONValue {
    guard owner.runtimeID == generationID,
      let record = ownedWork.snapshot.first(where: {
        $0.id == owner.ownershipID && $0.projectID == owner.projectID && $0.kind != .invocation
      }), var object = arguments.objectValue,
      !name.hasPrefix("runtime.owners.")
    else { throw GatewayOwnerSelection.unavailable() }
    if let project = object["project_id"], project != .string(owner.projectID) {
      throw GatewayOwnerSelection.unavailable()
    }
    object["project_id"] = .string(owner.projectID)
    let targetName = name
    let targetArguments = object
    var target: MCPContinuationTarget?
    if let connectionID = record.connectionID {
      let lookup: ContinuationLookup
      if let native = try continuationLookup(
        name: name, arguments: .object(object), projectID: owner.projectID)
      {
        lookup = native
      } else if targetName.hasPrefix("mcp."),
        let server = targetArguments["server"]?.stringValue, server == record.registrationID
      {
        lookup = .init(
          projectID: owner.projectID, reference: .init(serverID: server, toolName: targetName),
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
        projectID: owner.projectID, reference: lookup.reference, connectionID: connectionID,
        instanceID: ownedWork.continuations.entry(connectionID: connectionID)?.instanceID,
        resources: Dictionary(uniqueKeysWithValues: matches.map { ($0.resource, $0.acquiredBy) }),
        selectedOwnershipID: record.id)
    } else {
      let key: String
      switch targetName {
      case "shell.read", "shell.write", "shell.cancel": key = "session_id"
      case "process.read", "process.write", "process.cancel": key = "process_id"
      default: throw GatewayOwnerSelection.unavailable()
      }
      guard record.kind == .shell, targetArguments[key] == .string(record.resourceID) else {
        throw GatewayOwnerSelection.unavailable()
      }
    }
    let reservation = try ownedWork.admitInvocation(
      projectID: owner.projectID, resourceID: name)
    defer { reservation.finish() }
    return try await GatewayOwnerRouting.$selection.withValue(owner) {
      try await callToolAsync(
        name: name, arguments: .object(object),
        context: .init(session: context.session, continuation: target))
    }
  }

  private func executionOwners(arguments: [String: JSONValue], context: ExecutionContext) throws
    -> JSONValue
  {
    guard let projectID = context.projectID,
      Set(arguments.keys).isSubset(of: ["server", "after", "limit"]),
      arguments["server"] == nil || arguments["server"]?.stringValue != nil,
      arguments["after"] == nil || arguments["after"]?.stringValue != nil,
      let limit = arguments["limit"]?.int64Value ?? (arguments["limit"] == nil ? 50 : nil),
      (1...100).contains(limit)
    else {
      throw GatewayToolError.invalidArguments("Supply a project and a page limit from 1 to 100.")
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
        let grant = try? runtime.currentHostGrant(context: context),
        Self.allows(grant.permissions.state(for: .project(projectID)), .read),
        grant.allowedCallers.contains(context.caller),
        (try? runtime.validateExecutionProject(projectID)) != nil
      else { continue }
      let policy = MCPToolAccessPolicy(
        configuration: runtime.configuration, grant: grant, fullAccessConsented: grant.fullAccess,
        pluginIDs: Dictionary(
          uniqueKeysWithValues: runtime.pluginOrigins.compactMap { registration, origin in
            registration.kind == .mcp ? (registration.id, origin.pluginID) : nil
          }))
      let visibleServers = Set(
        runtime.configuration.mcp.servers.filter { policy.isVisible($0) }.map(\.id))
      for record in runtime.ownedWork.snapshot
      where record.kind != .invocation && record.projectID == projectID {
        if let server, record.registrationID != server { continue }
        if let registration = record.registrationID {
          guard visibleServers.contains(registration) else { continue }
        } else {
          guard record.kind == .shell else {
            continue
          }
        }
        let owner = GatewayOwnerSelection(
          runtimeID: runtime.generationID, projectID: projectID, ownershipID: record.id)
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

  private func selectedOwnerCall(
    arguments: [String: JSONValue], context: ExecutionContext, invocationContext: InvocationContext
  )
    async throws -> JSONValue
  {
    guard
      Set(arguments.keys).isSubset(of: [
        "owner", "tool", "arguments", GatewayPermissionRetryInput.field,
      ])
    else {
      throw GatewayOwnerSelection.unavailable()
    }
    let owner = try GatewayOwnerSelection(arguments["owner"])
    guard owner.projectID == context.projectID else {
      throw GatewayOwnerSelection.unavailable()
    }
    let name = try Self.requiredString("tool", in: arguments)
    var target = arguments["arguments"] ?? .object([:])
    if let ids = arguments[GatewayPermissionRetryInput.field], var nested = target.objectValue {
      nested[GatewayPermissionRetryInput.field] = ids
      target = .object(nested)
    }
    if let call = GatewayOwnerRouting.call { return try await call(owner, name, target) }
    return try await callOwnedTool(
      owner: owner, name: name, arguments: target,
      context: .init(
        admission: invocationContext.admission, session: context.controlSession,
        continuation: invocationContext.continuation))
  }

  /// Resolves cached routing and accepted ownership without starting a provider.
  package func continuationLookups(name: String, arguments: JSONValue?, projectID: String?) throws
    -> [ContinuationLookup]
  {
    let projectIDs = projectID.map { [$0] } ?? projectOrder
    return try projectIDs.compactMap {
      try continuationLookup(name: name, arguments: arguments, projectID: $0)
    }
  }

  func continuationLookup(name: String, arguments: JSONValue?, projectID: String?) throws
    -> ContinuationLookup?
  {
    var arguments = arguments?.objectValue ?? [:]
    guard let projectID = arguments["project_id"]?.stringValue ?? projectID,
      let router = providerRouters[projectID]
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
      arguments.removeValue(forKey: "project_id")
      nativeArguments = .object(arguments)
    }
    return try ContinuationLookup(
      projectID: projectID, reference: reference,
      observation: ownedWork.continuations.lookup(
        projectID: projectID, registrationID: reference.serverID,
        tool: reference.toolName, arguments: nativeArguments))
  }

  package func callTool(name: String, arguments: JSONValue?, context: InvocationContext)
    throws -> JSONValue
  {
    try callTool(
      name: name, arguments: arguments, context: contextForCall(context), invocationContext: context
    )
  }

  package func callToolAsync(
    name: String, arguments: JSONValue?, context: InvocationContext
  ) async throws -> JSONValue {
    try await callToolAsync(
      name: name, arguments: arguments, context: contextForCall(context), invocationContext: context
    )
  }

  package func callToolForMCPAsync(
    name: String,
    arguments: JSONValue?, context: InvocationContext
  ) async throws -> JSONValue {
    let callContext = contextForMCP(arguments: arguments, invocationContext: context)
    do {
      return try await callToolAsync(
        name: name, arguments: arguments, context: callContext, invocationContext: context)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return routingErrorForMCP(
        error, name: name, arguments: arguments, context: callContext, invocationContext: context)
    }
  }

  package func routingErrorForMCP(
    _ error: any Error, name: String, arguments: JSONValue?, context: ExecutionContext? = nil,
    invocationContext: InvocationContext, recordFailure: Bool = false
  ) -> JSONValue {
    let context =
      context ?? contextForMCP(arguments: arguments, invocationContext: invocationContext)
    let result = Self.executionErrorEnvelope(error, context: context, capabilityID: name)
    if recordFailure {
      try? recordAudit(
        context: context, capabilityID: name, decision: Self.auditDecision(for: error),
        errorCode: Self.auditErrorCode(for: error),
        refusal: error as? PluginCompatibilityRefusal, duration: .zero,
        inputDigest: try? Self.inputDigest(tool: name, arguments: arguments?.objectValue ?? [:]),
        output: result)
    }
    return result
  }

  private func contextForMCP(arguments: JSONValue?, invocationContext: InvocationContext)
    -> ExecutionContext
  {
    var callContext = contextForCall(invocationContext)
    let object = arguments?.objectValue ?? [:]
    if let projectID = object["project_id"]?.stringValue {
      callContext.projectID = projectID
    } else if callContext.projectID == nil, projectOrder.count == 1 {
      callContext.projectID = projectOrder[0]
    }
    return callContext
  }

  package func callTool(
    name: String, arguments: JSONValue?, context: ExecutionContext,
    invocationContext: InvocationContext
  ) throws -> JSONValue {
    let owner = GatewayOwnerRouting.selection
    let runtimes = GatewayOwnerRouting.runtimes
    let call = GatewayOwnerRouting.call
    return try GatewaySynchronousOperation.run {
      try await GatewayOwnerRouting.$runtimes.withValue(runtimes) {
        try await GatewayOwnerRouting.$call.withValue(call) {
          try await GatewayOwnerRouting.$selection.withValue(owner) {
            try await self.callToolAsync(
              name: name, arguments: arguments, context: context,
              invocationContext: invocationContext)
          }
        }
      }
    }
  }

  package func callToolAsync(
    name: String, arguments: JSONValue?, context: ExecutionContext,
    invocationContext: InvocationContext
  ) async throws -> JSONValue {
    let ownership = try ownedWork.admitInvocation(
      projectID: arguments?.objectValue?["project_id"]?.stringValue ?? context.projectID,
      resourceID: name)
    defer { ownership.finish() }
    return try await performAsync(
      name: name, arguments: arguments?.objectValue ?? [:], context: context,
      invocationContext: invocationContext)
  }

  private func performAsync(
    name: String, arguments: [String: JSONValue], context originalContext: ExecutionContext,
    invocationContext: InvocationContext
  ) async throws -> JSONValue {
    let start = ContinuousClock.now
    var auditContext = originalContext
    var digest = try? Self.inputDigest(tool: name, arguments: arguments)
    var authorization: InvocationAuthorization?
    var authorizationIDs: Set<UUID> = []
    var auditEvidence: GatewayPermissionAuditEvidence?
    var prepared: PreparedExecutionContext?
    var executionAccess: (any ExecutionAccessChecking)?
    var runtimeRequestGroups: [ExecutionPermissionRequestGroup] = []
    var dispatched = false
    do {
      try await permissionRuntime.ready()
      let input = try GatewayPermissionRetryInput(arguments)
      let admitted = try await Self.performAdmission {
        try self.admitInvocation(
          name: name, input: input, context: originalContext, invocationContext: invocationContext)
      }
      try GatewayHostToolScope.lifetime?.register(
        admitted.providerBinding?.authorizationIDs ?? [admitted.authorization.id])
      auditContext = admitted.route.context
      digest = admitted.resolved.identity.argumentsDigest
      authorization = admitted.authorization
      authorizationIDs = admitted.providerBinding?.authorizationIDs ?? [admitted.authorization.id]
      auditEvidence = admitted.evidence
      // The admission record must exist before a provider can make an effect.
      try recordAudit(
        context: auditContext, capabilityID: name, decision: .allowed,
        errorCode: "permission.admitted", duration: .zero, inputDigest: digest, output: nil,
        authorization: admitted.authorization, evidence: admitted.evidence)
      try validateAdmittedProject(
        name: name, descriptor: admitted.resolved.descriptor, context: auditContext)
      let execution: any InvocationExecutionAuthority
      if let callback = admitted.callbackExecution {
        try callback.validateProviderLaunch()
        let callbackLifetime = GatewayHostToolScope.lifetime
        execution = try await permissionRuntime.prepare(
          authorization: admitted.authorization, descriptor: admitted.resolved.descriptor,
          directory: admitted.directory, connectionID: admitted.route.context.controlSession?.id,
          auditContext: auditContext, callback: admitted.providerBinding,
          validateCallback: {
            if let callbackLifetime {
              try callbackLifetime.validateActive { try callback.validateProviderLaunch() }
            } else {
              try callback.validateProviderLaunch()
            }
          })
      } else if let retained = admitted.retainedExecution {
        try retained.validateProviderLaunch()
        execution = retained
      } else if let source = admitted.providerSource {
        execution = try await permissionRuntime.prepareProvider(
          review: source.review, registrationID: source.registrationID,
          authorization: admitted.authorization, directory: admitted.directory,
          connectionID: admitted.route.context.controlSession?.id, retryIDs: admitted.retryIDs,
          auditContext: auditContext, source: source,
          platformRules: permissionPlatformRules(), admittedProvider: admitted.providerBinding)
      } else {
        execution = try await permissionRuntime.prepare(
          authorization: admitted.authorization, descriptor: admitted.resolved.descriptor,
          directory: admitted.directory, connectionID: admitted.route.context.controlSession?.id,
          remoteService: admitted.remoteService,
          hostManagement: remoteManagement?.containsTool(named: name) == true,
          auditContext: auditContext)
      }
      prepared = execution as? PreparedExecutionContext
      executionAccess = execution as? any ExecutionAccessChecking
      if let prepared, !lifetime.registerExecution(prepared.executionID) {
        try await permissionRuntime.coordinator.stopExecutions([prepared.executionID])
        throw CancellationError()
      }
      let providerContext = InvocationContext(
        resolvedInvocation: admitted.resolved,
        admission: InvocationAdmission(descriptor: admitted.resolved.descriptor),
        session: auditContext.controlSession, continuation: invocationContext.continuation,
        executionRecoveryKey: Self.executionRecoveryKey(
          context: auditContext, grant: admitted.grant),
        executionAuthority: execution)
      dispatched = true
      let result = try await InvocationExecution.$current.withValue(execution) {
        try await HostPathAccess.$current.withValue(execution.pathAccess) {
          try await self.dispatchAdmitted(
            name: name, admitted: admitted, invocationContext: providerContext)
        }
      }
      do {
        runtimeRequestGroups = try executionAccess?.currentPermissionRequestGroups() ?? []
      } catch let error as PermissionModelError {
        throw error
      } catch let error as GatewayPermissionError {
        throw error
      } catch {
        // The operation's result remains usable if optional request metadata
        // cannot be read. Its normal authority and final audit checks still apply.
      }
      do {
        if let prepared {
          try prepared.finishAdmission()
        } else {
          for id in authorizationIDs { try permissionRuntime.service.finishInvocation(id) }
        }
      } catch { throw GatewayAuditCompletionError() }
      let envelope = GatewayExecutionPermissionMetadata.attach(
        to: Self.attachExecutionMetadata(to: result, context: auditContext, capabilityID: name),
        groups: runtimeRequestGroups)
      do {
        try recordAudit(
          context: auditContext, capabilityID: name, decision: .allowed, errorCode: nil,
          duration: start.duration(to: .now), inputDigest: digest, output: envelope,
          authorization: authorization, evidence: auditEvidence, executionID: prepared?.executionID,
          permissionFailure: runtimeRequestGroups.isEmpty
            ? nil : .required(runtimeRequestGroups.flatMap(\.requests), afterDispatch: true))
      } catch { throw GatewayAuditCompletionError() }
      return envelope
    } catch {
      if runtimeRequestGroups.isEmpty {
        runtimeRequestGroups = (try? executionAccess?.currentPermissionRequestGroups()) ?? []
      }
      let reportedError: any Error =
        !runtimeRequestGroups.isEmpty && !(error is GatewayPermissionCallError)
          && !(error is GatewayAuditCompletionError) && !(error is CancellationError)
        ? GatewayExecutionPermissionFailure(underlying: error, groups: runtimeRequestGroups) : error
      if let permission = reportedError as? GatewayPermissionCallError {
        auditEvidence = permission.evidence ?? auditEvidence
      }
      if let prepared {
        try? prepared.finishAdmission()
      } else {
        for id in authorizationIDs { try? permissionRuntime.service.finishInvocation(id) }
      }
      let result = Self.executionErrorEnvelope(
        reportedError, context: auditContext, capabilityID: name)
      do {
        try recordAudit(
          context: auditContext, capabilityID: name,
          decision: Self.auditDecision(for: reportedError),
          errorCode: Self.auditErrorCode(for: reportedError),
          refusal: error as? PluginCompatibilityRefusal,
          duration: start.duration(to: .now), inputDigest: digest, output: result,
          authorization: authorization, evidence: auditEvidence, executionID: prepared?.executionID,
          permissionFailure: (reportedError as? GatewayPermissionCallError)
            ?? (runtimeRequestGroups.isEmpty
              ? nil : .required(runtimeRequestGroups.flatMap(\.requests), afterDispatch: true)))
      } catch {
        if dispatched { throw GatewayAuditCompletionError() }
        throw error
      }
      throw reportedError
    }
  }

  private func providerRegistration(
    descriptor: CapabilityDescriptor, arguments: [String: JSONValue]
  )
    -> IntegrationRegistration?
  {
    switch descriptor.requirement.execution {
    case .read, .input, .cancel, .list: return nil
    default: break
    }
    if case .cli(let selector) = descriptor.requirement.contribution {
      let id: String?
      switch selector {
      case .registered(let value): id = value
      case .argument(let name): id = arguments[name]?.stringValue
      case .catalog, .skill: id = nil
      }
      if let id, pluginOrigins[.init(kind: .cli, id: id)] != nil {
        return .init(kind: .cli, id: id)
      }
    }
    guard descriptor.mcpReference != nil || descriptor.id.hasPrefix("mcp."),
      !["mcp.servers.list", "mcp.servers.status", "mcp.events.read", "mcp.tools.list"].contains(
        descriptor.id),
      let id = descriptor.mcpReference?.serverID ?? arguments["server"]?.stringValue,
      configuration.mcp.servers.contains(where: { $0.id == id && $0.transport == .stdio })
    else { return nil }
    return .init(kind: .mcp, id: id)
  }

  private func dispatchAdmitted(
    name: String, admitted: GatewayAdmittedInvocation, invocationContext: InvocationContext
  ) async throws -> JSONValue {
    let routed = admitted.route
    switch name {
    case "project.list": return try resultEnvelope(projectList(context: routed.context))
    case "project.request":
      let path = try Self.requiredString("path", in: routed.arguments)
      guard
        let access = routed.arguments["access"]?.stringValue.flatMap(
          PermissionValue.init(rawValue:)),
        access == .read || access == .write
      else {
        throw GatewayToolError.invalidArguments("access must be read or write.")
      }
      let decision = try permissionRuntime.service.requestProject(
        subject: GatewayPermissionSubject(context: routed.context), path: path, access: access,
        argumentsDigest: MCPExecutionRecord.digest(.object(routed.arguments)),
        retryIDs: admitted.retryIDs)
      switch decision {
      case .request(let request): throw GatewayPermissionCallError.required([request])
      case .denied(let reason): throw GatewayPermissionCallError.denied(reason)
      case .registered(let id): return try resultEnvelope(.object(["project_id": .string(id)]))
      }
    case "project.describe":
      return try resultEnvelope(
        projectDescribe(arguments: routed.arguments, context: routed.context))
    case "runtime.owners.list":
      return try resultEnvelope(
        executionOwners(arguments: routed.arguments, context: routed.context))
    case "runtime.owners.call":
      return try await selectedOwnerCall(
        arguments: routed.arguments, context: routed.context, invocationContext: invocationContext)
    case "policy.probe":
      return try await Self.performAdmission {
        try self.resultEnvelope(
          self.policyProbe(
            arguments: routed.arguments, context: routed.context,
            invocationContext: invocationContext))
      }
    case let tool where remoteManagement?.containsTool(named: tool) == true:
      guard let remoteManagement else { throw GatewayToolError.unknownTool(name) }
      return try resultEnvelope(
        await remoteManagement.call(
          name: name, arguments: routed.arguments, context: routed.context))
    default:
      guard
        let provider = routed.registryProjectID.flatMap({ providerRouters[$0] }) ?? unscopedRouter
      else {
        throw GatewayRuntimeError.noProjects
      }
      let hostInvocation = try beginHostInvocation(
        descriptor: admitted.resolved.descriptor, name: name, arguments: routed.arguments,
        context: routed.context, authorizationID: admitted.authorization.id,
        authorizationRevision: admitted.grant.authorizationRevision,
        providerExecution: (invocationContext.executionAuthority as? PreparedExecutionContext)
          .flatMap { $0.provider == nil ? nil : $0 })
      defer { hostToolDirectory.end(hostInvocation) }
      let providerContext = InvocationContext(
        resolvedInvocation: invocationContext.resolvedInvocation,
        admission: InvocationAdmission(
          descriptor: admitted.resolved.descriptor, hostInvocationID: hostInvocation?.id),
        session: invocationContext.session, continuation: invocationContext.continuation,
        executionRecoveryKey: invocationContext.executionRecoveryKey,
        executionAuthority: invocationContext.executionAuthority)
      return try await provider.callToolAsync(
        name: name, arguments: .object(routed.arguments),
        expectedCapability: name == "mcp.tools.call" ? nil : admitted.resolved.descriptor,
        context: providerContext)
    }
  }

  private func admitInvocation(
    name: String, input: GatewayPermissionRetryInput, context: ExecutionContext,
    invocationContext: InvocationContext
  ) throws -> GatewayAdmittedInvocation {
    let descriptor = try invocationDescriptor(
      named: name, arguments: input.arguments,
      context: context, invocationContext: invocationContext)
    let routed = try route(descriptor: descriptor, arguments: input.arguments, context: context)
    let grant = try authorize(descriptor, context: routed.context)
    let subject = try GatewayPermissionSubject(context: routed.context)
    let continuationPaths: PathEnvironmentSnapshot?
    switch descriptor.requirement.execution {
    case .read, .input, .cancel, .list:
      // Retained executions use live ledger authority, never the old runtime's path rules.
      continuationPaths = try permissionRuntime.store.readWithDatabase { _, ledger in
        ledger.environment.paths
      }
    default:
      continuationPaths =
        name.hasPrefix("runtime.owners.") || invocationContext.continuationTarget != nil
        ? try permissionRuntime.store.readWithDatabase { _, ledger in ledger.environment.paths }
        : nil
    }
    let paths: PathEnvironmentSnapshot
    if let continuationPaths {
      paths = continuationPaths
    } else {
      paths = try publishPermissionEnvironment()
    }
    let mode: ComputerMCPPermissions.ExecutionMode =
      grant.fullAccess && routed.context.controlSession != nil ? .fullAccess(.standing) : .sandbox
    let (resolvedRequirements, origins, skillLibraries) = try GatewayToolRequirementResolver(
      configuration: configuration,
      origins: pluginOrigins, paths: paths
    ).resolve(
      descriptor: descriptor,
      arguments: routed.arguments, projectID: routed.context.projectID, mode: mode)
    var requirements = resolvedRequirements
    let digest = try invocationDigest(descriptor: descriptor, arguments: routed.arguments)
    let forwarded: Bool
    if case .forwarded(_, _, nil) = descriptor.requirement.target {
      forwarded = name != "policy.probe"
    } else {
      forwarded = false
    }
    let retained = try invocationContext.continuationTarget.flatMap {
      try ownedWork.continuations.execution(for: $0)
    }
    let callback = GatewayHostToolScope.execution
    let source: GatewayProviderSource?
    if let callback, let provider = callback.provider, let database {
      try callback.validateProviderLaunch()
      guard provider.delegatingAuthorization?.invocation.principal == subject.principal,
        provider.delegatingAuthorization?.invocation.projectID == routed.context.projectID
      else { throw PermissionModelError.invalidAuthorization }
      source = try GatewayProviderSource.resolve(
        registration: .init(kind: .mcp, id: provider.registrationID),
        configuration: configuration, origins: pluginOrigins, database: database)
      let permission: Permission =
        switch provider.identity {
        case .package(let id): .plugin(id)
        case .localServer(let id): .mcpServer(id)
        }
      requirements = InvocationRequirements(
        actions: requirements.actions
          + (provider.delegatingAuthorization?.actions.filter {
            $0.requirement.permission == permission
          } ?? []), paths: requirements.paths, networks: requirements.networks,
        mode: requirements.mode, sandboxProjectID: requirements.sandboxProjectID,
        execution: requirements.execution, providers: requirements.providers)
    } else if retained == nil,
      let registration = providerRegistration(
        descriptor: descriptor, arguments: routed.arguments), let database
    {
      source = try GatewayProviderSource.resolve(
        registration: registration,
        configuration: configuration, origins: pluginOrigins, database: database)
    } else {
      source = nil
    }
    let evaluated = try permissionRuntime.service.evaluate(
      subject: subject, tool: name,
      projectID: routed.context.projectID, argumentsDigest: digest, requirements: requirements,
      retryIDs: forwarded || name == "project.request" ? [] : input.requestIDs,
      connectionID: routed.context.controlSession?.id,
      skillLibraries: skillLibraries, continuation: retained?.provider, providerSource: source,
      callbackExecutionID: callback?.executionID)
    let authorization: InvocationAuthorization
    switch evaluated.decision {
    case .allowed(let allowed): authorization = allowed
    case .requests(let requests):
      throw GatewayPermissionCallError.required(requests, evidence: evaluated.evidence)
    case .denied(let denial):
      throw GatewayPermissionCallError.denied(denial, evidence: evaluated.evidence)
    }
    let resolved = ResolvedToolInvocation(
      descriptor: descriptor,
      identity: InvocationIdentity(
        principal: subject.principal, tool: name,
        projectID: routed.context.projectID, argumentsDigest: digest),
      requirements: authorization.requirements,
      pluginOrigins: origins.union(
        authorization.requirements.actions.compactMap {
          if case .plugin(let id) = $0.requirement.permission { return .package(id) }
          return nil
        }))
    let directory =
      Self.requiresProjectDirectory(descriptor)
      ? routed.registryProjectID.flatMap { projectAccesses[$0]?.rootURL } : nil
    var dispatchRoute = routed
    if forwarded && !input.requestIDs.isEmpty {
      dispatchRoute.arguments[GatewayPermissionRetryInput.field] = .array(
        input.requestIDs.map { .string($0.uuidString) })
    }
    let serverID = descriptor.mcpReference?.serverID ?? routed.arguments["server"]?.stringValue
    let remoteService =
      descriptor.id.hasPrefix("mcp.") || descriptor.mcpReference != nil
      ? configuration.mcp.servers.first(where: { $0.id == serverID })?.transport != nil
        && configuration.mcp.servers.first(where: { $0.id == serverID })?.transport != .stdio
      : false
    return GatewayAdmittedInvocation(
      route: dispatchRoute, grant: grant, resolved: resolved,
      authorization: authorization, evidence: evaluated.evidence, directory: directory,
      remoteService: remoteService, retryIDs: input.requestIDs, retainedExecution: retained,
      providerSource: source, providerBinding: evaluated.provider, callbackExecution: callback)
  }

  private func permissionPaths() throws -> PathEnvironmentSnapshot {
    let snapshot = try database?.connection.writer.read { sql in
      (try GatewayDatabase.projects(in: sql), try GatewayDatabase.availableDerivedProjects(in: sql))
    }
    let current = snapshot?.0 ?? []
    let derived = Dictionary(uniqueKeysWithValues: (snapshot?.1 ?? []).map { ($0.projectID, $0) })
    let registrations =
      !persistedProjectRegistrations.isEmpty
      ? current : (current.isEmpty ? projectOrder.compactMap { projects[$0] } : current)
    let registered = try registrations.map { project in
      let root = try ProjectPathResolver.resolve(
        project.rootPath, relativeTo: URL(fileURLWithPath: "/"))
      return ComputerMCPPermissions.RegisteredProject(
        id: project.id, root: try CanonicalPath(root.path),
        sourceID: derived[project.id]?.source.id,
        hostContentIdentity: try GatewayDatabase.hostContentIdentity(derived[project.id]))
    }
    return try PathEnvironmentSnapshot(
      projects: registered,
      rules: permissionPlatformRules().union(GatewayConfigurationPaths.capture(configuration)))
  }

  private func publishPermissionEnvironment() throws -> PathEnvironmentSnapshot {
    let paths = try permissionPaths()
    try permissionRuntime.service.configureEnvironment(
      paths,
      trustedHosts: Set(EgressPolicy.trustedHosts.map(HostRule.init)),
      expectedProjects: database?.projects() ?? [],
      expectedConfigurationRevision: publication.configurationRevisionID,
      platformRules: permissionPlatformRules(),
      configurationRules: GatewayConfigurationPaths.capture(configuration))
    return paths
  }

  private func permissionPlatformRules() throws -> Set<PathRule> {
    try Self.permissionPlatformRules(platform: platform, database: database)
  }

  private static func permissionPlatformRules(
    platform: PlatformServices, database: GatewayDatabase?
  ) throws -> Set<PathRule> {
    var rules: Set<PathRule> = []
    func rule(_ path: String, _ kind: PathRule.Kind) throws {
      let resolved = try ProjectPathResolver.resolve(path, relativeTo: URL(fileURLWithPath: "/"))
      rules.insert(PathRule(root: try CanonicalPath(resolved.path), kind: kind))
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    for path in ["/Users", "/home", "/root", "/Volumes", home.path] { try rule(path, .userData) }
    for path in ["/System", "/Library", "/usr", "/bin", "/sbin", "/Applications"] {
      try rule(path, .systemOrApplication)
    }
    for (name, category) in [
      ("Desktop", FolderCategory.desktop), ("Documents", .documents), ("Downloads", .downloads),
      ("Library/Mobile Documents", .iCloudDrive),
    ] {
      try rule(home.appendingPathComponent(name).path, .folder(category))
    }
    for path in [
      ".ssh", ".gnupg", ".codex/auth.json", ".claude/.credentials.json", "Library/Keychains",
    ] {
      try rule(home.appendingPathComponent(path).path, .hostData)
    }
    for path in platform.hostDataPaths { try rule(path.path, .hostData) }
    for source in platform.permissionPolicyReader.readSources() where source.location.hasPrefix("/")
    {
      try rule(source.location, .hostData)
    }
    if let file = database?.fileURL {
      try rule(file.path, .hostData)
      try rule(file.path + "-wal", .hostData)
      try rule(file.path + "-shm", .hostData)
      try rule(
        file.deletingLastPathComponent().appendingPathComponent("Executions").path, .hostData)
    }
    if let ownership = database?.mcpProcessOwnershipRoot { try rule(ownership.path, .hostData) }
    if let executions = database?.permissionExecutionRoot { try rule(executions.path, .hostData) }
    if let containers = database?.providerContainerRoot { try rule(containers.path, .hostData) }
    return rules
  }

  private func policyProbe(
    arguments: [String: JSONValue], context: ExecutionContext,
    invocationContext: InvocationContext
  ) throws -> JSONValue {
    let tool = try Self.requiredString("capability_id", in: arguments)
    guard tool != "policy.probe" else {
      throw Self.invalid(
        code: "policy.invalid_probe_target", message: "policy.probe cannot target itself.")
    }
    let input = try GatewayPermissionRetryInput(arguments["arguments"]?.objectValue ?? [:])
    let descriptor = try invocationDescriptor(
      named: tool, arguments: input.arguments, context: context,
      invocationContext: invocationContext)
    let routed = try route(descriptor: descriptor, arguments: input.arguments, context: context)
    let grant = try authorize(descriptor, context: routed.context)
    let subject = try GatewayPermissionSubject(context: routed.context)
    let (requirements, _, skillLibraries) = try GatewayToolRequirementResolver(
      configuration: configuration, origins: pluginOrigins, paths: permissionPaths()
    )
    .resolve(
      descriptor: descriptor, arguments: routed.arguments, projectID: routed.context.projectID,
      mode: grant.fullAccess && context.controlSession != nil ? .fullAccess(.standing) : .sandbox)
    let decision = try permissionRuntime.service.probe(
      subject: subject, tool: tool,
      projectID: routed.context.projectID,
      argumentsDigest: invocationDigest(descriptor: descriptor, arguments: routed.arguments),
      requirements: requirements, connectionID: routed.context.controlSession?.id,
      skillLibraries: skillLibraries)
    let label: String
    switch decision {
    case .allowed: label = "allowed"
    case .requests: label = "permission.required"
    case .denied: label = "denied"
    }
    return .object([
      "capability_id": .string(tool), "risk": .string(descriptor.risk.rawValue),
      "decision": .string(label), "requirements": try .encoded(descriptor.requirement),
    ])
  }

  private func projectList(context: ExecutionContext) -> JSONValue {
    .object([
      "projects": .array(
        projectOrder.compactMap { id in
          guard GatewayHostToolScope.projectID == nil || GatewayHostToolScope.projectID == id else {
            return nil
          }
          guard let project = projects[id] else { return nil }
          let state = projectAccess(id: id, context: context)
          return .object([
            "id": .string(id), "display_name": .string(project.displayName),
            "caller_access": .string(state), "selected": .bool(context.projectID == id),
          ])
        })
    ])
  }

  private func projectDescribe(arguments: [String: JSONValue], context: ExecutionContext) throws
    -> JSONValue
  {
    let id = try Self.requiredString("project_id", in: arguments)
    guard let project = projects[id] else { throw GatewayRuntimeError.projectNotFound(id) }
    let state = projectAccess(id: id, context: context)
    var metadata: [String: JSONValue] = [
      "id": .string(id), "display_name": .string(project.displayName),
      "caller_access": .string(state),
    ]
    if state == "read" || state == "write" {
      metadata["root_path"] = .string(project.rootPath)
      metadata["bookmark_stale"] = .bool(project.bookmarkIsStale)
      metadata["access"] =
        ProjectAccessReport(project: project, error: projectAccessError(project)).json
    }
    return .object(metadata)
  }

  private func projectAccess(id: String, context: ExecutionContext) -> String {
    do {
      let subject = try GatewayPermissionSubject(context: context)
      let source = try database?.derivedSourceID(for: id) ?? id
      var missing = false
      for value in [PermissionValue.write, .read] {
        let requirement = try PermissionRequirement(.project(source), value)
        let decision = try permissionRuntime.service.probe(
          subject: subject, tool: "project.describe",
          projectID: id, argumentsDigest: MCPExecutionRecord.digest(.string(id)),
          requirements: InvocationRequirements(actions: [
            PermissionAction(requirement: requirement, scope: .project(source))
          ]),
          connectionID: context.controlSession?.id)
        switch decision {
        case .allowed: return value.rawValue
        case .requests: missing = true
        case .denied: break
        }
      }
      return missing ? "not_granted" : "deny"
    } catch { return "deny" }
  }

  private func route(
    descriptor: CapabilityDescriptor,
    arguments: [String: JSONValue],
    context: ExecutionContext
  ) throws -> RoutedCall {
    var cleanArguments = arguments
    let argumentProjectID: String?
    if let value = cleanArguments.removeValue(forKey: "project_id") {
      guard let string = value.stringValue, !string.isEmpty else {
        throw Self.invalid(
          code: "project.invalid_id",
          message: "project_id must be a non-empty string."
        )
      }
      argumentProjectID = string
      if descriptor.id == "project.describe" {
        cleanArguments["project_id"] = value
      }
    } else {
      argumentProjectID = nil
    }
    if let argumentProjectID, let contextProjectID = context.projectID,
      argumentProjectID != contextProjectID
    {
      throw Self.invalid(
        code: PolicyDenialCode.projectDenied.rawValue,
        message: "project_id does not match the bound execution context."
      )
    }

    var routedContext = context
    routedContext.projectID = argumentProjectID ?? context.projectID
    if routedContext.projectID == nil,
      descriptor.projectRequirement == .required,
      projectOrder.count == 1
    {
      routedContext.projectID = projectOrder[0]
    }
    if descriptor.projectRequirement == .required, routedContext.projectID == nil {
      throw Self.invalid(
        code: PolicyDenialCode.projectRequired.rawValue,
        message:
          projectOrder.isEmpty
          ? "Register and grant a project before calling this capability."
          : "An explicit project_id is required when multiple projects are registered."
      )
    }

    let needsProjectProvider =
      descriptor.projectRequirement != .none || descriptor.mcpReference != nil
      || descriptor.id.hasPrefix("mcp.")
    let registryProjectID =
      needsProjectProvider
      ? (routedContext.projectID ?? projectOrder.first { providerRouters[$0] != nil }) : nil
    if let registryProjectID, projects[registryProjectID] == nil {
      throw GatewayRuntimeError.projectNotFound(registryProjectID)
    }
    return RoutedCall(
      arguments: cleanArguments,
      context: routedContext,
      registryProjectID: registryProjectID
    )
  }

  @discardableResult
  private func authorize(
    _ descriptor: CapabilityDescriptor,
    context: ExecutionContext
  ) throws -> ProfileGrant {
    try publication.requirePublished()
    _ = try GatewayPermissionSubject(context: context)
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
    let authorizedGrant = try currentHostGrant(context: context)
    let decision = policyEvaluator.evaluate(
      capability: descriptor,
      context: context,
      grant: authorizedGrant,
      registeredProjectIDs: Set(projectOrder)
    )
    guard case .allow = decision else {
      if case .deny(let code, let message) = decision {
        throw Self.invalid(code: code.rawValue, message: message)
      }
      throw Self.invalid(code: "policy.denied", message: "The capability was denied.")
    }
    if let projectID = context.projectID {
      if descriptor.id.hasPrefix("runtime.owners.") {
        // Directory access uses the current registration; the selected target separately
        // validates its original execution scope, including registration lifetime and root.
        _ = try currentRegisteredProject(projectID)
      } else {
        try validateExecutionProject(projectID, requiresAccess: false)
      }
    }
    if descriptor.id.hasPrefix("shell.") && !configuration.policy.shellEnabled {
      throw Self.invalid(
        code: "policy.shell_disabled",
        message: "Shell execution is disabled by the active gateway manifest."
      )
    }
    return authorizedGrant
  }

  private func validateAdmittedProject(
    name: String, descriptor: CapabilityDescriptor, context: ExecutionContext
  ) throws {
    guard name != "policy.probe", let projectID = context.projectID else { return }
    if descriptor.id.hasPrefix("runtime.owners.") || descriptor.hostOperation == .worktreeLifecycle
    {
      _ = try currentRegisteredProject(projectID)
    } else {
      let metadata = Self.coreDefinitions(
        databaseEnabled: database != nil, management: remoteManagement
      ).contains { $0.tool.name == descriptor.id }
      try validateExecutionProject(
        projectID, requiresAccess: !metadata && Self.requiresProjectDirectory(descriptor))
    }
  }

  private static func requiresProjectDirectory(_ descriptor: CapabilityDescriptor) -> Bool {
    descriptor.projectRequirement != .none
      || descriptor.mcpReference != nil || descriptor.id.hasPrefix("mcp.")
      || descriptor.requirement.access != .none || !descriptor.requirement.paths.isEmpty
  }

  private func visibilityRequirement(_ descriptor: CapabilityDescriptor)
    -> GatewayToolVisibilityRequirement
  {
    var actions = descriptor.requirement.permissions.map { PermissionAction(requirement: $0) }
    if let reference = descriptor.mcpReference {
      let permission: Permission
      let value: PermissionValue
      if let origin = pluginOrigins[.init(kind: .mcp, id: reference.serverID)] {
        permission = .plugin(origin.pluginID)
        value = .use
      } else {
        permission = .mcpServer(reference.serverID)
        value = descriptor.risk == .readOnly ? .read : .all
      }
      actions.append(PermissionAction(requirement: try! PermissionRequirement(permission, value)))
    }
    return GatewayToolVisibilityRequirement(
      actions: actions, requiresFullAccess: descriptor.requirement.requiresFullAccess)
  }

  private static func allows(_ state: PermissionState, _ value: PermissionValue) -> Bool {
    guard case .granted(let granted) = state else { return false }
    return granted == value || value == .read && (granted == .all || granted == .write)
  }

  private func descriptor(
    named name: String, projectID: String? = nil, invocationContext: InvocationContext
  ) throws
    -> CapabilityDescriptor
  {
    if let definition = Self.coreDefinitions(
      databaseEnabled: database != nil, management: remoteManagement
    )
    .first(where: { $0.tool.name == name }) {
      return definition.capability
    }
    if let router = projectID.flatMap({ providerRouters[$0] }) ?? firstProviderRouter {
      return try reviewedContribution(router.capability(named: name, context: invocationContext))
    }
    throw GatewayToolError.unknownTool(name)
  }

  private func reviewedContribution(_ descriptor: CapabilityDescriptor) throws
    -> CapabilityDescriptor
  {
    guard let reference = descriptor.mcpReference,
      let origin = pluginOrigins[.init(kind: .mcp, id: reference.serverID)]
    else { return descriptor }
    return try origin.applyingRequirements(to: descriptor)
  }

  private func invocationDescriptor(
    named name: String, arguments: [String: JSONValue], context: ExecutionContext,
    invocationContext: InvocationContext
  ) throws -> CapabilityDescriptor {
    if name == "mcp.connections.close",
      invocationContext.continuationTarget?.selectedOwnershipID == nil
    {
      throw Self.invalid(
        code: "mcp.connection_owner_required",
        message:
          "Select a live execution owner with runtime.owners.call before closing its connection.")
    }
    let projectID = arguments["project_id"]?.stringValue ?? context.projectID
    var descriptor = try descriptor(
      named: name, projectID: projectID, invocationContext: invocationContext)
    if name == "mcp.tools.call" {
      let serverID = try Self.requiredString("server", in: arguments)
      let toolName = try Self.requiredString("tool", in: arguments)
      let reference = MCPToolReference(serverID: serverID, toolName: toolName)
      descriptor.mcpReference = reference
      descriptor.equivalentCapabilityIDs = configuration.mcpCapabilityIDs(for: reference)
      descriptor.risk = configuration.mcpRisk(for: reference)
      guard let server = configuration.mcp.servers.first(where: { $0.id == serverID }) else {
        throw GatewayToolError.unknownMCPServer(serverID)
      }
      guard server.permitsTool(toolName) else {
        throw Self.invalid(
          code: "mcp.tool_not_approved",
          message: "The host has not approved this downstream MCP tool.")
      }
      if server.hostServices { descriptor.projectRequirement = .required }
    }
    guard let reference = descriptor.mcpReference else { return descriptor }
    let routed = try route(descriptor: descriptor, arguments: arguments, context: context)
    // Check caller and project authority before querying a downstream catalog.
    try authorize(descriptor, context: routed.context)
    guard let router = routed.registryProjectID.flatMap({ providerRouters[$0] }) ?? unscopedRouter
    else { throw GatewayRuntimeError.noProjects }
    let admission = try router.downstreamPolicy(
      for: reference,
      context: .init(session: context.controlSession, continuation: invocationContext.continuation))
    descriptor.risk = admission.risk
    descriptor.hostServiceAction = admission.hostServiceAction
    guard let server = configuration.mcp.servers.first(where: { $0.id == reference.serverID })
    else {
      throw GatewayToolError.unknownMCPServer(reference.serverID)
    }
    descriptor.requirement = server.requirement(for: admission)
    return try reviewedContribution(descriptor)
  }

  private var firstProviderRouter: GatewayProviderRouter? {
    projectOrder.lazy.compactMap { self.providerRouters[$0] }.first ?? unscopedRouter
  }

  private static func executionRecoveryKey(context: ExecutionContext, grant: ProfileGrant)
    -> String?
  {
    if let authority = context.controlSession {
      guard let session = authority as? GatewayControlSession else { return nil }
      let snapshot = session.snapshot
      guard !snapshot.ended, let consent = snapshot.fullAccessConsent,
        consent.lifetime == .alwaysAllowClient,
        let trustID = consent.trustID, let revision = consent.trustRevision
      else { return nil }
      return "trust:" + trustID + ":" + String(revision)
    }
    do {
      let encoded = try JSONEncoder().encode(grant)
      guard var fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
      else { return nil }
      for (key, value) in fields {
        if let values = value as? [String] { fields[key] = values.sorted() }
      }
      let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    } catch { return nil }
  }

  private func contextForCall(_ invocationContext: InvocationContext) -> ExecutionContext {
    var callContext = context
    callContext.requestID = UUID().uuidString
    if let session = invocationContext.session { callContext.controlSession = session }
    if let trace = MCPRuntimeAdapter.requestTrace { callContext.transportTrace = trace }
    return callContext
  }

  private func recordAudit(
    context: ExecutionContext,
    capabilityID: String,
    decision: AuditDecision,
    errorCode: String?,
    refusal: PluginCompatibilityRefusal? = nil,
    duration: Duration,
    inputDigest: String?,
    output: JSONValue?,
    authorization: InvocationAuthorization? = nil, evidence: GatewayPermissionAuditEvidence? = nil,
    executionID: UUID? = nil, permissionFailure: GatewayPermissionCallError? = nil
  ) throws {
    guard let database else {
      return
    }
    let outputData = try output.map { try Self.encoder.encode($0) }
    var fields = evidence?.fields ?? [:]
    if let refusal { fields["refusal"] = try ControlToolResponse.encodedPayload(refusal) }
    if let permissionFailure { fields.merge(permissionFailure.auditFields) { _, new in new } }
    if let authorization {
      fields["authorization_id"] = .string(authorization.id.uuidString)
      let requestIDs = Set(authorization.requestIDs.map(\.uuidString)).union(
        fields["permission_request_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
      fields["permission_request_ids"] = .array(requestIDs.sorted().map(JSONValue.string))
      fields["admission"] = .string(errorCode == "permission.admitted" ? "allowed" : "completed")
      fields["acting_principal"] = try .encoded(authorization.invocation.principal)
    }
    if let executionID { fields["execution_id"] = .string(executionID.uuidString) }
    let details: JSONValue? = fields.isEmpty ? nil : .object(fields)
    try database.recordAudit(
      AuditEvent(
        requestID: context.requestID,
        caller: context.caller,
        principalDigest: AuditEvent.verifiedPrincipalDigest(context.trustedPrincipalID),
        transport: context.transportTrace?.transport,
        socketConnectionID: context.transportTrace?.socketConnectionID,
        tunnelInstanceID: context.transportTrace?.tunnelInstanceID,
        tunnelProfileID: context.transportTrace?.tunnelProfileID,
        profileID: context.profileID,
        projectID: context.projectID,
        capabilityID: capabilityID,
        decision: decision,
        errorCode: errorCode,
        errorDetails: details,
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

  static func executionErrorEnvelope(
    _ error: any Error, context: ExecutionContext, capabilityID: String
  ) -> JSONValue {
    let failure = error as? GatewayExecutionPermissionFailure
    let result = attachExecutionMetadata(
      to: errorEnvelope(failure?.underlying ?? error), context: context, capabilityID: capabilityID)
    return GatewayExecutionPermissionMetadata.attach(to: result, groups: failure?.groups ?? [])
  }

  private static func errorEnvelope(_ error: Error) -> JSONValue {
    let code = auditErrorCode(for: error) ?? "gateway.execution_failed"
    let message =
      (error as? any LocalizedError)?.errorDescription
      ?? String(describing: error)
    var fields: [String: JSONValue] = ["code": .string(code), "message": .string(message)]
    if let permission = error as? GatewayPermissionCallError {
      fields.merge(permission.fields) { _, value in value }
    }
    if let refusal = error as? PluginCompatibilityRefusal {
      fields["refusal"] = try? ControlToolResponse.encodedPayload(refusal)
    }
    let payload = JSONValue.object(fields)
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
    authorization: InvocationAuthorization? = nil
  ) -> JSONValue {
    guard var object = result.objectValue else {
      return result
    }
    var executionObject: [String: JSONValue] = [
      "request_id": .string(context.requestID),
      "caller": .string(context.caller.rawValue),
      "profile_id": .string(context.profileID.rawValue),
      "project_id": context.projectID.map(JSONValue.string) ?? .null,
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
    let execution = JSONValue.object(executionObject)

    if var structuredContent = object["structuredContent"]?.objectValue {
      if capabilityID == "runtime.owners.call",
        let targetExecution = structuredContent["gateway_execution"]
      {
        structuredContent["target_execution"] = targetExecution
      }
      structuredContent["gateway_execution"] = execution
      object["structuredContent"] = .object(structuredContent)
    }

    var metadata = object["_meta"]?.objectValue ?? [:]
    if capabilityID == "runtime.owners.call",
      let targetExecution = metadata["computer_mcp"]
    {
      metadata["computer_mcp_target"] = targetExecution
    }
    metadata["computer_mcp"] = execution
    object["_meta"] = .object(metadata)
    return .object(object)
  }

  private static func coreDefinitions(
    databaseEnabled: Bool, management: (any GatewayManagementProvider)?
  )
    -> [ToolDefinition]
  {
    var definitions = [
      ToolDefinition(
        tool: MCPTool(
          name: "project.list",
          description:
            "List each registered project’s stable ID, name and caller access. Project details require its read permission.",
          inputSchema: .object(["type": .string("object"), "additionalProperties": .bool(false)]),
          annotations: .init(
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
          )
        ),
        capability: CapabilityDescriptor(
          id: "project.list", risk: .readOnly, requirement: .none,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "project.request",
          description:
            "Ask the local owner to register a folder and grant read or write access. Allow is persistent; registration has no one-time option.",
          inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
              "path": .object([
                "type": .string("string"),
                "description": .string("Absolute path to an existing folder."),
              ]),
              "access": .object([
                "type": .string("string"), "enum": .array([.string("read"), .string("write")]),
              ]),
            ]),
            "required": .array([.string("path"), .string("access")]),
            "additionalProperties": .bool(false),
          ]),
          annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        capability: CapabilityDescriptor(
          id: "project.request", risk: .readOnly, requirement: .none,
          projectRequirement: .none, localOnly: false, usesNetwork: false)
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "project.describe",
          description: "Describe one registered project by stable project_id.",
          inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
              "project_id": .object([
                "type": .string("string"),
                "description": .string("Stable project id returned by project.list."),
              ])
            ]),
            "required": .array([.string("project_id")]),
            "additionalProperties": .bool(false),
          ]),
          annotations: .init(
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
          )
        ),
        capability: CapabilityDescriptor(
          id: "project.describe", risk: .readOnly, requirement: .none,
          projectRequirement: .none,
          localOnly: false, usesNetwork: false
        )
      ),
      ToolDefinition(
        tool: MCPTool(
          name: "policy.probe",
          description:
            "Evaluate whether the active Gateway profile and project would authorize one capability without executing it. Policy denials return their stable error code and are audited.",
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
                  "Optional target arguments used only for project routing and policy evaluation."
                ),
                "additionalProperties": .bool(true),
              ]),
              "project_id": .object([
                "type": .string("string"),
                "description": .string("Optional stable project id for the policy context."),
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
        capability: CapabilityDescriptor(
          id: "policy.probe", risk: .readOnly, requirement: .none,
          projectRequirement: .optional,
          localOnly: false, usesNetwork: false
        )
      ),
    ]
    definitions.append(contentsOf: GatewayOwnerRouting.definitions)
    if let management { definitions += management.definitions }
    return definitions
  }

  private static func toolWithRequirements(_ tool: MCPTool, descriptor: CapabilityDescriptor)
    -> MCPTool
  {
    guard case .object(var schema) = tool.inputSchema else { return tool }
    var properties = schema["properties"]?.objectValue ?? [:]
    if descriptor.projectRequirement != .none {
      properties["project_id"] = .object([
        "type": .string("string"),
        "description": .string("Stable project id returned by project.list."),
      ])
    }
    properties[GatewayPermissionRetryInput.field] = .object([
      "type": .string("array"),
      "items": .object(["type": .string("string"), "format": .string("uuid")]),
      "maxItems": .integer(64),
      "description": .string(
        "Permission request IDs for an exact retry after the local owner answers."),
    ])
    var metadata = tool.meta?.objectValue ?? [:]
    var gateway = metadata["computer_mcp"]?.objectValue ?? [:]
    gateway["requirements"] = try? .encoded(descriptor.requirement)
    metadata["computer_mcp"] = .object(gateway)
    schema["properties"] = .object(properties)
    return MCPTool(
      name: tool.name,
      title: tool.title,
      description: tool.description,
      inputSchema: .object(schema),
      outputSchema: tool.outputSchema,
      annotations: tool.annotations,
      meta: .object(metadata),
      mcpReference: tool.mcpReference
    )
  }

  private func invocationDigest(
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
          code: "permission.provider_unavailable",
          message: "The invocation provider is unavailable."
        )
      }
      // Registration launch/authentication inputs and plugin provenance bind retry identity.
      // Only their digest is stored; credentials never enter an error or audit payload.
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
    if let failure = error as? GatewayExecutionPermissionFailure {
      return auditDecision(for: failure.underlying)
    }
    if case .escapesProject = error as? ProjectPathResolutionError { return .denied }
    if error is GatewayPermissionError || error is PermissionModelError { return .denied }
    if let classification = (error as? any AuditErrorClassifying)?.auditClassification {
      return classification.decision
    }

    guard case .invalidArguments(let message) = error as? GatewayToolError else {
      return .failed
    }
    let deniedPrefixes = [
      "[policy.",
      "[management.local_consent_required]",
      "[permission.",
      "[mcp.tool_not_approved]",
    ]
    return deniedPrefixes.contains(where: message.hasPrefix) ? .denied : .failed
  }

  static func auditErrorCode(for error: Error) -> String? {
    if let failure = error as? GatewayExecutionPermissionFailure {
      return auditErrorCode(for: failure.underlying)
    }
    if case .escapesProject = error as? ProjectPathResolutionError {
      return "permission.invalid_path"
    }
    if let permission = error as? GatewayPermissionCallError { return permission.code }
    if case .unavailable = error as? ExecutionEnvironmentError { return "execution.unavailable" }
    if error is ExecutionEnvironmentError { return "execution.invalid_context" }
    if let permission = error as? PermissionModelError {
      switch permission {
      case .retryMismatch: return "permission.retry_mismatch"
      case .requestConsumed: return "permission.retry_consumed"
      case .expiredRequest: return "permission.request_expired"
      case .authoritySuspended: return "permission.authority_suspended"
      default: return "permission.invalid_authorization"
      }
    }
    if error is GatewayPermissionError { return "permission.unavailable" }
    if error is PluginCompatibilityRefusal || error is PluginManifestError
      || error is PluginCatalogError || error is PluginStoreError || error is PluginArchiveError
      || error is PluginHostError
    {
      return ControlToolResponse.auditDisposition(for: error).code
    }
    if case .configurationChanged = error as? GatewayDatabaseError {
      return "configuration.changed"
    }

    if let classification = (error as? any AuditErrorClassifying)?.auditClassification {
      return classification.code
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

private struct GatewayAdmittedInvocation: Sendable {
  let route: RoutedCall
  let grant: ProfileGrant
  let resolved: ResolvedToolInvocation
  let authorization: InvocationAuthorization
  let evidence: GatewayPermissionAuditEvidence
  let directory: URL?
  let remoteService: Bool
  let retryIDs: Set<UUID>
  let retainedExecution: PreparedExecutionContext?
  let providerSource: GatewayProviderSource?
  let providerBinding: ProviderExecutionBinding?
  let callbackExecution: PreparedExecutionContext?
}

private struct RoutedCall: Sendable {
  var arguments: [String: JSONValue]
  var context: ExecutionContext
  var registryProjectID: String?
}

/// Retains each acquired resource until one shared cleanup task has joined it, including failed initialization.
private final class GatewayRuntimeLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private var cleanup: [@Sendable () async -> Void] = []
  private var shutdown: Task<Void, Never>?
  private var executionIDs: Set<UUID> = []
  private var stopExecutions: (@Sendable (Set<UUID>) async -> Void)?
  private var drainInvocations: (@Sendable () async -> Void)?
  var isClosing: Bool { lock.withLock { shutdown != nil } }

  func bindExecutionOwner(
    stop: @escaping @Sendable (Set<UUID>) async -> Void,
    drain: @escaping @Sendable () async -> Void
  ) {
    lock.withLock {
      precondition(shutdown == nil && stopExecutions == nil)
      stopExecutions = stop
      drainInvocations = drain
    }
  }

  /// Registration and closing share a gate. A preparation that loses this race
  /// is stopped before dispatch and remains part of the final owner drain.
  func registerExecution(_ id: UUID) -> Bool {
    lock.withLock {
      executionIDs.insert(id)
      return shutdown == nil
    }
  }

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
      let initialExecutions = executionIDs
      let stop = stopExecutions
      let drain = drainInvocations
      let task = Task { [self] in
        await stop?(initialExecutions)
        for operation in operations { await operation() }
        await drain?()
        let finalExecutions = lock.withLock { executionIDs }
        await stop?(finalExecutions)
      }
      shutdown = task
      return task
    }
  }
}

enum GatewayHostToolScope {
  @TaskLocal static var projectID: String?
  @TaskLocal static var execution: PreparedExecutionContext?
  @TaskLocal static var lifetime: GatewayHostCallbackLifetime?
}

package enum GatewayRuntimeError: Error, LocalizedError, Equatable {
  case noProjects
  case duplicateProjectID(String)
  case projectNotFound(String)

  package var errorDescription: String? {
    switch self {
    case .noProjects:
      return "No registered project is available."
    case .duplicateProjectID(let id):
      return "Duplicate registered project id: \(id)"
    case .projectNotFound(let id):
      return "Unknown registered project id: \(id)"
    }
  }
}
