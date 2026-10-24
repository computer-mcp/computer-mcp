import Foundation

/// Complete caller-supplied conditions of one invocation. Equality includes path
/// operations (read/write cover subtrees; directory traversal does not), network
/// destinations, execution mode, and the source project that supplies settings.
/// Collections are sets in stable order, including after decoding. Paths must
/// already be canonical real paths; host names share the network rule normalizer.
package struct InvocationRequirements: Hashable, Sendable, Codable {
  package let actions: [PermissionAction]
  package let paths: [PathRequirement]
  package let networks: [NetworkRequirement]
  package let mode: ExecutionMode
  package let sandboxProjectID: String?
  let registration: ProjectRegistrationRequest?

  package init(
    actions: [PermissionAction] = [], paths: [PathRequirement] = [],
    networks: [NetworkRequirement] = [],
    mode: ExecutionMode = .sandbox, sandboxProjectID: String? = nil
  ) {
    self.actions = Self.canonical(
      actions.map {
        PermissionAction(
          requirement: $0.requirement, scope: $0.scope,
          pluginPurpose: $0.pluginPurpose, requiresFullAccess: $0.requiresFullAccess,
          pathOperation: $0.pathOperation)
      }, by: \.sortKey)
    self.paths = Self.canonical(
      paths, by: { [$0.path.string, $0.operation.sortKey] + Self.optionalKey($0.pluginPurpose) })
    self.networks = Self.canonical(
      networks.map {
        NetworkRequirement(
          host: $0.host, projectID: $0.projectID,
          isLocalNetwork: $0.isLocalNetwork, pluginPurpose: $0.pluginPurpose)
      },
      by: {
        [$0.projectID, $0.host, String($0.isLocalNetwork)] + Self.optionalKey($0.pluginPurpose)
      })
    self.mode = mode
    self.sandboxProjectID = sandboxProjectID
    self.registration = nil
  }

  init(registration: ProjectRegistrationRequest) {
    self.actions = []
    self.paths = []
    self.networks = []
    self.mode = .sandbox
    self.sandboxProjectID = registration.projectID
    self.registration = registration
  }

  private enum CodingKeys: String, CodingKey {
    case actions, paths, networks, mode, sandboxProjectID, registration
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let registration = try container.decodeIfPresent(
      ProjectRegistrationRequest.self, forKey: .registration)
    {
      self.init(registration: registration)
    } else {
      self.init(
        actions: try container.decode([PermissionAction].self, forKey: .actions),
        paths: try container.decode([PathRequirement].self, forKey: .paths),
        networks: try container.decode([NetworkRequirement].self, forKey: .networks),
        mode: try container.decode(ExecutionMode.self, forKey: .mode),
        sandboxProjectID: try container.decodeIfPresent(String.self, forKey: .sandboxProjectID))
    }
  }

  private static func canonical<Value: Hashable>(_ values: [Value], by key: (Value) -> [String])
    -> [Value]
  {
    Set(values).sorted { key($0).lexicographicallyPrecedes(key($1)) }
  }

  static func optionalKey(_ value: String?) -> [String] {
    value.map { ["1", $0] } ?? ["0"]
  }

  var permissionActions: [PermissionAction] {
    actions + (mode.isSandbox ? networks.filter(\.isLocalNetwork).map(\.localAction) : [])
  }

  func settingsProjectID(for action: PermissionAction) -> String? {
    if case .host(_, let projectID) = action.scope { return projectID }
    if let sandboxProjectID { return sandboxProjectID }
    if case .project(let projectID) = action.requirement.permission { return projectID }
    return nil
  }
}

/// A canonical path operation. Read and write cover a subtree with classification
/// boundaries retained in the authorization evidence. Opening or listing covers
/// only the named directory.
package struct PathRequirement: Hashable, Sendable, Codable {
  package let path: CanonicalPath
  package let operation: PathOperation
  package let pluginPurpose: String?

  package init(path: CanonicalPath, operation: PathOperation, pluginPurpose: String? = nil) {
    self.path = path
    self.operation = operation
    self.pluginPurpose = pluginPurpose
  }
}

