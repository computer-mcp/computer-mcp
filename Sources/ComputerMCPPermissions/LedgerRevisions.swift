import Foundation

extension PermissionLedger {
  /// CAS covers the complete submission, including removals and replacement drafts.
  /// Validation failure discards allocations, revocations and all other partial writes.
  mutating func commit<Result>(
    expectedRevision: UInt64, _ body: (inout Self) throws -> Result
  ) throws -> Result {
    guard expectedRevision == revision else { throw PermissionModelError.revisionConflict }
    var candidate = self
    candidate.revision += 1
    let result = try body(&candidate)
    self = candidate
    return result
  }

  mutating func allocateIdentity(id: UUID = UUID()) -> BasisIdentity {
    revision += 1
    return BasisIdentity(id: id, generation: revision)
  }

  mutating func commitIdentity(
    _ proposed: BasisIdentity, replacing current: BasisIdentity?, changed: Bool
  ) throws -> BasisIdentity {
    if proposed.isDraft { return allocateIdentity() }
    guard let current, proposed.id == current.id, proposed.generation == current.generation else {
      throw PermissionModelError.revisionConflict
    }
    return changed || proposed.isEdited ? allocateIdentity(id: current.id) : current
  }
}

/// Record identities are scoped to their owning collection. A copied identity
/// cannot introduce a record in another principal, policy or settings collection.
protocol PermissionRecord: Equatable {
  var identity: BasisIdentity { get set }
  mutating func commitContents(against current: Self?, in ledger: inout PermissionLedger) throws
}

extension PermissionRecord {
  mutating func commitContents(against current: Self?, in ledger: inout PermissionLedger) throws {}

  mutating func commit(against current: Self?, in ledger: inout PermissionLedger) throws {
    let changed = self != current
    let identity = try ledger.commitIdentity(
      identity, replacing: current?.identity, changed: changed)
    try commitContents(against: current, in: &ledger)
    self.identity = identity
  }
}

extension HostRule: PermissionRecord {}
extension PathRule: PermissionRecord {}
extension RegisteredProject: PermissionRecord {}

extension Set where Element: PermissionRecord {
  mutating func commit(against current: Self, in ledger: inout PermissionLedger) throws {
    let identities = filter { !$0.identity.isDraft }.map(\.identity.id)
    guard Set<UUID>(identities).count == identities.count else {
      throw PermissionModelError.revisionConflict
    }
    self = try Set(
      map { record in
        var record = record
        let old = current.first { $0.identity.id == record.identity.id && !record.identity.isDraft }
        try record.commit(against: old, in: &ledger)
        return record
      })
  }
}

extension Permissions {
  mutating func commit(against current: Self?, in ledger: inout PermissionLedger) throws {
    for (permission, identity) in grantIDs {
      grantIDs[permission] = try ledger.commitIdentity(
        identity, replacing: current?.grantIDs[permission],
        changed: entries[permission] != current?.entries[permission])
    }
  }
}

extension NetworkAccess {
  mutating func commit(against current: Self?, in ledger: inout PermissionLedger) throws {
    let valid: Bool
    switch configuration {
    case .none: valid = fullRule == nil && trustedRule == nil && customRules.isEmpty
    case .full: valid = fullRule != nil && trustedRule == nil && customRules.isEmpty
    case .trusted: valid = fullRule == nil && trustedRule != nil && customRules.isEmpty
    case .custom(let hosts, let includesTrusted):
      valid =
        fullRule == nil && (trustedRule != nil) == includesTrusted
        && Set(customRules.map(\.host)) == hosts
        && customRules.count == hosts.count
    }
    guard valid else { throw PermissionModelError.invalidAuthorization }
    if let identity = fullRule {
      fullRule = try ledger.commitIdentity(identity, replacing: current?.fullRule, changed: false)
    }
    if let identity = trustedRule {
      trustedRule = try ledger.commitIdentity(
        identity, replacing: current?.trustedRule, changed: false)
    }
    try customRules.commit(against: current?.customRules ?? [], in: &ledger)
  }
}

extension SandboxSettings {
  mutating func commit(against current: Self?, in ledger: inout PermissionLedger) throws {
    try network.commit(against: current?.network, in: &ledger)
    try deniedReadRules.commit(against: current?.deniedReadRules ?? [], in: &ledger)
  }
}

extension ManagedPolicy: PermissionRecord {
  mutating func commitContents(against current: Self?, in ledger: inout PermissionLedger) throws {
    try permissionCeilings.commit(against: current?.permissionCeilings, in: &ledger)
    try network.commit(against: current?.network, in: &ledger)
    try deniedReadRules.commit(against: current?.deniedReadRules ?? [], in: &ledger)
  }
}

extension PathEnvironmentSnapshot {
  mutating func commit(against current: Self?, in ledger: inout PermissionLedger) throws {
    let projects = try ProjectCatalog(registeredProjects)
    registeredProjects = try projects.projects.map { project in
      var project = project
      try project.commit(
        against: current?.registeredProjects.first { $0.id == project.id }, in: &ledger)
      return project
    }
    try pathRules.commit(against: current?.pathRules ?? [], in: &ledger)
    outsideUserDataIdentity = try ledger.commitIdentity(
      outsideUserDataIdentity, replacing: current?.outsideUserDataIdentity, changed: false)
  }
}

extension PermissionEnvironment {
  mutating func commit(against current: Self, in ledger: inout PermissionLedger) throws {
    for (principal, var limits) in limits {
      for (source, availability) in limits.sources {
        guard case .available(var policy) = availability else { continue }
        let old: ManagedPolicy?
        if case .available(let policy) = current.limits[principal]?.sources[source] {
          old = policy
        } else {
          old = nil
        }
        try policy.commit(against: old, in: &ledger)
        limits.sources[source] = .available(policy)
      }
      self.limits[principal] = limits
    }
    try trustedHosts.commit(against: current.trustedHosts, in: &ledger)
    try paths?.commit(against: current.paths, in: &ledger)
  }
}
