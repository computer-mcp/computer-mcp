import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import Foundation
import GRDB

/// The ledger owns consent authority; this record binds its identity to saved trust.
private struct StandingFullAccessBinding: Codable {
  let principal: Principal
  let trustID: String
  let trustRevision: Int64
  let consent: ModeConsent

  static let keyPrefix = "permission.full-access."
  var key: String { Self.keyPrefix + trustID }

  static func read(_ record: RuntimeSettingRecord) throws -> Self {
    guard record.value.utf8.count <= 16_384 else {
      throw PermissionPersistenceError.invalidCurrentState
    }
    let binding = try JSONDecoder().decode(Self.self, from: Data(record.value.utf8))
    guard binding.key == record.key, binding.consent.mode == .fullAccess(.standing) else {
      throw PermissionPersistenceError.invalidCurrentState
    }
    return binding
  }

  func isCurrent(database: Database, ledger: PermissionLedger) throws -> Bool {
    guard let epoch = ledger.authorizationEpochID,
      ledger.isConsentValid(consent, for: principal),
      ledger.environment.modes[principal] == consent,
      let trust = try GatewayClientTrust.fetchOne(database, key: trustID),
      trust.fullAccessAllowed, trust.revision == trustRevision,
      let row = try ProfileRecord.fetchOne(database, key: trust.profileID.rawValue),
      row.authorityEpoch == epoch.uuidString
    else { return false }
    let profile = try row.value()
    let subject = try GatewayPermissionSubject(
      context: .init(
        caller: trust.caller, profileID: trust.profileID, trustedPrincipalID: trust.principalID))
    return subject.principal == principal && profile.fullAccess
      && profile.allowedCallers.contains(trust.caller)
      && trust.profile.hasSameAuthorization(as: .init(grant: profile, persisted: true))
  }

  func save(_ database: Database) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try RuntimeSettingRecord(
      key: key, value: String(decoding: encoder.encode(self), as: UTF8.self), updatedAt: Date()
    ).save(database)
  }
}

extension GatewayPermissionService {
  static func standingConsent(
    for subject: GatewayPermissionSubject, consent: GatewayFullAccessConsent,
    profile: ProfileGrant, database: Database, ledger: inout PermissionLedger
  ) throws -> ModeConsent {
    guard consent.lifetime == .alwaysAllowClient,
      let trustID = consent.trustID, let revision = consent.trustRevision,
      let trust = try GatewayClientTrust.fetchOne(database, key: trustID),
      trust.revision == revision, trust.fullAccessAllowed,
      trust.profileID == subject.profileID, trust.caller == subject.caller,
      try GatewayPermissionSubject(
        context: .init(
          caller: trust.caller, profileID: trust.profileID, trustedPrincipalID: trust.principalID)
      ).principal
        == subject.principal,
      trust.profile.hasSameAuthorization(as: consent.profile),
      trust.profile.hasSameAuthorization(as: .init(grant: profile, persisted: true)),
      profile.fullAccess
    else { throw GatewayPermissionError.invalidBinding }
    let key = StandingFullAccessBinding.keyPrefix + trustID
    if let stored = try RuntimeSettingRecord.fetchOne(database, key: key) {
      let binding = try StandingFullAccessBinding.read(stored)
      if binding.trustRevision == revision {
        guard binding.principal == subject.principal,
          try binding.isCurrent(database: database, ledger: ledger)
        else { throw GatewayPermissionError.invalidBinding }
        return binding.consent
      }
      guard binding.trustRevision < revision else {
        throw GatewayPermissionError.invalidBinding
      }
    }
    let issued = ledger.consent(for: subject.principal, mode: .fullAccess(.standing))
    try StandingFullAccessBinding(
      principal: subject.principal, trustID: trustID, trustRevision: revision, consent: issued
    ).save(database)
    return issued
  }

  /// Restoration selects existing authority; it never issues or replaces consent.
  func hasValidFullAccessConsent(
    subject: GatewayPermissionSubject, connectionID: String, consent: GatewayFullAccessConsent
  ) throws -> Bool {
    try transactionWithPolicy { database, ledger, policies in
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: Date())
      guard let connection = ledger.environment.connections[connectionID],
        connection.principal == subject.principal,
        !ledger.environment.endedConnections.contains(connectionID)
      else { return false }
      switch consent.lifetime {
      case .thisSession:
        guard let selected = connection.consent,
          selected.mode == .fullAccess(.connection(connectionID))
        else { return false }
        return ledger.isConsentValid(selected, for: subject.principal)
      case .alwaysAllowClient:
        guard let id = consent.trustID, let revision = consent.trustRevision,
          let record = try RuntimeSettingRecord.fetchOne(
            database, key: StandingFullAccessBinding.keyPrefix + id)
        else { return false }
        let binding = try StandingFullAccessBinding.read(record)
        guard connection.consent == nil, binding.principal == subject.principal,
          binding.trustRevision == revision
        else { return false }
        return try binding.isCurrent(database: database, ledger: ledger)
      }
    }
  }

  /// Trust/profile retirement and dependent execution revocation share the writer.
  static func reconcileStandingConsents(
    database: Database, ledger: inout PermissionLedger
  ) throws {
    let records =
      try RuntimeSettingRecord
      .filter(Column("key").like(StandingFullAccessBinding.keyPrefix + "%")).fetchAll(database)
    var environment = ledger.environment
    for record in records {
      let binding = try StandingFullAccessBinding.read(record)
      if try !binding.isCurrent(database: database, ledger: ledger) {
        if environment.modes[binding.principal] == binding.consent {
          environment.modes[binding.principal] = nil
        }
        if var trust = try GatewayClientTrust.fetchOne(database, key: binding.trustID),
          trust.revision == binding.trustRevision, trust.fullAccessAllowed
        {
          trust.fullAccessAllowed = false
          if trust.revision < Int64.max { trust.revision += 1 }
          trust.updatedAt = Date()
          try trust.save(database)
        }
      }
    }
    if environment.modes != ledger.environment.modes {
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
  }
}