/// An outbound connection through the sandbox's egress policy. Host admission
/// and Local network permission are independent requirements. The caller classifies
/// the resolved destination, including tunnel routes, before constructing this value.
package struct NetworkRequirement: Hashable, Sendable, Codable {
  package let host: String
  package let projectID: String
  package let isLocalNetwork: Bool
  package let pluginPurpose: String?

  package init(
    host: String, projectID: String, isLocalNetwork: Bool, pluginPurpose: String? = nil
  ) {
    self.host = NetworkHost.canonical(host)
    self.projectID = projectID
    self.isLocalNetwork = isLocalNetwork
    self.pluginPurpose = pluginPurpose
  }

  var localAction: PermissionAction {
    PermissionAction(
      requirement: try! PermissionRequirement(.localNetwork, .access),
      scope: .host(host, project: projectID), pluginPurpose: pluginPurpose)
  }

  func content(principal: Principal) -> NetworkRequestContent {
    NetworkRequestContent(
      principal: principal, host: host, projectID: projectID, pluginPurpose: pluginPurpose)
  }
}

struct InvocationResolution {
  var denial: DenialReason?
  var missing: [RequestContent] = []
  var basis: Set<AuthorizationBasis> = []

  var isAllowed: Bool { denial == nil && missing.isEmpty }
}

