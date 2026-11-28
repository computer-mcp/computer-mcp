import Foundation

/// Filesystem evidence is acquired by the host adapter. The ledger owns the approval revision.
package struct ApprovedReadException: Hashable, Sendable, Codable {
  package let declaredPath: String
  package let ownerSelectedPath: CanonicalPath?
  package let path: CanonicalPath
  package let filesystemIdentity: Data
  package let isDirectory: Bool
  package var purpose: String
  package internal(set) var identity = BasisIdentity()

  package init(
    declaredPath: String, ownerSelectedPath: CanonicalPath? = nil, path: CanonicalPath,
    filesystemIdentity: Data, isDirectory: Bool, purpose: String
  ) throws {
    try Self.validate(declaredPath: declaredPath)
    guard !filesystemIdentity.isEmpty, filesystemIdentity.count <= 8192,
      !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !purpose.contains("\0")
    else { throw PermissionModelError.invalidPath }
    self.declaredPath = declaredPath
    self.ownerSelectedPath = ownerSelectedPath
    self.path = path
    self.filesystemIdentity = filesystemIdentity
    self.isDirectory = isDirectory
    self.purpose = purpose
  }

  package static func validate(declaredPath: String) throws {
    guard declaredPath.hasPrefix("~/"),
      !declaredPath.contains(where: { "\0$*?[]{}".contains($0) }),
      declaredPath.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
        .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw PermissionModelError.invalidPath }
  }

  private enum CodingKeys: String, CodingKey {
    case declaredPath, ownerSelectedPath, path, filesystemIdentity, isDirectory, purpose, identity
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      declaredPath: values.decode(String.self, forKey: .declaredPath),
      ownerSelectedPath: values.decodeIfPresent(CanonicalPath.self, forKey: .ownerSelectedPath),
      path: values.decode(CanonicalPath.self, forKey: .path),
      filesystemIdentity: values.decode(Data.self, forKey: .filesystemIdentity),
      isDirectory: values.decode(Bool.self, forKey: .isDirectory),
      purpose: values.decode(String.self, forKey: .purpose))
    identity = try values.decode(BasisIdentity.self, forKey: .identity)
  }

  func contains(_ candidate: CanonicalPath) -> Bool {
    !identity.isDraft && (isDirectory ? path.contains(candidate) : path == candidate)
  }

  mutating func commit(against current: Self?, in ledger: inout PermissionLedger) throws {
    guard !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !purpose.contains("\0")
    else { throw PermissionModelError.invalidPath }
    var comparable = self
    comparable.purpose = current?.purpose ?? purpose
    identity = try ledger.commitIdentity(
      identity, replacing: current?.identity, changed: comparable != current)
  }
}

extension Set where Element == ApprovedReadException {
  mutating func commit(against current: Self, in ledger: inout PermissionLedger) throws {
    guard Set<CanonicalPath>(map(\.path)).count == count,
      Set<String>(map(\.declaredPath)).count == count,
      Set<UUID>(filter { !$0.identity.isDraft }.map(\.identity.id)).count
        == filter({ !$0.identity.isDraft }).count
    else { throw PermissionModelError.invalidPath }
    self = try Set(
      map { proposed in
        var proposed = proposed
        let previous = current.first {
          !$0.identity.isDraft && $0.identity.id == proposed.identity.id
        }
        try proposed.commit(against: previous, in: &ledger)
        return proposed
      })
  }
}

/// Each omitted field inherits the provider default; an empty collection replaces it.
package struct SandboxSettingsOverride: Hashable, Sendable, Codable {
  package var network: NetworkAccess?
  package var readExceptions: Set<ApprovedReadException>?
  var deniedReadRules: Set<PathRule>?
  package var deniedReadLocations: Set<CanonicalPath>? {
    get { deniedReadRules.map { Set($0.map(\.root)) } }
    set {
      deniedReadRules = newValue.map { PathRule.replacingRoots(deniedReadRules ?? [], with: $0) }
    }
  }

  package init(
    network: NetworkAccess? = nil, readExceptions: Set<ApprovedReadException>? = nil,
    deniedReadLocations: Set<CanonicalPath>? = nil
  ) {
    self.network = network
    self.readExceptions = readExceptions
    deniedReadRules = deniedReadLocations.map { Set($0.map { PathRule(root: $0, kind: .denied) }) }
  }

  func applying(to defaults: SandboxSettings) -> SandboxSettings {
    var result = defaults
    if let network { result.network = network }
    if let readExceptions { result.readExceptions = readExceptions }
    if let deniedReadRules { result.deniedReadRules = deniedReadRules }
    return result
  }

  mutating func commit(against current: Self?, in ledger: inout PermissionLedger) throws {
    try network?.commit(against: current?.network, in: &ledger)
    try readExceptions?.commit(against: current?.readExceptions ?? [], in: &ledger)
    try deniedReadRules?.commit(against: current?.deniedReadRules ?? [], in: &ledger)
  }
}

