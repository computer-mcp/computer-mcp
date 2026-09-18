import Foundation

package struct GatewayProfileID: RawRepresentable, Codable, Hashable, Sendable {
  package let rawValue: String

  package init?(rawValue: String) {
    guard Self.isValid(rawValue) else {
      return nil
    }
    self.rawValue = rawValue
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let profile = Self(rawValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription:
          "Profile IDs must contain 1...128 ASCII letters, digits, underscores, or hyphens."
      )
    }
    self = profile
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  package static let chatGPTObserve = Self(rawValue: "chatgpt-observe")!
  package static let chatGPTOperate = Self(rawValue: "chatgpt-operate")!
  package static let cloudflareObserve = Self(rawValue: "cloudflare-observe")!
  package static let cloudflareOperate = Self(rawValue: "cloudflare-operate")!
  package static let localAdmin = Self(rawValue: "local-admin")!

  package static let builtIns: [Self] = [
    .chatGPTObserve,
    .chatGPTOperate,
    .cloudflareObserve,
    .cloudflareOperate,
    .localAdmin,
  ]

  private static func isValid(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else {
      return false
    }
    return value.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
        || $0 == 45 || $0 == 95
    }
  }
}

package enum GatewayCallerKind: String, Codable, Hashable, Sendable {
  case secureTunnel = "secure-tunnel"
  case cloudflareTunnel = "cloudflare-tunnel"
  case localApp = "local-app"
  case localCLI = "local-cli"
  case localMCP = "local-mcp"

  package var isRemote: Bool {
    self == .secureTunnel || self == .cloudflareTunnel
  }
}

package struct GatewayTransportTrace: Codable, Equatable, Sendable {
  package var transport: String
  package var socketConnectionID: String?
  package var tunnelInstanceID: String?
  package var tunnelProfileID: String?

  package init(
    transport: String,
    socketConnectionID: String? = nil,
    tunnelInstanceID: String? = nil,
    tunnelProfileID: String? = nil
  ) {
    self.transport = transport
    self.socketConnectionID = socketConnectionID
    self.tunnelInstanceID = tunnelInstanceID
    self.tunnelProfileID = tunnelProfileID
  }
}

package enum CapabilityRisk: String, Codable, Equatable, Sendable {
  case readOnly = "read-only"
  case workspaceWrite = "workspace-write"
  case externalWrite = "external-write"
  case destructive
  case fullShell = "full-shell"
}

package enum GatewayPermissionMode: String, Codable, CaseIterable, Sendable {
  case readOnly = "read-only"
  case workspaceOperations = "workspace-operations"
  case localFullAccess = "local-full-access"

  /// The source configuration granted risk ceilings by built-in profile identity.
  package static func legacy(profileID: GatewayProfileID, fullShellEnabled: Bool) -> Self {
    if profileID == .chatGPTObserve || profileID == .cloudflareObserve { return .readOnly }
    if fullShellEnabled && (profileID == .chatGPTOperate || profileID == .localAdmin) {
      return .localFullAccess
    }
    return .workspaceOperations
  }
}

package enum GatewayConfirmationPolicy: String, Codable, CaseIterable, Sendable {
  case riskBased = "risk-based"
  case allWrites = "all-writes"
  case never

  package func requiresConfirmation(for risk: CapabilityRisk) -> Bool {
    switch self {
    case .riskBased:
      risk == .externalWrite || risk == .destructive || risk == .fullShell
    case .allWrites:
      risk != .readOnly
    case .never:
      false
    }
  }
}

package enum WorkspaceRequirement: String, Codable, Sendable {
  case none
  case optional
  case required
}

