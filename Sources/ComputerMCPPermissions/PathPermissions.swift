import Foundation

package enum PathOperation: Hashable, Sendable, Codable {
  case read, write, openDirectory, listDirectory

  var isDirectoryTraversal: Bool { self == .openDirectory || self == .listDirectory }
}

/// All locations are canonical real paths. Classification, directory identity and
/// filesystem access remain outside the library. Categories may be volume-dependent.
/// Location sets must enumerate every boundary where classification can change;
/// a classification applies recursively until a more specific supplied boundary.
package protocol PathEnvironment: Sendable {
  var projects: ProjectCatalog { get }
  var pathRules: Set<PathRule> { get }
  var outsideUserDataIdentity: BasisIdentity { get }
}

extension PathEnvironment {
  package var hostDataLocations: Set<CanonicalPath> { locations(of: .hostData) }
  package var deniedLocations: Set<CanonicalPath> { locations(of: .denied) }
  package var developerLocations: Set<CanonicalPath> { locations(of: .developer) }
  package var userDataLocations: Set<CanonicalPath> { locations(of: .userData) }
  package var systemOrApplicationLocations: Set<CanonicalPath> {
    locations(of: .systemOrApplication)
  }

  package func locations(in category: FolderCategory) -> Set<CanonicalPath> {
    locations(of: .folder(category))
  }

  package func category(containing path: CanonicalPath) -> FolderCategory? {
    pathRules.filter { $0.root.contains(path) }.sorted {
      $0.root.string.count > $1.root.string.count
    }
    .compactMap {
      if case .folder(let category) = $0.kind { return category }
      return nil
    }.first
  }

  private func locations(of kind: PathRule.Kind) -> Set<CanonicalPath> {
    Set(pathRules.filter { $0.kind == kind }.map(\.root))
  }
}

/// Serializable classification records. Preserve identities across adapter reads.
package struct PathEnvironmentSnapshot: PathEnvironment, Hashable, Codable {
  package internal(set) var registeredProjects: [RegisteredProject]
  package var pathRules: Set<PathRule>
  package internal(set) var outsideUserDataIdentity: BasisIdentity

  package init(_ environment: some PathEnvironment) {
    registeredProjects = environment.projects.projects
    pathRules = environment.pathRules
    outsideUserDataIdentity = environment.outsideUserDataIdentity
  }

  package init(projects: [RegisteredProject] = [], rules: Set<PathRule> = []) throws {
    _ = try ProjectCatalog(projects)
    registeredProjects = projects
    pathRules = rules
    outsideUserDataIdentity = BasisIdentity()
  }

  package mutating func setProjects(_ projects: [RegisteredProject]) throws {
    _ = try ProjectCatalog(projects)
    registeredProjects = projects
  }

  private enum CodingKeys: String, CodingKey {
    case registeredProjects, pathRules, outsideUserDataIdentity
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let projects = try values.decode([RegisteredProject].self, forKey: .registeredProjects)
    _ = try ProjectCatalog(projects)
    registeredProjects = projects
    pathRules = try values.decode(Set<PathRule>.self, forKey: .pathRules)
    outsideUserDataIdentity = try values.decode(
      BasisIdentity.self, forKey: .outsideUserDataIdentity)
  }

  package var projects: ProjectCatalog { try! ProjectCatalog(registeredProjects) }
}

/// The exact permission and path evidence used to allow this operation.
package enum PathPermissionDecision: Equatable, Sendable {
  case allowed(Set<AuthorizationBasis>)
  case request(PermissionRequestContent)
  case denied(DenialReason)

  var decision: PermissionDecision {
    switch self {
    case .allowed: .allowed
    case .request(let content): .request(content)
    case .denied(let reason): .denied(reason)
    }
  }
}

