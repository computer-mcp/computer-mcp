import Foundation

/// Identifiers come from verified client identities or registered plugin/server identities.
package enum Principal: Hashable, Sendable, Codable {
  case client(String)
  case plugin(PluginIdentity)
}

package enum PluginIdentity: Hashable, Sendable, Codable {
  case package(String)
  /// An owner-registered local server is a plugin without a package.
  case localServer(String)
}

package enum FolderCategory: String, CaseIterable, Hashable, Sendable, Codable {
  case desktop, documents, downloads, iCloudDrive, networkVolumes, removableVolumes
}

package enum Permission: Hashable, Sendable, Codable {
  /// The identifier "*" is a fallback rule, never the object of an action.
  case project(String)
  case filesAndFolders(FolderCategory)
  case plugin(String)
  case mcpServer(String)
  case screen, desktopControl, localNetwork, machineInformation, unifiedLogs, skills

  var fallback: Permission? {
    switch self {
    case .project: .project("*")
    case .plugin: .plugin("*")
    case .mcpServer: .mcpServer("*")
    default: nil
    }
  }

  var isConcrete: Bool {
    switch self {
    case .project(let id), .plugin(let id), .mcpServer(let id): !id.isEmpty && id != "*"
    default: true
    }
  }

  func accepts(_ value: PermissionValue) -> Bool {
    switch self {
    case .project: value == .read || value == .write
    case .filesAndFolders: value == .read
    case .plugin: value == .use
    case .mcpServer: value == .read || value == .all
    default: value == .access
    }
  }
}

package enum PermissionValue: String, Hashable, Sendable, Codable {
  case read, write, use, all, access

  func includes(_ required: PermissionValue) -> Bool {
    self == required || (required == .read && (self == .write || self == .all))
  }
}

package enum PermissionState: Equatable, Sendable, Codable {
  case notGranted
  case granted(PermissionValue)
  case denied

  func allows(_ value: PermissionValue) -> Bool {
    if case .granted(let granted) = self { return granted.includes(value) }
    return false
  }
}

package enum PermissionModelError: Error, Equatable {
  case revisionConflict
  case invalidPermissionValue
  case invalidObject
  case invalidPath
  case invalidProjectGraph
  case narrowerNestedProject(inner: String, outer: String, principal: Principal)
  case unknownRequest, expiredRequest, alreadyAnswered, retryMismatch, requestConsumed
  case unknownAuthorization, invalidAuthorization, unknownExecution
  case invalidRegistrationAnswer
}

package struct PermissionRequirement: Hashable, Sendable, Codable {
  package let permission: Permission
  package let value: PermissionValue

  package init(_ permission: Permission, _ value: PermissionValue) throws {
    guard permission.isConcrete else { throw PermissionModelError.invalidObject }
    guard permission.accepts(value) else { throw PermissionModelError.invalidPermissionValue }
    self.permission = permission
    self.value = value
  }

  private enum CodingKeys: String, CodingKey { case permission, value }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      container.decode(Permission.self, forKey: .permission),
      container.decode(PermissionValue.self, forKey: .value))
  }
}

/// Absence and an explicit `notGranted` both require a request. An explicit entry
/// takes precedence over its fallback, including an explicit `notGranted` entry.
package struct Permissions: Equatable, Sendable, Codable {
  package private(set) var entries: [Permission: PermissionState] = [:]
  var grantIDs: [Permission: BasisIdentity] = [:]

  package init() {}

  private enum CodingKeys: String, CodingKey { case entries, grantIDs }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let entries = try container.decode([Permission: PermissionState].self, forKey: .entries)
    self.init()
    for (permission, state) in entries { try set(state, for: permission) }
    let grantIDs = try container.decode([Permission: BasisIdentity].self, forKey: .grantIDs)
    guard Set(grantIDs.keys) == Set(self.grantIDs.keys) else {
      throw PermissionModelError.invalidAuthorization
    }
    self.grantIDs = grantIDs
  }

  package static var newPrincipal: Permissions {
    var permissions = Permissions()
    try! permissions.set(.granted(.access), for: .machineInformation)
    try! permissions.set(.granted(.access), for: .skills)
    return permissions
  }

  package mutating func set(_ state: PermissionState, for permission: Permission) throws {
    if case .granted(let value) = state, !permission.accepts(value) {
      throw PermissionModelError.invalidPermissionValue
    }
    // Ending a grant retires its identity; a later grant is a new draft.
    if case .granted = state {
      if entries[permission] != state {
        grantIDs[permission] = grantIDs[permission]?.edited() ?? BasisIdentity()
      }
    } else {
      grantIDs[permission] = nil
    }
    entries[permission] = state
  }

  package func state(for permission: Permission) -> PermissionState {
    entry(for: permission)?.state ?? .notGranted
  }

  func grantID(for permission: Permission) -> BasisIdentity? { grantIDs[permission] }

  func entry(for permission: Permission) -> (permission: Permission, state: PermissionState)? {
    if let state = entries[permission] { return (permission, state) }
    if let fallback = permission.fallback, let state = entries[fallback] {
      return (fallback, state)
    }
    return nil
  }
}