package struct CapabilityDescriptor: Codable, Equatable, Sendable {
  package var id: String
  package var risk: CapabilityRisk
  package var workspaceRequirement: WorkspaceRequirement
  package var localOnly: Bool
  package var usesNetwork: Bool
  package var tccServices: [String]
  package var mcpReference: MCPToolReference?
  package var equivalentCapabilityIDs: [String]?

  package init(
    id: String,
    risk: CapabilityRisk,
    workspaceRequirement: WorkspaceRequirement = .none,
    localOnly: Bool = false,
    usesNetwork: Bool = false,
    tccServices: [String] = [],
    mcpReference: MCPToolReference? = nil,
    equivalentCapabilityIDs: [String]? = nil
  ) {
    self.id = id
    self.risk = risk
    self.workspaceRequirement = workspaceRequirement
    self.localOnly = localOnly
    self.usesNetwork = usesNetwork
    self.tccServices = tccServices
    self.mcpReference = mcpReference
    self.equivalentCapabilityIDs = equivalentCapabilityIDs
  }
}

package struct ExecutionContext: Codable, Equatable, Sendable {
  package var requestID: String
  package var caller: GatewayCallerKind
  package var profileID: GatewayProfileID
  package var workspaceID: String?
  package var transportTrace: GatewayTransportTrace?
  /// Established by the host's authenticated admission path, never by tool arguments.
  package var trustedPrincipalID: String?

  package var principalID: String {
    if let trustedPrincipalID, !trustedPrincipalID.isEmpty { return trustedPrincipalID }
    return "\(caller.rawValue):\(profileID.rawValue)"
  }

  package init(
    requestID: String = UUID().uuidString,
    caller: GatewayCallerKind,
    profileID: GatewayProfileID,
    workspaceID: String? = nil,
    transportTrace: GatewayTransportTrace? = nil,
    trustedPrincipalID: String? = nil
  ) {
    self.requestID = requestID
    self.caller = caller
    self.profileID = profileID
    self.workspaceID = workspaceID
    self.transportTrace = transportTrace
    self.trustedPrincipalID = trustedPrincipalID
  }
}

