import Foundation

package enum PolicySource: String, CaseIterable, Hashable, Sendable, Codable {
  case owner, machine, managedPreferences, connection
}

package struct ManagedPolicy: Equatable, Sendable, Codable {
  package internal(set) var identity = BasisIdentity()
  /// Missing entries impose no ceiling. Explicit entries and fallbacks use the
  /// same precedence as permissions; neither `notGranted` nor `denied` permits a grant.
  package var permissionCeilings: Permissions {
    didSet { if permissionCeilings != oldValue { identity = identity.edited() } }
  }
  package var allowsFullAccess: Bool {
    didSet { if allowsFullAccess != oldValue { identity = identity.edited() } }
  }
  package var network: NetworkAccess {
    didSet { if network != oldValue { identity = identity.edited() } }
  }
  package var executionLimits: ExecutionLimitCeilings
  package internal(set) var deniedReadRules: Set<PathRule>
  package var deniedReadLocations: Set<CanonicalPath> {
    get { Set(deniedReadRules.map(\.root)) }
    set {
      let rules = PathRule.replacingRoots(deniedReadRules, with: newValue)
      if rules != deniedReadRules { identity = identity.edited() }
      deniedReadRules = rules
    }
  }

  package init(
    permissionCeilings: Permissions = .init(), allowsFullAccess: Bool = true,
    network: NetworkAccess = .full, deniedReadLocations: Set<CanonicalPath> = [],
    executionLimits: ExecutionLimitCeilings = .none
  ) {
    self.executionLimits = executionLimits
    self.permissionCeilings = permissionCeilings
    self.allowsFullAccess = allowsFullAccess
    self.network = network
    self.deniedReadRules = Set(deniedReadLocations.map { PathRule(root: $0, kind: .denied) })
  }
}

package enum PolicyAvailability: Equatable, Sendable, Codable {
  case absent
  case available(ManagedPolicy)
  /// Existence is known but the source cannot be read. All ceilings fail closed.
  case unreadable
}

/// A fresh snapshot for one principal. Keep the sources separate so every
/// restrictive result retains its provenance, including unreadable sources.
package struct ManagedLimits: Equatable, Sendable, Codable {
  package internal(set) var sources: [PolicySource: PolicyAvailability]

  package init(owner: PolicyAvailability = .absent, machine: PolicyAvailability = .absent) {
    sources = [.owner: owner, .machine: machine]
  }

  package init(sources: [PolicySource: PolicyAvailability]) { self.sources = sources }

  package func restrictingSources(for requirement: PermissionRequirement) -> Set<PolicySource> {
    restrictingSources {
      guard let entry = $0.permissionCeilings.entry(for: requirement.permission) else {
        return false
      }
      return !entry.state.allows(requirement.value)
    }
  }

  /// A fallback edit must also respect concrete ceilings where no stored override applies.
  package func restrictingSources(forFallback permission: Permission, in permissions: Permissions)
    -> Set<PolicySource>
  {
    guard permission.fallback == permission,
      case .granted(let proposed) = permissions.entries[permission]
    else { return [] }
    return restrictingSources { policy in
      policy.permissionCeilings.entries.contains { key, ceiling in
        guard key.fallback == permission,
          case .granted(let intended) = permissions.entries[key] ?? .granted(proposed)
        else { return false }
        return !ceiling.allows(intended)
      }
    }
  }

  package func denying(_ path: CanonicalPath) -> Set<PolicySource> {
    restrictingSources { policy in policy.deniedReadLocations.contains { $0.contains(path) } }
  }

  package func restrictingNetwork(host: String, trustedHosts: Set<String>) -> Set<PolicySource> {
    restrictingSources { !$0.network.allows(host, trustedHosts: trustedHosts) }
  }

  package func network(
    applying settings: NetworkAccess, trustedHosts: Set<String>
  ) -> NetworkAccess.Configuration {
    var candidates: Set<String>?
    for level in [settings]
      + sources.values.compactMap({ source in
        switch source {
        case .absent: nil
        case .unreadable: NetworkAccess.none
        case .available(let policy): policy.network
        }
      })
    {
      guard let hosts = level.hosts(trustedHosts: trustedHosts) else { continue }
      candidates = candidates.map { NetworkHost.intersection($0, hosts) } ?? hosts
    }
    guard let candidates else { return .full }
    return candidates.isEmpty ? .none : .custom(hosts: candidates, includesTrusted: false)
  }

  var unreadableSources: Set<PolicySource> { restrictingSources { _ in false } }

  var deniedReadLocations: Set<CanonicalPath> {
    sources.values.reduce(into: []) { locations, source in
      if case .available(let policy) = source { locations.formUnion(policy.deniedReadLocations) }
    }
  }

  package func modeDenial(_ mode: ExecutionMode) -> DenialReason? {
    guard case .fullAccess(let consent) = mode else { return nil }
    if consent == .notGranted { return .fullAccessRequiresConsent }
    let sources = restrictingSources { !$0.allowsFullAccess }
    return sources.isEmpty ? nil : .managedLimit(sources)
  }

  private func restrictingSources(_ predicate: (ManagedPolicy) -> Bool) -> Set<PolicySource> {
    Set(
      sources.compactMap { source, availability in
        switch availability {
        case .absent: nil
        case .unreadable: source
        case .available(let policy): predicate(policy) ? source : nil
        }
      })
  }
}

/// Reading policy files, configuration profiles and owner databases belongs to adapters.
/// They must distinguish a missing source from an existing but unreadable source.
package protocol ManagedPolicyStore: Sendable {
  func read(source: PolicySource, principal: Principal) async throws -> PolicyAvailability
  func write(_ policy: PolicyAvailability, source: PolicySource, principal: Principal) async throws
}

package actor InMemoryManagedPolicyStore: ManagedPolicyStore {
  private var entries: [Principal: [PolicySource: PolicyAvailability]] = [:]

  package init() {}

  package func read(source: PolicySource, principal: Principal) -> PolicyAvailability {
    entries[principal]?[source] ?? .absent
  }

  package func write(_ policy: PolicyAvailability, source: PolicySource, principal: Principal) {
    entries[principal, default: [:]][source] = policy
  }
}

extension ManagedLimits {
  /// Adapter failures cannot silently turn an enforced source into an absent one.
  package static func read(
    for principal: Principal, from store: some ManagedPolicyStore
  ) async -> ManagedLimits {
    var sources: [PolicySource: PolicyAvailability] = [:]
    for source in [PolicySource.owner, .machine, .managedPreferences] {
      do { sources[source] = try await store.read(source: source, principal: principal) } catch {
        sources[source] = .unreadable
      }
    }
    return ManagedLimits(sources: sources)
  }
}
