import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import Foundation
import GRDB

/// One durable authority shared by the App and service. Inputs to admission are
/// authenticated host facts, never decoded tool arguments. Dispatch follows commit.
package final class GatewayPermissionService: @unchecked Sendable {
  let store: SQLitePermissionStore
  let policyReader: any ManagedPolicyReading
  let onAuthorityChange: @Sendable () -> Void
  let projectBookmarks: (any ProjectBookmarkServicing)?
  let projectNesting:
    @Sendable ([ComputerMCPCore.RegisteredProject]) throws -> [TrackedProjectNesting]

  package init(
    store: SQLitePermissionStore, policyReader: any ManagedPolicyReading,
    onAuthorityChange: @escaping @Sendable () -> Void = {},
    projectBookmarks: (any ProjectBookmarkServicing)? = nil,
    projectNesting:
      @escaping @Sendable ([ComputerMCPCore.RegisteredProject]) throws -> [TrackedProjectNesting] =
      { _ in [] }
  ) {
    self.store = store
    self.policyReader = policyReader
    self.onAuthorityChange = onAuthorityChange
    self.projectBookmarks = projectBookmarks
    self.projectNesting = projectNesting
  }

  package func admit(
    subject: GatewayPermissionSubject, tool: String, projectID: String?,
    argumentsDigest: String, requirements: InvocationRequirements, retryIDs: Set<UUID> = [],
    connectionID: String? = nil, now: Date = Date()
  ) throws -> AuthorizationDecision {
    try evaluate(
      subject: subject, tool: tool, projectID: projectID,
      argumentsDigest: argumentsDigest, requirements: requirements, retryIDs: retryIDs,
      connectionID: connectionID, now: now
    ).decision
  }

  func evaluate(
    subject: GatewayPermissionSubject, tool: String, projectID: String?,
    argumentsDigest: String, requirements: InvocationRequirements, retryIDs: Set<UUID> = [],
    connectionID: String? = nil, now: Date = Date(),
    skillLibraries: [GatewaySkillLibraryRequirement] = []
  ) throws -> GatewayPermissionEvaluation {
    let evaluated: (Result<AuthorizationDecision, any Error>, GatewayPermissionAuditEvidence) =
      try transactionWithPolicy {
        database, ledger, policies in
        let result: Result<AuthorizationDecision, any Error> = try {
          () throws -> Result<AuthorizationDecision, any Error> in
          let binding = try Self.bind(subject, database: database)
          _ = try refresh(database, ledger: &ledger, snapshot: policies, now: now)
          guard ledger.suspendedAuthority == nil, ledger.pendingEpochRecovery == nil else {
            return .success(.denied(.authoritySuspended))
          }
          let profile: ProfileGrant
          do {
            profile = try Self.profile(
              binding.profileID, database: database, epoch: ledger.authorizationEpochID)
          } catch GatewayPermissionError.profileUnavailable {
            return .success(.denied(.authoritySuspended))
          }
          guard profile.allowedCallers.contains(subject.caller) else {
            throw GatewayPermissionError.invalidBinding
          }
          try Self.synchronize(
            profile, principal: subject.principal,
            requestedProject: requirements.sandboxProjectID
              ?? projectID.flatMap { ledger.environment.paths?.projects.sourceID(for: $0) }
              ?? projectID,
            ledger: &ledger)
          if requirements.mode != .sandbox && !profile.fullAccess {
            return .success(.denied(.fullAccessRequired))
          }
          let invocation = InvocationIdentity(
            principal: subject.principal, tool: tool, projectID: projectID,
            argumentsDigest: argumentsDigest)
          let selected = GatewaySkillLibraryRequirement.selecting(
            skillLibraries, requirements: requirements, ledger: ledger,
            principal: subject.principal, connectionID: connectionID)
          return Result {
            try ledger.authorize(
              invocation: invocation, requirements: selected, retryIDs: retryIDs,
              connectionID: connectionID, now: now)
          }
        }()
        return (
          result,
          try GatewayPermissionAuditEvidence(
            database: database, ledger: ledger, profileID: subject.profileID)
        )
      }
    return GatewayPermissionEvaluation(decision: try evaluated.0.get(), evidence: evaluated.1)
  }

  package func answerRequest(
    _ id: UUID, answer: PermissionAnswer, owner: GatewayPermissionOwner,
    expectedRevision: UInt64, now: Date = Date()
  ) throws -> RevocationResult {
    let result: Result<RevocationResult, any Error> = try transactionWithPolicy {
      database, ledger, policies in
      try owner.authorize()
      try Self.requireRevision(expectedRevision, database: database)
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: now)
      guard let request = ledger.requests[id] else {
        return .failure(PermissionModelError.unknownRequest)
      }
      let binding = try Self.binding(request.invocation.principal, database: database)
      var profile = try Self.profile(
        binding.profileID, database: database, epoch: ledger.authorizationEpochID)
      guard profile.allowedCallers.contains(binding.caller) else {
        return .failure(GatewayPermissionError.invalidBinding)
      }
      if Self.isManagedLimited(request, ledger: ledger) {
        return .failure(GatewayPermissionError.managedLimit)
      }
      do { _ = try ledger.answer(id, with: answer, now: now) } catch { return .failure(error) }
      if case .always = answer {
        switch request.content {
        case .permission(let content):
          try profile.permissions.set(
            ledger.permissions(for: content.principal).state(for: content.requirement.permission),
            for: content.requirement.permission)
        case .network(let content):
          let key = SandboxSettingsKey(principal: content.principal, projectID: content.projectID)
          guard let setting = ledger.sandboxSettings.entries[key] else {
            throw GatewayPermissionError.invalidBinding
          }
          profile.projectNetworks[content.projectID] = NetworkAccess.none.updating(
            to: setting.network)
        case .projectRegistration: throw PermissionModelError.invalidRegistrationAnswer
        }
        try Self.advance(&profile)
        try Self.save(profile, database: database, epoch: ledger.authorizationEpochID)
        try Self.synchronizeBound(profile, database: database, ledger: &ledger)
      }
      let action: String
      switch answer {
      case .always: action = "always"
      case .onlyThisTime: action = "only_this_time"
      }
      try Self.advanceControlRevision(database)
      try GatewayPermissionAudit.record(
        action, capabilityID: "permissions.answer",
        owner: owner, database: database, ledger: ledger, profileIDs: [profile.id],
        request: request, expectedRevision: expectedRevision, now: now)
      return .success(ledger.pendingRevocations)
    }
    return try result.get()
  }

  /// Profile edits are shared by all verified clients bound to that profile.
  /// Expected revisions are supplied from the owner's current control-plane view.
  package func updateProfile(
    _ proposed: ProfileGrant, owner: GatewayPermissionOwner,
    expectedProfileRevision: Int64?, expectedRevision: UInt64,
    authorization: GatewayManagementAuthorization? = nil, now: Date = Date()
  ) throws {
    let result: Result<Void, any Error> = try transactionWithPolicy { database, ledger, policies in
      try owner.authorize()
      try Self.requireRevision(expectedRevision, database: database)
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: now)
      guard ledger.suspendedAuthority == nil, ledger.pendingEpochRecovery == nil else {
        return .failure(PermissionModelError.authoritySuspended)
      }
      do {
        try GatewayDatabase.requireManagementAuthorization(
          authorization, in: database, ledger: &ledger)
      } catch { return .failure(error) }
      let previous = try Self.optionalProfile(
        proposed.id, database: database, epoch: ledger.authorizationEpochID)
      guard previous?.authorizationRevision == expectedProfileRevision else {
        return .failure(GatewayPermissionError.revisionConflict)
      }
      do {
        try Self.validateEdit(proposed, previous: previous, snapshot: policies, ledger: ledger)
      } catch { return .failure(error) }
      var profile = proposed
      profile.authorizationRevision = previous?.authorizationRevision ?? 0
      try Self.advance(&profile)
      try Self.save(profile, database: database, epoch: ledger.authorizationEpochID)
      try Self.synchronizeBound(profile, database: database, ledger: &ledger)
      try Self.advanceControlRevision(database)
      try GatewayPermissionAudit.record(
        "update_profile", capabilityID: "profile.permissions", owner: owner,
        database: database, ledger: ledger, profileIDs: [profile.id],
        permissions: Set(profile.permissions.entries.keys).union(
          previous.map { Set($0.permissions.entries.keys) } ?? []),
        expectedRevision: expectedRevision, now: now)
      return .success(())
    }
    try result.get()
  }

  package func revokePermission(
    _ permission: Permission, profileID: GatewayProfileID,
    owner: GatewayPermissionOwner, expectedRevision: UInt64, now: Date = Date()
  ) throws -> RevocationResult {
    try transactionWithPolicy { database, ledger, policies in
      try owner.authorize()
      try Self.requireRevision(expectedRevision, database: database)
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: now)
      var profile = try Self.profile(
        profileID, database: database, epoch: ledger.authorizationEpochID)
      try profile.permissions.set(.denied, for: permission)
      try Self.advance(&profile)
      try Self.save(profile, database: database, epoch: ledger.authorizationEpochID)
      try Self.synchronizeBound(profile, database: database, ledger: &ledger)
      try Self.advanceControlRevision(database)
      try GatewayPermissionAudit.record(
        "revoke_permission", capabilityID: "profile.permissions", owner: owner,
        database: database, ledger: ledger, profileIDs: [profile.id], permissions: [permission],
        expectedRevision: expectedRevision, now: now)
      return ledger.pendingRevocations
    }
  }

  package func setOwnerPolicy(
    _ document: Data?, profileID: GatewayProfileID, owner: GatewayPermissionOwner,
    expectedRevision: UInt64, now: Date = Date()
  ) throws -> RevocationResult {
    let resolved = try document.map { try GatewayResolvedPolicy(bytes: $0, reader: policyReader) }
    return try transactionWithPolicy { database, ledger, policies in
      try owner.authorize()
      try Self.requireRevision(expectedRevision, database: database)
      guard ledger.suspendedAuthority == nil, ledger.pendingEpochRecovery == nil else {
        throw PermissionModelError.authoritySuspended
      }
      _ = try Self.profile(profileID, database: database, epoch: ledger.authorizationEpochID)
      guard let epoch = ledger.authorizationEpochID else {
        throw GatewayPermissionError.profileUnavailable
      }
      let record = PermissionOwnerPolicyRecord(
        profileID: profileID.rawValue, payload: document, authorityEpoch: epoch)
      try record.save(database)
      _ = try refresh(
        database, ledger: &ledger, snapshot: policies.settingOwner(record, document: resolved),
        now: now)
      try Self.advanceControlRevision(database)
      try GatewayPermissionAudit.record(
        document == nil ? "clear_owner_policy" : "set_owner_policy",
        capabilityID: "permissions.owner_policy", owner: owner,
        database: database, ledger: ledger, profileIDs: [profileID],
        expectedRevision: expectedRevision, now: now)
      return ledger.pendingRevocations
    }
  }

  package func reconcilePolicy(now: Date = Date(), notify: Bool = true) throws -> RevocationResult {
    try transactionWithPolicy(notify: notify) { database, ledger, policies in
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: now)
      return ledger.pendingRevocations
    }
  }

  /// Local diagnostics remain accessible with unreadable policies or suspended grants.
  package func view(owner: GatewayPermissionOwner, now: Date = Date()) throws
    -> GatewayPermissionView
  {
    _ = try transactionWithPolicy { database, ledger, policies in
      try owner.authorize()
      return try refresh(database, ledger: &ledger, snapshot: policies, now: now)
    }
    return try store.readWithDatabase { database, ledger in
      try owner.authorize()
      let bindings = try Self.bindings(database)
      let sources = try Row.fetchAll(
        database, sql: "SELECT payload FROM permissionPolicySources ORDER BY source"
      ).map { row in
        let bytes: Data = row["payload"]
        return try JSONDecoder().decode(GatewayManagedPolicyView.self, from: bytes)
      }
      let profiles = try Row.fetchAll(
        database, sql: "SELECT payload FROM permissionProfiles ORDER BY id"
      ).map { row in
        let bytes: Data = row["payload"]
        guard bytes.count <= 4_194_304 else { throw PermissionPersistenceError.invalidCurrentState }
        return try JSONDecoder().decode(ProfileGrant.self, from: bytes)
      }
      let registeredProjects = try GatewayDatabase.projects(in: database)
      return GatewayPermissionView(
        revision: try Self.controlRevision(database),
        profiles: profiles,
        subjects: bindings.map {
          .init(
            principal: $0.principal, profileID: $0.profileID, caller: $0.caller,
            limits: ledger.environment.limits[$0.principal] ?? .init())
        },
        requests: ledger.requests.values.sorted {
          $0.createdAt == $1.createdAt
            ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }.map { request in
          let profileID = bindings.first { $0.principal == request.invocation.principal }?.profileID
          let grantRoot: CanonicalPath?
          let grantName: String?
          if case .projectRegistration(let content) = request.content {
            grantRoot =
              ledger.environment.paths?.registeredProjects.first {
                $0.id == content.projectID
              }?.root
            grantName = registeredProjects.first { $0.id == content.projectID }?.displayName
          } else {
            grantRoot = nil
            grantName = nil
          }
          return .init(
            request: request, profileID: profileID, alwaysIsShared: profileID != nil,
            registrationGrantRoot: grantRoot, registrationGrantName: grantName)
        }, sources: sources, epoch: ledger.authorizationEpochID,
        suspended: ledger.suspendedAuthority != nil || ledger.pendingEpochRecovery != nil,
        unconfirmedProfileIDs: Set(
          try Row.fetchAll(
            database,
            sql:
              "SELECT id FROM permissionProfiles WHERE authorityEpoch IS NULL OR authorityEpoch != ?",
            arguments: [ledger.authorizationEpochID?.uuidString]
          ).compactMap { row in
            GatewayProfileID(rawValue: row["id"] as String)
          }))
    }
  }

  /// Recovery first retires the old runtime epoch through the store's host API.
  /// Only this local owner action adopts saved profiles and owner policy into the
  /// new epoch; merely reading SQL cannot restore authority after rollback.
  package func confirmAuthority(
    owner: GatewayPermissionOwner, epoch: UUID,
    expectedRevision: UInt64, profileEdits: [ProfileGrant], now: Date = Date()
  ) throws {
    try transactionWithPolicy { database, ledger, policies in
      try owner.authorize()
      try Self.requireRevision(expectedRevision, database: database)
      guard ledger.authorizationEpochID == epoch, ledger.pendingEpochRecovery == nil else {
        throw GatewayPermissionError.revisionConflict
      }
      let saved = try ProfileRecord.order(Column("id")).fetchAll(database).map { try $0.value() }
      let reviewedIDs = Set(profileEdits.map(\.id))
      guard reviewedIDs.count == profileEdits.count, reviewedIDs == Set(saved.map(\.id)) else {
        throw GatewayPermissionError.invalidBinding
      }
      let previousByID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
      let adopted = policies.adoptingOwners(epoch: epoch)
      for proposed in profileEdits {
        let previous = previousByID[proposed.id]!
        guard previous.authorizationRevision == proposed.authorizationRevision else {
          throw GatewayPermissionError.revisionConflict
        }
        try Self.validateEdit(proposed, previous: previous, snapshot: adopted, ledger: ledger)
      }
      try ledger.confirmSuspendedAuthority(epochID: epoch, expectedRevision: ledger.revision)
      try database.execute(
        sql: "UPDATE permissionProfiles SET authorityEpoch = ?", arguments: [epoch.uuidString])
      try database.execute(
        sql: "UPDATE permissionOwnerPolicies SET authorityEpoch = ?", arguments: [epoch.uuidString])
      for proposed in profileEdits {
        var edited = proposed
        try Self.advance(&edited)
        try Self.save(edited, database: database, epoch: epoch)
      }
      for binding in try Self.bindings(database) {
        let profile = try Self.profile(binding.profileID, database: database, epoch: epoch)
        try Self.synchronizeBound(profile, database: database, ledger: &ledger)
      }
      _ = try refresh(database, ledger: &ledger, snapshot: adopted, now: now)
      try Self.advanceControlRevision(database)
      try GatewayPermissionAudit.record(
        "confirm_authority", capabilityID: "permissions.confirm_authority", owner: owner,
        database: database, ledger: ledger, profileIDs: profileEdits.map(\.id),
        permissions: Set(profileEdits.flatMap { $0.permissions.entries.keys }),
        expectedRevision: expectedRevision, now: now)
    }
  }

  /// A source read may wait on disk or preferences, so it never holds the writer.
  /// A concurrent publisher invalidates the observed source state and forces a fresh read.
  func transactionWithPolicy<Result>(
    notify: Bool = true,
    _ body: (Database, inout PermissionLedger, GatewayPermissionPolicySnapshot) throws -> Result
  ) throws -> Result {
    for _ in 0..<3 {
      let baseline = try store.readWithDatabase { database, _ in
        (try Self.policyVersion(database), try PermissionOwnerPolicyRecord.fetchAll(database))
      }
      let snapshot = GatewayPermissionPolicySnapshot(reader: policyReader, owners: baseline.1)
      do {
        let result = try store.transactionWithDatabase { database, ledger in
          guard try Self.policyVersion(database) == baseline.0 else {
            throw GatewayPermissionError.invalidPolicySnapshot
          }
          return try body(database, &ledger, snapshot)
        }
        if notify { onAuthorityChange() }
        return result
      } catch GatewayPermissionError.invalidPolicySnapshot { continue }
    }
    throw GatewayPermissionError.invalidPolicySnapshot
  }

  private static func policyVersion(_ database: Database) throws -> Data {
    let projections = try Row.fetchAll(
      database, sql: "SELECT payload FROM permissionPolicySources ORDER BY source"
    ).map { $0["payload"] as Data }
    let owners = try PermissionOwnerPolicyRecord.order(Column("profileID")).fetchAll(database)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(projections + owners.map { try encoder.encode($0) })
  }

  func refresh(
    _ database: Database, ledger: inout PermissionLedger,
    snapshot: GatewayPermissionPolicySnapshot, now: Date
  ) throws -> [GatewayManagedPolicyView] {
    let views = snapshot.views(
      epoch: ledger.authorizationEpochID,
      suspended: ledger.suspendedAuthority != nil || ledger.pendingEpochRecovery != nil)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let incoming = try Dictionary(
      uniqueKeysWithValues: views.map { view in
        (
          view.source.rawValue + (view.profileID.map { ":" + $0.rawValue } ?? ""),
          try encoder.encode(view)
        )
      })
    let stored = try Dictionary(
      uniqueKeysWithValues: Row.fetchAll(
        database, sql: "SELECT source, payload FROM permissionPolicySources"
      ).map { row in
        (row["source"] as String, row["payload"] as Data)
      })
    for key in stored.keys where incoming[key] == nil {
      try database.execute(
        sql: "DELETE FROM permissionPolicySources WHERE source = ?", arguments: [key])
    }
    for (key, payload) in incoming where stored[key] != payload {
      try database.execute(
        sql:
          "INSERT INTO permissionPolicySources (source, payload) VALUES (?, ?) ON CONFLICT(source) DO UPDATE SET payload=excluded.payload",
        arguments: [key, payload])
    }
    var environment = ledger.environment
    for binding in try Self.bindings(database) {
      let policy = snapshot.ownerPolicy(
        binding.profileID, caller: binding.caller, epoch: ledger.authorizationEpochID)
      environment.limits[binding.principal] = snapshot.limits(
        owner: policy, caller: binding.caller,
        previous: environment.limits[binding.principal])
    }
    if environment.limits != ledger.environment.limits {
      _ = try ledger.reconcile(
        environment: environment, expectedRevision: ledger.revision, now: now)
    } else {
      _ = ledger.reconcileExecutionLimits(now: now)
    }
    for request in ledger.requests.values {
      switch request.status {
      case .pending, .onlyThisTime, .always:
        if Self.isManagedLimited(request, ledger: ledger) {
          _ = try ledger.retireRequest(request.id, expectedRevision: ledger.revision)
        }
      default: break
      }
    }
    try Self.reconcileStandingConsents(database: database, ledger: &ledger)
    return views
  }

  static func isManagedLimited(_ request: PermissionRequest, ledger: PermissionLedger)
    -> Bool
  {
    let limits = ledger.environment.limits[request.invocation.principal] ?? .init()
    switch request.content {
    case .permission(let content):
      return !limits.restrictingSources(for: content.requirement).isEmpty
    case .network(let content):
      return !limits.restrictingNetwork(
        host: content.host, trustedHosts: Set(ledger.environment.trustedHosts.map(\.host))
      ).isEmpty
    case .projectRegistration(let content):
      return
        (try? limits.restrictingSources(
          for: PermissionRequirement(.project(content.projectID), content.access)
        ).isEmpty) != true
    }
  }

  private static func controlRevision(_ database: Database) throws -> UInt64 {
    guard
      let value = try Int64.fetchOne(
        database, sql: "SELECT revision FROM permissionControlRevision WHERE id = 1"), value >= 0
    else {
      throw PermissionPersistenceError.invalidCurrentState
    }
    return UInt64(value)
  }

  static func requireRevision(_ revision: UInt64, database: Database) throws {
    guard try controlRevision(database) == revision else {
      throw GatewayPermissionError.revisionConflict
    }
  }

  static func advanceControlRevision(_ database: Database) throws {
    guard try controlRevision(database) < Int64.max else {
      throw PermissionMigrationError.revisionExhausted
    }
    try database.execute(
      sql: "UPDATE permissionControlRevision SET revision = revision + 1 WHERE id = 1")
  }

  static func advance(_ profile: inout ProfileGrant) throws {
    guard profile.authorizationRevision < Int64.max else {
      throw PermissionMigrationError.revisionExhausted
    }
    profile.authorizationRevision += 1
  }

  private static func validateProfile(_ profile: ProfileGrant) throws {
    try profile.validate()
    func validateObject(_ id: String) throws {
      guard !id.isEmpty, id.utf8.count <= 256,
        !id.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
        id == "*" || !id.contains("*")
      else { throw PermissionModelError.invalidObject }
    }
    var permissions = Permissions()
    for (permission, state) in profile.permissions.entries {
      switch permission {
      case .project(let id), .plugin(let id), .mcpServer(let id): try validateObject(id)
      default: break
      }
      try permissions.set(state, for: permission)
    }
    for (id, network) in profile.projectNetworks {
      try validateObject(id)
      if case .custom(let hosts, _) = network.configuration {
        guard hosts.allSatisfy({ NetworkHost.contains($0, rule: $0) }) else {
          throw PermissionModelError.invalidObject
        }
      }
    }
    let bundleCharacters = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-.")
    for id in profile.automation.keys {
      guard id != "*", id.utf8.count <= 256, id.contains("."),
        !id.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty),
        id.unicodeScalars.allSatisfy(bundleCharacters.contains)
      else { throw PermissionModelError.invalidObject }
    }
  }

  static func validateEdit(
    _ proposed: ProfileGrant, previous: ProfileGrant?,
    snapshot: GatewayPermissionPolicySnapshot, ledger: PermissionLedger
  ) throws {
    try validateProfile(proposed)
    let trustedHosts = Set(ledger.environment.trustedHosts.map(\.host))
    for caller in proposed.allowedCallers {
      let baseline = previous?.allowedCallers.contains(caller) == true ? previous : nil
      let limits = snapshot.limits(
        owner: snapshot.ownerPolicy(
          proposed.id, caller: caller,
          epoch: ledger.authorizationEpochID), caller: caller, previous: nil)
      let keys = Set(proposed.permissions.entries.keys).union(
        baseline?.permissions.entries.keys.map { $0 } ?? [])
      for permission in keys
      where permission != .project("*") && permission != .plugin("*")
        && permission != .mcpServer("*")
      {
        let state = proposed.permissions.state(for: permission)
        if case .granted(let value) = state, baseline?.permissions.state(for: permission) != state {
          guard limits.restrictingSources(for: try PermissionRequirement(permission, value)).isEmpty
          else {
            throw GatewayPermissionError.managedLimit
          }
        }
      }
      try checkFallbackEdits(proposed, previous: baseline, limits: limits)
      if proposed.fullAccess && baseline?.fullAccess != true {
        guard
          limits.sources.values.allSatisfy({ source in
            switch source {
            case .absent: true
            case .unreadable: false
            case .available(let policy): policy.allowsFullAccess
            }
          })
        else { throw GatewayPermissionError.managedLimit }
      }
      let projects = Set(proposed.projectNetworks.keys).union(
        baseline?.projectNetworks.keys.map { $0 } ?? [])
      for id in projects {
        let network = proposed.projectNetworks[id] ?? proposed.projectNetworks["*"] ?? .none
        let prior = baseline?.projectNetworks[id] ?? baseline?.projectNetworks["*"] ?? .none
        guard network.configuration != prior.configuration else { continue }
        for source in limits.sources.values {
          let ceiling: NetworkAccess
          switch source {
          case .absent: continue
          case .unreadable: ceiling = .none
          case .available(let policy): ceiling = policy.network
          }
          guard networkFits(network, ceiling: ceiling, trustedHosts: trustedHosts) else {
            throw GatewayPermissionError.managedLimit
          }
        }
      }
    }
  }

  private static func networkFits(
    _ network: NetworkAccess, ceiling: NetworkAccess, trustedHosts: Set<String>
  ) -> Bool {
    func includesTrusted(_ access: NetworkAccess) -> Bool {
      switch access.configuration {
      case .trusted, .full: true
      case .custom(_, let included): included
      case .none: false
      }
    }
    if network.configuration == .full { return ceiling.configuration == .full }
    if includesTrusted(network) && !includesTrusted(ceiling) { return false }
    let limits = ManagedLimits(machine: .available(ManagedPolicy(network: ceiling)))
    return limits.network(applying: network, trustedHosts: trustedHosts)
      == ManagedLimits().network(applying: network, trustedHosts: trustedHosts)
  }

  private static func checkFallbackEdits(
    _ profile: ProfileGrant, previous: ProfileGrant?, limits: ManagedLimits
  ) throws {
    for permission in [Permission.project("*"), .plugin("*"), .mcpServer("*")] {
      guard case .granted(let proposed) = profile.permissions.entries[permission],
        previous?.permissions.entries[permission] != .granted(proposed)
      else { continue }
      for source in limits.sources.values {
        switch source {
        case .absent: continue
        case .unreadable: throw GatewayPermissionError.managedLimit
        case .available(let policy):
          for (key, ceiling) in policy.permissionCeilings.entries {
            let sameKind: Bool
            switch (permission, key) {
            case (.project, .project), (.plugin, .plugin), (.mcpServer, .mcpServer): sameKind = true
            default: sameKind = false
            }
            guard sameKind else { continue }
            let intended = profile.permissions.entries[key] ?? .granted(proposed)
            guard case .granted(let intendedValue) = intended else { continue }
            switch ceiling {
            case .granted(let value)
            where value == intendedValue || value == .write && intendedValue == .read
              || value == .all && intendedValue == .read:
              continue
            default: throw GatewayPermissionError.managedLimit
            }
          }
        }
      }
    }
  }

  static func synchronizeBound(
    _ profile: ProfileGrant, database: Database, ledger: inout PermissionLedger
  ) throws {
    for binding in try bindings(database) where binding.profileID == profile.id {
      var effective = profile
      if !profile.allowedCallers.contains(binding.caller) {
        effective.permissions = Permissions()
        effective.projectNetworks = [:]
        _ = try ledger.retirePrincipal(binding.principal, expectedRevision: ledger.revision)
      }
      try synchronize(
        effective, principal: binding.principal, requestedProject: nil, ledger: &ledger)
      do {
        var environment = ledger.environment
        environment.modes[binding.principal] = nil
        for (id, connection) in environment.connections
        where connection.principal == binding.principal {
          environment.connections[id]!.consent = nil
          if !profile.allowedCallers.contains(binding.caller) {
            environment.endedConnections.insert(id)
          }
        }
        _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      }
    }
  }

  static func synchronize(
    _ profile: ProfileGrant, principal: Principal, requestedProject: String?,
    ledger: inout PermissionLedger
  ) throws {
    ledger.register(principal)
    var permissions = ledger.permissions(for: principal)
    for key in permissions.entries.keys where profile.permissions.entries[key] == nil {
      permissions.removeEntry(for: key)
    }
    for (permission, state) in profile.permissions.entries
    where permissions.entries[permission] != state { try permissions.set(state, for: permission) }
    if ledger.permissions(for: principal).entries != permissions.entries {
      _ = try ledger.setPermissions(permissions, for: principal, expectedRevision: ledger.revision)
    }
    var projects = Set(profile.projectNetworks.keys).union(
      ledger.sandboxSettings.entries.keys.filter { $0.principal == principal }.map(\.projectID))
    if let requestedProject { projects.insert(requestedProject) }
    projects.remove("*")
    for id in projects {
      let key = SandboxSettingsKey(principal: principal, projectID: id)
      var settings = ledger.sandboxSettings.entries[key] ?? SandboxSettings()
      let desired = profile.projectNetworks[id] ?? profile.projectNetworks["*"] ?? .none
      if settings.network.configuration != desired.configuration {
        settings.network = settings.network.updating(to: desired)
        _ = try ledger.setSandboxSettings(settings, for: key, expectedRevision: ledger.revision)
      }
    }
  }

  static func profile(_ id: GatewayProfileID, database: Database, epoch: UUID?) throws
    -> ProfileGrant
  {
    guard let profile = try optionalProfile(id, database: database, epoch: epoch) else {
      throw GatewayPermissionError.unknownProfile
    }
    return profile
  }

  static func optionalProfile(_ id: GatewayProfileID, database: Database, epoch: UUID?)
    throws -> ProfileGrant?
  {
    guard
      let row = try Row.fetchOne(
        database, sql: "SELECT * FROM permissionProfiles WHERE id = ?", arguments: [id.rawValue])
    else { return nil }
    let savedEpoch: String? = row["authorityEpoch"]
    guard let epoch, savedEpoch == epoch.uuidString else {
      throw GatewayPermissionError.profileUnavailable
    }
    let bytes: Data = row["payload"]
    guard bytes.count <= 4_194_304 else { throw PermissionPersistenceError.invalidCurrentState }
    let profile = try JSONDecoder().decode(ProfileGrant.self, from: bytes)
    guard profile.id == id, profile.authorizationRevision == row["authorizationRevision"] else {
      throw PermissionPersistenceError.invalidCurrentState
    }
    return profile
  }

  static func save(_ profile: ProfileGrant, database: Database, epoch: UUID?) throws {
    guard let epoch else { throw GatewayPermissionError.profileUnavailable }
    try database.execute(
      sql:
        "INSERT INTO permissionProfiles (id, authorizationRevision, payload, authorityEpoch) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET authorizationRevision = excluded.authorizationRevision, payload = excluded.payload, authorityEpoch = excluded.authorityEpoch",
      arguments: [
        profile.id.rawValue, profile.authorizationRevision, try JSONEncoder().encode(profile),
        epoch.uuidString,
      ])
  }

  struct Binding {
    let principal: Principal
    let profileID: GatewayProfileID
    let caller: GatewayCallerKind
  }
  static func bindings(_ database: Database) throws -> [Binding] {
    try Row.fetchAll(database, sql: "SELECT * FROM permissionSubjects ORDER BY principal").map {
      row in
      let bytes: Data = row["principal"]
      let id: String = row["profileID"]
      let caller: String = row["caller"]
      guard bytes.count < 4096, let profileID = GatewayProfileID(rawValue: id),
        let caller = GatewayCallerKind(rawValue: caller)
      else { throw GatewayPermissionError.invalidBinding }
      return Binding(
        principal: try JSONDecoder().decode(Principal.self, from: bytes), profileID: profileID,
        caller: caller)
    }
  }
  static func binding(_ principal: Principal, database: Database) throws -> Binding {
    guard let binding = try bindings(database).first(where: { $0.principal == principal }) else {
      throw GatewayPermissionError.invalidBinding
    }
    return binding
  }
  static func bind(_ subject: GatewayPermissionSubject, database: Database) throws
    -> Binding
  {
    let bytes = try JSONEncoder().encode(subject.principal)
    let existing =
      try Int.fetchOne(
        database, sql: "SELECT COUNT(*) FROM permissionSubjects WHERE principal = ?",
        arguments: [bytes]) ?? 0
    let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM permissionSubjects") ?? 0
    guard existing > 0 || count < 16_384 else { throw GatewayPermissionError.subjectCapacity }
    try database.execute(
      sql:
        "INSERT OR IGNORE INTO permissionSubjects (principal, profileID, caller) VALUES (?, ?, ?)",
      arguments: [bytes, subject.profileID.rawValue, subject.caller.rawValue])
    let binding = try binding(subject.principal, database: database)
    guard binding.profileID == subject.profileID, binding.caller == subject.caller else {
      throw GatewayPermissionError.invalidBinding
    }
    return binding
  }
}
