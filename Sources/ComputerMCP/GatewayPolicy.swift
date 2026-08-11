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

  package var supportsFullShell: Bool {
    self == .chatGPTOperate || self == .localAdmin
  }

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

package enum CapabilityRisk: String, Codable, Sendable {
  case readOnly = "read-only"
  case workspaceWrite = "workspace-write"
  case externalWrite = "external-write"
  case destructive
  case fullShell = "full-shell"
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

  package init(
    id: String,
    risk: CapabilityRisk,
    workspaceRequirement: WorkspaceRequirement = .none,
    localOnly: Bool = false,
    usesNetwork: Bool = false,
    tccServices: [String] = []
  ) {
    self.id = id
    self.risk = risk
    self.workspaceRequirement = workspaceRequirement
    self.localOnly = localOnly
    self.usesNetwork = usesNetwork
    self.tccServices = tccServices
  }
}

package struct ExecutionContext: Codable, Equatable, Sendable {
  package var requestID: String
  package var caller: GatewayCallerKind
  package var profileID: GatewayProfileID
  package var workspaceID: String?
  package var transportTrace: GatewayTransportTrace?

  package init(
    requestID: String = UUID().uuidString,
    caller: GatewayCallerKind,
    profileID: GatewayProfileID,
    workspaceID: String? = nil,
    transportTrace: GatewayTransportTrace? = nil
  ) {
    self.requestID = requestID
    self.caller = caller
    self.profileID = profileID
    self.workspaceID = workspaceID
    self.transportTrace = transportTrace
  }
}

package struct ProfileGrant: Codable, Equatable, Sendable {
  package var id: GatewayProfileID
  package var capabilityIDs: Set<String>
  package var workspaceIDs: Set<String>
  package var allowedCallers: Set<GatewayCallerKind>
  package var fullShellEnabled: Bool

  package init(
    id: GatewayProfileID,
    capabilityIDs: Set<String>,
    workspaceIDs: Set<String> = [],
    allowedCallers: Set<GatewayCallerKind>,
    fullShellEnabled: Bool = false
  ) {
    self.id = id
    self.capabilityIDs = capabilityIDs
    self.workspaceIDs = workspaceIDs
    self.allowedCallers = allowedCallers
    self.fullShellEnabled = fullShellEnabled
  }

  package static let observe = ProfileGrant(
    id: .chatGPTObserve,
    capabilityIDs: [],
    allowedCallers: [.secureTunnel]
  )

  package static let operate = ProfileGrant(
    id: .chatGPTOperate,
    capabilityIDs: [],
    allowedCallers: [.secureTunnel]
  )

  package static let cloudflareObserve = ProfileGrant(
    id: .cloudflareObserve,
    capabilityIDs: [],
    allowedCallers: [.cloudflareTunnel]
  )

  package static let cloudflareOperate = ProfileGrant(
    id: .cloudflareOperate,
    capabilityIDs: [],
    allowedCallers: [.cloudflareTunnel]
  )

  package static let localAdmin = ProfileGrant(
    id: .localAdmin,
    capabilityIDs: ["*"],
    allowedCallers: [.localApp, .localCLI, .localMCP],
    fullShellEnabled: true
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
    let effectiveFullShellEnabled = persisted.fullShellEnabled && id.supportsFullShell
    var effectiveCapabilities = capabilityIDs
    if effectiveFullShellEnabled {
      effectiveCapabilities.formUnion(Self.fullShellCapabilities)
    }
    return ProfileGrant(
      id: id,
      capabilityIDs: effectiveCapabilities,
      workspaceIDs: persisted.workspaceIDs,
      allowedCallers: allowedCallers,
      fullShellEnabled: effectiveFullShellEnabled
    )
  }

  package func validate() throws {
    if id == .localAdmin && allowedCallers.contains(where: \.isRemote) {
      throw GatewayPolicyConfigurationError.localAdminCannotBeRemote
    }
    if id == .chatGPTObserve && fullShellEnabled {
      throw GatewayPolicyConfigurationError.observeCannotEnableFullShell
    }
    if fullShellEnabled && !id.supportsFullShell {
      throw GatewayPolicyConfigurationError.fullShellProfileNotAllowed(id)
    }
  }
}

package enum GatewayPolicyConfigurationError: Error, LocalizedError, Equatable {
  case localAdminCannotBeRemote
  case observeCannotEnableFullShell
  case fullShellProfileNotAllowed(GatewayProfileID)

  package var errorDescription: String? {
    switch self {
    case .localAdminCannotBeRemote:
      return "local-admin must never allow a remote caller."
    case .observeCannotEnableFullShell:
      return "chatgpt-observe cannot enable Full Shell."
    case .fullShellProfileNotAllowed(let profile):
      return "Full Shell is not allowed for profile '\(profile.rawValue)'."
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

    guard grant.capabilityIDs.contains("*") || grant.capabilityIDs.contains(capability.id) else {
      return .deny(
        code: .capabilityDenied,
        message: "The profile does not grant capability '\(capability.id)'."
      )
    }

    if capability.risk == .fullShell && !grant.fullShellEnabled {
      return .deny(
        code: .fullShellDisabled,
        message: "Full Shell must be enabled for the active profile in Computer MCP."
      )
    }

    if capability.workspaceRequirement == .required {
      guard let workspaceID = context.workspaceID else {
        return .deny(
          code: .workspaceRequired,
          message: "An explicit workspace_id is required."
        )
      }
      guard registeredWorkspaceIDs.contains(workspaceID),
        grant.workspaceIDs.contains(workspaceID) || grant.capabilityIDs.contains("*")
      else {
        return .deny(
          code: .workspaceDenied,
          message: "The requested workspace is not registered and granted to this profile."
        )
      }
    } else if let workspaceID = context.workspaceID {
      guard registeredWorkspaceIDs.contains(workspaceID),
        grant.workspaceIDs.contains(workspaceID) || grant.capabilityIDs.contains("*")
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