/// The admission predicate for both new calls and saved requests/authorizations.
/// Evidence lifetime checks additionally pin grants and path classifications; they
/// cannot substitute for evaluating every condition in this value.
enum InvocationEvaluation {
  static func evaluate(
    _ requirements: InvocationRequirements, principal: Principal, permissions: Permissions,
    limits: ManagedLimits, trustedHosts: Set<HostRule>,
    settings: (String?) -> SandboxSettings,
    pathResolver: (CanonicalPath?) -> (any PathPermissionResolving)?,
    oneTimeRequests: [PermissionRequest] = [], recordedBasis: Set<AuthorizationBasis> = []
  ) -> InvocationResolution {
    let hostNames = Set(trustedHosts.map(\.host))
    let mode = requirements.mode
    if let denial = limits.modeDenial(mode) { return InvocationResolution(denial: denial) }
    if !limits.unreadableSources.isEmpty {
      return InvocationResolution(denial: .managedLimit(limits.unreadableSources))
    }
    var result = InvocationResolution(basis: [.mode(mode)])
    for (source, availability) in limits.sources {
      if case .available(let policy) = availability {
        result.basis.insert(.managed(source: source, identity: policy.identity))
      }
    }
    if let registration = requirements.registration {
      guard let resolver = pathResolver(nil) else {
        return InvocationResolution(denial: .pathResolutionRequired)
      }
      result.denial = resolver.registrationDenial(
        for: registration, permissions: permissions, limits: limits,
        sandbox: settings(registration.projectID))
      return result
    }
    for path in requirements.paths {
      guard let resolver = pathResolver(path.path) else {
        result.denial = .pathResolutionRequired
        continue
      }
      let projectID: String?
      if let source = requirements.sandboxProjectID {
        projectID = source
      } else if case .project(let source) = resolver.requirement(
        at: path.path, operation: path.operation)?.permission
      {
        projectID = source
      } else {
        projectID = nil
      }
      let resolution = resolver.resolve(
        path.path, operation: path.operation, principal: principal, permissions: permissions,
        mode: mode, limits: limits, sandbox: settings(projectID), sandboxProjectID: projectID,
        oneTimeRequests: oneTimeRequests, pluginPurpose: path.pluginPurpose,
        recordedBasis: recordedBasis)
      switch resolution {
      case .allowed(let basis): result.basis.formUnion(basis)
      case .denied(let reason): result.denial = result.denial ?? reason
      case .request(let content):
        if !result.missing.contains(.permission(content)) {
          result.missing.append(.permission(content))
        }
        var prospective = permissions
        try! prospective.set(
          .granted(content.requirement.value), for: content.requirement.permission)
        if case .allowed(let basis) = resolver.resolve(
          path.path, operation: path.operation, principal: principal, permissions: prospective,
          mode: mode, limits: limits, sandbox: settings(projectID), sandboxProjectID: projectID,
          oneTimeRequests: oneTimeRequests, pluginPurpose: path.pluginPurpose,
          recordedBasis: recordedBasis)
        {
          result.basis.formUnion(
            basis.filter {
              if case .permission(let grant) = $0 {
                return grant.requirement != content.requirement
              }
              return true
            })
        }
      }
    }
    for action in requirements.permissionActions {
      let projectID = requirements.settingsProjectID(for: action)
      let path: CanonicalPath?
      if case .path(let target) = action.scope { path = target } else { path = nil }
      let resolution = PermissionEvaluation.resolve(
        principal: principal, action: action, permissions: permissions, mode: mode,
        limits: limits, sandbox: settings(projectID), pathResolver: pathResolver(path),
        sandboxProjectID: projectID, oneTimeRequests: oneTimeRequests, recordedBasis: recordedBasis)
      result.basis.formUnion(resolution.basis)
      switch resolution.decision {
      case .allowed: break
      case .denied(let reason): result.denial = result.denial ?? reason
      case .request(let content):
        if !result.missing.contains(.permission(content)) {
          result.missing.append(.permission(content))
        }
        // Capture path provenance even while its permission is awaiting an answer.
        var prospective = permissions
        try! prospective.set(
          .granted(content.requirement.value), for: content.requirement.permission)
        let prospectiveResolution = PermissionEvaluation.resolve(
          principal: principal, action: action, permissions: prospective, mode: mode,
          limits: limits, sandbox: settings(projectID), pathResolver: pathResolver(path),
          sandboxProjectID: projectID, oneTimeRequests: oneTimeRequests,
          recordedBasis: recordedBasis)
        result.basis.formUnion(
          prospectiveResolution.basis.filter {
            if case .permission(let grant) = $0 { return grant.requirement != content.requirement }
            return true
          })
      }
    }
    if mode.isSandbox {
      for network in requirements.networks {
        let sources = limits.restrictingNetwork(host: network.host, trustedHosts: hostNames)
        if !sources.isEmpty { result.denial = .managedLimit(sources) }
        let content = network.content(principal: principal)
        if let request = oneTimeRequests.first(where: {
          $0.status == .onlyThisTime && $0.content == .network(content)
        }) {
          result.basis.insert(.request(request.identity))
          result.basis.insert(.permit(request: request.identity, identity: request.permitIdentity!))
          continue
        }
        let access = settings(network.projectID).network
        if let basis = networkBasis(
          content, access: access, trustedHosts: trustedHosts,
          recorded: recordedBasis.networkRule(for: content))
        {
          result.basis.insert(.network(basis))
        } else {
          // Local permission is requested first; the saved requirements still include
          // host admission and are re-evaluated after every answer.
          let localMissing = result.missing.contains {
            guard case .permission(let pending) = $0 else { return false }
            return pending.requirement.permission == .localNetwork
              && pending.scope == network.localAction.scope
          }
          if !localMissing { result.missing.append(.network(content)) }
        }
      }
    }
    let grantedRequirements = result.basis.compactMap { element -> PermissionRequirement? in
      if case .permission(let grant) = element { return grant.requirement }
      return nil
    }
    for (source, availability) in limits.sources {
      guard case .available(let policy) = availability else { continue }
      for requirement in Set(
        requirements.permissionActions.map(\.requirement) + grantedRequirements)
      {
        guard let entry = policy.permissionCeilings.entry(for: requirement.permission),
          entry.state.allows(requirement.value),
          let id = policy.permissionCeilings.grantID(for: entry.permission)
        else { continue }
        result.basis.insert(
          .managedPermission(
            source: source,
            grant: PermissionGrant(
              principal: principal, requirement: requirement, scope: .principal, pluginPurpose: nil,
              source: .standing(entry: entry.permission, id: id))))
      }
    }
    if mode.isSandbox {
      let projects = Set(
        requirements.permissionActions.map { requirements.settingsProjectID(for: $0) }
          + requirements.networks.map { Optional($0.projectID) }
          + result.basis.compactMap { element -> String?? in
            if case .path(let path) = element { return .some(path.sandboxProjectID) }
            return nil
          } + [requirements.sandboxProjectID])
      for projectID in projects {
        let profile = settings(projectID)
        let network = limits.network(applying: profile.network, trustedHosts: hostNames)
        result.basis.insert(
          .sandbox(
            SandboxAccessBasis(
              projectID: projectID, settings: profile,
              managedDeniedReadLocations: limits.deniedReadLocations, network: network)))
        if let projectID, let hosts = network.hosts(trustedHosts: hostNames) {
          for host in hosts {
            let content = NetworkRequestContent(
              principal: principal, host: host, projectID: projectID)
            if let basis = networkBasis(
              content, access: profile.network, trustedHosts: trustedHosts,
              recorded: recordedBasis.networkRule(for: content))
            {
              result.basis.insert(.network(basis))
            }
            recordManagedNetwork(content)
          }
        }
      }
      for network in requirements.networks {
        recordManagedNetwork(network.content(principal: principal))
      }
    }
    return result

    func recordManagedNetwork(_ content: NetworkRequestContent) {
      for (source, availability) in limits.sources {
        guard case .available(let policy) = availability else { continue }
        if let basis = networkBasis(
          content, access: policy.network, trustedHosts: trustedHosts,
          recorded: recordedBasis.networkRule(for: content, policySource: source),
          policySource: source)
        {
          result.basis.insert(.network(basis))
        }
      }
    }
  }