package struct ProfileGrant: Codable, Equatable, Sendable {
  package var id: GatewayProfileID
  package var capabilityIDs: Set<String>
  package var workspaceIDs: Set<String>
  package var allowedCallers: Set<GatewayCallerKind>
  package var fullShellEnabled: Bool
  package var mcpServerIDs: Set<String>
  package var mode: GatewayPermissionMode
  package var confirmationPolicy: GatewayConfirmationPolicy
  package var authorizationRevision: Int64

  package var supportsFullShell: Bool { mode == .localFullAccess }

  package init(
    id: GatewayProfileID,
    capabilityIDs: Set<String>,
    workspaceIDs: Set<String> = [],
    allowedCallers: Set<GatewayCallerKind>,
    fullShellEnabled: Bool = false,
    mcpServerIDs: Set<String> = [],
    mode: GatewayPermissionMode = .readOnly,
    confirmationPolicy: GatewayConfirmationPolicy = .riskBased,
    authorizationRevision: Int64 = 1
  ) {
    self.id = id
    self.capabilityIDs = capabilityIDs
    self.workspaceIDs = workspaceIDs
    self.allowedCallers = allowedCallers
    self.fullShellEnabled = fullShellEnabled
    self.mcpServerIDs = mcpServerIDs
    self.mode = mode
    self.confirmationPolicy = confirmationPolicy
    self.authorizationRevision = authorizationRevision
  }

  private enum CodingKeys: String, CodingKey {
    case id, capabilityIDs, workspaceIDs, allowedCallers, fullShellEnabled, mcpServerIDs
    case mode, confirmationPolicy, authorizationRevision
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(GatewayProfileID.self, forKey: .id)
    capabilityIDs = try container.decode(Set<String>.self, forKey: .capabilityIDs)
    workspaceIDs = try container.decode(Set<String>.self, forKey: .workspaceIDs)
    allowedCallers = try container.decode(Set<GatewayCallerKind>.self, forKey: .allowedCallers)
    fullShellEnabled = try container.decode(Bool.self, forKey: .fullShellEnabled)
    mcpServerIDs = try container.decodeIfPresent(Set<String>.self, forKey: .mcpServerIDs) ?? []
    mode =
      try container.decodeIfPresent(GatewayPermissionMode.self, forKey: .mode)
      ?? .legacy(profileID: id, fullShellEnabled: fullShellEnabled)
    confirmationPolicy =
      try container.decodeIfPresent(GatewayConfirmationPolicy.self, forKey: .confirmationPolicy)
      ?? .riskBased
    authorizationRevision =
      try container.decodeIfPresent(Int64.self, forKey: .authorizationRevision) ?? 0
  }

  package static let observe = ProfileGrant(
    id: .chatGPTObserve,
    capabilityIDs: [],
    allowedCallers: [.secureTunnel]
  )

  package static let operate = ProfileGrant(
    id: .chatGPTOperate,
    capabilityIDs: [],
    allowedCallers: [.secureTunnel],
    mode: .workspaceOperations
  )

  package static let cloudflareObserve = ProfileGrant(
    id: .cloudflareObserve,
    capabilityIDs: [],
    allowedCallers: [.cloudflareTunnel]
  )

  package static let cloudflareOperate = ProfileGrant(
    id: .cloudflareOperate,
    capabilityIDs: [],
    allowedCallers: [.cloudflareTunnel],
    mode: .workspaceOperations
  )

  package static let localAdmin = ProfileGrant(
    id: .localAdmin,
    capabilityIDs: ["*"],
    workspaceIDs: ["*"],
    allowedCallers: [.localApp, .localCLI, .localMCP],
    fullShellEnabled: true,
    mode: .localFullAccess
  )

  package static let fullShellCapabilities: Set<String> = [
    "shell.run",
    "shell.spawn",
    "shell.list",
    "shell.read",
    "shell.write",
    "shell.cancel",
    "cli.exec",
    "process.spawn",
  ]

  package func applyingPersistedRuntimeState(_ persisted: ProfileGrant) -> ProfileGrant {
    guard persisted.id == id else {
      return self
    }
    if persisted.authorizationRevision > 0 { return persisted }
    let effectiveFullShellEnabled = persisted.fullShellEnabled && persisted.supportsFullShell
    var effectiveCapabilities = capabilityIDs
    if effectiveFullShellEnabled {
      effectiveCapabilities.formUnion(Self.fullShellCapabilities)
    }
    return ProfileGrant(
      id: id,
      capabilityIDs: effectiveCapabilities,
      workspaceIDs: persisted.workspaceIDs,
      allowedCallers: allowedCallers,
      fullShellEnabled: effectiveFullShellEnabled,
      mcpServerIDs: mcpServerIDs,
      mode: persisted.mode,
      confirmationPolicy: persisted.confirmationPolicy,
      authorizationRevision: 0
    )
  }

  package func validate() throws {
    if id == .localAdmin && allowedCallers.contains(where: \.isRemote) {
      throw GatewayPolicyConfigurationError.localAdminCannotBeRemote
    }
    if fullShellEnabled && !supportsFullShell {
      throw GatewayPolicyConfigurationError.fullShellRequiresFullAccess
    }
  }

  package func permitsRisk(_ risk: CapabilityRisk) -> Bool {
    switch mode {
    case .readOnly: risk == .readOnly
    case .workspaceOperations: risk != .fullShell
    case .localFullAccess: true
    }
  }

  package func grants(_ capability: CapabilityDescriptor) -> Bool {
    if capabilityIDs.contains("*") { return true }
    if let reference = capability.mcpReference {
      // The generic call capability explicitly grants the host-selected tools across registrations.
      if mcpServerIDs.contains(reference.serverID) || capabilityIDs.contains("mcp.tools.call") {
        return true
      }
      let names = Set([capability.id] + (capability.equivalentCapabilityIDs ?? []))
        .subtracting(Self.mcpSurfaceCapabilities)
      return !capabilityIDs.isDisjoint(with: names)
    }
    if capabilityIDs.contains(capability.id) { return true }
    return !mcpServerIDs.isEmpty && Self.mcpSurfaceCapabilities.contains(capability.id)
  }

  package static let mcpSurfaceCapabilities: Set<String> = [
    "mcp.servers.list", "mcp.servers.status", "mcp.tools.list", "mcp.tools.describe",
    "mcp.tools.find", "mcp.tools.call", "mcp.resources.list", "mcp.resources.templates.list",
    "mcp.resources.read", "mcp.prompts.list", "mcp.prompts.get", "mcp.events.read",
    "mcp.requests.list", "mcp.requests.read", "mcp.requests.cancel",
  ]
}

