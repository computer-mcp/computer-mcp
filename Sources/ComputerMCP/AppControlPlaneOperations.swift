import Foundation

package struct AppControlPlaneRestartResult: Codable, Equatable, Sendable {
  package var restarted: Bool
  package var profileID: GatewayProfileID?
  package var reconnectedTunnelIDs: [String]
  package var deferredTunnelIDs: [String]

  package init(
    restarted: Bool,
    profileID: GatewayProfileID?,
    reconnectedTunnelIDs: [String] = [],
    deferredTunnelIDs: [String] = []
  ) {
    self.restarted = restarted
    self.profileID = profileID
    self.reconnectedTunnelIDs = reconnectedTunnelIDs
    self.deferredTunnelIDs = deferredTunnelIDs
  }

  private enum CodingKeys: String, CodingKey {
    case restarted
    case profileID = "profile_id"
    case reconnectedTunnelIDs = "reconnected_tunnel_ids"
    case deferredTunnelIDs = "deferred_tunnel_ids"
  }
}

package struct OpenAITunnelConfigurationInput: Equatable, Sendable {
  package var id: String
  package var tunnelClientProfile: String
  package var tunnelID: String
  package var gatewayProfile: GatewayProfileID
  package var tunnelClientPath: String?
  package var httpProxy: String?
  package var apiKey: String?

  package init(
    id: String,
    tunnelClientProfile: String,
    tunnelID: String,
    gatewayProfile: GatewayProfileID,
    tunnelClientPath: String? = nil,
    httpProxy: String? = nil,
    apiKey: String? = nil
  ) {
    self.id = id
    self.tunnelClientProfile = tunnelClientProfile
    self.tunnelID = tunnelID
    self.gatewayProfile = gatewayProfile
    self.tunnelClientPath = tunnelClientPath
    self.httpProxy = httpProxy
    self.apiKey = apiKey
  }
}

package struct OpenAITunnelConfigurationResult: Codable, Equatable, Sendable {
  package var configuration: OpenAITunnelConfiguration
  package var reconnected: Bool

  package init(configuration: OpenAITunnelConfiguration, reconnected: Bool) {
    self.configuration = configuration
    self.reconnected = reconnected
  }
}

package struct CloudflareTunnelConfigurationInput: Equatable, Sendable {
  package var id: String
  package var tunnelName: String
  package var publicHostname: String
  package var gatewayProfile: GatewayProfileID
  package var localPort: Int
  package var metricsPort: Int
  package var cloudflaredPath: String?
  package var tunnelToken: String?
  package var regenerateAccessToken: Bool

  package init(
    id: String,
    tunnelName: String,
    publicHostname: String,
    gatewayProfile: GatewayProfileID,
    localPort: Int = 8_765,
    metricsPort: Int = 20_241,
    cloudflaredPath: String? = nil,
    tunnelToken: String? = nil,
    regenerateAccessToken: Bool = false
  ) {
    self.id = id
    self.tunnelName = tunnelName
    self.publicHostname = publicHostname
    self.gatewayProfile = gatewayProfile
    self.localPort = localPort
    self.metricsPort = metricsPort
    self.cloudflaredPath = cloudflaredPath
    self.tunnelToken = tunnelToken
    self.regenerateAccessToken = regenerateAccessToken
  }
}

package enum AppControlPlaneOperationError: Error, LocalizedError, Equatable, Sendable {
  case invalidField(label: String)
  case invalidRemoteProfile(GatewayProfileID)
  case missingCredential(label: String)
  case unknownProvider(String)
  case conflictingDesiredTunnel(
    tunnelID: String,
    requiredProfile: GatewayProfileID,
    requestedProfile: GatewayProfileID
  )
  case conflictingRunningTunnel(
    tunnelID: String,
    requiredProfile: GatewayProfileID,
    requestedProfile: GatewayProfileID
  )

  package var errorDescription: String? {
    switch self {
    case .invalidField(let label):
      "\(label) must not be empty."
    case .invalidRemoteProfile(let profile):
      "Gateway profile '\(profile.rawValue)' cannot expose a remote Tunnel."
    case .missingCredential(let label):
      "\(label) is required when creating the Tunnel configuration."
    case .unknownProvider(let id):
      "Unknown provider '\(id)'."
    case .conflictingDesiredTunnel(let tunnelID, let requiredProfile, let requestedProfile):
      "Tunnel '\(tunnelID)' is configured to stay running with profile "
        + "\(requiredProfile.rawValue). Stop it before activating \(requestedProfile.rawValue)."
    case .conflictingRunningTunnel(let tunnelID, let requiredProfile, let requestedProfile):
      "Tunnel '\(tunnelID)' is already running with profile \(requiredProfile.rawValue). "
        + "Stop it before starting \(requestedProfile.rawValue)."
    }
  }
}