protocol PathPermissionResolving: Sendable {
  func sourceProjectID(for projectID: String) -> String?
  func requirement(at path: CanonicalPath, operation: PathOperation) -> PermissionRequirement?
  func resolve(
    _ path: CanonicalPath, operation: PathOperation, principal: Principal,
    permissions: Permissions, mode: ExecutionMode, limits: ManagedLimits,
    sandbox: SandboxSettings, sandboxProjectID: String?, oneTimeRequests: [PermissionRequest],
    pluginPurpose: String?, recordedBasis: Set<AuthorizationBasis>
  ) -> PathPermissionDecision
  func registrationDenial(
    for content: ProjectRegistrationRequest, permissions: Permissions,
    limits: ManagedLimits, sandbox: SandboxSettings
  ) -> DenialReason?
  /// Checks the recorded path and classification without selecting another route.
  func validate(
    _ basis: PathAccessBasis, principal: Principal, permissions: Permissions,
    mode: ExecutionMode, limits: ManagedLimits, sandbox: SandboxSettings
  ) -> Bool
}

extension PathPermissionResolving {
  func evaluate(
    _ path: CanonicalPath, operation: PathOperation, principal: Principal,
    permissions: Permissions, mode: ExecutionMode = .sandbox, limits: ManagedLimits = .init(),
    sandbox: SandboxSettings = .init(), pluginPurpose: String? = nil
  ) -> PermissionDecision {
    let resolution = InvocationEvaluation.evaluate(
      InvocationRequirements(
        paths: [PathRequirement(path: path, operation: operation, pluginPurpose: pluginPurpose)],
        mode: mode), principal: principal, permissions: permissions,
      limits: limits, trustedHosts: [], settings: { _ in sandbox }, pathResolver: { _ in self })
    if let denial = resolution.denial { return .denied(denial) }
    if case .permission(let content) = resolution.missing.first { return .request(content) }
    return .allowed
  }
}

struct PathPermissions<Environment: PathEnvironment>: PathPermissionResolving {
  let environment: Environment

  func sourceProjectID(for projectID: String) -> String? {
    environment.projects.sourceID(for: projectID)
  }

  func requirement(at path: CanonicalPath, operation: PathOperation)
    -> PermissionRequirement?
  {
    if let project = environment.projects.location(at: path) {
      return try! PermissionRequirement(
        .project(project.projectID), operation == .write ? .write : .read)
    }
    if let category = environment.category(containing: path), operation != .write {
      return try! PermissionRequirement(.filesAndFolders(category), .read)
    }
    return nil
  }

