import Foundation

/// Host-published identity of the reviewed requirement projection. It grants no permission.
package struct ProviderRequirementBinding: Equatable, Sendable, Codable {
  package internal(set) var identity = BasisIdentity()
  package let digest: String

  package init(digest: String) { self.digest = digest }
}

extension ProviderRequirementBinding: PermissionRecord {}

/// The host selects a reviewed contribution before submitting an invocation.
package struct ProviderRequirement: Hashable, Sendable, Codable {
  package let provider: PluginIdentity
  package let digest: String
  package let conservative: Bool

  package init(provider: PluginIdentity, digest: String, conservative: Bool) {
    self.provider = provider
    self.digest = digest
    self.conservative = conservative
  }
}

package struct ProviderRequirementBasis: Hashable, Sendable, Codable {
  let requirement: ProviderRequirement
  let binding: BasisIdentity
  let coverageDigest: String?
  let callerFallbacks: [Permission: BasisIdentity]
}

extension PermissionLedger {
  /// Wildcards describe future-object coverage, never concrete permission requests.
  /// Concrete holes in either principal's rules must still be evaluated individually.
  func providerRequirements(
    _ requirements: InvocationRequirements, principal: Principal, connection: ManagedPolicy?
  ) -> (InvocationRequirements, Set<AuthorizationBasis>)? {
    guard !requirements.providers.isEmpty else { return (requirements, []) }
    var actions = requirements.actions
    var evidence: Set<AuthorizationBasis> = []
    let caller = permissions(for: principal)
    var callerLimits = environment.limits[principal] ?? .init()
    if let connection { callerLimits.sources[.connection] = .available(connection) }
    for requirement in requirements.providers {
      guard let binding = environment.providerRequirements?[requirement.provider],
        binding.digest == requirement.digest, !binding.identity.isDraft,
        !binding.identity.isEdited
      else { return nil }
      var coverageDigest: String?
      var fallbacks: [Permission: BasisIdentity] = [:]
      if requirement.conservative {
        let provider = permissions(for: .plugin(requirement.provider))
        let limits = environment.limits[.plugin(requirement.provider)] ?? .init()
        guard limits.unreadableSources.isEmpty, callerLimits.unreadableSources.isEmpty else {
          return nil
        }
        let grants = provider.entries.compactMap { key, state -> String? in
          guard key != .machineInformation && key != .skills else { return nil }
          return ProfileDigest.canonical(key) + ":" + ProfileDigest.canonical(state)
            + ":" + ProfileDigest.canonical(provider.grantID(for: key))
        }.sorted()
        let policies = limits.sources.map { source, availability in
          let value: String
          switch availability {
          case .absent: value = "absent"
          case .unreadable: value = "unreadable"
          case .available(let policy): value = ProfileDigest.canonical(policy.identity)
          }
          return source.rawValue + ":" + value
        }.sorted()
        coverageDigest = ProfileDigest.hash(
          ProfileDigest.ordered(grants) + ProfileDigest.ordered(policies))
        let keys = Set(provider.entries.keys).union(caller.entries.keys)
          .union(limits.permissionKeys).union(callerLimits.permissionKeys)
        for key in keys where key != .machineInformation && key != .skills {
          guard let level = Self.effectivePermission(key, permissions: provider, limits: limits)
          else { continue }
          if key.fallback == key {
            guard
              Self.effectivePermission(key, permissions: caller, limits: callerLimits)?
                .includes(level) == true, let identity = caller.grantID(for: key),
              !identity.isDraft, !identity.isEdited
            else { return nil }
            fallbacks[key] = identity
          } else {
            guard key.isConcrete, let permission = try? PermissionRequirement(key, level) else {
              return nil
            }
            let scope: RequestScope
            if case .project(let id) = key { scope = .project(id) } else { scope = .principal }
            actions.append(PermissionAction(requirement: permission, scope: scope))
          }
        }
      }
      evidence.insert(
        .provider(
          ProviderRequirementBasis(
            requirement: requirement, binding: binding.identity, coverageDigest: coverageDigest,
            callerFallbacks: fallbacks)))
    }
    return (
      InvocationRequirements(
        actions: actions, paths: requirements.paths, networks: requirements.networks,
        mode: requirements.mode, sandboxProjectID: requirements.sandboxProjectID,
        execution: requirements.execution, providers: requirements.providers), evidence
    )
  }

  private static func effectivePermission(
    _ permission: Permission, permissions: Permissions, limits: ManagedLimits
  ) -> PermissionValue? {
    guard case .granted(var value) = permissions.state(for: permission) else { return nil }
    for availability in limits.sources.values {
      if case .unreadable = availability { return nil }
      guard case .available(let policy) = availability,
        let ceiling = policy.permissionCeilings.entry(for: permission)
      else { continue }
      guard case .granted(let maximum) = ceiling.state else { return nil }
      if value.includes(maximum) { value = maximum } else if !maximum.includes(value) { return nil }
    }
    return value
  }
}

extension ManagedLimits {
  fileprivate var permissionKeys: Set<Permission> {
    sources.values.reduce(into: []) { keys, availability in
      if case .available(let policy) = availability {
        keys.formUnion(policy.permissionCeilings.entries.keys)
      }
    }
  }
}