/// Shared App-control use cases used by both the SwiftUI adapter and owner-only CLI socket.
package struct AppControlPlaneOperations: Sendable {
  package let controlPlane: AppControlPlaneService
  package let gatewayService: AppGatewayService

  package init(
    controlPlane: AppControlPlaneService,
    gatewayService: AppGatewayService
  ) {
    self.controlPlane = controlPlane
    self.gatewayService = gatewayService
  }

  package func startGateway(profile: GatewayProfileID? = nil) async throws
    -> AppGatewayServiceSnapshot
  {
    try await controlPlane.setGatewayDesiredRunning(true)
    try await gatewayService.start(profile: profile)
    return await gatewayService.snapshot()
  }

  package func stopGateway() async throws -> AppGatewayServiceSnapshot {
    try await controlPlane.setGatewayDesiredRunning(false)
    await gatewayService.stop()
    return await gatewayService.snapshot()
  }

  package func restartGateway() async throws -> AppControlPlaneRestartResult {
    let snapshot = await gatewayService.snapshot()
    let profile: GatewayProfileID
    if let runningProfile = snapshot.profileID {
      profile = runningProfile
    } else {
      profile = try await controlPlane.activeGatewayProfile()
    }
    try await controlPlane.setGatewayDesiredRunning(true)
    if snapshot.state == .running {
      return try await restartGatewayIfRunning(profile: profile)
    }
    try await gatewayService.start(profile: profile)
    return AppControlPlaneRestartResult(restarted: true, profileID: profile)
  }

  package func registerWorkspace(
    at url: URL,
    displayName: String? = nil
  ) async throws -> RegisteredWorkspace {
    let workspace = try await controlPlane.registerWorkspace(at: url, displayName: displayName)
    _ = try await restartGatewayIfRunning()
    return workspace
  }

  package func removeWorkspace(id: String) async throws {
    try await controlPlane.removeWorkspace(id: id)
    _ = try await restartGatewayIfRunning()
  }

  package func applyWorkspaceDeduplication(
    expectedPlanDigest: String,
    allowMetadataConflicts: Bool
  ) async throws -> WorkspaceDeduplicationResult {
    let result = try await controlPlane.applyWorkspaceDeduplication(
      expectedPlanDigest: expectedPlanDigest,
      allowMetadataConflicts: allowMetadataConflicts
    )
    _ = try await restartGatewayIfRunning()
    return result
  }

  package func setWorkspaceEnabled(
    _ enabled: Bool,
    workspaceID: String,
    profileID: GatewayProfileID
  ) async throws -> ProfileGrant {
    let grant = try await controlPlane.setWorkspaceEnabled(
      enabled,
      workspaceID: workspaceID,
      profileID: profileID
    )
    let gateway = await gatewayService.snapshot()
    if gateway.state == .running, gateway.profileID == profileID {
      _ = try await restartGatewayIfRunning(profile: profileID)
    }
    return grant
  }

  package func activateProfile(_ profile: GatewayProfileID) async throws
    -> AppControlPlaneRestartResult
  {
    let previousProfile = try await controlPlane.activeGatewayProfile()
    try await validateDesiredTunnelProfileAlignment(with: profile)
    try await controlPlane.setActiveGatewayProfile(profile)
    do {
      return try await restartGatewayIfRunning(profile: profile)
    } catch {
      try? await controlPlane.setActiveGatewayProfile(previousProfile)
      if await gatewayService.snapshot().state == .running {
        try? await gatewayService.restart(profile: previousProfile)
      }
      throw error
    }
  }

  package func setFullShellEnabled(
    _ enabled: Bool,
    profileID: GatewayProfileID
  ) async throws -> ProfileGrant {
    let grant = try await controlPlane.setFullShellEnabled(enabled, profileID: profileID)
    let gateway = await gatewayService.snapshot()
    if gateway.state == .running, gateway.profileID == profileID {
      _ = try await restartGatewayIfRunning(profile: profileID)
    }
    return grant
  }

  package func activateManifest(_ manifest: String) async throws -> ConfigurationRevision {
    let previous = try String(
      contentsOf: controlPlane.directories.manifest,
      encoding: .utf8
    )
    let revision = try await controlPlane.activateManifest(manifest)
    do {
      _ = try await restartGatewayIfRunning()
      return revision
    } catch {
      _ = try? await controlPlane.activateManifest(previous)
      _ = try? await restartGatewayIfRunning()
      throw error
    }
  }

  package func rollbackManifest(to revisionID: String) async throws -> ConfigurationRevision {
    let previous = try String(
      contentsOf: controlPlane.directories.manifest,
      encoding: .utf8
    )
    let revision = try await controlPlane.rollbackManifest(to: revisionID)
    do {
      _ = try await restartGatewayIfRunning()
      return revision
    } catch {
      _ = try? await controlPlane.activateManifest(previous)
      _ = try? await restartGatewayIfRunning()
      throw error
    }
  }

  package func refreshProvider(id: String? = nil) async throws -> [ProviderState] {
    let states = try await controlPlane.refreshProviders()
    guard let id else { return states }
    guard let state = states.first(where: { $0.id == id }) else {
      throw AppControlPlaneOperationError.unknownProvider(id)
    }
    return [state]
  }

  package func startOpenAITunnel(id: String) async throws -> OpenAITunnelStatus {
    let profile = try await openAITunnelConfiguration(id: id)
    try await ensureGateway(for: profile)
    return try await controlPlane.startOpenAITunnel(profileID: id)
  }

  package func reconnectOpenAITunnel(id: String) async throws -> OpenAITunnelStatus {
    let profile = try await openAITunnelConfiguration(id: id)
    try await ensureGateway(for: profile)
    return try await controlPlane.reconnectOpenAITunnel(profileID: id)
  }

  package func stopOpenAITunnel(id: String) async throws -> OpenAITunnelStatus {
    try await controlPlane.stopOpenAITunnel(profileID: id)
  }

  package func saveOpenAITunnelConfiguration(
    _ input: OpenAITunnelConfigurationInput
  ) async throws -> OpenAITunnelConfigurationResult {
    let id = try Self.required(input.id, label: "Profile ID")
    let tunnelClientProfile = try Self.required(
      input.tunnelClientProfile,
      label: "Tunnel client profile"
    )
    let tunnelID = try Self.required(input.tunnelID, label: "Tunnel ID")
    guard input.gatewayProfile != .localAdmin else {
      throw AppControlPlaneOperationError.invalidRemoteProfile(input.gatewayProfile)
    }

    let existing = try await controlPlane.openAITunnelConfigurations().first { $0.id == id }
    let secretReference =
      try existing?.apiKeyReference
      ?? SecretReference(account: "tunnel.\(id).openai-api-key")
    let apiKey = Self.optional(input.apiKey)
    if apiKey == nil && existing == nil {
      throw AppControlPlaneOperationError.missingCredential(label: "OpenAI API key")
    }

    let profile = OpenAITunnelConfiguration(
      id: id,
      tunnelClientProfile: tunnelClientProfile,
      tunnelID: tunnelID,
      gatewayProfile: input.gatewayProfile,
      manifestPath: controlPlane.directories.manifest.path,
      gatewayExecutablePath: controlPlane.openAITunnelGatewayExecutablePath,
      gatewaySocketPath: controlPlane.directories.gatewaySocket.path,
      profileDirectory: controlPlane.directories.tunnelClientProfiles.path,
      tunnelClientPath: Self.optional(input.tunnelClientPath),
      httpProxy: Self.optional(input.httpProxy),
      apiKeyReference: secretReference
    )
    try profile.validate()
    let wasDesired = Set(try await controlPlane.desiredOpenAITunnelConfigurationIDs()).contains(id)
    if wasDesired {
      try await validateDesiredTunnelProfileAlignment(
        with: input.gatewayProfile,
        excludingTunnelID: id
      )
    }
    let keyCheckpoint = try await controlPlane.checkpointOpenAITunnelAPIKey(
      reference: secretReference
    )
    if existing != nil {
      _ = try await controlPlane.suspendOpenAITunnel(profileID: id)
    }
    do {
      try await controlPlane.saveOpenAITunnelConfiguration(profile)
      if let apiKey {
        try await controlPlane.setOpenAITunnelAPIKey(apiKey, reference: secretReference)
      }
      if wasDesired {
        try await ensureGateway(for: profile)
        _ = try await controlPlane.reconnectOpenAITunnel(profileID: id)
      }
      return OpenAITunnelConfigurationResult(
        configuration: profile,
        reconnected: wasDesired
      )
    } catch {
      if let existing {
        try? await controlPlane.saveOpenAITunnelConfiguration(existing)
      } else {
        try? await controlPlane.deleteOpenAITunnelConfiguration(id: id)
      }
      try? await controlPlane.restoreOpenAITunnelAPIKey(keyCheckpoint)
      if wasDesired, let existing {
        try? await ensureGateway(for: existing)
        _ = try? await controlPlane.reconnectOpenAITunnel(profileID: id)
      }
      throw error
    }
  }

  package func deleteOpenAITunnelConfiguration(id: String) async throws {
    try await controlPlane.deleteOpenAITunnelConfiguration(id: id)
  }

  package func startCloudflareTunnel(id: String) async throws -> CloudflareTunnelStatus {
    try await controlPlane.startCloudflareTunnel(profileID: id)
  }

  package func stopCloudflareTunnel(id: String) async throws -> CloudflareTunnelStatus {
    try await controlPlane.stopCloudflareTunnel(profileID: id)
  }

  package func saveCloudflareTunnelConfiguration(
    _ input: CloudflareTunnelConfigurationInput
  ) async throws -> CloudflareOnboardingResult {
    let id = try Self.required(input.id, label: "Profile ID")
    let tunnelName = try Self.required(input.tunnelName, label: "Named tunnel")
    let publicHostname = try Self.required(input.publicHostname, label: "Public hostname")
    guard input.gatewayProfile != .localAdmin else {
      throw AppControlPlaneOperationError.invalidRemoteProfile(input.gatewayProfile)
    }
    let existing = try await controlPlane.cloudflareTunnelConfigurations().first { $0.id == id }
    let tunnelTokenReference =
      try existing?.tunnelTokenReference
      ?? SecretReference(account: "cloudflare.\(id).tunnel-token")
    let accessTokenReference =
      try existing?.accessTokenReference
      ?? SecretReference(account: "cloudflare.\(id).access-token")
    let token = Self.optional(input.tunnelToken)
    if existing == nil && token == nil {
      throw AppControlPlaneOperationError.missingCredential(label: "Named-tunnel token")
    }
    return try await controlPlane.saveCloudflareTunnelConfiguration(
      CloudflareTunnelConfiguration(
        id: id,
        tunnelName: tunnelName,
        publicHostname: publicHostname,
        gatewayProfile: input.gatewayProfile,
        localPort: input.localPort,
        metricsPort: input.metricsPort,
        cloudflaredPath: Self.optional(input.cloudflaredPath),
        tunnelTokenReference: tunnelTokenReference,
        accessTokenReference: accessTokenReference
      ),
      tunnelToken: token,
      regenerateAccessToken: input.regenerateAccessToken
    )
  }

  package func deleteCloudflareTunnelConfiguration(id: String) async throws {
    try await controlPlane.deleteCloudflareTunnelConfiguration(id: id)
  }

  package func restartGatewayIfRunning(
    profile requestedProfile: GatewayProfileID? = nil
  ) async throws -> AppControlPlaneRestartResult {
    let snapshot = await gatewayService.snapshot()
    guard snapshot.state == .running else {
      return AppControlPlaneRestartResult(restarted: false, profileID: snapshot.profileID)
    }
    let profile = requestedProfile ?? snapshot.profileID
    if let profile {
      try await validateDesiredTunnelProfileAlignment(with: profile)
    }
    let desiredProfiles = try await desiredOpenAITunnelConfigurations()
    try await gatewayService.restart(profile: profile)
    var reconnected: [String] = []
    var deferred: [String] = []
    for tunnel in desiredProfiles {
      do {
        _ = try await controlPlane.reconnectOpenAITunnel(
          profileID: tunnel.id,
          allowKeychainAuthenticationUI: false
        )
        reconnected.append(tunnel.id)
      } catch {
        deferred.append(tunnel.id)
      }
    }
    return AppControlPlaneRestartResult(
      restarted: true,
      profileID: profile,
      reconnectedTunnelIDs: reconnected.sorted(),
      deferredTunnelIDs: deferred.sorted()
    )
  }

  package func ensureGateway(for profile: OpenAITunnelConfiguration) async throws {
    let runningTunnels = try await controlPlane.snapshot().openAITunnelStatuses.filter {
      $0.profileID != profile.id && $0.state == .running
    }
    if !runningTunnels.isEmpty {
      let profiles = try await controlPlane.openAITunnelConfigurations()
      if let conflicting = runningTunnels.compactMap({ status in
        profiles.first { $0.id == status.profileID }
      }).first(where: { $0.gatewayProfile != profile.gatewayProfile }) {
        throw AppControlPlaneOperationError.conflictingRunningTunnel(
          tunnelID: conflicting.id,
          requiredProfile: conflicting.gatewayProfile,
          requestedProfile: profile.gatewayProfile
        )
      }
    }

    let previousDesiredRunning = try await controlPlane.gatewayDesiredRunning()
    let previousProfile = try await controlPlane.activeGatewayProfile()
    let service = await gatewayService.snapshot()
    try await controlPlane.setGatewayDesiredRunning(true)
    do {
      try await controlPlane.setActiveGatewayProfile(profile.gatewayProfile)
      if service.state == .running {
        if service.profileID != profile.gatewayProfile {
          try await gatewayService.restart(profile: profile.gatewayProfile)
        }
      } else {
        try await gatewayService.start(profile: profile.gatewayProfile)
      }
    } catch {
      try? await controlPlane.setActiveGatewayProfile(previousProfile)
      try? await controlPlane.setGatewayDesiredRunning(previousDesiredRunning)
      if service.state == .running {
        try? await gatewayService.restart(profile: previousProfile)
      } else {
        await gatewayService.stop()
      }
      throw error
    }
  }

  package func validateDesiredTunnelProfileAlignment(
    with profile: GatewayProfileID,
    excludingTunnelID: String? = nil
  ) async throws {
    if let conflicting = try await desiredOpenAITunnelConfigurations().first(where: {
      $0.id != excludingTunnelID && $0.gatewayProfile != profile
    }) {
      throw AppControlPlaneOperationError.conflictingDesiredTunnel(
        tunnelID: conflicting.id,
        requiredProfile: conflicting.gatewayProfile,
        requestedProfile: profile
      )
    }
  }

  package func desiredOpenAITunnelConfigurations() async throws
    -> [OpenAITunnelConfiguration]
  {
    let desiredIDs = Set(try await controlPlane.desiredOpenAITunnelConfigurationIDs())
    return try await controlPlane.openAITunnelConfigurations()
      .filter { desiredIDs.contains($0.id) }
      .sorted { $0.id < $1.id }
  }

  private func openAITunnelConfiguration(id: String) async throws
    -> OpenAITunnelConfiguration
  {
    guard
      let profile = try await controlPlane.openAITunnelConfigurations().first(where: {
        $0.id == id
      })
    else {
      throw AppControlPlaneServiceError.unknownOpenAITunnelConfiguration(id)
    }
    return profile
  }

  private static func required(_ value: String, label: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, !normalized.contains("\0") else {
      throw AppControlPlaneOperationError.invalidField(label: label)
    }
    return normalized
  }

  private static func optional(_ value: String?) -> String? {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return normalized.isEmpty ? nil : normalized
  }
}