  static func networkBasis(
    _ content: NetworkRequestContent, access: NetworkAccess, trustedHosts: Set<HostRule>,
    recorded: NetworkAccessBasis? = nil, policySource: PolicySource? = nil
  ) -> NetworkAccessBasis? {
    if let recorded, recorded.isValid(access: access, trustedHosts: trustedHosts) {
      return recorded
    }
    let source: NetworkAccessBasis.Source
    switch access.configuration {
    case .full: source = .full
    case .custom(let hosts, _) where Set(hosts.map(NetworkHost.canonical)).contains(content.host):
      source = .custom
    case .trusted, .custom(_, true):
      guard trustedHosts.contains(where: { $0.host == content.host }) else { return nil }
      source = .trusted
    default: return nil
    }
    return NetworkAccessBasis(
      host: content.host, projectID: content.projectID, source: source, policySource: policySource,
      ruleIdentity: access.identity(for: source, host: content.host)!,
      trustedHostIdentity: source == .trusted
        ? trustedHosts.first { $0.host == content.host }?.identity : nil)
  }
}

extension PermissionAction {
  fileprivate var sortKey: [String] {
    let permission: [String]
    switch requirement.permission {
    case .project(let id): permission = ["0", id]
    case .filesAndFolders(let category): permission = ["1", category.rawValue]
    case .plugin(let id): permission = ["2", id]
    case .mcpServer(let id): permission = ["3", id]
    case .screen: permission = ["4"]
    case .desktopControl: permission = ["5"]
    case .localNetwork: permission = ["6"]
    case .machineInformation: permission = ["7"]
    case .unifiedLogs: permission = ["8"]
    case .skills: permission = ["9"]
    }
    let scopeKey: [String]
    switch scope {
    case .principal: scopeKey = ["0"]
    case .project(let id): scopeKey = ["1", id]
    case .path(let path): scopeKey = ["2", path.string]
    case .host(let host, let project): scopeKey = ["3", project, host]
    }
    return permission + [requirement.value.rawValue] + scopeKey
      + [String(requiresFullAccess), pathOperation.sortKey]
      + InvocationRequirements.optionalKey(pluginPurpose)
  }
}

extension PathOperation {
  fileprivate var sortKey: String {
    switch self {
    case .read: "0"
    case .write: "1"
    case .openDirectory: "2"
    case .listDirectory: "3"
    }
  }
}
