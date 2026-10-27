import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPWorktrees
import Foundation
import GRDB

extension GatewayPermissionService {
  package func connect(
    subject: GatewayPermissionSubject, id: String, attenuation: ManagedPolicy = .init()
  ) throws {
    try transactionWithPolicy { database, ledger, policies in
      let binding = try Self.bind(subject, database: database)
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: Date())
      let profile = try Self.profile(
        binding.profileID, database: database, epoch: ledger.authorizationEpochID)
      guard profile.allowedCallers.contains(subject.caller),
        !ledger.environment.endedConnections.contains(id)
      else {
        throw GatewayPermissionError.invalidBinding
      }
      try Self.synchronize(
        profile, principal: subject.principal, requestedProject: nil, ledger: &ledger)
      if let current = ledger.environment.connections[id] {
        guard current.principal == subject.principal else {
          throw GatewayPermissionError.invalidBinding
        }
        return
      }
      var environment = ledger.environment
      environment.connections[id] = PermissionConnection(
        principal: subject.principal, attenuation: attenuation)
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
  }

  /// Local session consent selects execution mode; it never edits a permission.
  package func setConnectionConsent(
    subject: GatewayPermissionSubject, id: String, allowed: Bool,
    consent: GatewayFullAccessConsent? = nil
  ) throws {
    try transactionWithPolicy { database, ledger, policies in
      _ = try Self.bind(subject, database: database)
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: Date())
      let profile = try Self.profile(
        subject.profileID, database: database, epoch: ledger.authorizationEpochID)
      guard profile.allowedCallers.contains(subject.caller),
        let connection = ledger.environment.connections[id],
        connection.principal == subject.principal,
        !ledger.environment.endedConnections.contains(id),
        !allowed || profile.fullAccess
      else { throw GatewayPermissionError.invalidBinding }
      try Self.synchronize(
        profile, principal: subject.principal, requestedProject: nil, ledger: &ledger)
      if allowed, consent?.lifetime == .alwaysAllowClient, let paths = ledger.environment.paths {
        let projects = Set(paths.registeredProjects.map { $0.sourceID ?? $0.id })
        for project in projects.sorted() {
          try Self.synchronize(
            profile, principal: subject.principal, requestedProject: project, ledger: &ledger)
        }
      }
      var environment = ledger.environment
      if allowed, let consent, consent.lifetime == .alwaysAllowClient {
        let standing = try Self.standingConsent(
          for: subject, consent: consent, profile: profile, database: database, ledger: &ledger)
        environment.modes[subject.principal] = standing
        environment.connections[id]!.consent = nil
      } else {
        environment.connections[id]!.consent =
          allowed
          ? ledger.consent(for: subject.principal, mode: .fullAccess(.connection(id))) : nil
      }
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
  }

  package func limitConnection(
    subject: GatewayPermissionSubject, id: String, to proposed: ManagedPolicy
  ) throws {
    try transactionWithPolicy { database, ledger, policies in
      _ = try Self.bind(subject, database: database)
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: Date())
      guard let current = ledger.environment.connections[id],
        current.principal == subject.principal,
        !ledger.environment.endedConnections.contains(id), proposed.narrows(current.attenuation)
      else { throw GatewayPermissionError.managedLimit }
      var environment = ledger.environment
      environment.connections[id]!.attenuation = proposed
      if !proposed.allowsFullAccess { environment.connections[id]!.consent = nil }
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
  }

