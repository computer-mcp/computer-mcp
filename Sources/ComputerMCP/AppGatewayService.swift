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
  package nonisolated let socketConfiguration: GatewaySocketConfiguration

  private let controlPlane: AppControlPlaneService
  private var server: GatewaySocketServer?
  private var state: AppGatewayServiceState = .stopped
  private var profileID: GatewayProfileID?
  private var startedAt: Date?
  private var lastError: String?

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

      try await controlPlane.start()
      if let credentialFile = socketConfiguration.tunnelCredentialFile {
        try GatewaySocketCredentialStore.create(at: credentialFile)
      }
      let controlPlane = controlPlane
      let server = GatewaySocketServer(
        configuration: socketConfiguration,
        responseObserver: { data, identity in
          try? await controlPlane.correlateMCPResponse(data, identity: identity)
        },
        serverFactory: { identity in
          try await controlPlane.makeGatewayServer(
            caller: identity.caller,
            profileID: selectedProfile,
            transportTrace: identity.transportTrace
          )
        }
      )
      try await server.start()
      self.server = server
      self.profileID = selectedProfile
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

  package func restart(profile: GatewayProfileID? = nil) async throws {
    await stop()
    try await start(profile: profile)
  }

  package func stop() async {
    guard state != .stopped && state != .stopping else {
      return
    }
    state = .stopping
    let activeServer = server
    server = nil
    await activeServer?.stop()
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

  private static func stableDescription(_ error: Error) -> String {
    if let localized = error as? any LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    return String(describing: error)
  }
}
