import Foundation

/// An absolute, normalized real path supplied by the caller. This type validates
/// lexical form only; resolving links, volume casing and filesystem races is the caller's job.
package struct CanonicalPath: Hashable, Sendable, Codable {
  package let string: String

  package init(_ string: String) throws {
    let components = string.split(separator: "/", omittingEmptySubsequences: false)
    guard string.hasPrefix("/"), !string.contains("\0"),
      string == "/"
        || (!string.hasSuffix("/") && !components.dropFirst().contains("")
          && !components.contains(".") && !components.contains(".."))
    else { throw PermissionModelError.invalidPath }
    self.string = string
  }

  package init(from decoder: any Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(string)
  }

  package func contains(_ path: CanonicalPath) -> Bool {
    string == "/" || path.string == string || path.string.hasPrefix(string + "/")
  }

  func projecting(_ path: CanonicalPath, from source: CanonicalPath) throws -> CanonicalPath {
    let suffix = path.string.dropFirst(source.string == "/" ? 0 : source.string.count)
    return try CanonicalPath((string == "/" ? "" : string) + suffix)
  }
}

package struct RegisteredProject: Hashable, Sendable, Codable {
  package let id: String
  package var root: CanonicalPath {
    didSet { if root != oldValue { identity = identity.edited() } }
  }
  package var sourceID: String? {
    didSet { if sourceID != oldValue { identity = identity.edited() } }
  }
  package internal(set) var identity = BasisIdentity()

  package init(id: String, root: CanonicalPath, sourceID: String? = nil) {
    self.id = id
    self.root = root
    self.sourceID = sourceID
  }
}

/// Git tracking is an input fact; path nesting alone does not establish shared history.
package struct TrackedProjectNesting: Sendable {
  package let innerID: String
  package let outerID: String

  package init(innerID: String, outerID: String) {
    self.innerID = innerID
    self.outerID = outerID
  }
}

package struct ProjectLocation: Hashable, Sendable, Codable {
  package let projectID: String
  package let root: CanonicalPath
  package let isDerived: Bool
  package let registrations: Set<RegisteredProject>
}

package struct ProjectCatalog: Sendable {
  package let projects: [RegisteredProject]
  private let sources: [String: String]
  private let locations: [ProjectLocation]

  package init(_ projects: [RegisteredProject] = []) throws {
    guard Set(projects.map(\.id)).count == projects.count,
      Set(projects.map(\.root)).count == projects.count,
      projects.allSatisfy({ !$0.id.isEmpty && $0.id != "*" })
    else { throw PermissionModelError.invalidProjectGraph }
    let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    var sources: [String: String] = [:]
    for project in projects {
      var current = project
      var visited: Set<String> = [project.id]
      while let sourceID = current.sourceID {
        guard let source = byID[sourceID], visited.insert(sourceID).inserted else {
          throw PermissionModelError.invalidProjectGraph
        }
        current = source
      }
      sources[project.id] = current.id
    }
    func registrations(for project: RegisteredProject) -> Set<RegisteredProject> {
      var result: Set<RegisteredProject> = [project]
      var current = project
      while let sourceID = current.sourceID, let source = byID[sourceID] {
        result.insert(source)
        current = source
      }
      return result
    }
    var locations: [ProjectLocation] = []
    for project in projects {
      let enclosingDerived = projects.filter {
        $0.sourceID != nil && $0.root.contains(project.root)
      }
      let isDerived = !enclosingDerived.isEmpty
      let provenance = enclosingDerived.reduce(into: registrations(for: project)) {
        $0.formUnion(registrations(for: $1))
      }
      locations.append(
        ProjectLocation(
          projectID: sources[project.id]!, root: project.root, isDerived: isDerived,
          registrations: provenance))
    }
    for derived in projects where derived.sourceID != nil {
      let source = byID[sources[derived.id]!]!
      for nested in projects where nested.id != source.id && source.root.contains(nested.root) {
        locations.append(
          ProjectLocation(
            projectID: sources[nested.id]!,
            root: try derived.root.projecting(nested.root, from: source.root), isDerived: true,
            registrations: registrations(for: derived).union(registrations(for: nested))))
      }
    }
    self.projects = projects
    self.sources = sources
    // Explicit registrations win ties with projected locations.
    self.locations = locations.enumerated().sorted {
      if $0.element.root.string.count != $1.element.root.string.count {
        return $0.element.root.string.count > $1.element.root.string.count
      }
      return $0.offset < $1.offset
    }.map(\.element)
  }

  package func sourceID(for projectID: String) -> String? { sources[projectID] }

  package func location(at path: CanonicalPath) -> ProjectLocation? {
    locations.first { $0.root.contains(path) }
  }

  package var allLocations: [ProjectLocation] { locations }

  package func validate(
    nesting: [TrackedProjectNesting], permissions: [Principal: Permissions]
  ) throws {
    for pair in nesting {
      guard let inner = sourceID(for: pair.innerID), let outer = sourceID(for: pair.outerID) else {
        throw PermissionModelError.invalidProjectGraph
      }
      for (principal, rules) in permissions {
        let outerState = rules.state(for: .project(outer))
        let innerState = rules.state(for: .project(inner))
        if case .granted(let value) = outerState, !innerState.allows(value) {
          throw PermissionModelError.narrowerNestedProject(
            inner: inner, outer: outer, principal: principal)
        }
      }
    }
  }
}

