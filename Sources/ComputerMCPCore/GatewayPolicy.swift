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
  case projectWrite = "project-write"
  case externalWrite = "external-write"
  case destructive
  case fullShell = "full-shell"
}

package enum ProjectRequirement: String, Codable, Sendable {
  case none
  case optional
  case required
}

/// Trusted provider implementation, never conveyed by a serialized descriptor.
package enum HostOperation: Equatable, Sendable {
  case fileMutation, git
}

package struct CapabilityDescriptor: Codable, Equatable, Sendable {
  package var id: String
  package var risk: CapabilityRisk
  package var requirement: ToolRequirement
  package var projectRequirement: ProjectRequirement
  package var localOnly: Bool
  package var usesNetwork: Bool
  package var tccServices: [String]
  package var mcpReference: MCPToolReference?
  package var equivalentCapabilityIDs: [String]?
  package var hostServiceAction: MCPHostServiceAction?
  package var hostOperation: HostOperation? = nil

  private enum CodingKeys: String, CodingKey {
    case id, risk, requirement, projectRequirement, localOnly, usesNetwork, tccServices
    case mcpReference, equivalentCapabilityIDs, hostServiceAction
  }

  package init(
    id: String,
    risk: CapabilityRisk,
    requirement: ToolRequirement,
    projectRequirement: ProjectRequirement = .none,
    localOnly: Bool = false,
    usesNetwork: Bool = false,
    tccServices: [String] = [],
    mcpReference: MCPToolReference? = nil,
    equivalentCapabilityIDs: [String]? = nil,
    hostServiceAction: MCPHostServiceAction? = nil,
    hostOperation: HostOperation? = nil
  ) {
    self.id = id
    self.risk = risk
    self.requirement = requirement
    self.projectRequirement = projectRequirement
    self.localOnly = localOnly
    self.usesNetwork = usesNetwork
    self.tccServices = tccServices
    self.mcpReference = mcpReference
    self.equivalentCapabilityIDs = equivalentCapabilityIDs
    self.hostServiceAction = hostServiceAction
    self.hostOperation = hostOperation
  }
}

package struct ExecutionContext: Codable, Sendable {
  package var requestID: String
  package var caller: GatewayCallerKind
  package var profileID: GatewayProfileID
  package var projectID: String?
  package var transportTrace: GatewayTransportTrace?
  /// Established by the host's authenticated admission path, never by tool arguments.
  package var trustedPrincipalID: String?
  /// In-process admission evidence, set only by the host's admission path. Encoding a
  /// context never conveys session authority.
  package var controlSession: (any GatewaySessionAuthority)? = nil

  private enum CodingKeys: String, CodingKey {
    case requestID, caller, profileID, projectID, transportTrace, trustedPrincipalID
  }

  package var principalID: String {
    if let trustedPrincipalID, !trustedPrincipalID.isEmpty { return trustedPrincipalID }
    return "\(caller.rawValue):\(profileID.rawValue)"
  }

  package init(
    requestID: String = UUID().uuidString,
    caller: GatewayCallerKind,
    profileID: GatewayProfileID,
    projectID: String? = nil,
    transportTrace: GatewayTransportTrace? = nil,
    trustedPrincipalID: String? = nil
  ) {
    self.requestID = requestID
    self.caller = caller
    self.profileID = profileID
    self.projectID = projectID
    self.transportTrace = transportTrace
    self.trustedPrincipalID = trustedPrincipalID
  }
}

extension ExecutionContext: Equatable {
  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.requestID == rhs.requestID && lhs.caller == rhs.caller
      && lhs.profileID == rhs.profileID && lhs.projectID == rhs.projectID
      && lhs.transportTrace == rhs.transportTrace
      && lhs.trustedPrincipalID == rhs.trustedPrincipalID
      && lhs.controlSession === rhs.controlSession
  }
}

package enum GatewayPolicyConfigurationError: Error, LocalizedError, Equatable {
  case localAdminCannotBeRemote

  package var errorDescription: String? {
    switch self {
    case .localAdminCannotBeRemote:
      return "local-admin must never allow a remote caller."

    }
  }
}

package enum PolicyDenialCode: String, Codable, Sendable {
  case profileMismatch = "policy.profile_mismatch"
  case callerDenied = "policy.caller_denied"
  case localAdminRemote = "policy.local_admin_remote"
  case localOnly = "policy.local_only"
  case projectRequired = "policy.project_required"
  case projectDenied = "policy.project_denied"
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
    registeredProjectIDs: Set<String>
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

    if capability.projectRequirement == .required {
      guard let projectID = context.projectID else {
        return .deny(
          code: .projectRequired,
          message: "An explicit project_id is required."
        )
      }
      guard registeredProjectIDs.contains(projectID)
      else {
        return .deny(
          code: .projectDenied,
          message: "The requested project is not registered."
        )
      }
    } else if let projectID = context.projectID {
      guard registeredProjectIDs.contains(projectID)
      else {
        return .deny(
          code: .projectDenied,
          message: "The requested project is not registered."
        )
      }
    }

    return .allow
  }
}