package enum GatewayPolicyConfigurationError: Error, LocalizedError, Equatable {
  case localAdminCannotBeRemote
  case fullShellRequiresFullAccess

  package var errorDescription: String? {
    switch self {
    case .localAdminCannotBeRemote:
      return "local-admin must never allow a remote caller."
    case .fullShellRequiresFullAccess:
      return
        "Arbitrary execution requires local-full-access mode and separate Full Shell permission."
    }
  }
}

package enum PolicyDenialCode: String, Codable, Sendable {
  case profileMismatch = "policy.profile_mismatch"
  case callerDenied = "policy.caller_denied"
  case localAdminRemote = "policy.local_admin_remote"
  case localOnly = "policy.local_only"
  case capabilityDenied = "policy.capability_denied"
  case workspaceRequired = "policy.workspace_required"
  case workspaceDenied = "policy.workspace_denied"
  case fullShellDisabled = "policy.full_shell_disabled"
  case readOnlyProfile = "policy.read_only_profile"
}

package enum PolicyDecision: Equatable, Sendable {
  case allow
  case deny(code: PolicyDenialCode, message: String)

  package var isAllowed: Bool {
    self == .allow
  }
}

package struct GatewayPolicyEvaluator: Sendable {
  package init() {}

  package func evaluate(
    capability: CapabilityDescriptor,
    context: ExecutionContext,
    grant: ProfileGrant,
    registeredWorkspaceIDs: Set<String>
  ) -> PolicyDecision {
    guard context.profileID == grant.id else {
      return .deny(
        code: .profileMismatch,
        message: "The execution context profile does not match the configured grant."
      )
    }

    if context.caller.isRemote && grant.id == .localAdmin {
      return .deny(
        code: .localAdminRemote,
        message: "local-admin is available only to local callers."
      )
    }

    if !grant.allowedCallers.contains(context.caller) {
      return .deny(
        code: .callerDenied,
        message: "This profile does not allow caller '\(context.caller.rawValue)'."
      )
    }

    if context.caller.isRemote && capability.localOnly {
      return .deny(
        code: .localOnly,
        message: "The requested capability is local-only."
      )
    }

    guard grant.grants(capability) else {
      return .deny(
        code: .capabilityDenied,
        message: "The profile does not grant capability '\(capability.id)'."
      )
    }

    if capability.risk == .fullShell && (!grant.supportsFullShell || !grant.fullShellEnabled) {
      return .deny(
        code: .fullShellDisabled,
        message:
          "Arbitrary execution requires local-full-access mode and separate Full Shell permission."
      )
    }

    guard grant.permitsRisk(capability.risk) else {
      return .deny(
        code: .readOnlyProfile,
        message: "Read-only mode requires a host-classified read-only capability.")
    }

    if capability.workspaceRequirement == .required {
      guard let workspaceID = context.workspaceID else {
        return .deny(
          code: .workspaceRequired,
          message: "An explicit workspace_id is required."
        )
      }
      guard registeredWorkspaceIDs.contains(workspaceID),
        grant.workspaceIDs.contains(workspaceID) || grant.workspaceIDs.contains("*")
      else {
        return .deny(
          code: .workspaceDenied,
          message: "The requested workspace is not registered and granted to this profile."
        )
      }
    } else if let workspaceID = context.workspaceID {
      guard registeredWorkspaceIDs.contains(workspaceID),
        grant.workspaceIDs.contains(workspaceID) || grant.workspaceIDs.contains("*")
      else {
        return .deny(
          code: .workspaceDenied,
          message: "The requested workspace is not registered and granted to this profile."
        )
      }
    }

    return .allow
  }
}
