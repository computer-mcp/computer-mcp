import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import Crypto
import Foundation

/// File and filesystem acquisition happens before the database writer is acquired.
struct GatewayResolvedPolicy {
  let document: ManagedPolicyDocument
  let deniedPaths: Set<CanonicalPath>

  init(bytes: Data, reader: any ManagedPolicyReading) throws {
    document = try ManagedPolicyDocument.decode(bytes)
    deniedPaths = try Set(
      document.deniedReadLocations.map {
        try CanonicalPath(reader.canonicalPolicyPath($0.string))
      })
  }

  func resolved(for caller: GatewayCallerKind) -> ManagedPolicy {
    var policy = document.resolved(for: caller)
    policy.deniedReadLocations = deniedPaths
    return policy
  }

  func resolvedForProvider() -> ManagedPolicy {
    ManagedPolicy(
      permissionCeilings: document.permissions, allowsFullAccess: document.allowsFullAccess,
      network: document.network, deniedReadLocations: deniedPaths,
      executionLimits: document.executionLimits)
  }
}

struct GatewayPermissionPolicySnapshot {
  private struct Owner {
    let record: PermissionOwnerPolicyRecord
    let document: GatewayResolvedPolicy?
  }
  private let documents: [PolicySource: GatewayResolvedPolicy]
  private let unavailable: [PolicySource: PolicyAvailability]
  private let machineViews: [GatewayManagedPolicyView]
  private var owners: [String: Owner]
  private var providers: [PluginIdentity: (ProviderAuthorityRecord, GatewayResolvedPolicy?)]

  init(
    reader: any ManagedPolicyReading, owners: [PermissionOwnerPolicyRecord],
    providers: [ProviderAuthorityRecord] = []
  ) throws {
    let snapshots = reader.readSources()
    var documents: [PolicySource: GatewayResolvedPolicy] = [:]
    var unavailable: [PolicySource: PolicyAvailability] = [:]
    var views: [GatewayManagedPolicyView] = []
    for id in ManagedPolicySourceID.allCases {
      let source: PolicySource = id == .machineFile ? .machine : .managedPreferences
      let matching = snapshots.filter { $0.source == id }
      guard matching.count == 1, let snapshot = matching.first else {
        unavailable[source] = .unreadable
        views.append(
          .init(
            source: source, location: id.rawValue, revision: "unavailable",
            failure: "Policy source snapshot is missing or ambiguous."))
        continue
      }
      let revision: String
      let failure: String?
      switch snapshot.status {
      case .absent:
        unavailable[source] = .absent
        revision = "absent"
        failure = nil
      case .unreadable(let reason):
        unavailable[source] = .unreadable
        revision = "unreadable"
        failure = String(reason.prefix(256))
      case .available(let bytes):
        revision = Self.digest(bytes)
        do {
          documents[source] = try GatewayResolvedPolicy(bytes: bytes, reader: reader)
          failure = nil
        } catch {
          unavailable[source] = .unreadable
          failure = "Policy contains malformed, unsupported or unavailable settings."
        }
      }
      views.append(
        .init(source: source, location: snapshot.location, revision: revision, failure: failure))
    }
    self.documents = documents
    self.unavailable = unavailable
    machineViews = views
    self.owners = Dictionary(
      uniqueKeysWithValues: owners.map { record in
        (
          record.profileID,
          Owner(
            record: record,
            document: record.payload.flatMap {
              try? GatewayResolvedPolicy(bytes: $0, reader: reader)
            })
        )
      })
    self.providers = try Dictionary(
      uniqueKeysWithValues: providers.map { record in
        (
          try record.identity,
          (
            record,
            record.ownerPolicy.flatMap {
              try? GatewayResolvedPolicy(bytes: $0, reader: reader)
            }
          )
        )
      })
  }

