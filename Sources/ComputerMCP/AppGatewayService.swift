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
  private struct RuntimeKey: Hashable {
    let principalID: String
    let profileID: GatewayProfileID
    let caller: GatewayCallerKind
  }

  private typealias AdmittedRuntime = (
    inputs: AppControlPlaneService.GatewayInputs, gateway: GatewayRuntime
  )

  package nonisolated let socketConfiguration: GatewaySocketConfiguration

  private let controlPlane: AppControlPlaneService
  private var server: GatewaySocketServer?
  private var state: AppGatewayServiceState = .stopped
  private var profileID: GatewayProfileID?
  private var startedAt: Date?
  private var lastError: String?
  private var pluginChangeInProgress = false
  private var runtimes: [RuntimeKey: AdmittedRuntime] = [:]
  private var pendingRuntimes: [RuntimeKey: Task<AdmittedRuntime, any Error>] = [:]
  private var retiredRuntimes: [GatewayRuntime] = []
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
    guard !pluginChangeInProgress else { throw PluginHostError.changeInProgress }
    guard state != .running && state != .starting else {
      return
    }

    state = .starting
    lastError = nil
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
    } catch {
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
    await acquireLifecycle()
    defer { releaseLifecycle() }
    await stopOwnedRuntime()
    try await startOwnedRuntime(profile: profile)
  }

  package func stop() async {
    await acquireLifecycle()
    defer { releaseLifecycle() }
    await stopOwnedRuntime()
  }

  private func stopOwnedRuntime() async {
    guard state != .stopped && state != .stopping else {
      return
    }
    state = .stopping
    let activeServer = server
    server = nil
    await activeServer?.stop()
    let ownedRuntimes = runtimes.values.map(\.gateway) + retiredRuntimes
    runtimes.removeAll()
    retiredRuntimes.removeAll()
    for runtime in ownedRuntimes { await runtime.shutdown() }
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
    guard state == .running || state == .starting, let profileID,
      !pluginChangeInProgress
    else { throw GatewaySocketError.notConnected }
    let key = RuntimeKey(
      principalID: identity.trustedPrincipalID, profileID: profileID, caller: identity.caller)
    let admitted = try await admittedRuntime(key: key, trace: identity.transportTrace)
    let server = await MCPRuntimeAdapter.makeGatewayServer(
      configuration: admitted.inputs.configuration, registry: admitted.gateway,
      transportTrace: identity.transportTrace)
    // The listener owns executions. A disconnected MCP session only releases its protocol server.
    return GatewaySocketServerSession(server: server)
  }

  private func admittedRuntime(key: RuntimeKey, trace: GatewayTransportTrace) async throws
    -> AdmittedRuntime
  {
    if let pending = pendingRuntimes[key] {
      return try await pending.value
    }
    let current = try await controlPlane.gatewayInputs()
    if let pending = pendingRuntimes[key] { return try await pending.value }
    if let existing = runtimes[key], existing.inputs.configuration == current.configuration,
      existing.inputs.workspaces == current.workspaces, existing.inputs.plugins == current.plugins
    {
      return existing
    }
    guard runtimes.count + retiredRuntimes.count + pendingRuntimes.count < 128 else {
      throw GatewaySocketError.invalidConfiguration(
        "The gateway has reached its owned runtime capacity.")
    }
    let task = Task { [controlPlane] in
      do {
        let admitted = try await controlPlane.makeGatewaySocketRuntime(
          caller: key.caller, profileID: key.profileID, transportTrace: trace,
          trustedPrincipalID: key.principalID)
        if let previous = runtimes.updateValue(admitted, forKey: key) {
          retiredRuntimes.append(previous.gateway)
        }
        pendingRuntimes.removeValue(forKey: key)
        return admitted
      } catch {
        pendingRuntimes.removeValue(forKey: key)
        throw error
      }
    }
    pendingRuntimes[key] = task
    return try await task.value
  }

  package func snapshot() async -> AppGatewayServiceSnapshot {
    AppGatewayServiceSnapshot(
      state: state,
      profileID: profileID,
      socketPath: socketConfiguration.socketURL.path,
      processIdentifier: getpid(),
      startedAt: startedAt,
      connectionCount: await server?.connectionCount() ?? 0,
      lastError: lastError
    )
  }

  /// The listener remains bound, but admission is paused while an idle gateway adopts new registrations.
  package func changePlugins(_ change: PluginHostChange, expectedRevision: Int64) async throws
    -> PluginHostSnapshot
  {
    guard !pluginChangeInProgress, !lifecycleInProgress else {
      throw PluginHostError.changeInProgress
    }
    pluginChangeInProgress = true
    lifecycleInProgress = true
    defer { releaseLifecycle() }
    let activeServer = server
    if let activeServer, !(await activeServer.reserveIdleConfigurationChange()) {
      pluginChangeInProgress = false
      throw PluginHostError.connectedClients
    }
    do {
      let result = try await controlPlane.applyPluginChange(
        change, expectedRevision: expectedRevision)
      await activeServer?.finishConfigurationChange()
      pluginChangeInProgress = false
      return result
    } catch {
      await activeServer?.finishConfigurationChange()
      pluginChangeInProgress = false
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