package struct ProviderSandboxSettings: Hashable, Sendable, Codable {
  package var defaults: SandboxSettings
  package var projects: [String: SandboxSettingsOverride]

  package init(
    defaults: SandboxSettings = .init(), projects: [String: SandboxSettingsOverride] = [:]
  ) {
    self.defaults = defaults
    self.projects = projects
  }

  package func settings(sourceProjectID: String?) -> SandboxSettings {
    sourceProjectID.flatMap { projects[$0]?.applying(to: defaults) } ?? defaults
  }

  /// A reviewed provider default must still respect existing restrictions on unreviewed projects.
  package mutating func retainProjectRestrictions(
    from current: Self, projectIDs: Set<String>, trustedHosts: Set<String>
  ) {
    for (id, var override) in current.projects where projectIDs.contains(id) && projects[id] == nil
    {
      override.network = override.network.map {
        $0.intersecting(defaults.network, trustedHosts: trustedHosts)
      }
      if let exceptions = override.readExceptions {
        override.readExceptions = Set(
          exceptions.compactMap { prior in
            guard
              let reviewed = defaults.readExceptions.first(where: {
                $0.declaredPath == prior.declaredPath
                  && $0.ownerSelectedPath == prior.ownerSelectedPath
                  && $0.path == prior.path && $0.filesystemIdentity == prior.filesystemIdentity
                  && $0.isDirectory == prior.isDirectory
              })
            else { return nil }
            var retained = prior
            retained.purpose = reviewed.purpose
            return retained
          })
      }
      projects[id] = override
    }
  }

  /// A new authority epoch keeps reviewed values and revalidates their filesystem
  /// evidence before the ledger allocates any rule identities.
  package func rebindingReviewedChoices() -> Self {
    func drafts(_ exceptions: Set<ApprovedReadException>) -> Set<ApprovedReadException> {
      Set(
        exceptions.map { exception in
          var draft = exception
          draft.identity = BasisIdentity()
          return draft
        })
    }
    return Self(
      defaults: SandboxSettings(
        network: defaults.network.freshDraft(), deniedReadLocations: defaults.deniedReadLocations,
        readExceptions: drafts(defaults.readExceptions)),
      projects: projects.mapValues {
        SandboxSettingsOverride(
          network: $0.network?.freshDraft(), readExceptions: $0.readExceptions.map(drafts),
          deniedReadLocations: $0.deniedReadLocations)
      })
  }

  mutating func commit(against current: Self?, in ledger: inout PermissionLedger) throws {
    try defaults.commit(against: current?.defaults, in: &ledger)
    for (id, var override) in projects {
      guard ledger.environment.paths?.projects.sourceID(for: id) == id else {
        throw PermissionModelError.invalidProjectGraph
      }
      try override.commit(against: current?.projects[id], in: &ledger)
      projects[id] = override
    }
  }
}

extension NetworkAccess {
  fileprivate func intersecting(_ ceiling: Self, trustedHosts: Set<String>) -> Self {
    if ceiling.configuration == .full || configuration == .none { return self }
    if configuration == .full { return updating(to: ceiling) }
    // A trusted-host choice stays dynamic only when both scopes allow it.
    let includesTrusted = trustedRule != nil && ceiling.trustedRule != nil
    let concreteTrustedHosts = includesTrusted ? [] : trustedHosts
    let hosts = NetworkHost.intersection(
      hosts(trustedHosts: concreteTrustedHosts) ?? [],
      ceiling.hosts(trustedHosts: concreteTrustedHosts) ?? [])
    if hosts.isEmpty { return updating(to: includesTrusted ? .trusted : .none) }
    return updating(to: .custom(hosts: hosts, includesTrusted: includesTrusted))
  }
}