  func resolve(
    _ path: CanonicalPath, operation: PathOperation, principal: Principal,
    permissions: Permissions, mode: ExecutionMode = .sandbox, limits: ManagedLimits = .init(),
    sandbox: SandboxSettings = .init(), sandboxProjectID: String? = nil,
    oneTimeRequests: [PermissionRequest] = [], pluginPurpose: String? = nil,
    recordedBasis: Set<AuthorizationBasis> = []
  ) -> PathPermissionDecision {
    let location = classify(path)
    let recorded = recordedBasis.compactMap { element -> PathAccessBasis? in
      if case .path(let basis) = element, basis.path == path, basis.operation == operation {
        return basis
      }
      return nil
    }.first
    let direct = basis()
    if let recorded, recorded.readableDescendant != nil,
      validate(
        recorded, principal: principal, permissions: permissions, mode: mode, limits: limits,
        sandbox: sandbox),
      let traversal = traversalBasis()
    {
      return .allowed(traversal.union(recorded.requirement.map { [.traversal($0)] } ?? []))
    }
    if let reason = denial(
      for: direct, permissions: permissions, mode: mode, limits: limits,
      sandbox: sandbox)
    {
      if reason == .userData, let traversal = traversalBasis() { return .allowed(traversal) }
      return .denied(reason)
    }
    if let requirement = direct.requirement {
      let resolution = PermissionEvaluation.resolveRequirement(
        principal: principal,
        action: PermissionAction(
          requirement: requirement, scope: .path(path), pluginPurpose: pluginPurpose),
        permissions: permissions, mode: mode, limits: limits, sandbox: sandbox,
        oneTimeRequests: oneTimeRequests,
        recordedGrant: recordedBasis.permissionGrant(
          for: requirement, scope: .path(path), pluginPurpose: pluginPurpose,
          oneTimeRequests: oneTimeRequests))
      switch resolution.decision {
      case .allowed: return .allowed(resolution.basis.union([.path(direct)]))
      case .denied(let reason): return .denied(reason)
      case .request(let content):
        if let traversal = traversalBasis() {
          return .allowed(traversal.union([.traversal(requirement)]))
        }
        return .request(content)
      }
    }
    return .allowed([.path(direct)])

    func basis(descendant: CanonicalPath? = nil) -> PathAccessBasis {
      let exclusions = Set(
        boundaries(limits: limits, sandbox: sandbox, mode: mode).filter {
          $0 != path && path.contains($0)
            && (classify($0) != location
              || denial(
                at: $0, operation: operation, location: classify($0), mode: mode,
                limits: limits, sandbox: sandbox) != nil)
        })
      let excludedRoots = exclusions.filter { candidate in
        !exclusions.contains { $0 != candidate && $0.contains(candidate) }
      }
      return PathAccessBasis(
        path: path, operation: operation, location: location, readableDescendant: descendant,
        sandboxProjectID: sandboxProjectID,
        excludedSubtrees: operation.isDirectoryTraversal
          ? nil
          : excludedRoots,
        ruleIdentities: identities(for: location, at: path).union(
          exclusionIdentities(operation.isDirectoryTraversal ? [] : excludedRoots, sandbox: sandbox)
        ))
    }

    // Directory entries can expose a route to a readable descendant, but never
    // override an explicit denial on the directory itself.
    func traversalBasis() -> Set<AuthorizationBasis>? {
      guard operation.isDirectoryTraversal else { return nil }
      var locations = environment.developerLocations
      locations.formUnion(environment.projects.allLocations.map(\.root))
      for category in FolderCategory.allCases {
        locations.formUnion(environment.locations(in: category))
      }
      let preferred = recorded?.readableDescendant
      for descendant in locations.sorted(by: {
        if $0 == preferred { return $1 != preferred }
        if $1 == preferred { return false }
        return $0.string < $1.string
      }) {
        if descendant != path && path.contains(descendant),
          case .allowed(let evidence) = resolve(
            descendant, operation: .read, principal: principal, permissions: permissions,
            mode: mode, limits: limits, sandbox: sandbox, sandboxProjectID: sandboxProjectID,
            oneTimeRequests: oneTimeRequests, pluginPurpose: pluginPurpose,
            recordedBasis: recordedBasis)
        {
          return evidence.union([.path(basis(descendant: descendant))])
        }
      }
      return nil
    }
  }

  func registrationDenial(
    for content: ProjectRegistrationRequest, permissions: Permissions,
    limits: ManagedLimits, sandbox: SandboxSettings
  ) -> DenialReason? {
    if environment.hostDataLocations.contains(where: { $0.contains(content.path) }) {
      return .hostData
    }
    if environment.deniedLocations.contains(where: { $0.contains(content.path) }) {
      return .deniedLocation
    }
    if let existing = environment.projects.allLocations.first(where: { $0.root == content.path }),
      existing.projectID != content.projectID
    {
      return .authorizationRevoked
    }
    if let source = environment.projects.sourceID(for: content.projectID),
      source != content.projectID
        || !environment.projects.allLocations.contains(where: {
          $0.root == content.path && $0.projectID == content.projectID
        })
    {
      return .authorizationRevoked
    }
    return PermissionEvaluation.denial(
      for: PermissionAction(
        requirement: try! PermissionRequirement(.project(content.projectID), content.access),
        scope: .path(content.path)),
      permissions: permissions, mode: .sandbox, limits: limits, sandbox: sandbox)
  }