  package func endConnection(subject: GatewayPermissionSubject, id: String) throws {
    try store.transactionWithDatabase { _, ledger in
      guard ledger.environment.connections[id]?.principal == subject.principal else { return }
      var environment = ledger.environment
      environment.endedConnections.insert(id)
      environment.connections[id]!.consent = nil
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    onAuthorityChange()
  }

  package func configureEnvironment(
    _ paths: PathEnvironmentSnapshot, trustedHosts: Set<HostRule>,
    expectedProjects: [ComputerMCPCore.RegisteredProject], expectedConfigurationRevision: String?,
    platformRules: Set<PathRule>? = nil, configurationRules: Set<PathRule>? = nil
  ) throws {
    try store.transactionWithDatabase { database, ledger in
      let current = try GatewayDatabase.projects(in: database).sorted { $0.id < $1.id }
      let revision = try String.fetchOne(
        database,
        sql:
          "SELECT id FROM configurationRevisions WHERE activatedAt IS NOT NULL AND activationError IS NULL ORDER BY activatedAt DESC, createdAt DESC, id DESC LIMIT 1"
      )
      guard current == expectedProjects.sorted(by: { $0.id < $1.id }),
        revision == expectedConfigurationRevision
      else {
        throw GatewayDatabaseError.configurationChanged
      }
      guard paths.registeredProjects.count == current.count else {
        throw GatewayDatabaseError.configurationChanged
      }
      for expected in current {
        let root = try ProjectPathResolver.resolve(
          expected.rootPath, relativeTo: URL(fileURLWithPath: "/"))
        guard
          paths.registeredProjects.contains(where: {
            $0.id == expected.id && $0.root.string == root.path
          })
        else { throw GatewayDatabaseError.configurationChanged }
      }
      let sources = try SQLiteDerivedProjectStore.records(database).filter { $0.state == .active }
      let sourceIDs = Dictionary(uniqueKeysWithValues: sources.map { ($0.projectID, $0.source.id) })
      guard paths.registeredProjects.allSatisfy({ $0.sourceID == sourceIDs[$0.id] }) else {
        throw GatewayDatabaseError.configurationChanged
      }
      try GatewayConfigurationPaths.save(
        platformRules ?? paths.pathRules,
        key: GatewayConfigurationPaths.platformKey, database: database)
      if let configurationRules {
        try GatewayConfigurationPaths.save(
          configurationRules, key: GatewayConfigurationPaths.configurationKey, database: database)
      }
      var environment = ledger.environment
      var merged = environment.paths ?? paths
      let previous = merged.registeredProjects
      try merged.setProjects(
        paths.registeredProjects.map { proposed in
          previous.first {
            $0.id == proposed.id && $0.root == proposed.root && $0.sourceID == proposed.sourceID
          } ?? proposed
        })
      merged.pathRules = Set(
        paths.pathRules.map { proposed in
          environment.paths?.pathRules.first {
            $0.root == proposed.root && $0.kind == proposed.kind
          } ?? proposed
        })
      environment.paths = merged
      environment.trustedHosts = Set(
        trustedHosts.map { proposed in
          environment.trustedHosts.first { $0.host == proposed.host } ?? proposed
        })
      if environment != ledger.environment {
        _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      } else {
        _ = ledger.reconcileExecutionLimits(now: Date())
      }
      try Self.reconcileStandingConsents(database: database, ledger: &ledger)
    }
    onAuthorityChange()
  }

  package func validateAuthorization(_ id: UUID) throws {
    let result: Result<Void, any Error> = try store.transactionWithDatabase { _, ledger in
      Result {
        do { _ = try ledger.invocationAccess(id) } catch {
          guard let proof = ledger.authorizations[id], let executionID = proof.executionID,
            ledger.executionAccess(
              executionID, principal: proof.invocation.principal,
              operation: .readResult, now: Date()) == .allowed
          else { throw error }
        }
      }
    }
    try result.get()
  }

  package func finishInvocation(_ id: UUID) throws {
    try store.transactionWithDatabase { _, ledger in try ledger.finishInvocation(id) }
  }

  package func declineRequest(
    _ id: UUID, owner: GatewayPermissionOwner, expectedRevision: UInt64, now: Date = Date()
  ) throws -> RevocationResult {
    try transactionWithPolicy { database, ledger, _ in
      try owner.authorize()
      try Self.requireRevision(expectedRevision, database: database)
      guard let request = ledger.requests[id] else { throw PermissionModelError.unknownRequest }
      let binding = try Self.binding(request.invocation.principal, database: database)
      let result = try ledger.retireRequest(id, expectedRevision: ledger.revision)
      try GatewayPermissionAudit.record(
        "deny", capabilityID: "permissions.answer", owner: owner,
        database: database, ledger: ledger, profileIDs: [binding.profileID],
        request: request, expectedRevision: expectedRevision, now: now)
      return result
    }
  }

  /// Evaluation uses a copy: pending requests and one-time grants remain untouched.
  package func probe(
    subject: GatewayPermissionSubject, tool: String, projectID: String?, argumentsDigest: String,
    requirements: InvocationRequirements, connectionID: String?,
    skillLibraries: [GatewaySkillLibraryRequirement] = []
  ) throws -> AuthorizationDecision {
    try transactionWithPolicy { database, ledger, policies in
      _ = try Self.bind(subject, database: database)
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: Date())
      let profile = try Self.profile(
        subject.profileID, database: database, epoch: ledger.authorizationEpochID)
      guard profile.allowedCallers.contains(subject.caller) else {
        throw GatewayPermissionError.invalidBinding
      }
      try Self.synchronize(
        profile, principal: subject.principal, requestedProject: requirements.sandboxProjectID,
        ledger: &ledger)
      var preview = ledger
      if requirements.mode != .sandbox && !profile.fullAccess {
        return .denied(.fullAccessRequired)
      }
      let selected = GatewaySkillLibraryRequirement.selecting(
        skillLibraries, requirements: requirements, ledger: ledger,
        principal: subject.principal, connectionID: connectionID)
      return try preview.authorize(
        invocation: InvocationIdentity(
          principal: subject.principal, tool: tool, projectID: projectID,
          argumentsDigest: argumentsDigest),
        requirements: selected, connectionID: connectionID, now: Date())
    }
  }
}