  func views(epoch: UUID?, suspended: Bool) -> [GatewayManagedPolicyView] {
    machineViews
      + owners.values.map { owner in
        let active = owner.record.authorityEpoch == epoch?.uuidString && !suspended
        let readable = owner.record.payload == nil || owner.document != nil
        return .init(
          profileID: GatewayProfileID(rawValue: owner.record.profileID), source: .owner,
          location: "Owner policy", revision: owner.record.payload.map(Self.digest) ?? "absent",
          failure: !active
            ? "Owner policy requires confirmation."
            : !readable ? "Owner policy cannot be read." : nil)
      }
      + providers.map { identity, owner in
        .init(
          provider: identity, source: .owner, location: "Owner policy",
          revision: owner.0.ownerPolicy.map(Self.digest) ?? "absent",
          failure: owner.0.ownerPolicy == nil
            ? nil
            : owner.0.policyEpoch != epoch?.uuidString || suspended
              ? "Owner policy requires confirmation."
              : owner.1 == nil ? "Owner policy cannot be read." : nil)
      }
  }

  func providerLimits(_ identity: PluginIdentity, epoch: UUID?, previous: ManagedLimits?)
    -> ManagedLimits
  {
    var sources = unavailable
    sources[.owner] = .absent
    if let owner = providers[identity], owner.0.ownerPolicy != nil {
      sources[.owner] =
        owner.0.policyEpoch == epoch?.uuidString
        ? owner.1.map { .available($0.resolvedForProvider()) } ?? .unreadable : .unreadable
    }
    for (source, document) in documents {
      sources[source] = .available(document.resolvedForProvider())
    }
    for (source, current) in sources {
      if let old = previous?.sources[source] {
        sources[source] = Self.preservingEvidence(current, previous: old)
      }
    }
    return ManagedLimits(sources: sources)
  }

  func settingProvider(_ record: ProviderAuthorityRecord, document: GatewayResolvedPolicy?) throws
    -> Self
  {
    var result = self
    result.providers[try record.identity] = (record, document)
    return result
  }

  func ownerPolicy(_ id: GatewayProfileID, caller: GatewayCallerKind, epoch: UUID?)
    -> PolicyAvailability
  {
    guard let owner = owners[id.rawValue] else { return .absent }
    guard let epoch, owner.record.authorityEpoch == epoch.uuidString else { return .unreadable }
    guard owner.record.payload != nil else { return .absent }
    return owner.document.map { .available($0.resolved(for: caller)) } ?? .unreadable
  }

  func settingOwner(_ record: PermissionOwnerPolicyRecord, document: GatewayResolvedPolicy?) -> Self
  {
    var snapshot = self
    snapshot.owners[record.profileID] = Owner(record: record, document: document)
    return snapshot
  }

  func adoptingOwners(epoch: UUID) -> Self {
    var snapshot = self
    for (id, owner) in owners {
      snapshot.owners[id] = Owner(
        record: .init(
          profileID: id, payload: owner.record.payload,
          authorityEpoch: epoch), document: owner.document)
    }
    return snapshot
  }

  func limits(owner: PolicyAvailability, caller: GatewayCallerKind, previous: ManagedLimits?)
    -> ManagedLimits
  {
    var sources = unavailable
    sources[.owner] = owner
    for (source, document) in documents {
      sources[source] = .available(document.resolved(for: caller))
    }
    for (source, current) in sources {
      if let old = previous?.sources[source] {
        sources[source] = Self.preservingEvidence(current, previous: old)
      }
    }
    if let connection = previous?.sources[.connection] { sources[.connection] = connection }
    return ManagedLimits(sources: sources)
  }

  private static func preservingEvidence(
    _ current: PolicyAvailability, previous: PolicyAvailability
  ) -> PolicyAvailability {
    guard case .available(let new) = current, case .available(var old) = previous,
      new.permissionCeilings.entries == old.permissionCeilings.entries,
      new.allowsFullAccess == old.allowsFullAccess,
      new.network.configuration == old.network.configuration,
      new.deniedReadLocations == old.deniedReadLocations
    else { return current }
    // Resource ceilings update running work without replacing permission evidence.
    old.executionLimits = new.executionLimits
    return .available(old)
  }

  private static func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
}
