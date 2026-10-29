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