package enum FullAccessScope: Hashable, Sendable, Codable {
  case notGranted
  case standing
  case connection(String)
}

package enum ExecutionMode: Hashable, Sendable, Codable {
  case sandbox
  case fullAccess(FullAccessScope)

  var isSandbox: Bool { self == .sandbox }
}

package struct InvocationIdentity: Hashable, Sendable, Codable {
  package let principal: Principal
  package let tool: String
  package let projectID: String?
  /// A caller-computed digest of canonical arguments, never the arguments themselves.
  package let argumentsDigest: String

  package init(principal: Principal, tool: String, projectID: String?, argumentsDigest: String) {
    self.principal = principal
    self.tool = tool
    self.projectID = projectID
    self.argumentsDigest = argumentsDigest
  }
}

package enum RequestScope: Hashable, Sendable, Codable {
  case principal
  case project(String)
  case path(CanonicalPath)
  case host(String, project: String)
}

package struct PermissionRequestContent: Equatable, Sendable, Codable {
  package let principal: Principal
  package let requirement: PermissionRequirement
  package let scope: RequestScope
  package let pluginPurpose: String?

  package init(
    principal: Principal, requirement: PermissionRequirement, scope: RequestScope,
    pluginPurpose: String? = nil
  ) {
    self.principal = principal
    self.requirement = requirement
    if case .host(let host, let project) = scope {
      self.scope = .host(NetworkHost.canonical(host), project: project)
    } else {
      self.scope = scope
    }
    self.pluginPurpose = pluginPurpose
  }
}

package enum DenialReason: Equatable, Sendable {
  case permissionDenied(Permission)
  case managedLimit(Set<PolicySource>)
  case hostData
  case deniedLocation
  case userData
  case readOnlyLocation
  case mainProjectWrite
  case fullAccessRequiresConsent
  case fullAccessRequired
  case pathResolutionRequired
  case invalidPathRequirement
  case authorizationRevoked
  case executionOwner
  case resultExpired
  case executionEnded
}

package enum PermissionDecision: Equatable, Sendable {
  case allowed
  case request(PermissionRequestContent)
  case denied(DenialReason)
}

package struct PermissionAction: Hashable, Sendable, Codable {
  package let requirement: PermissionRequirement
  package let scope: RequestScope
  package let pluginPurpose: String?
  package let requiresFullAccess: Bool
  package let pathOperation: PathOperation

  package init(
    requirement: PermissionRequirement, scope: RequestScope = .principal,
    pluginPurpose: String? = nil, requiresFullAccess: Bool = false,
    pathOperation: PathOperation? = nil
  ) {
    self.requirement = requirement
    if case .host(let host, let project) = scope {
      self.scope = .host(NetworkHost.canonical(host), project: project)
    } else {
      self.scope = scope
    }
    self.pluginPurpose = pluginPurpose
    self.requiresFullAccess = requiresFullAccess
    self.pathOperation = pathOperation ?? (requirement.value == .write ? .write : .read)
  }
}

enum PermissionEvaluation {
  static func evaluate(
    principal: Principal, action: PermissionAction, permissions: Permissions,
    mode: ExecutionMode = .sandbox, limits: ManagedLimits = .init(),
    sandbox: SandboxSettings = .init(), pathResolver: (any PathPermissionResolving)? = nil
  ) -> PermissionDecision {
    let resolution = InvocationEvaluation.evaluate(
      InvocationRequirements(actions: [action], mode: mode),
      principal: principal, permissions: permissions, limits: limits, trustedHosts: [],
      settings: { _ in sandbox }, pathResolver: { _ in pathResolver })
    if let denial = resolution.denial { return .denied(denial) }
    if case .permission(let content) = resolution.missing.first { return .request(content) }
    return .allowed
  }