  func validate(
    _ basis: PathAccessBasis, principal: Principal, permissions: Permissions,
    mode: ExecutionMode, limits: ManagedLimits, sandbox: SandboxSettings
  ) -> Bool {
    denial(for: basis, permissions: permissions, mode: mode, limits: limits, sandbox: sandbox)
      == nil
  }

  /// Both admission and revalidation check the same fixed range. New boundaries
  /// inside it cannot be authorized by selecting a replacement classification.
  private func denial(
    for basis: PathAccessBasis, permissions: Permissions, mode: ExecutionMode,
    limits: ManagedLimits, sandbox: SandboxSettings
  ) -> DenialReason? {
    guard classify(basis.path) == basis.location,
      basis.ruleIdentities.isSubset(
        of: identities(for: basis.location, at: basis.path).union(
          exclusionIdentities(basis.excludedSubtrees ?? [], sandbox: sandbox))),
      (basis.excludedSubtrees == nil) == basis.operation.isDirectoryTraversal
    else { return .authorizationRevoked }
    if let reason = denial(
      at: basis.path, operation: basis.operation, location: basis.location,
      mode: mode, limits: limits, sandbox: sandbox)
    {
      return reason
    }
    if let descendant = basis.readableDescendant {
      guard basis.operation.isDirectoryTraversal, descendant != basis.path,
        basis.path.contains(descendant)
      else { return .authorizationRevoked }
    } else if basis.location == .userData {
      return .userData
    }
    if let exclusions = basis.excludedSubtrees {
      for boundary in boundaries(limits: limits, sandbox: sandbox, mode: mode)
      where basis.path.contains(boundary) && !exclusions.contains(where: { $0.contains(boundary) })
      {
        guard classify(boundary) == basis.location else { return .authorizationRevoked }
        if let reason = denial(
          at: boundary, operation: basis.operation, location: basis.location,
          mode: mode, limits: limits, sandbox: sandbox)
        {
          return reason
        }
      }
    }
    if let requirement = basis.requirement {
      return PermissionEvaluation.denial(
        for: PermissionAction(requirement: requirement, scope: .path(basis.path)),
        permissions: permissions, mode: mode, limits: limits, sandbox: sandbox)
    }
    return nil
  }

  private func boundaries(limits: ManagedLimits, sandbox: SandboxSettings, mode: ExecutionMode)
    -> Set<CanonicalPath>
  {
    var roots = environment.hostDataLocations.union(environment.deniedLocations)
      .union(environment.developerLocations).union(environment.userDataLocations)
      .union(environment.systemOrApplicationLocations).union(limits.deniedReadLocations)
      .union(environment.projects.allLocations.map(\.root))
    if mode.isSandbox { roots.formUnion(sandbox.deniedReadLocations) }
    for category in FolderCategory.allCases { roots.formUnion(environment.locations(in: category)) }
    return roots
  }

  private func exclusionIdentities(_ roots: Set<CanonicalPath>, sandbox: SandboxSettings) -> Set<
    BasisIdentity
  > {
    Set(
      environment.pathRules.union(sandbox.deniedReadRules).filter { roots.contains($0.root) }.map(
        \.identity)
    ).union(
      environment.projects.allLocations.filter { roots.contains($0.root) }
        .flatMap { $0.registrations.map(\.identity) })
  }

  private func identities(for location: PathAccessBasis.Location, at path: CanonicalPath)
    -> Set<BasisIdentity>
  {
    let kind: PathRule.Kind
    let root: CanonicalPath?
    switch location {
    case .project(let project): return Set(project.registrations.map(\.identity))
    case .folder(let category, let selected):
      kind = .folder(category)
      root = selected
    case .developer(let selected):
      kind = .developer
      root = selected
    case .systemOrApplication(let selected):
      kind = .systemOrApplication
      root = selected
    case .userData:
      kind = .userData
      root = nil
    case .outsideUserData: return [environment.outsideUserDataIdentity]
    }
    return Set(
      environment.pathRules.filter {
        $0.kind == kind && (root == nil ? $0.root.contains(path) : $0.root == root)
      }.map(\.identity))
  }