package struct NetworkAccess: Hashable, Sendable, Codable {
  package enum Configuration: Hashable, Sendable, Codable {
    case none, trusted, full
    case custom(hosts: Set<String>, includesTrusted: Bool)
  }

  package private(set) var configuration: Configuration
  package internal(set) var customRules: Set<HostRule> = []
  var fullRule: BasisIdentity?
  var trustedRule: BasisIdentity?

  private init(_ configuration: Configuration) {
    self.configuration = configuration
    switch configuration {
    case .full: fullRule = BasisIdentity()
    case .trusted: trustedRule = BasisIdentity()
    case .custom(let hosts, let includesTrusted):
      customRules = Set(Set(hosts.map(NetworkHost.canonical)).map(HostRule.init))
      if includesTrusted { trustedRule = BasisIdentity() }
    case .none: break
    }
  }

  package static var none: Self { Self(.none) }
  package static var trusted: Self { Self(.trusted) }
  package static var full: Self { Self(.full) }
  package static func custom(hosts: Set<String>, includesTrusted: Bool) -> Self {
    Self(.custom(hosts: Set(hosts.map(NetworkHost.canonical)), includesTrusted: includesTrusted))
  }

  func identity(for source: NetworkAccessBasis.Source, host: String) -> BasisIdentity? {
    switch source {
    case .full: fullRule
    case .trusted: trustedRule
    case .custom: customRules.first { $0.host == NetworkHost.canonical(host) }?.identity
    }
  }

  func preservesUnboundedRule(of previous: NetworkAccess) -> Bool {
    previous.fullRule == nil || fullRule == previous.fullRule
  }

  package func allows(_ host: String, trustedHosts: Set<String>) -> Bool {
    hosts(trustedHosts: trustedHosts)?.contains(NetworkHost.canonical(host)) ?? true
  }

  func hosts(trustedHosts: Set<String>) -> Set<String>? {
    configuration.hosts(trustedHosts: trustedHosts)
  }

  func isMoreRestrictive(than previous: NetworkAccess, trustedHosts: Set<String>) -> Bool {
    configuration.isMoreRestrictive(than: previous.configuration, trustedHosts: trustedHosts)
  }

  /// Retains existing rule identities; a newly added host gets a new record.
  package func adding(_ host: String) -> Self {
    guard fullRule == nil else { return self }
    let host = NetworkHost.canonical(host)
    var result = self
    if !customRules.contains(where: { $0.host == host }) {
      result.customRules.insert(HostRule(host))
    }
    result.configuration = .custom(
      hosts: Set(result.customRules.map(\.host)), includesTrusted: trustedRule != nil)
    return result
  }

  package func removing(_ host: String) -> Self {
    var result = self
    result.customRules = customRules.filter { $0.host != NetworkHost.canonical(host) }
    if case .custom = configuration {
      result.configuration = .custom(
        hosts: Set(result.customRules.map(\.host)), includesTrusted: trustedRule != nil)
    }
    return result
  }
}

package struct SandboxSettings: Hashable, Sendable, Codable {
  package var network: NetworkAccess
  package internal(set) var deniedReadRules: Set<PathRule>
  package var deniedReadLocations: Set<CanonicalPath> {
    get { Set(deniedReadRules.map(\.root)) }
    set { deniedReadRules = PathRule.replacingRoots(deniedReadRules, with: newValue) }
  }

  package init(network: NetworkAccess = .none, deniedReadLocations: Set<CanonicalPath> = []) {
    self.network = network
    self.deniedReadRules = Set(deniedReadLocations.map { PathRule(root: $0, kind: .denied) })
  }
}

extension SandboxSettings {
  func isMoreRestrictive(than previous: SandboxSettings, trustedHosts: Set<String>) -> Bool {
    network.isMoreRestrictive(than: previous.network, trustedHosts: trustedHosts)
      || deniedReadLocations.contains { path in
        !previous.deniedReadLocations.contains { $0.contains(path) }
      }
  }
}

package struct SandboxSettingsKey: Hashable, Sendable, Codable {
  package let principal: Principal
  package let projectID: String

  package init(principal: Principal, projectID: String) {
    self.principal = principal
    self.projectID = projectID
  }
}

package struct ProjectSandboxSettings: Sendable, Codable {
  package var entries: [SandboxSettingsKey: SandboxSettings]

  package init(entries: [SandboxSettingsKey: SandboxSettings] = [:]) { self.entries = entries }

  package func settings(
    for principal: Principal, projectID: String, projects: ProjectCatalog
  ) throws -> SandboxSettings {
    guard let source = projects.sourceID(for: projectID) else {
      throw PermissionModelError.invalidProjectGraph
    }
    return entries[SandboxSettingsKey(principal: principal, projectID: source)] ?? SandboxSettings()
  }
}

/// Host adapters supply DNS/IDNA and address resolution; lexical DNS identity is
/// shared by requirements, custom rules and trusted-host snapshots.
enum NetworkHost {
  static func canonical(_ value: String) -> String {
    let lower = value.lowercased()
    return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
  }
}

extension NetworkAccess.Configuration {
  func hosts(trustedHosts: Set<String>) -> Set<String>? {
    let trustedHosts = Set(trustedHosts.map(NetworkHost.canonical))
    return switch self {
    case .full: nil
    case .none: []
    case .trusted: trustedHosts
    case .custom(let hosts, let includesTrusted): hosts.union(includesTrusted ? trustedHosts : [])
    }
  }

  func isMoreRestrictive(than previous: NetworkAccess.Configuration, trustedHosts: Set<String>)
    -> Bool
  {
    guard let current = hosts(trustedHosts: trustedHosts) else { return false }
    guard let previous = previous.hosts(trustedHosts: trustedHosts) else { return true }
    return !previous.isSubset(of: current)
  }

}
