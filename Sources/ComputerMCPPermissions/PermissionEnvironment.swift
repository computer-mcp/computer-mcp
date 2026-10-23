import Foundation

/// An uncommitted value has the zero identity. Only the ledger assigns UUIDs and
/// monotonically increasing revisions. Editing a snapshot preserves its expected
/// identity; the edit marker also records changes reverted before submission.
package struct BasisIdentity: Hashable, Sendable, Codable {
  package let id: UUID
  package let generation: UInt64
  private(set) var isEdited = false

  package init() {
    id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    generation = 0
  }

  init(id: UUID, generation: UInt64) {
    self.id = id
    self.generation = generation
  }

  var isDraft: Bool { generation == 0 }

  func edited() -> Self {
    var result = self
    result.isEdited = true
    return result
  }
}

package struct HostRule: Hashable, Sendable, Codable {
  package internal(set) var identity = BasisIdentity()
  package var host: String {
    didSet {
      host = NetworkHost.canonical(host)
      if host != oldValue { identity = identity.edited() }
    }
  }

  package init(_ host: String) { self.host = NetworkHost.canonical(host) }
}

package struct PathRule: Hashable, Sendable, Codable {
  package enum Kind: Hashable, Sendable, Codable {
    case hostData, denied, developer, userData, systemOrApplication
    case folder(FolderCategory)
  }

  package internal(set) var identity = BasisIdentity()
  package var root: CanonicalPath {
    didSet { if root != oldValue { identity = identity.edited() } }
  }
  package var kind: Kind {
    didSet { if kind != oldValue { identity = identity.edited() } }
  }

  package init(root: CanonicalPath, kind: Kind) {
    self.root = root
    self.kind = kind
  }
}

/// An editable environment snapshot. Submit it with the ledger revision at which
/// it was read; successful reconciliation publishes ledger-assigned identities.
package struct PermissionEnvironment: Sendable, Codable {
  package var limits: [Principal: ManagedLimits] = [:]
  package var trustedHosts: Set<HostRule> = []
  package var paths: PathEnvironmentSnapshot?
  package var endedConnections: Set<String> = []
  package var modes: [Principal: ModeConsent] = [:]

  package init() {}
}

/// Local consent pins the complete principal profile. Reusing a scope name does
/// not renew consent. The host creates another record after obtaining new consent.
package struct ModeConsent: Hashable, Sendable, Codable {
  package let identity: BasisIdentity
  package let mode: ExecutionMode
  package let profileDigest: String

}

extension PathRule {
  static func replacingRoots(_ rules: Set<PathRule>, with roots: Set<CanonicalPath>) -> Set<
    PathRule
  > {
    let retained = rules.filter { roots.contains($0.root) }
    return retained.union(
      roots.subtracting(retained.map(\.root)).map {
        PathRule(root: $0, kind: .denied)
      })
  }
}