extension ManagedPolicy {
  package func narrows(_ previous: ManagedPolicy) -> Bool {
    guard !allowsFullAccess || previous.allowsFullAccess,
      previous.deniedReadLocations.allSatisfy({ old in
        deniedReadLocations.contains { $0.contains(old) }
      })
    else { return false }
    func ceiling(_ permissions: Permissions, for permission: Permission) -> PermissionState? {
      if let explicit = permissions.entries[permission] { return explicit }
      let fallback: Permission
      switch permission {
      case .project: fallback = .project("*")
      case .plugin: fallback = .plugin("*")
      case .mcpServer: fallback = .mcpServer("*")
      default: return nil
      }
      return permissions.entries[fallback]
    }
    let permissions = Set(previous.permissionCeilings.entries.keys).union(
      permissionCeilings.entries.keys)
    for permission in permissions {
      guard let old = ceiling(previous.permissionCeilings, for: permission) else { continue }
      guard let proposed = ceiling(permissionCeilings, for: permission) else { return false }
      switch (old, proposed) {
      case (_, .denied), (_, .notGranted): break
      case (.granted(let old), .granted(let new))
      where old == new || (new == .read && (old == .all || old == .write)): break
      default: return false
      }
    }
    let ceilings: [(Int64?, Int64?)] = [
      (executionLimits.timeMilliseconds, previous.executionLimits.timeMilliseconds),
      (executionLimits.outputBytes, previous.executionLimits.outputBytes),
      (executionLimits.memoryBytes, previous.executionLimits.memoryBytes),
      (executionLimits.retentionSeconds, previous.executionLimits.retentionSeconds),
      (executionLimits.retainedOutputBytes, previous.executionLimits.retainedOutputBytes),
    ]
    guard
      ceilings.allSatisfy({ current, old in
        old.map { ceiling in current.map { $0 <= ceiling } ?? false } ?? true
      })
    else { return false }
    if previous.network.configuration == .full { return true }
    if network.configuration == .none { return true }
    if network.configuration == previous.network.configuration { return true }
    let old = previous.network.configuration
    let new = network.configuration
    guard case .custom(let proposed, let includeTrusted) = new else { return false }
    switch old {
    case .none: return proposed.isEmpty && !includeTrusted
    case .trusted: return proposed.isEmpty
    case .custom(let hosts, let trusted):
      return (!includeTrusted || trusted)
        && proposed.allSatisfy { host in hosts.contains { NetworkHost.contains($0, rule: host) } }
    case .full: return true
    }
  }
}

package struct GatewayToolVisibilityRequirement: Sendable {
  package let actions: [PermissionAction]
  package let requiresFullAccess: Bool
}

extension GatewayPermissionService {
  /// A catalog uses one current profile and policy snapshot for all of its tools.
  package func canRequest(
    subject: GatewayPermissionSubject, requirements: [GatewayToolVisibilityRequirement],
    connectionID: String?
  ) throws -> [Bool] {
    try transactionWithPolicy { database, ledger, policies in
      _ = try Self.bind(subject, database: database)
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: Date())
      let profile = try Self.profile(
        subject.profileID, database: database, epoch: ledger.authorizationEpochID)
      guard profile.allowedCallers.contains(subject.caller) else {
        return requirements.map { _ in false }
      }
      try Self.synchronize(
        profile, principal: subject.principal, requestedProject: nil, ledger: &ledger)
      var limits = ledger.environment.limits[subject.principal] ?? ManagedLimits()
      if let connectionID {
        guard let connection = ledger.environment.connections[connectionID],
          connection.principal == subject.principal,
          !ledger.environment.endedConnections.contains(connectionID)
        else { throw GatewayPermissionError.invalidBinding }
        limits = ManagedLimits(
          sources: limits.sources.merging([.connection: .available(connection.attenuation)]) {
            _, next in next
          })
      }
      return requirements.map { requirement in
        limits.sources.values.allSatisfy { source in
          switch source {
          case .absent: return true
          case .unreadable: return false
          case .available(let policy):
            return !requirement.requiresFullAccess || policy.allowsFullAccess
          }
        }
          && requirement.actions.allSatisfy {
            limits.restrictingSources(for: $0.requirement).isEmpty
          }
      }
    }
  }
}