  static func resolve(
    principal: Principal, action: PermissionAction, permissions: Permissions,
    mode: ExecutionMode, limits: ManagedLimits,
    sandbox: SandboxSettings, pathResolver: (any PathPermissionResolving)?,
    sandboxProjectID: String? = nil, oneTimeRequests: [PermissionRequest] = [],
    recordedBasis: Set<AuthorizationBasis> = []
  ) -> PermissionResolution {
    let permission = resolveRequirement(
      principal: principal, action: action, permissions: permissions, mode: mode,
      limits: limits, sandbox: sandbox, oneTimeRequests: oneTimeRequests,
      recordedGrant: recordedBasis.permissionGrant(
        for: action.requirement, scope: action.scope, pluginPurpose: action.pluginPurpose,
        oneTimeRequests: oneTimeRequests))
    guard case .path(let path) = action.scope else { return permission }
    guard let pathResolver else {
      return PermissionResolution(decision: .denied(.pathResolutionRequired))
    }
    let resolution = pathResolver.resolve(
      path, operation: action.pathOperation, principal: principal, permissions: permissions,
      mode: mode, limits: limits, sandbox: sandbox, sandboxProjectID: sandboxProjectID,
      oneTimeRequests: oneTimeRequests, pluginPurpose: action.pluginPurpose,
      recordedBasis: recordedBasis)
    if case .denied(let reason) = resolution {
      return PermissionResolution(decision: .denied(reason))
    }
    let pathRequirement = pathResolver.requirement(at: path, operation: action.pathOperation)
    if let required = pathRequirement, required != action.requirement {
      return PermissionResolution(decision: .denied(.invalidPathRequirement))
    }
    if case .denied = permission.decision { return permission }
    switch resolution {
    case .allowed(let basis):
      if action.pathOperation.isDirectoryTraversal, pathRequirement == action.requirement,
        basis.contains(.traversal(action.requirement))
      {
        return PermissionResolution(
          decision: .allowed, basis: basis.union([.traversal(action.requirement)]))
      }
      return PermissionResolution(
        decision: permission.decision, basis: basis.union(permission.basis))
    case .request(let content):
      guard content.requirement == action.requirement else {
        return PermissionResolution(decision: .denied(.invalidPathRequirement))
      }
      return PermissionResolution(decision: .request(content))
    case .denied(let reason): return PermissionResolution(decision: .denied(reason))
    }
  }

  static func resolveRequirement(
    principal: Principal, action: PermissionAction, permissions: Permissions,
    mode: ExecutionMode, limits: ManagedLimits, sandbox: SandboxSettings = .init(),
    oneTimeRequests: [PermissionRequest] = [], recordedGrant: PermissionGrant? = nil,
    authorizationID: UUID? = nil
  ) -> PermissionResolution {
    if let denial = denial(
      for: action, permissions: permissions, mode: mode, limits: limits, sandbox: sandbox)
    {
      return PermissionResolution(decision: .denied(denial))
    }
    let requirement = action.requirement
    let content = PermissionRequestContent(
      principal: principal, requirement: requirement, scope: action.scope,
      pluginPurpose: action.pluginPurpose)
    let source: PermissionGrant.Source
    if let recordedGrant {
      guard recordedGrant.principal == principal, recordedGrant.requirement == requirement else {
        return PermissionResolution(decision: .denied(.authorizationRevoked))
      }
      source = recordedGrant.source
    } else if let request = oneTimeRequests.first(where: {
      $0.status == .onlyThisTime && $0.content == .permission(content)
    }) {
      source = .onlyThisTime(request: request.identity, permit: request.permitIdentity!)
    } else if let entry = permissions.entry(for: requirement.permission),
      entry.state.allows(requirement.value),
      let id = permissions.grantID(for: entry.permission)
    {
      source = .standing(entry: entry.permission, id: id)
    } else {
      return PermissionResolution(decision: .request(content))
    }
    let valid: Bool
    switch source {
    case .standing(let entry, let id):
      valid =
        permissions.grantID(for: entry) == id
        && permissions.entries[entry]?.allows(requirement.value) == true
        && permissions.state(for: requirement.permission).allows(requirement.value)
    case .onlyThisTime(let identity, let permit):
      valid = oneTimeRequests.contains { request in
        guard request.identity == identity, request.permitIdentity == permit else { return false }
        if let authorizationID { return request.status == .consumed(authorizationID) }
        if recordedGrant != nil, case .permission(let original) = request.content {
          return request.status == .onlyThisTime && original.principal == principal
            && original.requirement == requirement
        }
        return request.status == .onlyThisTime && request.content == .permission(content)
      }
    }
    guard valid else { return PermissionResolution(decision: .denied(.authorizationRevoked)) }
    return PermissionResolution(
      decision: .allowed,
      basis: [
        .permission(
          PermissionGrant(
            principal: principal, requirement: requirement, scope: action.scope,
            pluginPurpose: action.pluginPurpose, source: source))
      ])
  }

  static func denial(
    for action: PermissionAction, permissions: Permissions, mode: ExecutionMode,
    limits: ManagedLimits, sandbox: SandboxSettings
  ) -> DenialReason? {
    if let denial = limits.modeDenial(mode) { return denial }
    if action.requiresFullAccess && mode.isSandbox { return .fullAccessRequired }
    if case .path(let path) = action.scope {
      if mode.isSandbox && sandbox.deniedReadLocations.contains(where: { $0.contains(path) }) {
        return .deniedLocation
      }
      let sources = limits.denying(path)
      if !sources.isEmpty { return .managedLimit(sources) }
    }
    let requirement = action.requirement
    let sources = limits.restrictingSources(for: requirement)
    if !sources.isEmpty { return .managedLimit(sources) }
    if permissions.state(for: requirement.permission) == .denied {
      return .permissionDenied(requirement.permission)
    }
    return nil
  }
}
