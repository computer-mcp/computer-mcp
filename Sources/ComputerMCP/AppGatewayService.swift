import Darwin
import Foundation

package enum AppGatewayServiceState: String, Codable, Equatable, Sendable {
  case stopped
  case starting
  case running
  case stopping
  case failed
}

package struct AppGatewayServiceSnapshot: Codable, Equatable, Sendable {
  package var state: AppGatewayServiceState
  package var profileID: GatewayProfileID?
  package var socketPath: String
  package var processIdentifier: Int32
  package var startedAt: Date?
  package var connectionCount: Int
  package var lastError: String?

  package init(
    state: AppGatewayServiceState,
    profileID: GatewayProfileID?,
    socketPath: String,
    processIdentifier: Int32,
    startedAt: Date?,
    connectionCount: Int,
    lastError: String?
  ) {
    self.state = state
    self.profileID = profileID
    self.socketPath = socketPath
    self.processIdentifier = processIdentifier
    self.startedAt = startedAt
    self.connectionCount = connectionCount
    self.lastError = lastError
  }
}

package actor AppGatewayService {
  private struct ManifestAttempt: Equatable {
    let fingerprint: ManifestFileMonitor.Fingerprint?
  }

  private struct RuntimeKey: Hashable {
    let principalID: String
    let profileID: GatewayProfileID
    let caller: GatewayCallerKind
  }

  private typealias AdmittedRuntime = (
    inputs: AppControlPlaneService.GatewayInputs, gateway: GatewayRuntime
  )

  private struct PendingRuntime {
    let id: UUID
    let task: Task<AdmittedRuntime, any Error>
  }

  private struct InvocationSelection {
    let gateway: GatewayRuntime
    let target: MCPContinuationTarget?
    let ownership: GatewayOwnedWork.Lease
  }

  /// The connection fixes identity; each invocation resolves its generation at admission.
  private struct SessionDispatcher: GatewayAsyncToolServing {
    weak var service: AppGatewayService?
    let key: RuntimeKey
    let epoch: UUID
    let trace: GatewayTransportTrace
    let changes: GatewayToolChangeBroadcaster

    func toolChanges() -> AsyncStream<Void> { changes.stream() }

    func listToolsAsync() async throws -> [MCPTool] {
      guard let service else { throw GatewaySocketError.notConnected }
      return try await service.listTools(key: key, epoch: epoch, trace: trace)
    }

    func refreshTools() async throws {
      guard let service else { throw GatewaySocketError.notConnected }
      try await service.refreshTools(key: key, epoch: epoch, trace: trace)
    }

    func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
      guard let service else { throw GatewaySocketError.notConnected }
      return try await service.callTool(
        name: name, arguments: arguments, key: key, epoch: epoch, trace: trace, envelope: false)
    }

    func callToolForMCPAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
      guard let service else { throw GatewaySocketError.notConnected }
      return try await service.callTool(
        name: name, arguments: arguments, key: key, epoch: epoch, trace: trace, envelope: true)
    }
  }

  package nonisolated let socketConfiguration: GatewaySocketConfiguration

  private let controlPlane: AppControlPlaneService
  private var server: GatewaySocketServer?
  private var state: AppGatewayServiceState = .stopped
  private var profileID: GatewayProfileID?
  private var startedAt: Date?
  private var lastError: String?
  private var configurationChangeInProgress = false
  private var publicationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
  private var preparingRuntimeCount = 0
  private var runtimes: [RuntimeKey: AdmittedRuntime] = [:]
  private var pendingRuntimes: [RuntimeKey: PendingRuntime] = [:]
  private var retiredRuntimes: [RuntimeKey: [UUID: GatewayRuntime]] = [:]
  private var retiringRuntimes: [UUID: Task<Void, Never>] = [:]
  private var runtimeObservers: [UUID: [Task<Void, Never>]] = [:]
  private var catalogChanges: [RuntimeKey: GatewayToolChangeBroadcaster] = [:]
  private var manifestObserver: Task<Void, Never>?
  private var manifestMonitor: ManifestFileMonitor?
  private var manifestReloadObserver: Task<Void, Never>?
  private var manifestReloadError: String?
  private var lastManifestAttempt: ManifestAttempt?
  private var listenerEpoch = UUID()
  private var terminalSessions = GatewayTerminalSessions()
  private var lifecycleInProgress = false
  private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []

  package init(
    controlPlane: AppControlPlaneService,
    socketConfiguration: GatewaySocketConfiguration
  ) {
    self.controlPlane = controlPlane
    self.socketConfiguration = socketConfiguration
  }

  package static func live(
    controlPlane: AppControlPlaneService,
    directories: AppControlPlaneServiceDirectories
  ) -> AppGatewayService {
    AppGatewayService(
      controlPlane: controlPlane,
      socketConfiguration: GatewaySocketConfiguration(
        socketURL: directories.gatewaySocket,
        tunnelCredentialFile: directories.openAITunnelGatewayCredential
      )
    )
  }

  package func start(profile requestedProfile: GatewayProfileID? = nil) async throws {
    await acquireLifecycle()
    defer { releaseLifecycle() }
    try await startOwnedRuntime(profile: requestedProfile)
  }

  private func startOwnedRuntime(profile requestedProfile: GatewayProfileID?) async throws {
    guard !configurationChangeInProgress else { throw PluginHostError.changeInProgress }
    guard state != .running && state != .starting else {
      return
    }

    state = .starting
    listenerEpoch = UUID()
    lastError = nil
    manifestReloadError = nil
    lastManifestAttempt = nil
    let selectedProfile: GatewayProfileID
    do {
      if let requestedProfile {
        selectedProfile = requestedProfile
      } else {
        selectedProfile = try await controlPlane.activeGatewayProfile()
      }
      guard selectedProfile != .localAdmin else {
        throw AppControlPlaneServiceError.localAdminCannotBeSocketProfile
      }
      self.profileID = selectedProfile

      try await controlPlane.start()
      let epoch = listenerEpoch
      let manifestChanges = await controlPlane.manifestChanges()
      manifestObserver = Task { [weak self] in
        for await _ in manifestChanges {
          guard !Task.isCancelled else { break }
          await self?.configurationChanged(epoch: epoch)
        }
      }
      let monitor = try ManifestFileMonitor(manifestURL: controlPlane.directories.manifest)
      manifestMonitor = monitor
      if let credentialFile = socketConfiguration.tunnelCredentialFile {
        try GatewaySocketCredentialStore.create(at: credentialFile)
      }
      let controlPlane = controlPlane
      var configuration = socketConfiguration
      if configuration.tunnelCredentialFile != nil {
        configuration.tunnelPrincipalID = try await controlPlane.gatewayTunnelPrincipalID()
      }
      let server = GatewaySocketServer(
        configuration: configuration,
        responseObserver: { data, identity in
          try? await controlPlane.correlateMCPResponse(data, identity: identity)
        },
        sessionFactory: { [weak self] identity in
          guard let self else { throw GatewaySocketError.notConnected }
          return try await self.makeSession(identity: identity)
        }
      )
      try await server.start()
      self.server = server
      self.startedAt = Date()
      state = .running
      manifestReloadObserver = Task { [weak self, changes = monitor.changes] in
        for await _ in changes {
          guard !Task.isCancelled else { break }
          do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
          while await self?.reloadExternalManifest(epoch: epoch) == true {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
          }
        }
      }
    } catch {
      await stopManifestMonitoring()
      if let credentialFile = socketConfiguration.tunnelCredentialFile {
        GatewaySocketCredentialStore.remove(at: credentialFile)
      }
      self.server = nil
      profileID = nil
      startedAt = nil
      lastError = Self.stableDescription(error)
      state = .failed
      throw error
    }
  }

  /// Existing sessions retain their admitted profile; only future connections adopt this selection.
  package func selectProfile(_ profile: GatewayProfileID) throws {
    guard profile != .localAdmin else {
      throw AppControlPlaneServiceError.localAdminCannotBeSocketProfile
    }
    if state == .running || state == .starting { profileID = profile }
  }

  package func restart(profile: GatewayProfileID? = nil) async throws {
    manifestReloadObserver?.cancel()
    await acquireLifecycle()
    defer { releaseLifecycle() }
    await stopOwnedRuntime()
    try await startOwnedRuntime(profile: profile)
  }

  package func stop() async {
    manifestReloadObserver?.cancel()
    await acquireLifecycle()
    defer { releaseLifecycle() }
    await stopOwnedRuntime()
  }

  private func stopOwnedRuntime() async {
    guard state != .stopped && state != .stopping else {
      return
    }
    state = .stopping
    listenerEpoch = UUID()
    await stopManifestMonitoring()
    let pending = pendingRuntimes.values.map(\.task)
    pendingRuntimes.removeAll()
    for task in pending { task.cancel() }
    let activeServer = server
    server = nil
    await activeServer?.stop()
    for task in pending { _ = try? await task.value }
    let ownedRuntimes =
      runtimes.values.map(\.gateway)
      + retiredRuntimes.values.flatMap { $0.values }
    runtimes.removeAll()
    retiredRuntimes.removeAll()
    for observers in runtimeObservers.values { for observer in observers { observer.cancel() } }
    runtimeObservers.removeAll()
    for changes in catalogChanges.values { changes.finish() }
    catalogChanges.removeAll()
    let retiring = Array(retiringRuntimes.values)
    for runtime in ownedRuntimes { await runtime.shutdown() }
    for cleanup in retiring { await cleanup.value }
    retiringRuntimes.removeAll()
    terminalSessions = GatewayTerminalSessions()
    if let credentialFile = socketConfiguration.tunnelCredentialFile {
      GatewaySocketCredentialStore.remove(at: credentialFile)
    }
    do {
      try await controlPlane.stop()
      state = .stopped
      profileID = nil
      startedAt = nil
      lastError = nil
    } catch {
      state = .failed
      lastError = Self.stableDescription(error)
    }
  }

  private func makeSession(identity: GatewaySocketConnectionIdentity) async throws
    -> GatewaySocketServerSession
  {
    let epoch = listenerEpoch
    try requireAdmission(epoch: epoch)
    guard let profileID else { throw GatewaySocketError.notConnected }
    let key = RuntimeKey(
      principalID: identity.trustedPrincipalID, profileID: profileID, caller: identity.caller)
    let admitted = try await admittedRuntime(key: key, epoch: epoch, trace: identity.transportTrace)
    try requireAdmission(epoch: epoch)
    let dispatcher = SessionDispatcher(
      service: self, key: key, epoch: epoch, trace: identity.transportTrace,
      changes: changes(for: key))
    let server = await MCPRuntimeAdapter.makeGatewayServer(
      configuration: admitted.inputs.configuration, registry: dispatcher,
      transportTrace: identity.transportTrace)
    do {
      try requireAdmission(epoch: epoch)
    } catch {
      await server.stop()
      throw error
    }
    // A disconnected MCP session releases its protocol server, not listener-owned work.
    return GatewaySocketServerSession(server: server)
  }

  private func requireAdmission(epoch: UUID) throws {
    try Task.checkCancellation()
    guard listenerEpoch == epoch, state == .running || state == .starting
    else { throw GatewaySocketError.notConnected }
  }

  private func admittedRuntime(key: RuntimeKey, epoch: UUID, trace: GatewayTransportTrace)
    async throws
    -> AdmittedRuntime
  {
    try requireAdmission(epoch: epoch)
    if configurationChangeInProgress {
      if let existing = runtimes[key] { return existing }
      try await waitForPublication()
      return try await admittedRuntime(key: key, epoch: epoch, trace: trace)
    }
    if let pending = pendingRuntimes[key] { return try await pending.task.value }
    let current = try await controlPlane.gatewayInputs()
    try requireAdmission(epoch: epoch)
    if configurationChangeInProgress {
      if let existing = runtimes[key] { return existing }
      try await waitForPublication()
      return try await admittedRuntime(key: key, epoch: epoch, trace: trace)
    }
    if let pending = pendingRuntimes[key] { return try await pending.task.value }
    if let existing = runtimes[key], existing.inputs.configuration == current.configuration,
      existing.inputs.workspaces == current.workspaces, existing.inputs.plugins == current.plugins
    {
      return existing
    }
    reapRetiredRuntimes()
    let retiredCount = retiredRuntimes.values.reduce(0) { $0 + $1.count }
    guard
      runtimes.count + retiredCount + retiringRuntimes.count + pendingRuntimes.count
        + preparingRuntimeCount < 128
    else {
      throw GatewaySocketError.invalidConfiguration(
        "The gateway has reached its owned runtime capacity.")
    }
    let id = UUID()
    let terminalSessions = terminalSessions
    let task = Task { [controlPlane] in
      do {
        let admitted = try await controlPlane.makeGatewaySocketRuntime(
          caller: key.caller, profileID: key.profileID, transportTrace: trace,
          trustedPrincipalID: key.principalID, terminalSessions: terminalSessions)
        do {
          try requireAdmission(epoch: epoch)
          guard pendingRuntimes[key]?.id == id else { throw GatewaySocketError.notConnected }
        } catch {
          await admitted.gateway.shutdown()
          throw error
        }
        if let previous = runtimes.updateValue(admitted, forKey: key) {
          retiredRuntimes[key, default: [:]][previous.gateway.generationID] = previous.gateway
        }
        pendingRuntimes.removeValue(forKey: key)
        observe(admitted.gateway, key: key, epoch: epoch)
        reapRetiredRuntimes()
        changes(for: key).send()
        return admitted
      } catch {
        if pendingRuntimes[key]?.id == id { pendingRuntimes.removeValue(forKey: key) }
        throw error
      }
    }
    pendingRuntimes[key] = PendingRuntime(id: id, task: task)
    return try await task.value
  }

  private func changes(for key: RuntimeKey) -> GatewayToolChangeBroadcaster {
    if let existing = catalogChanges[key] { return existing }
    let changes = GatewayToolChangeBroadcaster()
    catalogChanges[key] = changes
    return changes
  }

  private func configurationChanged(epoch: UUID) {
    guard epoch == listenerEpoch else { return }
    for changes in catalogChanges.values { changes.send() }
  }

  private func observe(_ runtime: GatewayRuntime, key: RuntimeKey, epoch: UUID) {
    let id = runtime.generationID
    let work = runtime.ownedWork.updates()
    let tools = runtime.toolChanges()
    runtimeObservers[id] = [
      Task { [weak self] in
        for await _ in work {
          guard !Task.isCancelled else { break }
          await self?.workChanged(epoch: epoch)
        }
      },
      Task { [weak self] in
        for await _ in tools {
          guard !Task.isCancelled else { break }
          await self?.toolsChanged(key: key, generation: id, epoch: epoch)
        }
      },
    ]
  }

  private func toolsChanged(key: RuntimeKey, generation: UUID, epoch: UUID) {
    guard epoch == listenerEpoch, runtimes[key]?.gateway.generationID == generation else { return }
    changes(for: key).send()
  }

  private func workChanged(epoch: UUID) {
    guard epoch == listenerEpoch else { return }
    reapRetiredRuntimes()
  }

  /// Invocation reservations and the retirement claim run without suspending the listener actor.
  private func reapRetiredRuntimes() {
    for (key, generations) in retiredRuntimes {
      for (id, runtime) in generations {
        guard let cleanup = runtime.beginRetirementIfDrained() else { continue }
        retiredRuntimes[key]?.removeValue(forKey: id)
        if retiredRuntimes[key]?.isEmpty == true { retiredRuntimes.removeValue(forKey: key) }
        if let observers = runtimeObservers.removeValue(forKey: id) {
          for observer in observers { observer.cancel() }
        }
        retiringRuntimes[id] = Task {
          await cleanup.value
          retiringRuntimes.removeValue(forKey: id)
        }
      }
    }
  }

  private func listTools(key: RuntimeKey, epoch: UUID, trace: GatewayTransportTrace) async throws
    -> [MCPTool]
  {
    _ = try await admittedRuntime(key: key, epoch: epoch, trace: trace)
    try requireAdmission(epoch: epoch)
    guard let runtime = runtimes[key]?.gateway else { throw GatewaySocketError.notConnected }
    let reservation = try runtime.ownedWork.admitInvocation(
      workspaceID: nil, resourceID: "tools/list")
    defer { reservation.finish() }
    return try await runtime.listToolsAsync()
  }

  private func refreshTools(key: RuntimeKey, epoch: UUID, trace: GatewayTransportTrace) async throws
  {
    _ = try await admittedRuntime(key: key, epoch: epoch, trace: trace)
    try requireAdmission(epoch: epoch)
    guard let runtime = runtimes[key]?.gateway else { throw GatewaySocketError.notConnected }
    let reservation = try runtime.ownedWork.admitInvocation(
      workspaceID: nil, resourceID: "tools/list")
    defer { reservation.finish() }
    try await runtime.refreshTools()
  }

  private func selectInvocation(
    name: String, arguments: JSONValue?, key: RuntimeKey, epoch: UUID, trace: GatewayTransportTrace
  ) async throws -> InvocationSelection {
    try requireAdmission(epoch: epoch)
    if name.hasPrefix("runtime.owners."), let current = runtimes[key]?.gateway {
      return InvocationSelection(
        gateway: current, target: nil,
        ownership: try current.ownedWork.admitInvocation(
          workspaceID: arguments?.objectValue?["workspace_id"]?.stringValue, resourceID: name))
    }
    if let owned = try retainedInvocation(name: name, arguments: arguments, key: key) {
      return owned
    }
    _ = try await admittedRuntime(key: key, epoch: epoch, trace: trace)
    try requireAdmission(epoch: epoch)
    guard let current = runtimes[key]?.gateway else { throw GatewaySocketError.notConnected }
    // Construction suspends; a prior invocation may have published its owner while we waited.
    if let owned = try retainedInvocation(name: name, arguments: arguments, key: key) {
      return owned
    }
    return InvocationSelection(
      gateway: current, target: nil,
      ownership: try current.ownedWork.admitInvocation(
        workspaceID: arguments?.objectValue?["workspace_id"]?.stringValue,
        resourceID: name))
  }

  private func retainedInvocation(name: String, arguments: JSONValue?, key: RuntimeKey) throws
    -> InvocationSelection?
  {
    let generations =
      (runtimes[key].map { [$0.gateway] } ?? [])
      + Array(retiredRuntimes[key]?.values ?? [:].values)
    let workspaceID =
      arguments?.objectValue?["workspace_id"]?.stringValue
      ?? runtimes[key]?.gateway.unambiguousWorkspaceID
    var lookups: [(GatewayRuntime, GatewayRuntime.ContinuationLookup)] = []
    for runtime in generations {
      for lookup in try runtime.continuationLookups(
        name: name, arguments: arguments, workspaceID: workspaceID)
      {
        lookups.append((runtime, lookup))
      }
    }
    if let matches = try MCPContinuationDirectory.uniqueOwner(in: lookups.map { $0.1.observation }),
      let match = matches.first,
      let (runtime, lookup) = lookups.first(where: { $0.1.observation.matches.contains(match) })
    {
      let target = MCPContinuationTarget(
        workspaceID: lookup.workspaceID, reference: lookup.reference,
        connectionID: match.connectionID, instanceID: match.instanceID,
        resources: Dictionary(uniqueKeysWithValues: matches.map { ($0.resource, $0.acquiredBy) }))
      return InvocationSelection(
        gateway: runtime, target: target,
        ownership: try runtime.ownedWork.admitInvocation(
          workspaceID: lookup.workspaceID, resourceID: name))
    }
    var tool = name
    var object = arguments?.objectValue ?? [:]
    if tool == "operations.prepare" || tool == "operations.commit" {
      tool = object["tool"]?.stringValue ?? ""
      object = object["arguments"]?.objectValue ?? [:]
    }
    let kind: GatewayOwnedWork.Kind
    let id: String
    switch tool {
    case "shell.read", "shell.write", "shell.cancel":
      kind = .shell
      guard let value = object["session_id"]?.stringValue else { return nil }
      id = value
    case "process.read", "process.cancel":
      kind = .shell
      guard let value = object["process_id"]?.stringValue else { return nil }
      id = value
    case "mcp.requests.read", "mcp.requests.cancel":
      kind = .mcpRequest
      guard let value = object["request_id"]?.stringValue else { return nil }
      id = value
    default: return nil
    }
    let owners = generations.filter { runtime in
      runtime.ownedWork.snapshot.contains {
        $0.kind == kind && $0.workspaceID == workspaceID && $0.resourceID == id
          && (kind != .mcpRequest || $0.registrationID == object["server"]?.stringValue)
      }
    }
    guard owners.count <= 1 else {
      throw GatewayToolError.invalidArguments(
        "[runtime.owner_ambiguous] Select the exact work owner.")
    }
    guard let owner = owners.first else { return nil }
    return InvocationSelection(
      gateway: owner, target: nil,
      ownership: try owner.ownedWork.admitInvocation(workspaceID: workspaceID, resourceID: name))
  }

  private func callTool(
    name: String, arguments: JSONValue?, key: RuntimeKey, epoch: UUID, trace: GatewayTransportTrace,
    envelope: Bool
  ) async throws -> JSONValue {
    do {
      let selection = try await selectInvocation(
        name: name, arguments: arguments, key: key, epoch: epoch, trace: trace)
      defer { selection.ownership.finish() }
      var scopedArguments = arguments
      if let workspaceID = selection.target?.workspaceID {
        var object = arguments?.objectValue ?? [:]
        // The verified continuation owner supplies the scope for an unscoped request.
        if object["workspace_id"] == nil { object["workspace_id"] = .string(workspaceID) }
        scopedArguments = .object(object)
      }
      let owners =
        (runtimes[key].map { [$0.gateway] } ?? [])
        + Array(retiredRuntimes[key]?.values ?? [:].values)
      return try await GatewayOwnerRouting.$runtimes.withValue(owners) {
        try await GatewayOwnerRouting.$call.withValue({ [weak self] owner, tool, arguments in
          guard let self else { throw GatewayOwnerSelection.unavailable() }
          return try await self.callOwnedTool(
            owner: owner, name: tool, arguments: arguments, key: key, epoch: epoch)
        }) {
          try await MCPContinuationTarget.$current.withValue(selection.target) {
            if envelope {
              return try await selection.gateway.callToolForMCPAsync(
                name: name, arguments: scopedArguments)
            }
            return try await selection.gateway.callToolAsync(name: name, arguments: scopedArguments)
          }
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard envelope, let runtime = runtimes[key]?.gateway else { throw error }
      return runtime.routingErrorForMCP(
        error, name: name, arguments: arguments, recordFailure: true)
    }
  }

  private func callOwnedTool(
    owner: GatewayOwnerSelection, name: String, arguments: JSONValue, key: RuntimeKey, epoch: UUID
  ) async throws -> JSONValue {
    try requireAdmission(epoch: epoch)
    let runtime: GatewayRuntime?
    if runtimes[key]?.gateway.generationID == owner.runtimeID {
      runtime = runtimes[key]?.gateway
    } else {
      runtime = retiredRuntimes[key]?[owner.runtimeID]
    }
    guard let runtime else { throw GatewayOwnerSelection.unavailable() }
    return try await runtime.callOwnedTool(owner: owner, name: name, arguments: arguments)
  }

  package func snapshot() async -> AppGatewayServiceSnapshot {
    AppGatewayServiceSnapshot(
      state: state,
      profileID: profileID,
      socketPath: socketConfiguration.socketURL.path,
      processIdentifier: getpid(),
      startedAt: startedAt,
      connectionCount: await server?.connectionCount() ?? 0,
      lastError: lastError ?? manifestReloadError
    )
  }

  /// Existing keys continue on their admitted generation while new keys await publication.
  package func changePlugins(_ change: PluginHostChange, expectedRevision: Int64) async throws
    -> PluginHostSnapshot
  {
    try await withConfigurationChange {
      try await controlPlane.applyPluginChange(change, expectedRevision: expectedRevision) {
        [self] expected, proposed, storage in
        let state = GatewayDatabase.ConfigurationState(
          workspaces: expected.workspaces, workspaceAliases: expected.persisted.workspaceAliases,
          profiles: expected.profiles, plugins: proposed)
        _ = try await preparePublication(expected: expected, proposed: state, storage: storage) {
          try self.controlPlane.database.savePluginStoreSnapshot(
            proposed, expectedRevision: expected.plugins.revision,
            expectedConfiguration: expected.persisted, resolution: $0)
        }
      }
    }
  }

  func changeWorkspaces(_ change: WorkspaceHostChange) async throws -> WorkspaceChangeResult {
    try await withConfigurationChange {
      try await controlPlane.applyWorkspaceChange(change) { [self] expected, prepared in
        let selected: (id: String, root: WorkspaceRootIdentity)?
        if case .repair(let workspace, let root) = prepared.mutation {
          selected = (workspace.id, root)
        } else {
          selected = nil
        }
        return try await preparePublication(
          expected: expected, proposed: prepared.proposed, storage: nil, requiredWorkspace: selected
        ) {
          try self.controlPlane.database.saveWorkspaceChange(prepared, resolution: $0)
        }
      }
    }
  }

  func changeManifest(
    _ manifest: String, reason: ManifestChangeReason = .activated, expectedDigest: String? = nil
  ) async throws -> ConfigurationRevision {
    let revision = try await withConfigurationChange {
      try await publishManifest(manifest, reason: reason, expectedDigest: expectedDigest)
    }
    manifestReloadError = nil
    lastManifestAttempt = nil
    return revision
  }

  private func publishManifest(
    _ manifest: String, reason: ManifestChangeReason, expectedDigest: String?
  ) async throws -> ConfigurationRevision {
    try await controlPlane.applyManifestChange(
      manifest, reason: reason, expectedDigest: expectedDigest
    ) { [self] _, prepared in
      try await preparePublication(
        inputs: .init(configuration: prepared.configuration, persisted: prepared.persisted),
        storage: nil
      ) { resolution, install in
        try self.controlPlane.manifestStore.commit(
          prepared, resolution: resolution, install: install)
      }
    }
  }

  /// True retries a transient conflict within the one owned, cancellable consumer.
  private func reloadExternalManifest(epoch: UUID) async -> Bool {
    guard !Task.isCancelled, epoch == listenerEpoch, state == .running else { return false }
    guard !lifecycleInProgress else { return true }
    let attempt = ManifestAttempt(
      fingerprint: ManifestFileMonitor.fingerprint(controlPlane.directories.manifest))
    guard attempt != lastManifestAttempt else { return false }
    do {
      guard let input = try controlPlane.manifestStore.externalInput() else {
        lastManifestAttempt = attempt
        manifestReloadError = nil
        return false
      }
      guard
        attempt.fingerprint == ManifestFileMonitor.fingerprint(controlPlane.directories.manifest)
      else { return true }
      try await withConfigurationChange {
        _ = try await publishManifest(
          input.manifest, reason: .externalReload, expectedDigest: input.digest)
      }
      manifestReloadError = nil
      lastManifestAttempt = attempt
    } catch PluginHostError.changeInProgress {
      return true
    } catch AtomicManifestStoreError.changeInProgress {
      return true
    } catch AtomicManifestStoreError.staleDigest {
      return true
    } catch GatewayDatabaseError.configurationChanged {
      return true
    } catch is CancellationError {
      return false
    } catch {
      lastManifestAttempt = attempt
      manifestReloadError = "Configuration reload failed: \(Self.stableDescription(error))"
    }
    return false
  }

  private func stopManifestMonitoring() async {
    let admittedObserver = manifestObserver
    manifestObserver = nil
    admittedObserver?.cancel()
    let observer = manifestReloadObserver
    manifestReloadObserver = nil
    observer?.cancel()
    let monitor = manifestMonitor
    manifestMonitor = nil
    await monitor?.close()
    await observer?.value
    await admittedObserver?.value
    manifestReloadError = nil
  }

  private func withConfigurationChange<Result: Sendable>(
    _ operation: () async throws -> Result
  ) async throws -> Result {
    guard !configurationChangeInProgress, !lifecycleInProgress else {
      throw PluginHostError.changeInProgress
    }
    configurationChangeInProgress = true
    lifecycleInProgress = true
    defer {
      configurationChangeInProgress = false
      let waiters = Array(publicationWaiters.values)
      publicationWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      releaseLifecycle()
    }
    // Finish admissions that already own construction; later new keys wait above.
    let pending = pendingRuntimes.values.map(\.task)
    for task in pending { _ = try? await task.value }
    try Task.checkCancellation()
    return try await operation()
  }

  private func waitForPublication() async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else if !configurationChangeInProgress {
          continuation.resume()
        } else if publicationWaiters.count >= 128 {
          continuation.resume(
            throwing: GatewaySocketError.invalidConfiguration(
              "The gateway has reached its configuration admission capacity."))
        } else {
          publicationWaiters[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelPublicationWaiter(id) }
    }
  }

  private func cancelPublicationWaiter(_ id: UUID) {
    publicationWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }

  private func preparePublication(
    expected: AppControlPlaneService.GatewayInputs, proposed: GatewayDatabase.ConfigurationState,
    storage: PluginInstallationStorage?,
    requiredWorkspace: (id: String, root: WorkspaceRootIdentity)? = nil,
    commit: @Sendable (GatewayConfigurationResolution) throws -> GatewayDatabase.ConfigurationState
  ) async throws -> GatewayDatabase.ConfigurationState {
    try await preparePublication(
      inputs: .init(configuration: expected.configuration, persisted: proposed), storage: storage,
      requiredWorkspace: requiredWorkspace
    ) { resolution, install in
      try self.controlPlane.manifestStore.withCurrentConfiguration(expected.configuration) {
        let persisted = try commit(resolution)
        install(persisted)
        return persisted
      }
    }
  }

  private func preparePublication<Result: Sendable>(
    inputs: AppControlPlaneService.GatewayInputs, storage: PluginInstallationStorage?,
    requiredWorkspace: (id: String, root: WorkspaceRootIdentity)? = nil,
    publish: (GatewayConfigurationResolution, (GatewayDatabase.ConfigurationState) -> Void) throws
      -> Result
  ) async throws -> Result {
    let epoch = listenerEpoch
    let keys = Array(runtimes.keys)
    reapRetiredRuntimes()
    let retiredCount = retiredRuntimes.values.reduce(0) { $0 + $1.count }
    let required = max(1, keys.count)
    guard
      runtimes.count + retiredCount + retiringRuntimes.count + pendingRuntimes.count + required
        <= 128
    else {
      throw GatewaySocketError.invalidConfiguration(
        "The gateway has reached its owned runtime capacity.")
    }
    preparingRuntimeCount = required
    defer { preparingRuntimeCount = 0 }
    var candidates: [RuntimeKey: GatewayRuntimePreparation] = [:]
    var validation: GatewayRuntimePreparation?
    do {
      if keys.isEmpty {
        validation = try await controlPlane.prepareGateway(
          inputs: inputs, caller: .localCLI, profileID: .localAdmin, trustedPrincipalID: nil,
          terminalSessions: terminalSessions, artifactStorage: storage)
      } else {
        for key in keys {
          candidates[key] = try await controlPlane.prepareGateway(
            inputs: inputs, caller: key.caller, profileID: key.profileID,
            trustedPrincipalID: key.principalID, terminalSessions: terminalSessions,
            artifactStorage: storage)
        }
      }
      try Task.checkCancellation()
      guard listenerEpoch == epoch, configurationChangeInProgress else {
        throw GatewaySocketError.notConnected
      }
      var resolution = GatewayConfigurationResolution()
      for candidate in Array(candidates.values) + [validation].compactMap({ $0 }) {
        try candidate.runtime.requirePreparedPublication()
        if let requiredWorkspace {
          try candidate.runtime.requirePreparedWorkspace(
            id: requiredWorkspace.id, root: requiredWorkspace.root)
        }
        try resolution.merge(candidate.resolution)
      }
      let committed = try publish(resolution) { persisted in
        let published = AppControlPlaneService.GatewayInputs(
          configuration: inputs.configuration, persisted: persisted)
        for (key, candidate) in candidates {
          if let previous = runtimes.updateValue((published, candidate.runtime), forKey: key) {
            retiredRuntimes[key, default: [:]][previous.gateway.generationID] = previous.gateway
          }
          candidate.runtime.publishPrepared()
          observe(candidate.runtime, key: key, epoch: epoch)
        }
        for key in candidates.keys { changes(for: key).send() }
        reapRetiredRuntimes()
      }
      await validation?.runtime.shutdown()
      return committed
    } catch {
      for candidate in candidates.values { await candidate.runtime.shutdown() }
      await validation?.runtime.shutdown()
      throw error
    }
  }

  /// Actor reentrancy must not overlap listener binding with asynchronous teardown.
  private func acquireLifecycle() async {
    if lifecycleInProgress {
      await withCheckedContinuation { lifecycleWaiters.append($0) }
    } else {
      lifecycleInProgress = true
    }
  }

  private func releaseLifecycle() {
    if lifecycleWaiters.isEmpty {
      lifecycleInProgress = false
    } else {
      lifecycleWaiters.removeFirst().resume()
    }
  }

  private static func stableDescription(_ error: Error) -> String {
    if let localized = error as? any LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    return String(describing: error)
  }
}