  private func classify(_ path: CanonicalPath) -> PathAccessBasis.Location {
    if let project = environment.projects.location(at: path) { return .project(project) }
    if let category = environment.category(containing: path),
      let root = environment.locations(in: category).filter({ $0.contains(path) })
        .max(by: { $0.string.count < $1.string.count })
    {
      return .folder(category, root: root)
    }
    if let root = environment.developerLocations.filter({ $0.contains(path) })
      .max(by: { $0.string.count < $1.string.count })
    {
      return .developer(root)
    }
    if let root = environment.systemOrApplicationLocations.filter({ $0.contains(path) })
      .max(by: { $0.string.count < $1.string.count })
    {
      return .systemOrApplication(root)
    }
    return environment.userDataLocations.contains(where: { $0.contains(path) })
      ? .userData : .outsideUserData
  }

  private func denial(
    at path: CanonicalPath, operation: PathOperation, location: PathAccessBasis.Location,
    mode: ExecutionMode, limits: ManagedLimits, sandbox: SandboxSettings
  ) -> DenialReason? {
    if environment.hostDataLocations.contains(where: { $0.contains(path) }) { return .hostData }
    let sources = limits.denying(path)
    if !sources.isEmpty { return .managedLimit(sources) }
    if environment.deniedLocations.contains(where: { $0.contains(path) })
      || (mode.isSandbox && sandbox.deniedReadLocations.contains(where: { $0.contains(path) }))
    {
      return .deniedLocation
    }
    if let denial = limits.modeDenial(mode) { return denial }
    if operation == .write {
      guard case .project(let project) = location else { return .readOnlyLocation }
      if mode.isSandbox && !project.isDerived { return .mainProjectWrite }
    }
    return nil
  }
}

package struct NetworkRequestContent: Equatable, Sendable, Codable {
  package let principal: Principal
  package let host: String
  /// The source project, shared by its derived projects.
  package let projectID: String
  package let pluginPurpose: String?

  package init(principal: Principal, host: String, projectID: String, pluginPurpose: String? = nil)
  {
    self.principal = principal
    self.host = NetworkHost.canonical(host)
    self.projectID = projectID
    self.pluginPurpose = pluginPurpose
  }
}

package enum NetworkDecision: Equatable, Sendable {
  case allowed
  case permissionRequest(PermissionRequestContent)
  case hostRequest(NetworkRequestContent)
  case denied(DenialReason)
}

enum NetworkEvaluation {
  /// The caller classifies the resolved destination, including tunnel routes.
  /// Loopback isolation and DNS/connection enforcement belong to the sandbox adapter.
  static func evaluate(
    host: String, projectID: String, principal: Principal, isLocalNetwork: Bool,
    permissions: Permissions, settings: SandboxSettings, limits: ManagedLimits = .init(),
    mode: ExecutionMode = .sandbox, trustedHosts: Set<String>, pluginPurpose: String? = nil
  ) -> NetworkDecision {
    let resolution = InvocationEvaluation.evaluate(
      InvocationRequirements(
        networks: [
          NetworkRequirement(
            host: host, projectID: projectID, isLocalNetwork: isLocalNetwork,
            pluginPurpose: pluginPurpose)
        ], mode: mode, sandboxProjectID: projectID),
      principal: principal, permissions: permissions, limits: limits,
      trustedHosts: Set(trustedHosts.map(HostRule.init)),
      settings: { _ in settings }, pathResolver: { _ in nil })
    if let denial = resolution.denial { return .denied(denial) }
    switch resolution.missing.first {
    case .permission(let content): return .permissionRequest(content)
    case .network(let content): return .hostRequest(content)
    case .projectRegistration: preconditionFailure("Network requirements cannot register a project")
    case nil: return .allowed
    }
  }
}
