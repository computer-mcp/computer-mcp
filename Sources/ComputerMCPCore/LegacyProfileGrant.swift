import Foundation

/// Source authorization retained solely for deterministic stored-profile migration.
package enum LegacyPermissionMode: String, Codable, CaseIterable, Sendable {
  case readOnly = "read-only"
  case projectOperations = "project-operations"
  case localFullAccess = "local-full-access"

  /// The source configuration granted risk ceilings by built-in profile identity.
  package static func legacy(profileID: GatewayProfileID, fullShellEnabled: Bool) -> Self {
    if profileID == .chatGPTObserve || profileID == .cloudflareObserve { return .readOnly }
    if fullShellEnabled && (profileID == .chatGPTOperate || profileID == .localAdmin) {
      return .localFullAccess
    }
    return .projectOperations
  }
}

package enum LegacyConfirmationPolicy: String, Codable, CaseIterable, Sendable {
  case riskBased = "risk-based"
  case allWrites = "all-writes"
  case never

}

package struct LegacyProfileGrant: Codable, Equatable, Sendable {
  package var id: GatewayProfileID
  package var capabilityIDs: Set<String>
  package var projectIDs: Set<String>
  package var allowedCallers: Set<GatewayCallerKind>
  package var fullShellEnabled: Bool
  package var mcpServerIDs: Set<String>
  package var mode: LegacyPermissionMode
  package var confirmationPolicy: LegacyConfirmationPolicy
  package var authorizationRevision: Int64

  package var supportsFullShell: Bool { mode == .localFullAccess }

  package init(
    id: GatewayProfileID,
    capabilityIDs: Set<String>,
    projectIDs: Set<String> = [],
    allowedCallers: Set<GatewayCallerKind>,
    fullShellEnabled: Bool = false,
    mcpServerIDs: Set<String> = [],
    mode: LegacyPermissionMode = .readOnly,
    confirmationPolicy: LegacyConfirmationPolicy = .riskBased,
    authorizationRevision: Int64 = 1
  ) {
    self.id = id
    self.capabilityIDs = capabilityIDs
    self.projectIDs = projectIDs
    self.allowedCallers = allowedCallers
    self.fullShellEnabled = fullShellEnabled
    self.mcpServerIDs = mcpServerIDs
    self.mode = mode
    self.confirmationPolicy = confirmationPolicy
    self.authorizationRevision = authorizationRevision
  }

  private enum CodingKeys: String, CodingKey {
    case id, capabilityIDs, projectIDs, allowedCallers, fullShellEnabled, mcpServerIDs
    case mode, confirmationPolicy, authorizationRevision
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(GatewayProfileID.self, forKey: .id)
    capabilityIDs = try container.decode(Set<String>.self, forKey: .capabilityIDs)
    projectIDs = try container.decode(Set<String>.self, forKey: .projectIDs)
    allowedCallers = try container.decode(Set<GatewayCallerKind>.self, forKey: .allowedCallers)
    fullShellEnabled = try container.decode(Bool.self, forKey: .fullShellEnabled)
    mcpServerIDs = try container.decodeIfPresent(Set<String>.self, forKey: .mcpServerIDs) ?? []
    mode =
      try container.decodeIfPresent(LegacyPermissionMode.self, forKey: .mode)
      ?? .legacy(profileID: id, fullShellEnabled: fullShellEnabled)
    confirmationPolicy =
      try container.decodeIfPresent(LegacyConfirmationPolicy.self, forKey: .confirmationPolicy)
      ?? .riskBased
    authorizationRevision =
      try container.decodeIfPresent(Int64.self, forKey: .authorizationRevision) ?? 0
  }

  package static let fullShellCapabilities: Set<String> = [
    "shell.run",
    "shell.spawn",
    "shell.list",
    "shell.read",
    "shell.write",
    "shell.cancel",
    "cli.exec",
    "process.spawn",
    "process.write",
  ]

  package func applyingPersistedRuntimeState(_ persisted: LegacyProfileGrant) -> LegacyProfileGrant
  {
    guard persisted.id == id else {
      return self
    }
    if persisted.authorizationRevision > 0 { return persisted }
    let effectiveFullShellEnabled = persisted.fullShellEnabled && persisted.supportsFullShell
    var effectiveCapabilities = capabilityIDs
    if effectiveFullShellEnabled {
      effectiveCapabilities.formUnion(Self.fullShellCapabilities)
    }
    return LegacyProfileGrant(
      id: id,
      capabilityIDs: effectiveCapabilities,
      projectIDs: persisted.projectIDs,
      allowedCallers: allowedCallers,
      fullShellEnabled: effectiveFullShellEnabled,
      mcpServerIDs: mcpServerIDs,
      mode: persisted.mode,
      confirmationPolicy: persisted.confirmationPolicy,
      authorizationRevision: 0
    )
  }

  package func permitsRisk(_ risk: CapabilityRisk) -> Bool {
    switch mode {
    case .readOnly: risk == .readOnly
    case .projectOperations: risk != .fullShell
    case .localFullAccess: true
    }
  }

  package func grants(_ capability: CapabilityDescriptor) -> Bool {
    if capabilityIDs.contains("*") { return true }
    if let reference = capability.mcpReference {
      return grantsMCP(
        reference, capabilityIDs: [capability.id] + (capability.equivalentCapabilityIDs ?? []))
    }
    if capabilityIDs.contains(capability.id) { return true }
    return !mcpServerIDs.isEmpty && Self.mcpSurfaceCapabilities.contains(capability.id)
  }

  /// Registration grant matching does not need a dispatch descriptor or discovery.
  package func grantsMCP(_ reference: MCPToolReference, capabilityIDs names: [String]) -> Bool {
    if capabilityIDs.contains("*") || mcpServerIDs.contains(reference.serverID)
      || capabilityIDs.contains("mcp.tools.call")
    {
      return true
    }
    return !capabilityIDs.isDisjoint(with: Set(names).subtracting(Self.mcpSurfaceCapabilities))
  }

  package static let mcpSurfaceCapabilities: Set<String> = [
    "mcp.servers.list", "mcp.servers.status", "mcp.tools.list", "mcp.tools.describe",
    "mcp.tools.find", "mcp.tools.call", "mcp.resources.list", "mcp.resources.templates.list",
    "mcp.resources.read", "mcp.prompts.list", "mcp.prompts.get", "mcp.events.read",
    "mcp.requests.list", "mcp.requests.read", "mcp.requests.cancel", "mcp.connections.close",
  ]
}
