import Foundation

/// Standing permissions, path authority, sandbox policy and connection ceilings
/// are constant within one fixed-point pass. Request, consent and execution
/// dependencies stay live.
private final class BasisValidationMemo {
  private struct Key: Hashable {
    let path: PathAccessBasis
    let principal: Principal
    let mode: ExecutionMode
    let connectionID: String?
    let ceiling: BasisIdentity?
  }
  private var results: [Key: Bool] = [:]

  private struct StandingGrantKey: Hashable {
    let grant: PermissionGrant
    let principal: Principal
    let mode: ExecutionMode
    let connectionID: String?
    let ceiling: BasisIdentity?
  }
  private var standingGrantResults: [StandingGrantKey: Bool] = [:]

  private struct ResolutionKey: Hashable {
    let requirements: InvocationRequirements
    let principal: Principal
    let basis: Set<AuthorizationBasis>
  }
  private var resolutions: [ResolutionKey: InvocationResolution] = [:]

  private struct SandboxKey: Hashable {
    let basis: SandboxAccessBasis
    let principal: Principal
    let connectionID: String?
  }
  private var sandboxResults: [SandboxKey: Bool] = [:]

  func resolve(
    _ requirements: InvocationRequirements, principal: Principal,
    basis: Set<AuthorizationBasis>, operation: () -> InvocationResolution
  ) -> InvocationResolution {
    let key = ResolutionKey(requirements: requirements, principal: principal, basis: basis)
    if let result = resolutions[key] { return result }
    let result = operation()
    resolutions[key] = result
    return result
  }

  func validate(
    _ path: PathAccessBasis, principal: Principal, mode: ExecutionMode,
    connectionID: String?, ceiling: BasisIdentity?, operation: () -> Bool
  ) -> Bool {
    let key = Key(
      path: path, principal: principal, mode: mode, connectionID: connectionID, ceiling: ceiling)
    if let result = results[key] { return result }
    let result = operation()
    results[key] = result
    return result
  }

  func validateStandingGrant(
    _ grant: PermissionGrant, principal: Principal, mode: ExecutionMode,
    connectionID: String?, ceiling: BasisIdentity?, operation: () -> Bool
  ) -> Bool {
    let key = StandingGrantKey(
      grant: grant, principal: principal, mode: mode, connectionID: connectionID, ceiling: ceiling)
    if let result = standingGrantResults[key] { return result }
    let result = operation()
    standingGrantResults[key] = result
    return result
  }

  func validateSandbox(
    _ basis: SandboxAccessBasis, principal: Principal, connectionID: String?,
    operation: () -> Bool
  ) -> Bool {
    let key = SandboxKey(basis: basis, principal: principal, connectionID: connectionID)
    if let result = sandboxResults[key] { return result }
    let result = operation()
    sandboxResults[key] = result
    return result
  }
}

package enum PermissionAnswer: Sendable {
  case onlyThisTime, always
}

package struct ProjectRegistrationRequest: Hashable, Sendable, Codable {
  package let principal: Principal
  /// The host reserves this identity before evaluating policy or recording the request.
  package let projectID: String
  package let path: CanonicalPath
  package let access: PermissionValue

  package init(
    principal: Principal, projectID: String, path: CanonicalPath, access: PermissionValue
  ) throws {
    guard !projectID.isEmpty, projectID != "*" else { throw PermissionModelError.invalidObject }
    guard access == .read || access == .write else {
      throw PermissionModelError.invalidPermissionValue
    }
    self.principal = principal
    self.projectID = projectID
    self.path = path
    self.access = access
  }
}

package enum ProjectRegistrationDecision: Equatable, Sendable {
  case request(PermissionRequest)
  case registered(String)
  case denied(DenialReason)
}

package enum RequestContent: Equatable, Sendable, Codable {
  case permission(PermissionRequestContent)
  case network(NetworkRequestContent)
  case projectRegistration(ProjectRegistrationRequest)

  var principal: Principal {
    switch self {
    case .permission(let content): content.principal
    case .network(let content): content.principal
    case .projectRegistration(let content): content.principal
    }
  }
}

package enum RequestStatus: Equatable, Sendable, Codable {
  case pending, onlyThisTime, always, declined, revoked
  case consumed(UUID)
  case registered(String)

  var isUnconsumed: Bool {
    switch self {
    case .pending, .onlyThisTime, .always: true
    default: false
    }
  }
}

package struct PermissionRequest: Equatable, Sendable, Codable {
  package let identity: BasisIdentity
  package var id: UUID { identity.id }
  package let invocation: InvocationIdentity
  package let content: RequestContent
  package let requirements: InvocationRequirements
  package let createdAt: Date
  /// Selected grant/path provenance and dependencies shared by the call's requests.
  /// Answering a request binds its condition to the chosen grant.
  var basis: Set<AuthorizationBasis>
  /// Last standing value while unconsumed; lowering it retires the outstanding request.
  var observedPermission: PermissionState = .notGranted
  package internal(set) var permitIdentity: BasisIdentity?
  package var expiresAt: Date { createdAt.addingTimeInterval(86_400) }
  package internal(set) var status: RequestStatus

  var requirement: PermissionRequirement? {
    switch content {
    case .permission(let content): content.requirement
    case .projectRegistration(let content):
      try! PermissionRequirement(.project(content.projectID), content.access)
    case .network: nil
    }
  }

  init(
    identity: BasisIdentity, invocation: InvocationIdentity, content: RequestContent, now: Date,
    requirements: InvocationRequirements, basis: Set<AuthorizationBasis>
  ) {
    self.identity = identity
    self.invocation = invocation
    self.content = content
    self.requirements = requirements
    self.createdAt = now
    self.basis = basis
    self.status = .pending
  }
}

package struct InvocationAuthorization: Equatable, Sendable, Codable {
  package let identity: BasisIdentity
  package var id: UUID { identity.id }
  package let invocation: InvocationIdentity
  package let requirements: InvocationRequirements
  package var actions: [PermissionAction] { requirements.permissionActions }
  package var mode: ExecutionMode { requirements.mode }
  package var requestIDs: Set<UUID> { Set(basis.compactMap(\.requestID)) }
  /// Source project for settings; the invocation retains the actual project used by the retry.
  package var sandboxProjectID: String? { requirements.sandboxProjectID }
  package internal(set) var basis: Set<AuthorizationBasis>
  /// Persisted consumption: completion and result retention never clear this binding.
  package internal(set) var executionID: UUID?
  var finished = false
  var revoked = false
  var revokesRetries = false
}

package enum AuthorizationDecision: Equatable, Sendable {
  case allowed(InvocationAuthorization)
  case requests([PermissionRequest])
  case denied(DenialReason)
}

package enum ExecutionOperation: Sendable {
  case readResult, writeInput, cancel
  /// Authorize a protocol stop request without claiming or forcing native termination.
  case requestCancellation
}

package struct AuthorizedExecution: Equatable, Sendable, Codable {
  package let id: UUID
  package let owner: Principal
  package let delegatedTo: PluginIdentity?
  package let authorizationIDs: Set<UUID>
  package let startedAt: Date
  package let limitRequest: ExecutionLimitRequest
  package let limitCapabilities: ExecutionLimitCapabilities
  package internal(set) var limits: EffectiveExecutionLimits
  package internal(set) var limitEndReason: ExecutionLimitEndReason?
  package internal(set) var endedAt: Date?
  package internal(set) var isRunning = true
  package internal(set) var retainUntil: Date?
  package internal(set) var revoked = false
  package internal(set) var interruptedAt: Date?
}

package struct RevocationResult: Equatable, Sendable {
  /// Snapshot of the ledger's unacknowledged termination queue, including earlier changes.
  package let executionsToTerminate: Set<UUID>
}

/// Value state changed only inside a store transaction. The store owns atomicity
/// across answering, granting, consuming a retry and recording execution provenance.
///
/// Authority boundary:
/// - Environment, permission and sandbox edits carry the revision of their ledger
///   read. Record UUIDs/generations are checked in their owning collection; content
///   is compared before the ledger allocates replacements. Drafts hold no authority.
/// - Request, permit, consent, authorization and execution identities are allocated
///   here. Supplied UUIDs only select stored records; status, expiry, requirements,
///   delegation and consumption are checked against those records.
/// - Consent is issued for a principal and its committed profile; reconciliation
///   checks issuance, and evaluation checks the profile and connection lifetime.
/// - Principal/project/connection keys, canonical paths, classifications, resolved
///   network facts, action declarations, argument digests and time are host-adapter
///   facts. The library validates their model shape, graph, scope, matching and
///   policy consequences; the adapter authenticates/resolves them before submission.
/// - Codable restores trusted durable state, including counters, transaction tokens
///   and consumption. It is not an import format for caller-supplied authority.
package struct PermissionLedger: Equatable, Sendable, Codable {
  package private(set) var authorizationEpochID: UUID?
  package private(set) var suspendedAuthority: SuspendedPermissionAuthority?
  package private(set) var pendingEpochRecovery: AuthorizationEpochRecovery?
  private var runtimeChains: [UUID: RuntimeRetryChain] = [:]
  private var runtimeSuccessors: [UUID: Set<UUID>] = [:]
  private var retryOrigins: [UUID: InvocationRequirements] = [:]
  private var transactionIdentity: UUID?
  private var issuedConsents: [Principal: Set<ModeConsent>] = [:]
  package internal(set) var revision: UInt64 = 0
  private var rules: [Principal: Permissions] = [:]
  package private(set) var requests: [UUID: PermissionRequest] = [:]
  package private(set) var authorizations: [UUID: InvocationAuthorization] = [:]
  package private(set) var executions: [UUID: AuthorizedExecution] = [:]
  package private(set) var sandboxSettings = ProjectSandboxSettings()
  /// Running executions that lost authority, persisted with their revocation.
  /// Reading, reconciliation and execution completion leave these IDs pending until
  /// the host confirms termination. Delivery is at least once; IDs are never reused.
  package private(set) var pendingExecutionTerminations: Set<UUID> = []

  package private(set) var environment = PermissionEnvironment()
  private var retiredConsents: Set<BasisIdentity> = []
  private var currentLimits: [Principal: ManagedLimits] { environment.limits }
  private var trustedHosts: Set<HostRule> { environment.trustedHosts }
  private func permitsHostContent(_ path: CanonicalPath, projectID: String?) -> Bool {
    guard let paths = environment.paths else { return true }
    return !paths.registeredProjects.contains {
      $0.hostContentIdentity != nil && $0.root.contains(path) && $0.id != projectID
    }
  }

  private var pathResolver: PathPermissions<PathEnvironmentSnapshot>? {
    environment.paths.map(PathPermissions.init)
  }

  package init() {}

  /// Persistence calls this only after detecting a missing or mismatched external
  /// watermark. It rotates the snapshot token and retires all transient authority.
  package mutating func beginAuthorizationEpoch(_ epochID: UUID) {
    authorizationEpochID = epochID
    pendingEpochRecovery = AuthorizationEpochRecovery(
      epochID: epochID,
      executionsToTerminate: Set(executions.values.filter(\.isRunning).map(\.id))
        .union(pendingExecutionTerminations)
        .union(pendingEpochRecovery?.executionsToTerminate ?? []))
    let principals = Set(rules.keys).union(environment.limits.keys)
      .union(sandboxSettings.entries.keys.map(\.principal))
      .union(sandboxSettings.providers.keys.map { Principal.plugin($0) })
    if suspendedAuthority == nil {
      suspendedAuthority = SuspendedPermissionAuthority(
        permissions: rules,
        ownerPolicies: Dictionary(
          uniqueKeysWithValues: principals.map {
            ($0, environment.limits[$0]?.sources[.owner] ?? .absent)
          }), sandboxSettings: sandboxSettings)
    }
    rules = Dictionary(uniqueKeysWithValues: principals.map { ($0, Permissions()) })
    for principal in principals {
      var limits = environment.limits[principal] ?? .init()
      limits.sources[.owner] = .unreadable
      for (source, availability) in limits.sources where source != .owner {
        if case .available = availability { limits.sources[source] = .unreadable }
      }
      environment.limits[principal] = limits
    }
    sandboxSettings = .init()
    requests = [:]
    authorizations = [:]
    executions = [:]
    runtimeChains = [:]
    runtimeSuccessors = [:]
    retryOrigins = [:]
    pendingExecutionTerminations = []
    issuedConsents = [:]
    retiredConsents = []
    environment.modes = [:]
    environment.connections = [:]
    environment.endedConnections = []
    environment.trustedHosts = []
    environment.providerRequirements = nil
    transactionIdentity = allocateIdentity().id
  }

  /// Local owner confirmation restores saved standing authority with fresh grant
  /// identities. It cannot restore old requests, consent or execution access.
  /// Machine policy adapters must separately refresh any suspended source.
  package mutating func confirmSuspendedAuthority(epochID: UUID, expectedRevision: UInt64) throws {
    guard authorizationEpochID == epochID else { throw PermissionModelError.revisionConflict }
    try commit(expectedRevision: expectedRevision) { ledger in
      guard let suspended = ledger.suspendedAuthority else { return }
      for (principal, saved) in suspended.permissions {
        var fresh = Permissions()
        for (permission, state) in saved.entries { try fresh.set(state, for: permission) }
        try fresh.commit(against: ledger.rules[principal], in: &ledger)
        ledger.rules[principal] = fresh
      }
      for (key, saved) in suspended.sandboxSettings.entries {
        var fresh = SandboxSettings(
          network: saved.network.freshDraft(),
          deniedReadLocations: saved.deniedReadLocations)
        try fresh.commit(against: nil, in: &ledger)
        ledger.sandboxSettings.entries[key] = fresh
      }
      var environment = ledger.environment
      for principal in environment.limits.keys where suspended.ownerPolicies[principal] == nil {
        environment.limits[principal]!.sources[.owner] = .absent
      }
      for (principal, saved) in suspended.ownerPolicies {
        switch saved {
        case .available(let policy):
          var ceilings = Permissions()
          for (permission, state) in policy.permissionCeilings.entries {
            try ceilings.set(state, for: permission)
          }
          environment.limits[principal, default: .init()].sources[.owner] = .available(
            ManagedPolicy(
              permissionCeilings: ceilings, allowsFullAccess: policy.allowsFullAccess,
              network: policy.network.freshDraft(), deniedReadLocations: policy.deniedReadLocations,
              executionLimits: policy.executionLimits))
        case .absent, .unreadable:
          environment.limits[principal, default: .init()].sources[.owner] = saved
        }
      }
      try environment.commit(against: ledger.environment, in: &ledger)
      ledger.environment = environment
      ledger.issuedConsents = [:]
      ledger.retiredConsents = []
      ledger.environment.modes = [:]
      ledger.environment.endedConnections.formUnion(ledger.environment.connections.keys)
      ledger.environment.connections = [:]
      ledger.suspendedAuthority = nil
    }
  }

  /// Acknowledge only after stopping all runtime work from other epochs. A stale
  /// runtime cannot acknowledge a newer recovery, even if it knew the same IDs.
  package mutating func acknowledgeEpochRecovery(_ epochID: UUID) throws {
    guard pendingEpochRecovery?.epochID == epochID else {
      throw PermissionModelError.revisionConflict
    }
    pendingEpochRecovery = nil
    _ = allocateIdentity()
  }

  private var authorityIsSuspended: Bool {
    suspendedAuthority != nil || pendingEpochRecovery != nil
  }

  /// Validates codec shape and durable cross-references before any authority is
  /// evaluated. Revoked records may retain obsolete grant provenance, but never
  /// dangling request, permit, authorization or execution references.
  package func validatePersistedState() throws {
    func valid(_ identity: BasisIdentity) -> Bool {
      identity.generation > 0 && identity.generation <= revision && !identity.isEdited
    }
    func validBasis(_ basis: Set<AuthorizationBasis>) -> Bool {
      basis.allSatisfy { element in
        switch element {
        case .execution(let id): return executions[id] != nil
        case .worktreeAuthority(let id): return authorizations[id] != nil
        case .request(let identity): return requests[identity.id]?.identity == identity
        case .permit(let request, let permit):
          return requests[request.id]?.identity == request
            && requests[request.id]?.permitIdentity == permit
        case .permission(let grant), .managedPermission(_, let grant):
          if case .onlyThisTime(let request, let permit) = grant.source {
            return requests[request.id]?.identity == request
              && requests[request.id]?.permitIdentity == permit
              && requests[request.id]?.content.principal == grant.principal
          }
          return true
        case .retryOrigin(let identity): return authorizations[identity.id]?.identity == identity
        default: return true
        }
      }
    }
    guard revision < UInt64(Int64.max),
      pendingEpochRecovery.map({ $0.epochID == authorizationEpochID }) ?? true,
      requests.allSatisfy({ id, request in
        guard id == request.id, valid(request.identity),
          request.invocation.principal == request.content.principal,
          request.permitIdentity.map(valid) ?? true, validBasis(request.basis)
        else { return false }
        switch request.status {
        case .onlyThisTime, .always: return request.permitIdentity != nil
        case .consumed(let id):
          return request.permitIdentity != nil
            && authorizations[id]?.requestIDs.contains(request.id) == true
            && authorizations[id]?.invocation == request.invocation
        default: return true
        }
      }),
      authorizations.allSatisfy({ id, proof in
        guard id == proof.id, valid(proof.identity), validBasis(proof.basis),
          proof.basis.allSatisfy({ element in
            guard case .worktreeAuthority(let parentID) = element else { return true }
            guard let parent = authorizations[parentID] else { return false }
            return proof.executionID == nil && parentID != id && parent.executionID != nil
              && parent.invocation.principal == proof.invocation.principal
              && parent.invocation.projectID == proof.invocation.projectID
              && parent.sandboxProjectID == proof.sandboxProjectID
          })
        else { return false }
        return proof.executionID.map { executions[$0]?.authorizationIDs.contains(id) == true }
          ?? true
      }),
      executions.allSatisfy({ id, execution in
        id == execution.id && !execution.authorizationIDs.isEmpty
          && execution.authorizationIDs.allSatisfy { authorizations[$0]?.executionID == id }
          && execution.authorizationIDs.contains {
            authorizations[$0]?.invocation.principal == execution.owner
          }
      }),
      pendingExecutionTerminations.isSubset(of: Set(executions.keys)),
      runtimeChains.allSatisfy({ id, chain in
        requests[id]?.invocation == chain.invocation
          && requests[id]?.requirements == chain.requirements
          && chain.carriedIDs.allSatisfy { requests[$0]?.invocation == chain.invocation }
      }),
      runtimeSuccessors.allSatisfy({ id, requests in
        authorizations[id] != nil && requests.allSatisfy { runtimeChains[$0] != nil }
      }),
      retryOrigins.keys.allSatisfy({ authorizations[$0] != nil })
    else {
      throw PermissionModelError.invalidAuthorization
    }
  }

  /// Stores call this against their current durable ledger before committing a
  /// transaction. The persisted token rejects replacement with a stale or foreign
  /// whole-ledger snapshot, including snapshots with unused authorization copies.
  package mutating func commitTransaction(replacing current: PermissionLedger) throws {
    guard transactionIdentity == current.transactionIdentity, revision >= current.revision else {
      throw PermissionModelError.revisionConflict
    }
    transactionIdentity = allocateIdentity().id
  }

  /// Call in a store transaction after confirming termination. Unknown or already
  /// acknowledged IDs are harmless; acknowledgements cannot restore authority.
  package mutating func acknowledgeExecutionTerminations(_ ids: Set<UUID>) {
    pendingExecutionTerminations.subtract(ids)
  }

  /// Selects aggregate library candidates without issuing requests or authority.
  /// Skills itself is admitted with the complete selected paths, preserving exact retries.
  package func permitsSkillLibrary(
    _ root: CanonicalPath, pluginID: String?, principal: Principal,
    mode: ExecutionMode, sandboxProjectID: String?, connectionID: String?
  ) -> Bool {
    let actions =
      pluginID.map {
        [PermissionAction(requirement: try! PermissionRequirement(.plugin($0), .use))]
      } ?? []
    let requirements = InvocationRequirements(
      actions: actions,
      paths: [.init(path: root, operation: .read, purpose: .skillLibrary(root: root))],
      mode: mode, sandboxProjectID: sandboxProjectID)
    let resolution = evaluate(
      requirements, principal: principal, connectionID: connectionID, admission: true)
    return resolution.denial == nil
      && resolution.missing.allSatisfy {
        if case .permission(let request) = $0 { return request.requirement.permission == .skills }
        return false
      }
  }

  package func permissions(for principal: Principal) -> Permissions {
    rules[principal] ?? (authorityIsSuspended ? Permissions() : .newPrincipal)
  }

  package mutating func register(_ principal: Principal) {
    guard !authorityIsSuspended, rules[principal] == nil else { return }
    var permissions = Permissions.newPrincipal
    try! permissions.commit(against: nil, in: &self)
    rules[principal] = permissions
  }

  /// Changes the standing rule. Editing a grant invalidates its recorded generation;
  /// a later grant cannot restore executions that have already lost authority.
  /// Denial retires related requests, including consumed grants. Lowering a standing
  /// value also retires unconsumed requests; consumed one-time grants have their own lifetime.
  @discardableResult
  package mutating func setPermission(
    _ state: PermissionState, for permission: Permission, principal: Principal,
    expectedRevision: UInt64
  ) throws -> RevocationResult {
    guard expectedRevision == revision else { throw PermissionModelError.revisionConflict }
    var permissions = permissions(for: principal)
    try permissions.set(state, for: permission)
    return try setPermissions(permissions, for: principal, expectedRevision: expectedRevision)
  }

  /// Commits an edited permission snapshot using the revision from its ledger read.
  @discardableResult
  package mutating func setPermissions(
    _ permissions: Permissions, for principal: Principal, expectedRevision: UInt64
  ) throws -> RevocationResult {
    guard suspendedAuthority == nil else { throw PermissionModelError.authoritySuspended }
    return try commit(expectedRevision: expectedRevision) { ledger in
      var permissions = permissions
      try permissions.commit(against: ledger.rules[principal], in: &ledger)
      ledger.rules[principal] = permissions
      return ledger.propagateRevocations()
    }
  }

  /// The caller supplies every requirement for the invocation, including delegation
  /// and all permissions used to construct a program's sandbox profile.
  /// Path scopes require a reconciled path environment; its decision cannot be replaced
  /// by a one-time grant. Derived invocations keep their identity but use source settings.
  /// Failed retry validation retires its requests. In a store transaction, catch
  /// validation errors and return them as values so that retirement commits.
  package mutating func authorize(
    invocation: InvocationIdentity, actions: [PermissionAction],
    networks: [NetworkRequirement] = [],
    retryIDs: Set<UUID> = [], sourceProjectID: String? = nil, connectionID: String? = nil, now: Date
  ) throws -> AuthorizationDecision {
    let resolvedSource = invocation.projectID.flatMap { pathResolver?.sourceProjectID(for: $0) }
    let requirements = InvocationRequirements(
      actions: actions, networks: networks,
      mode: selectedConsent(principal: invocation.principal, connectionID: connectionID)?.mode
        ?? .sandbox,
      sandboxProjectID: sourceProjectID ?? resolvedSource ?? invocation.projectID)
    return try authorize(
      invocation: invocation, requirements: requirements, retryIDs: retryIDs,
      connectionID: connectionID, now: now)
  }

  /// A request matches only the same invocation and exactly equal requirements.
  /// IDs for different requirements supply no authority and the call is evaluated afresh.
  package mutating func authorize(
    invocation: InvocationIdentity, requirements: InvocationRequirements,
    retryIDs: Set<UUID> = [], connectionID: String? = nil,
    callbackExecutionID: UUID? = nil, now: Date
  ) throws -> AuthorizationDecision {
    guard !authorityIsSuspended else { return .denied(.authoritySuspended) }
    if requirements.paths.contains(where: {
      !permitsHostContent($0.path, projectID: invocation.projectID)
    }) {
      return .denied(.hostData)
    }
    let originalRequirements = requirements
    let expanded = try runtimeRetry(
      invocation: invocation, requirements: requirements, ids: retryIDs)
    let requirements = expanded.requirements
    let retryIDs = expanded.ids
    propagateRevocations(now: now)
    if let source = requirements.sandboxProjectID,
      let resolved = invocation.projectID.flatMap({ pathResolver?.sourceProjectID(for: $0) }),
      source != resolved
    {
      throw PermissionModelError.invalidProjectGraph
    }
    register(invocation.principal)
    let preliminary = evaluate(
      requirements,
      principal: invocation.principal, connectionID: connectionID, admission: true)
    if let denial = preliminary.denial, denial != .authorizationRevoked,
      denial != .fullAccessRequiresConsent
    {
      return .denied(denial)
    }
    let retries = try matchingRetries(
      retryIDs, invocation: invocation, requirements: requirements, now: now)
    defer { propagateRevocations() }
    var inherited = inheritedBasis(retries)
    guard
      inherited.allSatisfy({
        if case .execution(let id) = $0 { return id == callbackExecutionID }
        return true
      })
    else { throw PermissionModelError.invalidAuthorization }
    if let callbackExecutionID {
      guard let execution = executions[callbackExecutionID], execution.delegatedTo != nil,
        executionIsLive(callbackExecutionID),
        execution.authorizationIDs.contains(where: {
          authorizations[$0]?.invocation.principal == invocation.principal
            && authorizations[$0]?.invocation.projectID == invocation.projectID
        })
      else { throw PermissionModelError.invalidAuthorization }
      inherited.insert(.execution(callbackExecutionID))
    }
    let borrowed = callbackRequests(inherited, principal: invocation.principal)
    let admittedRequests = retries + borrowed
    let resolution = evaluate(
      requirements,
      principal: invocation.principal,
      oneTimeRequests: admittedRequests,
      basis: inherited, connectionID: connectionID, admission: true)
    let retriesValid = validateRetries(
      retries,
      basis: inherited,
      requirements: requirements,
      now: now)
    if let denial = resolution.denial { return .denied(denial) }
    guard retriesValid else { throw PermissionModelError.invalidAuthorization }
    // Union preserves every inherited source and adds the complete admission proof.
    var basis = inherited.union(resolution.basis)
    let missingContents = resolution.missing
    if !missingContents.isEmpty { basis = basis.requestEvidence }
    if retries.isEmpty && !missingContents.isEmpty {
      for candidate in requests.values
      where candidate.status == .pending && candidate.invocation == invocation
        && candidate.requirements == requirements
      {
        let group = candidate.basis.compactMap(\.requestID).compactMap { requests[$0] }
        guard group.count == missingContents.count,
          group.allSatisfy({
            $0.status == .pending && now < $0.expiresAt && missingContents.contains($0.content)
          }),
          candidate.basis.subtracting(group.map { .request($0.identity) }) == basis
        else { continue }
        return .requests(
          missingContents.compactMap { content in group.first { $0.content == content } })
      }
    }
    if inherited.compactMap(\.requestID).compactMap({ requests[$0] }).contains(where: {
      $0.status == .onlyThisTime && missingContents.contains($0.content)
    }) {
      throw PermissionModelError.invalidAuthorization
    }
    let missing = missingContents.map { content in
      if let pending = basis.compactMap(\.requestID).compactMap({ requests[$0] }).first(where: {
        $0.status == .pending && $0.content == content
      }) {
        return pending
      }
      return record(
        content, invocation: invocation, now: now, requirements: requirements, basis: basis)
    }
    if !missing.isEmpty {
      basis.formUnion(missing.map { .request($0.identity) })
      for id in basis.compactMap(\.requestID) {
        if requests[id]?.requirements == requirements {
          requests[id]!.basis.formUnion(basis.requestEvidence)
        }
      }
      let carried = Set(
        basis.compactMap(\.requestID).filter { requests[$0]?.status == .onlyThisTime })
      if !carried.isEmpty {
        let chain = RuntimeRetryChain(
          invocation: invocation, originalRequirements: originalRequirements,
          requirements: requirements, carriedIDs: carried)
        for request in missing { runtimeChains[request.id] = chain }
      }
      return .requests(missing.map { requests[$0.id]! })
    }
    try requireAnsweredDependencies(basis, retryIDs: Set(retries.map(\.id)))
    for id in basis.compactMap(\.requestID) where requests[id]?.status == .onlyThisTime {
      requests[id]!.basis.formUnion(basis.requestEvidence)
    }
    if let connectionID,
      let connection = activeConnection(connectionID, principal: invocation.principal)
    {
      basis = restricting(
        basis, by: connection.attenuation, requirements: requirements,
        principal: invocation.principal, requests: admittedRequests)
    }
    let identity = allocateIdentity()
    let id = identity.id
    consumeRetries(retries, authorizationID: id)
    let authorization = InvocationAuthorization(
      identity: identity, invocation: invocation, requirements: requirements, basis: basis)
    authorizations[id] = authorization
    retryOrigins[id] = originalRequirements
    guard
      isValid(authorization)
    else { throw PermissionModelError.invalidAuthorization }
    propagateRevocations()
    return .allowed(authorization)
  }

  /// Project IDs here identify source projects; adapters resolve derived projects
  /// through `ProjectCatalog` before reading or updating their shared settings.
  package mutating func setSandboxSettings(
    _ settings: SandboxSettings, for key: SandboxSettingsKey, expectedRevision: UInt64
  ) throws -> RevocationResult {
    guard suspendedAuthority == nil else { throw PermissionModelError.authoritySuspended }
    guard settings.readExceptions.isEmpty else { throw PermissionModelError.invalidAuthorization }
    if case .plugin(let identity) = key.principal, sandboxSettings.providers[identity] != nil {
      throw PermissionModelError.invalidAuthorization
    }
    return try commit(expectedRevision: expectedRevision) { ledger in
      var settings = settings
      try settings.commit(against: ledger.sandboxSettings.entries[key], in: &ledger)
      ledger.sandboxSettings.entries[key] = settings
      return ledger.propagateRevocations()
    }
  }

  /// Retry validation has the same transaction contract as `authorize`.
  package mutating func authorizeNetwork(
    invocation: InvocationIdentity, host: String, sourceProjectID: String, isLocalNetwork: Bool,
    retryIDs: Set<UUID> = [], pluginPurpose: String? = nil, connectionID: String? = nil, now: Date
  ) throws -> AuthorizationDecision {
    try authorize(
      invocation: invocation,
      requirements: InvocationRequirements(
        networks: [
          NetworkRequirement(
            host: host, projectID: sourceProjectID, isLocalNetwork: isLocalNetwork,
            pluginPurpose: pluginPurpose)
        ],
        mode: selectedConsent(principal: invocation.principal, connectionID: connectionID)?.mode
          ?? .sandbox,
        sandboxProjectID: sourceProjectID),
      retryIDs: retryIDs, connectionID: connectionID, now: now)
  }

  package mutating func revokeAuthorization(_ id: UUID) throws -> RevocationResult {
    guard authorizations[id] != nil else { throw PermissionModelError.unknownAuthorization }
    authorizations[id]!.revoked = true
    authorizations[id]!.revokesRetries = true
    return propagateRevocations()
  }

  package mutating func retireRequest(_ id: UUID, expectedRevision: UInt64) throws
    -> RevocationResult
  {
    try commit(expectedRevision: expectedRevision) { ledger in
      guard ledger.requests[id] != nil else { throw PermissionModelError.unknownRequest }
      ledger.requests[id]!.status = .revoked
      return ledger.propagateRevocations()
    }
  }

  /// Retiring a host-authenticated subject also retires transient authority that
  /// has no standing permission or connection record to revoke.
  package mutating func retirePrincipal(_ principal: Principal, expectedRevision: UInt64) throws
    -> RevocationResult
  {
    try commit(expectedRevision: expectedRevision) { ledger in
      for (id, request) in ledger.requests
      where request.invocation.principal == principal || request.content.principal == principal {
        ledger.requests[id]!.status = .revoked
      }
      for (id, authorization) in ledger.authorizations
      where authorization.invocation.principal == principal {
        ledger.authorizations[id]!.revoked = true
        ledger.authorizations[id]!.revokesRetries = true
      }
      for consent in ledger.issuedConsents[principal] ?? [] {
        ledger.retiredConsents.insert(consent.identity)
      }
      ledger.issuedConsents[principal] = nil
      return ledger.propagateRevocations()
    }
  }

  /// A source replacement ends work admitted to that source without withdrawing
  /// the owner's standing permission selection or Full access consent.
  package mutating func retireProviderExecutions(
    _ identity: PluginIdentity, expectedRevision: UInt64
  ) throws -> RevocationResult {
    try commit(expectedRevision: expectedRevision) { ledger in
      let principal = Principal.plugin(identity)
      for execution in ledger.executions.values
      where execution.authorizationIDs.contains(where: {
        ledger.authorizations[$0]?.invocation.principal == principal
      }) {
        for id in execution.authorizationIDs {
          ledger.authorizations[id]?.revoked = true
          ledger.authorizations[id]?.revokesRetries = true
        }
      }
      return ledger.propagateRevocations()
    }
  }

  /// Invalid dependency evidence retires the request. Catch validation errors
  /// inside store transactions so that retirement commits without granting access.
  @discardableResult
  package mutating func answer(
    _ id: UUID, with answer: PermissionAnswer, now: Date
  ) throws -> RevocationResult {
    guard !authorityIsSuspended else { throw PermissionModelError.authoritySuspended }
    var request = try pendingRequest(id, now: now)
    let limits = currentLimits[request.content.principal] ?? .init()
    defer { propagateRevocations() }
    guard
      basisRemainsValid(
        inheritedBasis([request]),
        requirements: request.requirements,
        principal: request.content.principal,
        now: now)
    else {
      requests[id]!.status = .revoked
      propagateRevocations()
      throw PermissionModelError.invalidAuthorization
    }
    switch request.content {
    case .permission(let content):
      guard limits.restrictingSources(for: content.requirement).isEmpty,
        permissions(for: content.principal).state(for: content.requirement.permission) != .denied
      else { throw PermissionModelError.invalidAuthorization }
      if case .always = answer,
        !permissions(for: content.principal).state(for: content.requirement.permission).allows(
          content.requirement.value)
      {
        try setPermission(
          .granted(content.requirement.value), for: content.requirement.permission,
          principal: content.principal, expectedRevision: revision)
      }
    case .network(let content):
      guard
        limits.restrictingNetwork(host: content.host, trustedHosts: Set(trustedHosts.map(\.host)))
          .isEmpty
      else {
        throw PermissionModelError.invalidAuthorization
      }
      if case .always = answer {
        if case .plugin(let identity) = content.principal,
          var provider = sandboxSettings.providers[identity]
        {
          var override = provider.projects[content.projectID] ?? .init()
          let network =
            override.network
            ?? provider.settings(sourceProjectID: content.projectID).network.freshDraft()
          override.network = network.adding(content.host)
          provider.projects[content.projectID] = override
          try provider.commit(against: sandboxSettings.providers[identity], in: &self)
          sandboxSettings.providers[identity] = provider
        } else {
          let key = SandboxSettingsKey(principal: content.principal, projectID: content.projectID)
          var settings = sandboxSettings.entries[key] ?? SandboxSettings()
          settings.network = settings.network.adding(content.host)
          try settings.commit(against: sandboxSettings.entries[key], in: &self)
          sandboxSettings.entries[key] = settings
        }
      }
    case .projectRegistration: throw PermissionModelError.invalidRegistrationAnswer
    }
    request.permitIdentity = allocateIdentity()
    if case .onlyThisTime = answer, case .permission(let content) = request.content {
      request.basis.insert(
        .permission(
          PermissionGrant(
            principal: content.principal, requirement: content.requirement, scope: content.scope,
            pluginPurpose: content.pluginPurpose,
            source: .onlyThisTime(request: request.identity, permit: request.permitIdentity!))))
    }
    if case .always = answer {
      switch request.content {
      case .permission(let content):
        request.basis.formUnion(
          PermissionEvaluation.resolveRequirement(
            principal: content.principal,
            action: PermissionAction(
              requirement: content.requirement, scope: content.scope,
              pluginPurpose: content.pluginPurpose),
            permissions: permissions(for: content.principal), mode: request.requirements.mode,
            limits: limits
          ).basis)
      case .network(let content):
        if let basis = networkBasis(content) {
          request.basis.insert(.network(basis))
        }
      case .projectRegistration: break
      }
    }
    request.status =
      switch answer {
      case .onlyThisTime: .onlyThisTime
      case .always: .always
      }
    requests[id] = request
    let inherited = inheritedBasis([request])
    let resolution = evaluate(
      request.requirements,
      principal: request.content.principal,
      oneTimeRequests: inheritedRequests([request]),
      basis: inherited)
    requests[id]!.basis.formUnion(resolution.basis)
    return propagateRevocations()
  }

  package mutating func requestProjectRegistration(
    _ content: ProjectRegistrationRequest, invocation: InvocationIdentity,
    now: Date
  ) throws -> ProjectRegistrationDecision {
    guard !authorityIsSuspended else { return .denied(.authoritySuspended) }
    propagateRevocations(now: now)
    guard let paths = environment.paths else { return .denied(.pathResolutionRequired) }
    guard content.principal == invocation.principal else {
      throw PermissionModelError.retryMismatch
    }
    register(content.principal)
    defer { propagateRevocations() }
    let existing = paths.projects.allLocations.first { $0.root == content.path }
    let projectID = existing?.projectID ?? content.projectID
    let evaluated = try ProjectRegistrationRequest(
      principal: content.principal,
      projectID: projectID, path: content.path, access: content.access)
    let resolution = evaluate(
      InvocationRequirements(registration: evaluated),
      principal: content.principal)
    if let denial = resolution.denial {
      return .denied(denial)
    }
    if let existing,
      permissions(for: content.principal).state(for: .project(existing.projectID)).allows(
        content.access)
    {
      return .registered(
        paths.registeredProjects.first(where: { $0.root == content.path })?.id ?? existing.projectID
      )
    }
    guard existing != nil || paths.projects.sourceID(for: content.projectID) == nil else {
      throw PermissionModelError.invalidProjectGraph
    }
    let request = record(
      .projectRegistration(evaluated), invocation: invocation, now: now,
      requirements: InvocationRequirements(registration: evaluated), basis: resolution.basis)
    requests[request.id] = request
    return .request(request)
  }

  /// The caller verifies the canonical path and registers the project in the same
  /// durable transaction. Nil means Don't Allow; registration has no one-time answer.
  @discardableResult
  package mutating func answerProjectRegistration(
    _ id: UUID, registeredProject: RegisteredProject?, now: Date
  ) throws -> RevocationResult {
    guard !authorityIsSuspended else { throw PermissionModelError.authoritySuspended }
    var request = try pendingRequest(id, now: now)
    defer { propagateRevocations() }
    guard case .projectRegistration(let content) = request.content else {
      throw PermissionModelError.invalidRegistrationAnswer
    }
    guard let project = registeredProject else {
      request.status = .declined
      requests[id] = request
      return propagateRevocations()
    }
    let catalog = environment.paths?.projects
    let existingSource = catalog?.projects.first { $0.id == content.projectID }
    let derivedLocation = catalog?.projects.first {
      $0.root == content.path && $0.sourceID != nil
        && catalog?.sourceID(for: $0.id) == content.projectID
    }
    guard project.id == content.projectID, project.sourceID == nil,
      project.root == content.path || (derivedLocation != nil && existingSource == project)
    else {
      throw PermissionModelError.invalidRegistrationAnswer
    }
    let requirement = try PermissionRequirement(.project(project.id), content.access)
    guard
      basisRemainsValid(
        inheritedBasis([request]),
        requirements: request.requirements,
        principal: content.principal,
        now: now)
    else { throw PermissionModelError.invalidAuthorization }
    if !permissions(for: content.principal).state(for: requirement.permission).allows(
      content.access)
    {
      try setPermission(
        .granted(content.access), for: requirement.permission, principal: content.principal,
        expectedRevision: revision)
    }
    request.status = .registered(project.id)
    requests[id] = request
    return propagateRevocations()
  }

  /// Selects implicit process access without creating requests or consuming another
  /// retry. Store callers commit this evidence with reservation before launch.
  package mutating func prepareExecutionPermissions(_ id: UUID, sandboxed: Bool = true) throws
    -> ExecutionPermissionProjection
  {
    guard let proof = authorizations[id], !proof.finished, proof.executionID == nil,
      validateAuthorization(id), let paths = environment.paths,
      !paths.userDataLocations.isEmpty, !paths.hostDataLocations.isEmpty
    else { throw PermissionModelError.invalidAuthorization }
    let principal = proof.invocation.principal
    let requests = evidenceRequests(proof.basis, authorizationID: id)
    let settings =
      sandboxSettings.settings(for: principal, sourceProjectID: proof.sandboxProjectID)
    var limits = currentLimits[principal] ?? .init()
    for element in proof.basis {
      if case .connection(let connectionID, _) = element,
        let ceiling = environment.connections[connectionID]?.attenuation
      {
        limits.sources[.connection] = .available(ceiling)
      }
    }
    let effectiveLimits = try EffectiveExecutionLimits.resolve(
      proof.requirements.execution, limits: [limits])
    if !sandboxed {
      guard !proof.mode.isSandbox else { throw PermissionModelError.invalidAuthorization }
      // An unconfined program has no implicit sandbox openings to pin. Its
      // admitted requirements, consent and execution limits remain authoritative.
      return ExecutionPermissionProjection(
        authorization: proof, readablePaths: [], directoryPaths: [],
        forbiddenPaths: [], boundaries: [], network: .none,
        screenCapture: false, accessibility: false, localNetwork: false,
        localNetworkHosts: [], limits: effectiveLimits)
    }
    var forbidden = paths.hostDataLocations.union(paths.deniedLocations)
      .union(limits.deniedReadLocations)
    if proof.mode.isSandbox { forbidden.formUnion(settings.deniedReadLocations) }
    let boundaries = Set(paths.pathRules.map(\.root))
      .union(settings.readExceptions.map(\.path))
      .union(paths.projects.allLocations.map(\.root)).union(forbidden)
      .union(proof.requirements.paths.map(\.path))
      .union([try CanonicalPath("/")])
    var basis = proof.basis
    var executionPermissions = permissions(for: principal)
    if case .plugin = principal, proof.invocation.projectID == nil {
      try executionPermissions.set(.denied, for: .project("*"))
      for permission in executionPermissions.entries.keys {
        if case .project = permission { try executionPermissions.set(.denied, for: permission) }
      }
    }
    func resolve(_ requirements: InvocationRequirements) -> InvocationResolution {
      InvocationEvaluation.evaluate(
        requirements, principal: principal, permissions: executionPermissions,
        limits: limits, trustedHosts: trustedHosts,
        settings: { _ in settings }, pathResolver: { _ in PathPermissions(environment: paths) },
        oneTimeRequests: requests, recordedBasis: proof.basis)
    }
    func conditions(paths: [PathRequirement] = [], actions: [PermissionAction] = [])
      -> InvocationRequirements
    {
      .init(
        actions: actions, paths: paths, mode: proof.mode,
        sandboxProjectID: proof.sandboxProjectID, execution: proof.requirements.execution,
        providers: proof.requirements.providers)
    }
    var reads: [PathAccessBasis] = []
    var directories: [PathAccessBasis] = []
    func purposes(at path: CanonicalPath, operation: PathOperation) -> [PathPurpose?] {
      var result: Set<PathPurpose?> = [nil]
      for declared in proof.requirements.paths
      where declared.purpose != nil
        && declared.operation != .write
        && (declared.path.contains(path)
          || operation.isDirectoryTraversal && path.contains(declared.path))
      {
        result.insert(declared.purpose)
      }
      return result.sorted { ($0?.libraryRoot.string ?? "") < ($1?.libraryRoot.string ?? "") }
    }
    for path in boundaries.sorted(by: { $0.string < $1.string }) {
      guard permitsHostContent(path, projectID: proof.invocation.projectID) else { continue }
      for purpose in purposes(at: path, operation: .read) {
        let result = resolve(
          conditions(paths: [.init(path: path, operation: .read, purpose: purpose)]))
        guard result.isAllowed else { continue }
        basis.formUnion(result.basis)
        reads += result.basis.compactMap {
          if case .path(let value) = $0, value.path == path, value.operation == .read {
            return value
          }
          return nil
        }
      }
    }
    let ancestors = Set(
      reads.flatMap { value -> [CanonicalPath] in
        if value.path.string == "/" { return [value.path] }
        var current = URL(fileURLWithPath: value.path.string).deletingLastPathComponent()
        var result: [CanonicalPath] = []
        while true {
          result.append(try! CanonicalPath(current.path))
          if current.path == "/" { return result }
          current.deleteLastPathComponent()
        }
      })
    for path in ancestors.sorted(by: { $0.string < $1.string }) {
      for purpose in purposes(at: path, operation: .listDirectory) {
        let result = resolve(
          conditions(paths: [.init(path: path, operation: .listDirectory, purpose: purpose)]))
        guard result.isAllowed else { continue }
        basis.formUnion(result.basis)
        directories += result.basis.compactMap {
          if case .path(let value) = $0, value.path == path, value.operation == .listDirectory {
            return value
          }
          return nil
        }
      }
    }
    func permits(_ permission: Permission) -> Bool {
      let result = resolve(
        conditions(actions: [
          .init(requirement: try! PermissionRequirement(permission, .access), scope: .principal)
        ]))
      guard result.isAllowed else { return false }
      basis.formUnion(result.basis)
      return true
    }
    let screen = permits(.screen)
    let desktop = permits(.desktopControl)
    let local = permits(.localNetwork)
    authorizations[id]!.basis = basis
    for requestID in proof.requestIDs where self.requests[requestID]?.status == .consumed(id) {
      self.requests[requestID]!.basis.formUnion(basis.requestEvidence)
    }
    var network =
      proof.mode.isSandbox
      ? settings.effectiveNetwork(limits: limits, trustedHosts: Set(trustedHosts.map(\.host)))
      : NetworkAccess.Configuration.none
    if proof.mode.isSandbox, let hosts = network.hosts(trustedHosts: Set(trustedHosts.map(\.host)))
    {
      let expanded = hosts.union(proof.requirements.networks.map(\.host))
      network = expanded.isEmpty ? .none : .custom(hosts: expanded, includesTrusted: false)
    }
    return ExecutionPermissionProjection(
      authorization: authorizations[id]!, readablePaths: reads, directoryPaths: directories,
      forbiddenPaths: forbidden, boundaries: boundaries,
      network: network,
      screenCapture: screen, accessibility: desktop, localNetwork: local,
      localNetworkHosts: Set(proof.requirements.networks.filter(\.isLocalNetwork).map(\.host)),
      limits: effectiveLimits)
  }

  package mutating func invocationAccess(_ id: UUID) throws -> InvocationAuthorization {
    guard !authorityIsSuspended, let proof = authorizations[id], !proof.revoked, !proof.finished,
      validateAuthorization(id)
    else { throw PermissionModelError.invalidAuthorization }
    return proof
  }

  /// A host-verified resource can continue only within the authority that acquired it.
  /// Consumed request evidence is usable here without admitting a second execution.
  package mutating func continuationAuthorization(
    _ id: UUID, principal: Principal, projectID: String?, requirements: InvocationRequirements,
    connectionID: String? = nil, now: Date = Date()
  ) throws -> InvocationAuthorization {
    guard validateAuthorization(id), let proof = authorizations[id],
      proof.invocation.principal == principal, proof.invocation.projectID == projectID,
      let executionID = proof.executionID, let execution = executions[executionID],
      execution.isRunning, !execution.revoked, execution.interruptedAt == nil,
      !pendingExecutionTerminations.contains(executionID),
      requirements.mode == proof.mode,
      requirements.sandboxProjectID == proof.sandboxProjectID
    else {
      throw PermissionModelError.invalidAuthorization
    }
    let requests = evidenceRequests(proof.basis, authorizationID: id)
    let result = evaluate(
      requirements, principal: principal, oneTimeRequests: requests, basis: proof.basis)
    guard result.isAllowed, carriesPermissionEvidence(result.basis, from: proof.basis) else {
      throw PermissionModelError.invalidAuthorization
    }
    for element in proof.basis {
      if case .connection(let originalID, _) = element {
        guard let connection = environment.connections[originalID],
          connection.principal == principal,
          evaluateCeiling(
            connection.attenuation, requirements: requirements, principal: principal,
            requests: requests
          ).isAllowed
        else { throw PermissionModelError.invalidAuthorization }
      }
    }
    if let connectionID {
      guard let connection = activeConnection(connectionID, principal: principal),
        evaluateCeiling(
          connection.attenuation, requirements: requirements, principal: principal,
          requests: requests
        ).isAllowed
      else { throw PermissionModelError.invalidAuthorization }
    }
    return proof
  }

  /// Checks project write against current standing authority and this proof's exact
  /// consumed evidence, without admitting work or transferring its grant ownership.
  package mutating func checkProjectWriteAuthority(
    _ id: UUID, projectID: String, connectionID: String? = nil, now: Date = Date()
  ) throws {
    _ = reconcileExecutionLimits(now: now)
    guard !authorityIsSuspended, validateAuthorization(id), let proof = authorizations[id],
      let executionID = proof.executionID,
      executions[executionID]?.authorizationIDs.contains(id) == true,
      executionIsLive(executionID)
    else { throw PermissionModelError.invalidAuthorization }
    let requirements = InvocationRequirements(
      actions: [
        .init(
          requirement: try PermissionRequirement(.project(projectID), .write),
          scope: .project(projectID))
      ], mode: proof.mode, sandboxProjectID: proof.sandboxProjectID,
      providers: proof.requirements.providers)
    let result = evaluate(
      requirements, principal: proof.invocation.principal,
      oneTimeRequests: evidenceRequests(proof.basis, authorizationID: id), basis: proof.basis,
      connectionID: connectionID, admission: true)
    guard result.isAllowed else { throw PermissionModelError.invalidAuthorization }
  }

  /// Rechecks an actual host file use, including recursive descendants. New access
  /// can only be drawn from this invocation's existing grant evidence.
  package mutating func authorizePathUse(
    _ id: UUID, path: CanonicalPath, operation: PathOperation
  ) throws {
    guard let proof = authorizations[id], !proof.finished, validateAuthorization(id),
      permitsHostContent(path, projectID: proof.invocation.projectID), pathResolver != nil
    else { throw PermissionModelError.invalidAuthorization }
    let requests = evidenceRequests(proof.basis, authorizationID: id)
    // Only declared, admitted path evidence can carry host library intent into
    // a later file use. Projection openings and registration alone confer none.
    var candidates = proof.requirements.paths.filter { declared in
      guard declared.purpose != nil || declared.pluginPurpose != nil,
        proof.basis.contains(where: {
          if case .path(let admitted) = $0 {
            return admitted.path == declared.path && admitted.operation == declared.operation
              && admitted.purpose == declared.purpose
          }
          return false
        })
      else { return false }
      if declared.operation.isDirectoryTraversal {
        return declared.path == path && operation.isDirectoryTraversal
      }
      return (declared.operation == .write || operation != .write)
        && (declared.path.contains(path)
          || operation.isDirectoryTraversal && path.contains(declared.path))
    }.map {
      PathRequirement(
        path: path, operation: operation, pluginPurpose: $0.pluginPurpose, purpose: $0.purpose)
    }
    candidates.append(.init(path: path, operation: operation))
    candidate: for candidate in candidates {
      let requirements = InvocationRequirements(
        paths: [candidate], mode: proof.mode,
        sandboxProjectID: proof.sandboxProjectID, execution: proof.requirements.execution,
        providers: proof.requirements.providers)
      let result = evaluate(
        requirements, principal: proof.invocation.principal,
        oneTimeRequests: requests, basis: proof.basis)
      guard result.isAllowed else { continue }
      for element in proof.basis {
        if case .connection(let connectionID, _) = element,
          let connection = environment.connections[connectionID],
          !evaluateCeiling(
            connection.attenuation, requirements: requirements,
            principal: proof.invocation.principal, requests: requests
          ).isAllowed
        {
          continue candidate
        }
      }
      // Traversal may use a readable descendant, but cannot import grants acquired
      // after admission. Every permission must retain its principal and purpose.
      guard carriesPermissionEvidence(result.basis, from: proof.basis) else { continue candidate }
      authorizations[id]!.basis.formUnion(result.basis)
      return
    }
    throw PermissionModelError.invalidAuthorization
  }

  /// Converts fresh callback proofs to same-principal lifecycle dependencies while
  /// the complete parent execution is still live. Owned consumed requests change in
  /// the same transaction; borrowed parent grants keep their exact consumption owner.
  package mutating func prepareWorktreeCallback(
    _ ids: Set<UUID>, parentExecutionID: UUID
  ) throws -> [UUID: InvocationAuthorization] {
    var candidate = self
    guard !ids.isEmpty, candidate.executionIsLive(parentExecutionID),
      let execution = candidate.executions[parentExecutionID], execution.delegatedTo != nil
    else { throw PermissionModelError.invalidAuthorization }
    for id in ids {
      let proof = try candidate.invocationAccess(id)
      guard proof.executionID == nil, proof.basis.contains(.execution(parentExecutionID)),
        proof.basis.allSatisfy({
          switch $0 {
          case .execution(let parent): parent == parentExecutionID
          case .worktreeAuthority: false
          default: true
          }
        })
      else { throw PermissionModelError.invalidAuthorization }
      let parents = execution.authorizationIDs.compactMap { candidate.authorizations[$0] }.filter {
        $0.invocation.principal == proof.invocation.principal
          && $0.invocation.projectID == proof.invocation.projectID
          && $0.sandboxProjectID == proof.sandboxProjectID && !$0.revoked
      }
      guard parents.count == 1, let parent = parents.first, parent.id != id else {
        throw PermissionModelError.invalidAuthorization
      }
      candidate.authorizations[id]!.basis.remove(.execution(parentExecutionID))
      candidate.authorizations[id]!.basis.insert(.worktreeAuthority(parent.id))
      for requestID in proof.requestIDs
      where candidate.requests[requestID]?.status == .consumed(id) {
        if candidate.requests[requestID]!.basis.remove(.execution(parentExecutionID)) != nil {
          candidate.requests[requestID]!.basis.insert(.worktreeAuthority(parent.id))
        }
      }
    }
    var prepared: [UUID: InvocationAuthorization] = [:]
    for id in ids { prepared[id] = try candidate.prepareWorktreePermissions(id) }
    self = candidate
    return prepared
  }

  /// Pins available nested-project grants before worktree operations or programs
  /// start using paths. Effects still check live paths and ceilings, and cannot
  /// import grants obtained after preparation.
  package mutating func prepareWorktreePermissions(_ id: UUID) throws
    -> InvocationAuthorization
  {
    let proof = try invocationAccess(id)
    guard proof.executionID == nil, let catalog = environment.paths?.projects,
      let selectedID = proof.invocation.projectID,
      let sourceID = catalog.sourceID(for: selectedID),
      let source = catalog.projects.first(where: { $0.id == sourceID })
    else { throw PermissionModelError.invalidAuthorization }
    let requests = evidenceRequests(proof.basis, authorizationID: id)
    var basis = proof.basis
    let values: [PermissionValue] =
      proof.requirements.actions.contains {
        $0.requirement.permission == .project(sourceID) && $0.requirement.value == .write
      } ? [.write, .read] : [.read]
    for project in catalog.projects
    where project.sourceID == nil && project.id != sourceID && source.root.contains(project.root) {
      for value in values {
        let requirements = InvocationRequirements(
          actions: [
            PermissionAction(
              requirement: try PermissionRequirement(.project(project.id), value),
              scope: .project(project.id))
          ], mode: proof.mode, sandboxProjectID: proof.sandboxProjectID)
        let result = evaluate(
          requirements, principal: proof.invocation.principal,
          oneTimeRequests: requests, basis: proof.basis)
        guard result.isAllowed else { continue }
        let ceilingsAllow = proof.basis.allSatisfy { element in
          guard case .connection(let connectionID, _) = element else { return true }
          guard let connection = environment.connections[connectionID] else { return false }
          return evaluateCeiling(
            connection.attenuation, requirements: requirements,
            principal: proof.invocation.principal, requests: requests
          ).isAllowed
        }
        guard ceilingsAllow else { continue }
        // Registration and path evidence is checked at use, so unregistering a
        // derived checkout does not invalidate journaled cleanup authority.
        basis.formUnion(
          result.basis.filter {
            if case .permission = $0 { return true }
            return false
          })
        break
      }
    }
    authorizations[id]!.basis = basis
    for requestID in proof.requestIDs where self.requests[requestID]?.status == .consumed(id) {
      self.requests[requestID]!.basis.formUnion(basis.requestEvidence)
    }
    return authorizations[id]!
  }

  /// A lifecycle service owns the filesystem effect. Read admission still checks every
  /// path denial; write authority comes from the admitted project's grant rather than
  /// granting a sandbox program write access to the source checkout.
  ///
  /// Lifecycle effects are host-owned once claimed, so an end that does not invalidate
  /// authority (an owner stop, a provider exit or a channel close) does not end them: a
  /// finished authorization still serves them while it is unrevoked and its basis holds.
  /// Revocation propagation evaluates finished authorizations too, so every invalidation
  /// fails the next check.
  package mutating func authorizeWorktreeHostPath(
    _ id: UUID, path: CanonicalPath, writing: Bool
  ) throws {
    guard !authorityIsSuspended, validateAuthorization(id), let proof = authorizations[id] else {
      throw PermissionModelError.invalidAuthorization
    }
    guard let project = environment.paths?.projects.location(at: path) else {
      throw PermissionModelError.invalidAuthorization
    }
    let requests = evidenceRequests(proof.basis, authorizationID: id)
    let requirements = InvocationRequirements(
      actions: [
        PermissionAction(
          requirement: try PermissionRequirement(
            .project(project.projectID), writing ? .write : .read),
          scope: .project(project.projectID))
      ],
      paths: [.init(path: path, operation: .read)], mode: proof.mode,
      sandboxProjectID: proof.sandboxProjectID)
    let result = evaluate(
      requirements, principal: proof.invocation.principal,
      oneTimeRequests: requests, basis: proof.basis)
    guard result.isAllowed, carriesPermissionEvidence(result.basis, from: proof.basis) else {
      throw PermissionModelError.invalidAuthorization
    }
    for element in proof.basis {
      if case .connection(let connectionID, _) = element {
        guard let connection = environment.connections[connectionID],
          evaluateCeiling(
            connection.attenuation, requirements: requirements,
            principal: proof.invocation.principal, requests: requests
          ).isAllowed
        else { throw PermissionModelError.invalidAuthorization }
      }
    }
    // These effects consume live path checks, not a new program/path grant. Keeping
    // the source proof lets journaled cleanup finish after unregistering its child.
  }

  private func carriesPermissionEvidence(
    _ basis: Set<AuthorizationBasis>, from admitted: Set<AuthorizationBasis>
  ) -> Bool {
    for element in basis {
      guard case .permission(let used) = element else { continue }
      guard
        admitted.contains(where: {
          guard case .permission(let existing) = $0,
            existing.principal == used.principal, existing.pluginPurpose == used.pluginPurpose,
            existing.requirement.permission == used.requirement.permission,
            PermissionState.granted(existing.requirement.value).allows(used.requirement.value)
          else { return false }
          if case .standing = existing.source, existing.source == used.source { return true }
          if existing.scope == used.scope { return true }
          switch (existing.scope, used.scope) {
          case (.principal, _): return true
          case (.project(let id), .path): return used.requirement.permission == .project(id)
          case (.path(let root), .path(let child)): return root.contains(child)
          default: return false
          }
        })
      else { return false }
    }
    return true
  }

  /// Ends invocation work; execution consumption is independently durable.
  package mutating func finishInvocation(_ id: UUID) throws {
    guard authorizations[id] != nil else { throw PermissionModelError.unknownAuthorization }
    authorizations[id]!.finished = true
  }

  /// All proofs describe the same originating call. A delegated execution carries
  /// both the initiating client's authority and the acting plugin's own authority.
  /// Each authorization binds to at most one execution. All supplied authorizations
  /// are checked before any binding is written; completion never releases them.
  /// Failed revalidation revokes the authorization. Inside a store transaction,
  /// catch the error and return it as a value so the revocation can commit.
  package mutating func startExecution(
    owner: Principal, delegatedTo: PluginIdentity? = nil, authorizationIDs: Set<UUID>,
    capabilities: ExecutionLimitCapabilities = .init(), now: Date = Date()
  ) throws -> AuthorizedExecution {
    guard !authorityIsSuspended else { throw PermissionModelError.authoritySuspended }
    propagateRevocations()
    guard !authorizationIDs.isEmpty else { throw PermissionModelError.invalidAuthorization }
    let authorizations = try authorizationIDs.map { id in
      guard let authorization = self.authorizations[id] else {
        throw PermissionModelError.unknownAuthorization
      }
      guard !authorization.finished, authorization.executionID == nil,
        !authorization.basis.contains(where: {
          if case .worktreeAuthority = $0 { return true }
          return false
        }),
        authorization.invocation.principal == owner
          || delegatedTo.map({ authorization.invocation.principal == .plugin($0) }) == true
      else { throw PermissionModelError.invalidAuthorization }
      guard
        validateAuthorization(id)
      else { throw PermissionModelError.invalidAuthorization }
      let principal = authorization.invocation.principal
      let resolution = evaluate(
        authorization.requirements,
        principal: principal,
        oneTimeRequests: evidenceRequests(authorization.basis, authorizationID: authorization.id),
        basis: authorization.basis)
      self.authorizations[id]!.basis.formUnion(resolution.basis)
      for requestID in authorization.requestIDs where requests[requestID]?.status == .consumed(id) {
        requests[requestID]!.basis.formUnion(resolution.basis.requestEvidence)
      }
      return self.authorizations[id]!
    }
    guard
      let initiatingCall = authorizations.first(where: { $0.invocation.principal == owner })?
        .invocation,
      authorizations.allSatisfy({
        $0.invocation.tool == initiatingCall.tool
          && $0.invocation.projectID == initiatingCall.projectID
          && $0.invocation.argumentsDigest == initiatingCall.argumentsDigest
      })
    else { throw PermissionModelError.invalidAuthorization }
    if let delegatedTo {
      guard authorizations.contains(where: { $0.invocation.principal == .plugin(delegatedTo) })
      else {
        throw PermissionModelError.invalidAuthorization
      }
      let permission: Permission =
        switch delegatedTo {
        case .package(let id): .plugin(id)
        case .localServer(let id): .mcpServer(id)
        }
      guard
        authorizations.contains(where: {
          $0.invocation.principal == owner
            && $0.actions.contains { $0.requirement.permission == permission }
        })
      else { throw PermissionModelError.invalidAuthorization }
    }
    let limitRequest = authorizations.first?.requirements.execution ?? .foreground
    guard authorizations.allSatisfy({ $0.requirements.execution == limitRequest })
    else {
      throw PermissionModelError.invalidAuthorization
    }
    let limits = try EffectiveExecutionLimits.resolve(
      limitRequest,
      limits: executionPolicies(authorizations))
    try limits.requireEnforceable(by: capabilities)
    let execution = AuthorizedExecution(
      id: allocateIdentity().id, owner: owner, delegatedTo: delegatedTo,
      authorizationIDs: authorizationIDs, startedAt: now, limitRequest: limitRequest,
      limitCapabilities: capabilities, limits: limits)
    for id in authorizationIDs { self.authorizations[id]!.executionID = execution.id }
    executions[execution.id] = execution
    return execution
  }

  /// Recovery retires running work without revoking retained-result authority.
  /// Physical completion remains in the durable termination queue until confirmed.
  package mutating func interruptExecution(_ id: UUID, now: Date = Date()) throws {
    guard executions[id] != nil else { throw PermissionModelError.unknownExecution }
    executions[id]!.interruptedAt = executions[id]!.interruptedAt ?? now
    try terminateExecution(id, now: now)
  }

  package mutating func terminateExecution(_ id: UUID, now: Date = Date()) throws {
    guard let execution = executions[id] else { throw PermissionModelError.unknownExecution }
    pendingExecutionTerminations.insert(id)
    try finishExecution(
      id, retainUntil: now.addingTimeInterval(TimeInterval(execution.limits.retentionSeconds)),
      now: now)
  }

  package mutating func finishExecution(_ id: UUID, retainUntil: Date, now: Date = Date()) throws {
    guard executions[id] != nil else { throw PermissionModelError.unknownExecution }
    let end = executions[id]!.endedAt ?? now
    executions[id]!.isRunning = false
    executions[id]!.endedAt = end
    executions[id]!.retainUntil = min(
      executions[id]!.retainUntil ?? retainUntil, retainUntil,
      end.addingTimeInterval(TimeInterval(executions[id]!.limits.retentionSeconds)))
    propagateRevocations(now: now)
  }

  /// Failed revalidation revokes dependent executions and queues termination atomically.
  package mutating func executionAccess(
    _ id: UUID, principal: Principal, operation: ExecutionOperation, connectionID: String? = nil,
    now: Date
  ) -> PermissionDecision {
    guard !authorityIsSuspended else { return .denied(.authoritySuspended) }
    propagateRevocations()
    return executionAccessAfterRevalidation(
      id, principal: principal, operation: operation, connectionID: connectionID, now: now)
  }

  /// A host I/O boundary checks the calling invocation and effective execution
  /// limits against the same freshly revalidated authority state.
  package mutating func executionAccess(
    _ id: UUID, principal: Principal, operation: ExecutionOperation, connectionID: String?,
    authorizingInvocation: UUID?, now: Date
  ) -> PermissionDecision {
    _ = reconcileExecutionLimits(now: now)
    guard !authorityIsSuspended else { return .denied(.authoritySuspended) }
    if let authorizingInvocation {
      guard let proof = authorizations[authorizingInvocation], !proof.revoked, !proof.finished,
        proof.invocation.principal == principal
      else { return .denied(.authorizationRevoked) }
    }
    return executionAccessAfterRevalidation(
      id, principal: principal, operation: operation, connectionID: connectionID, now: now)
  }

  private func executionAccessAfterRevalidation(
    _ id: UUID, principal: Principal, operation: ExecutionOperation, connectionID: String?,
    now: Date
  ) -> PermissionDecision {
    guard let execution = executions[id], execution.owner == principal else {
      return .denied(.executionOwner)
    }
    guard !execution.revoked else { return .denied(.authorizationRevoked) }
    if operation == .writeInput,
      execution.authorizationIDs.contains(where: {
        authorizations[$0]?.invocation.principal == principal
          && authorizations[$0]?.mode.isSandbox == false
      })
    {
      guard let consent = selectedConsent(principal: principal, connectionID: connectionID),
        !consent.mode.isSandbox, consentIsValid(consent, principal: principal)
      else {
        return .denied(.fullAccessRequiresConsent)
      }
    }
    if let connectionID {
      guard let connection = activeConnection(connectionID, principal: principal) else {
        return .denied(.authorizationRevoked)
      }
      for authorizationID in execution.authorizationIDs {
        guard let proof = authorizations[authorizationID], proof.invocation.principal == principal
        else { continue }
        let resolution = evaluateCeiling(
          connection.attenuation, requirements: proof.requirements,
          principal: principal, requests: evidenceRequests(proof.basis, authorizationID: proof.id))
        if let denial = resolution.denial { return .denied(denial) }
      }
    }
    // The fixed-point pass above revalidated every proof. The intervening
    // consent and connection checks do not mutate their authority.
    guard execution.authorizationIDs.allSatisfy({ authorizations[$0]?.revoked == false }) else {
      return .denied(.authorizationRevoked)
    }
    if !execution.isRunning {
      guard operation == .readResult else { return .denied(.executionEnded) }
      guard let retainUntil = execution.retainUntil, now < retainUntil else {
        return .denied(.resultExpired)
      }
    }
    return .allowed
  }

  package mutating func revoke(
    principal: Principal, permission: Permission, expectedRevision: UInt64
  ) throws
    -> RevocationResult
  {
    try setPermission(
      .denied, for: permission, principal: principal, expectedRevision: expectedRevision)
  }

  /// The host must call this in the same transaction as changes to managed policy,
  /// project registration/removal/nesting, or any environment-supplied location.
  /// It supplies fresh snapshots, terminates the queued executions and proxy connections,
  /// then acknowledges confirmed terminations in another transaction. Unacknowledged
  /// IDs are returned on every reconciliation; the library never performs I/O.
  @discardableResult
  package mutating func reconcile(
    environment: PermissionEnvironment, expectedRevision: UInt64, now: Date? = nil
  ) throws -> RevocationResult {
    try commit(expectedRevision: expectedRevision) { ledger in
      var environment = environment
      if ledger.suspendedAuthority != nil {
        for principal in environment.limits.keys {
          environment.limits[principal]!.sources[.owner] = .unreadable
        }
      }
      for (principal, consent) in environment.modes {
        if case .fullAccess(.connection) = consent.mode {
          throw PermissionModelError.invalidAuthorization
        }
        guard ledger.issuedConsents[principal]?.contains(consent) == true else {
          throw PermissionModelError.invalidAuthorization
        }
      }
      for (id, connection) in environment.connections {
        if let consent = connection.consent {
          guard ledger.issuedConsents[connection.principal]?.contains(consent) == true,
            consent.mode == .fullAccess(.standing) || consent.mode == .fullAccess(.connection(id))
              || consent.mode == .sandbox
          else { throw PermissionModelError.invalidAuthorization }
        }
      }
      try environment.commit(against: ledger.environment, in: &ledger)
      let previous = Set(ledger.environment.modes.values.map(\.identity))
        .union(ledger.environment.connections.values.compactMap { $0.consent?.identity })
      let current = Set(environment.modes.values.map(\.identity))
        .union(environment.connections.values.compactMap { $0.consent?.identity })
      ledger.retiredConsents.formUnion(previous.subtracting(current))
      ledger.environment = environment
      ledger.tightenExecutionLimits(now: now ?? Date())
      return ledger.propagateRevocations(now: now)
    }
  }

  /// Create only after local consent. Installing this record requires reconciliation.
  package mutating func consent(for principal: Principal, mode: ExecutionMode) -> ModeConsent {
    register(principal)
    let consent = ModeConsent(
      identity: allocateIdentity(), mode: mode, profileDigest: profileDigest(for: principal))
    issuedConsents[principal, default: []].insert(consent)
    return consent
  }

  /// Read-only validation of an issued identity; retired consent never becomes valid again.
  package func isConsentValid(_ consent: ModeConsent, for principal: Principal) -> Bool {
    guard !authorityIsSuspended, issuedConsents[principal]?.contains(consent) == true,
      consentIsValid(consent, principal: principal)
    else { return false }
    if case .fullAccess(.connection(let id)) = consent.mode {
      return activeConnection(id, principal: principal) != nil
    }
    return true
  }

  /// Every state transition re-evaluates every live proof to a fixed point. Revocation
  /// and its durable execution notification commit together and are never undone.
  @discardableResult
  private mutating func propagateRevocations(
    now: Date? = nil
  ) -> RevocationResult {
    // Revoking proofs and requests does not change profile authority. Reuse its
    // digest within this fixed-point pass without caching across state edits.
    let standingPrincipals = issuedConsents.compactMap { principal, consents in
      consents.contains {
        $0.mode == .fullAccess(.standing) && !retiredConsents.contains($0.identity)
      }
        ? principal : nil
    }
    let environmentDigest = standingPrincipals.isEmpty ? "" : profileEnvironmentDigest()
    let profileDigests = Dictionary(
      uniqueKeysWithValues: standingPrincipals.map {
        ($0, profileDigest(for: $0, environmentDigest: environmentDigest))
      })
    let memo = BasisValidationMemo()
    for (principal, consents) in issuedConsents {
      for consent in consents
      where !consent.mode.isSandbox && !retiredConsents.contains(consent.identity) {
        if (consent.mode == .fullAccess(.standing)
          && consent.profileDigest != profileDigests[principal])
          || {
            if case .fullAccess(.connection(let id)) = consent.mode {
              return environment.endedConnections.contains(id)
            }
            return false
          }()
        {
          retiredConsents.insert(consent.identity)
        }
      }
    }
    var changed: Bool
    repeat {
      changed = false
      for (id, request) in requests {
        let owner: UUID?
        if case .consumed(let authorizationID) = request.status {
          owner = authorizationID
        } else if request.status.isUnconsumed {
          owner = nil
        } else {
          continue
        }
        if owner.map({ authorizations[$0]?.revoked != false }) == true
          || !basisRemainsValid(
            request.basis,
            requirements: request.requirements,
            principal: request.content.principal,
            authorizationID: owner,
            now: now,
            currentProfileDigest: profileDigests[request.content.principal], memo: memo)
        {
          requests[id]!.status = .revoked
          changed = true
        }
      }
      for (id, authorization) in authorizations where !authorization.revoked {
        if !isValid(
          authorization, currentProfileDigest: profileDigests[authorization.invocation.principal],
          memo: memo)
        {
          authorizations[id]!.revoked = true
          changed = true
        }
      }
    } while changed
    for (id, request) in requests where request.status.isUnconsumed {
      if let requirement = request.requirement {
        requests[id]!.observedPermission = permissions(for: request.content.principal)
          .state(for: requirement.permission)
      }
    }
    for (id, execution) in executions where !execution.revoked {
      if execution.authorizationIDs.contains(where: { authorizations[$0]?.revoked != false }) {
        executions[id]!.revoked = true
        if execution.isRunning { pendingExecutionTerminations.insert(id) }
      }
    }
    return RevocationResult(executionsToTerminate: pendingExecutionTerminations)
  }

  private mutating func validateAuthorization(_ id: UUID) -> Bool {
    propagateRevocations()
    guard let proof = authorizations[id], !proof.revoked else { return false }
    return proof.basis.allSatisfy {
      if case .execution(let id) = $0 {
        return proof.executionID == nil ? executionIsLive(id) : executionAuthorityIsValid(id)
      }
      return true
    }
  }

  private func isValid(
    _ authorization: InvocationAuthorization, currentProfileDigest: String? = nil,
    memo: BasisValidationMemo? = nil
  ) -> Bool {
    guard !authorization.revoked,
      authorization.mode.isSandbox
        || authorization.basis.contains(where: {
          if case .consent = $0 { return true }
          return false
        }),
      basisRemainsValid(
        authorization.basis,
        requirements: authorization.requirements,
        principal: authorization.invocation.principal,
        authorizationID: authorization.id,
        currentProfileDigest: currentProfileDigest, memo: memo)
    else { return false }
    return true
  }

  private func evidenceRequests(_ basis: Set<AuthorizationBasis>, authorizationID: UUID?)
    -> [PermissionRequest]
  {
    basis.compactMap(\.requestID).compactMap { requests[$0] }.map {
      request in
      var grant = request
      if let authorizationID, grant.status == .consumed(authorizationID) {
        grant.status = .onlyThisTime
      } else if callbackRequestOwner(request.id, basis: basis) != nil {
        grant.status = .onlyThisTime
      }
      return grant
    }
  }

  private func executionIsLive(_ id: UUID) -> Bool {
    guard let execution = executions[id] else { return false }
    return execution.isRunning && executionAuthorityIsValid(id) && execution.interruptedAt == nil
      && !pendingExecutionTerminations.contains(id)
  }

  private func executionAuthorityIsValid(_ id: UUID) -> Bool {
    guard let execution = executions[id], !execution.revoked else { return false }
    return execution.authorizationIDs.allSatisfy { authorizations[$0]?.revoked == false }
  }

  private func callbackRequestOwner(_ id: UUID, basis: Set<AuthorizationBasis>) -> UUID? {
    guard let request = requests[id], case .consumed(let owner) = request.status else { return nil }
    return basis.contains(where: {
      switch $0 {
      case .execution(let executionID):
        return executionAuthorityIsValid(executionID)
          && executions[executionID]?.authorizationIDs.contains(owner) == true
          && authorizations[owner]?.requestIDs.contains(id) == true
      case .worktreeAuthority(let parentID):
        guard parentID == owner, let parent = authorizations[parentID], !parent.revoked,
          parent.invocation.principal == request.content.principal
        else { return false }
        return parent.requestIDs.contains(id)
      default: return false
      }
    }) ? owner : nil
  }

  private func callbackRequests(_ basis: Set<AuthorizationBasis>, principal: Principal)
    -> [PermissionRequest]
  {
    requests.values.compactMap { request in
      guard request.content.principal == principal,
        callbackRequestOwner(request.id, basis: basis) != nil
      else { return nil }
      var grant = request
      grant.status = .onlyThisTime
      return grant
    }
  }

  private func basisRemainsValid(
    _ basis: Set<AuthorizationBasis>, requirements: InvocationRequirements, principal: Principal,
    authorizationID: UUID? = nil, now: Date? = nil, currentProfileDigest: String? = nil,
    memo: BasisValidationMemo? = nil
  ) -> Bool {
    var limits = currentLimits[principal] ?? .init()
    let connection = basis.compactMap { element -> (String, ManagedPolicy)? in
      if case .connection(let id, _) = element,
        let policy = environment.connections[id]?.attenuation
      {
        return (id, policy)
      }
      return nil
    }.first
    let connectionCeiling = connection?.1
    if let connectionCeiling { limits.sources[.connection] = .available(connectionCeiling) }
    let mode = requirements.mode
    let admittedRequests = evidenceRequests(basis, authorizationID: authorizationID)
    let resolve = {
      evaluate(requirements, principal: principal, oneTimeRequests: admittedRequests, basis: basis)
    }
    let resolution =
      admittedRequests.isEmpty
      ? (memo?.resolve(requirements, principal: principal, basis: basis, operation: resolve)
        ?? resolve())
      : resolve()
    guard resolution.denial == nil, authorizationID == nil || resolution.isAllowed else {
      return false
    }
    let permissions = permissions(for: principal)
    return basis.allSatisfy { element in
      switch element {
      case .execution(let id):
        return executionAuthorityIsValid(id) && (authorizationID != nil || executionIsLive(id))
      case .worktreeAuthority(let parentID):
        guard let authorizationID, let proof = authorizations[authorizationID],
          let parent = authorizations[parentID], proof.executionID == nil,
          parentID != authorizationID,
          parent.executionID != nil, !parent.revoked,
          parent.invocation.principal == principal,
          parent.invocation.projectID == proof.invocation.projectID,
          parent.sandboxProjectID == requirements.sandboxProjectID
        else { return false }
        return true
      case .provider(let recorded):
        return resolution.basis.contains(.provider(recorded))
      case .permission(let grant):
        if authorizationID == nil, let now, let id = grant.source.requestID,
          requests[id].map({ now >= $0.expiresAt }) != false
        {
          return false
        }
        let validate = { [self] in
          PermissionEvaluation.resolveRequirement(
            principal: principal,
            action: PermissionAction(
              requirement: grant.requirement, scope: grant.scope, pluginPurpose: grant.pluginPurpose
            ),
            permissions: permissions, mode: mode, limits: limits,
            oneTimeRequests: grant.source.requestID.flatMap { requests[$0] }.map { [$0] } ?? [],
            recordedGrant: grant,
            authorizationID: grant.source.requestID.flatMap {
              callbackRequestOwner($0, basis: basis)
            }
              ?? authorizationID
          ).decision == .allowed
        }
        if case .standing = grant.source, let memo {
          return memo.validateStandingGrant(
            grant, principal: principal, mode: mode, connectionID: connection?.0,
            ceiling: connectionCeiling?.identity, operation: validate)
        }
        return validate()
      case .traversal(let requirement):
        return PermissionEvaluation.denial(
          for: PermissionAction(requirement: requirement), permissions: permissions,
          mode: mode, limits: limits, sandbox: .init()) == nil
      case .permit(let request, let identity):
        return requests[request.id]?.identity == request
          && requests[request.id]?.permitIdentity == identity
      case .request(let identity):
        guard let request = requests[identity.id], request.identity == identity,
          request.content.principal == principal,
          request.requirements == requirements
        else {
          return false
        }
        if authorizationID == nil, request.status != .always, let now, now >= request.expiresAt {
          return false
        }
        if let requirement = request.requirement {
          let state = permissions.state(for: requirement.permission)
          guard state != .denied, limits.restrictingSources(for: requirement).isEmpty else {
            return false
          }
          if authorizationID == nil, case .granted(let value) = request.observedPermission,
            !state.allows(value)
          {
            return false
          }
        }
        switch request.status {
        case .pending: return authorizationID == nil
        case .onlyThisTime: return authorizationID == nil
        case .always: return true
        case .consumed(let owner): return authorizationID == owner
        default: return false
        }
      case .managed(let source, let identity):
        guard case .available(let policy) = limits.sources[source] else { return false }
        return policy.identity == identity
      case .managedPermission(let source, let grant):
        guard case .available(let policy) = limits.sources[source] else { return false }
        return PermissionEvaluation.resolveRequirement(
          principal: principal, action: PermissionAction(requirement: grant.requirement),
          permissions: policy.permissionCeilings, mode: mode, limits: .init(),
          recordedGrant: grant
        ).decision == .allowed
      case .mode(let recorded):
        return recorded == mode && limits.modeDenial(mode) == nil
      case .consent(let identity):
        return issuedConsents[principal]?.contains {
          $0.identity == identity
            && consentIsValid($0, principal: principal, currentProfileDigest: currentProfileDigest)
        } == true
      case .retryOrigin(let identity):
        return authorizations[identity.id]?.identity == identity
          && authorizations[identity.id]?.revokesRetries == false
      case .connection(let id, let ceiling):
        return environment.connections[id]?.principal == principal
          && environment.connections[id]?.attenuation.identity == ceiling
      case .network(let network):
        if let source = network.policySource {
          if source == .connection, let connectionCeiling {
            return network.isValid(access: connectionCeiling.network, trustedHosts: trustedHosts)
          }
          guard case .available(let policy) = limits.sources[source] else { return false }
          return network.isValid(access: policy.network, trustedHosts: trustedHosts)
        }
        let settings =
          sandboxSettings.settings(for: principal, sourceProjectID: network.projectID)
        return network.isValid(access: settings.network, trustedHosts: trustedHosts)
      case .path(let path):
        guard let resolver = self.pathResolver else { return false }
        let sandbox =
          sandboxSettings.settings(for: principal, sourceProjectID: path.sandboxProjectID)
        let validate = {
          resolver.validate(
            path, principal: principal, permissions: permissions, mode: mode,
            limits: limits, sandbox: sandbox)
        }
        return memo?.validate(
          path, principal: principal, mode: mode, connectionID: connection?.0,
          ceiling: connectionCeiling?.identity, operation: validate) ?? validate()
      case .sandbox(let original):
        guard mode.isSandbox else { return true }
        let validate = { [self] in
          let current =
            sandboxSettings.settings(for: principal, sourceProjectID: original.projectID)
          if case .plugin(let identity) = principal, sandboxSettings.providers[identity] != nil {
            guard current.network == original.settings.network,
              current.networkCeiling == original.settings.networkCeiling,
              current.deniedReadRules == original.settings.deniedReadRules,
              Set(current.readExceptions.map(\.identity))
                == Set(original.settings.readExceptions.map(\.identity))
            else { return false }
          }
          let hostNames = Set(trustedHosts.map(\.host))
          return current.network.preservesUnboundedRule(of: original.settings.network)
            && Set(original.settings.deniedReadRules.map(\.identity)).isSubset(
              of: Set(current.deniedReadRules.map(\.identity)))
            && !current.isMoreRestrictive(than: original.settings, trustedHosts: hostNames)
            && !limits.deniedReadLocations.contains { path in
              !original.managedDeniedReadLocations.contains { $0.contains(path) }
            }
            && !current.effectiveNetwork(limits: limits, trustedHosts: hostNames)
              .isMoreRestrictive(than: original.network, trustedHosts: hostNames)
        }
        return memo?.validateSandbox(
          original, principal: principal, connectionID: connection?.0, operation: validate)
          ?? validate()
      }
    }
  }

  /// The host submits needs attributed to this execution's processes. The saved
  /// continuation adds them to the original call; it never extends the running
  /// execution. Discoveries accumulate in one continuation per authorization.
  package mutating func recordDiscoveredNeeds(
    executionID: UUID, principal: Principal, needs: [DiscoveredRequirement], now: Date
  ) throws -> DiscoveredRequirementDecision {
    var candidate = self
    let result = try candidate.recordRuntimeNeeds(
      executionID: executionID,
      principal: principal, needs: needs, now: now)
    self = candidate
    return result
  }

  private mutating func recordRuntimeNeeds(
    executionID: UUID, principal: Principal,
    needs: [DiscoveredRequirement], now: Date
  ) throws -> DiscoveredRequirementDecision {
    propagateRevocations(now: now)
    guard !needs.isEmpty, let execution = executions[executionID],
      execution.isRunning
        || (execution.endedAt.map {
          now >= $0 && now.timeIntervalSince($0) <= DiscoveredRequirement.completedReportWindow
        } == true && execution.retainUntil.map { now < $0 } == true),
      !execution.revoked,
      execution.owner == principal
        || execution.delegatedTo.map({ principal == .plugin($0) }) == true,
      let proof = execution.authorizationIDs.compactMap({ authorizations[$0] }).first(where: {
        $0.invocation.principal == principal
      }), isValid(proof)
    else { throw PermissionModelError.invalidAuthorization }
    return try recordInvocationNeeds(proof: proof, needs: needs, now: now)
  }

  /// Host file readers report a checked location before accessing it. The
  /// continuation preserves the call's digest and never widens its live proof.
  package mutating func recordHostPathNeed(
    authorizationID: UUID, path: PathRequirement, now: Date
  ) throws -> DiscoveredRequirementDecision {
    propagateRevocations(now: now)
    guard let proof = authorizations[authorizationID], !proof.finished, isValid(proof) else {
      throw PermissionModelError.invalidAuthorization
    }
    var candidate = self
    let result = try candidate.recordInvocationNeeds(proof: proof, needs: [.path(path)], now: now)
    self = candidate
    return result
  }

  private mutating func recordInvocationNeeds(
    proof: InvocationAuthorization, needs: [DiscoveredRequirement], now: Date
  ) throws -> DiscoveredRequirementDecision {
    let principal = proof.invocation.principal
    let existingIDs = runtimeSuccessors[proof.id] ?? []
    var existingChain = existingIDs.compactMap { runtimeChains[$0] }.first
    var supersededIDs: Set<UUID> = []
    var paths = existingChain?.requirements.paths ?? proof.requirements.paths
    var networks = existingChain?.requirements.networks ?? proof.requirements.networks
    for need in needs {
      switch need {
      case .path(let path): paths.append(path)
      case .network(let network):
        guard network.projectID == proof.requirements.sandboxProjectID else {
          throw PermissionModelError.invalidProjectGraph
        }
        networks.append(network)
      }
    }
    let requirements = InvocationRequirements(
      actions: proof.requirements.actions,
      paths: paths, networks: networks, mode: proof.mode,
      sandboxProjectID: proof.sandboxProjectID, execution: proof.requirements.execution,
      providers: proof.requirements.providers)
    if let chain = existingChain {
      let seeds = existingIDs.union(chain.carriedIDs).compactMap { requests[$0] }
      let ids = Set(inheritedRequests(seeds).map(\.id))
      let live = ids.allSatisfy {
        requests[$0].map { $0.status.isUnconsumed && now < $0.expiresAt } == true
      }
      let unanswered = existingIDs.allSatisfy { requests[$0]?.status == .pending }
      if !live || (unanswered && chain.requirements != requirements) {
        // An execution can report new needs after a request batch expires. Rebuild
        // from its consumed proof, never renew an unconsumed one-time answer.
        supersededIDs = ids
        existingChain = nil
      }
    }
    if let existingChain {
      let seeds = existingIDs.union(existingChain.carriedIDs).compactMap { requests[$0] }
      let ids = Set(inheritedRequests(seeds).map(\.id))
      if existingChain.requirements == requirements {
        return .requests(existingIDs.compactMap { requests[$0] })
      }
      var basis = inheritedBasis(ids.compactMap { requests[$0] })
      let evidence = ids.compactMap { requests[$0] }
      let resolution = evaluate(
        requirements, principal: principal, oneTimeRequests: evidence, basis: basis)
      if let denial = resolution.denial { return .denied(denial) }
      for element in proof.basis {
        if case .connection(let id, _) = element, let connection = environment.connections[id],
          let denial = evaluateCeiling(
            connection.attenuation, requirements: requirements,
            principal: principal, requests: evidence
          ).denial
        {
          return .denied(denial)
        }
      }
      basis.formUnion(resolution.basis.requestEvidence)
      for id in ids {
        let old = requests[id]!
        var revised = PermissionRequest(
          identity: old.identity, invocation: old.invocation, content: old.content,
          now: old.createdAt, requirements: requirements, basis: old.basis)
        revised.status = old.status
        revised.permitIdentity = old.permitIdentity
        revised.observedPermission = old.observedPermission
        requests[id] = revised
      }
      let added = resolution.missing.filter { content in
        !evidence.contains { $0.content == content }
      }.map {
        record($0, invocation: proof.invocation, now: now, requirements: requirements, basis: basis)
      }
      basis.formUnion(added.map { .request($0.identity) })
      let allIDs = ids.union(added.map(\.id))
      let chain = RuntimeRetryChain(
        invocation: proof.invocation, originalRequirements: existingChain.originalRequirements,
        requirements: requirements, carriedIDs: existingChain.carriedIDs)
      for id in allIDs {
        requests[id]!.basis.formUnion(basis)
        runtimeChains[id] = chain
      }
      runtimeSuccessors[proof.id] = existingIDs.union(added.map(\.id))
      return .requests(runtimeSuccessors[proof.id]!.compactMap { requests[$0] })
    }
    let original = retryOrigins[proof.id] ?? proof.requirements
    let oldRequests = proof.requestIDs.compactMap { requests[$0] }
    var replacements: [BasisIdentity: BasisIdentity] = [:]
    var permits: [BasisIdentity: BasisIdentity] = [:]
    for request in oldRequests {
      guard request.status == .always || request.status == .consumed(proof.id) else {
        throw PermissionModelError.invalidAuthorization
      }
      replacements[request.identity] = allocateIdentity()
      if request.permitIdentity != nil { permits[request.identity] = allocateIdentity() }
    }
    func replacing(_ basis: Set<AuthorizationBasis>) -> Set<AuthorizationBasis> {
      Set(
        basis.requestEvidence.map { element in
          switch element {
          case .request(let id): return .request(replacements[id] ?? id)
          case .permit(let id, let permit):
            return .permit(request: replacements[id] ?? id, identity: permits[id] ?? permit)
          case .permission(let grant):
            guard case .onlyThisTime(let id, let permit) = grant.source else { return element }
            return .permission(
              PermissionGrant(
                principal: grant.principal,
                requirement: grant.requirement, scope: grant.scope,
                pluginPurpose: grant.pluginPurpose,
                source: .onlyThisTime(
                  request: replacements[id] ?? id, permit: permits[id] ?? permit)))
          default: return element
          }
        })
    }
    var basis = replacing(proof.basis)
    basis.insert(.retryOrigin(proof.identity))
    var carried: [PermissionRequest] = []
    for request in oldRequests {
      var copy = PermissionRequest(
        identity: replacements[request.identity]!,
        invocation: proof.invocation, content: request.content, now: now,
        requirements: requirements, basis: replacing(request.basis))
      copy.permitIdentity = permits[request.identity]
      copy.status = request.status == .always ? .always : .onlyThisTime
      copy.observedPermission = request.observedPermission
      carried.append(copy)
    }
    let resolution = evaluate(
      requirements, principal: principal,
      oneTimeRequests: carried, basis: basis)
    if let denial = resolution.denial { return .denied(denial) }
    // Check the execution's connection ceiling as well as standing managed limits.
    for element in proof.basis {
      if case .connection(let id, _) = element, let connection = environment.connections[id] {
        if let denial = evaluateCeiling(
          connection.attenuation, requirements: requirements,
          principal: principal, requests: carried
        ).denial {
          return .denied(denial)
        }
      }
    }
    guard !resolution.missing.isEmpty else { return .satisfied }
    // A non-requestable need must leave the current retry group answerable.
    // Retire it only after its replacement passes every policy boundary.
    for id in supersededIDs where requests[id]?.status.isUnconsumed == true {
      requests[id]!.status = .revoked
    }
    basis.formUnion(resolution.basis.requestEvidence)
    for request in carried { requests[request.id] = request }
    let pending = resolution.missing.map {
      record($0, invocation: proof.invocation, now: now, requirements: requirements, basis: basis)
    }
    basis.formUnion(pending.map { .request($0.identity) })
    let ids = Set(carried.map(\.id) + pending.map(\.id))
    let chain = RuntimeRetryChain(
      invocation: proof.invocation, originalRequirements: original,
      requirements: requirements, carriedIDs: Set(carried.map(\.id)))
    for id in ids {
      requests[id]!.basis.formUnion(basis)
      runtimeChains[id] = chain
    }
    runtimeSuccessors[proof.id] = Set(pending.map(\.id))
    return .requests(pending.map { requests[$0.id]! })
  }

  private func runtimeRetry(
    invocation: InvocationIdentity, requirements: InvocationRequirements,
    ids: Set<UUID>
  ) throws -> (requirements: InvocationRequirements, ids: Set<UUID>) {
    var effective = requirements
    var expanded = ids
    var selected: RuntimeRetryChain?
    for id in ids {
      guard let chain = runtimeChains[id] else { continue }
      guard chain.invocation == invocation, chain.originalRequirements == requirements,
        selected == nil || selected == chain
      else { throw PermissionModelError.retryMismatch }
      selected = chain
      effective = chain.requirements
      expanded.formUnion(chain.carriedIDs)
      expanded.formUnion(
        inheritedRequests([requests[id]!]).filter { $0.status == .onlyThisTime }.map(\.id))
    }
    return (effective, expanded)
  }

  private func executionPolicies(_ proofs: [InvocationAuthorization]) -> [ManagedLimits] {
    proofs.flatMap { proof in
      [currentLimits[proof.invocation.principal] ?? .init()]
        + proof.basis.compactMap {
          if case .connection(let id, _) = $0, let connection = environment.connections[id] {
            return ManagedLimits(sources: [.connection: .available(connection.attenuation)])
          }
          return nil
        }
    }
  }

  /// Reconcile before dispatch, during periodic deadline checks, and after policy
  /// edits. Adapters apply the returned ledger limits to output buffers and backend
  /// memory controls; termination IDs remain queued until explicitly acknowledged.
  @discardableResult
  package mutating func reconcileExecutionLimits(now: Date) -> RevocationResult {
    tightenExecutionLimits(now: now)
    return propagateRevocations()
  }

  private mutating func tightenExecutionLimits(now: Date) {
    for (id, var execution) in executions where !execution.revoked {
      let proofs = execution.authorizationIDs.compactMap { authorizations[$0] }
      guard
        let proposed = try? EffectiveExecutionLimits.resolve(
          execution.limitRequest,
          limits: executionPolicies(proofs))
      else { continue }
      let previous = execution.limits
      let current = proposed.tightening(previous)
      execution.limits = current
      if execution.isRunning {
        if let memory = current.memoryBytes,
          previous.memoryBytes.map({ memory < $0 }) ?? true,
          !(execution.limitCapabilities.memory && execution.limitCapabilities.liveMemory)
        {
          execution.limitEndReason = .memoryLimitUnavailable
        } else if let time = current.timeMilliseconds,
          now.timeIntervalSince(execution.startedAt) >= Double(time) / 1000
        {
          execution.limitEndReason = .timeLimit
        }
        if execution.limitEndReason != nil {
          execution.isRunning = false
          execution.endedAt = now
          execution.retainUntil = now.addingTimeInterval(TimeInterval(current.retentionSeconds))
          pendingExecutionTerminations.insert(id)
        }
      }
      if let end = execution.endedAt {
        let cap = end.addingTimeInterval(TimeInterval(current.retentionSeconds))
        execution.retainUntil = min(execution.retainUntil ?? cap, cap)
      }
      executions[id] = execution
    }
  }

  private func selectedConsent(principal: Principal, connectionID: String?) -> ModeConsent? {
    if let connectionID {
      guard let connection = activeConnection(connectionID, principal: principal) else {
        return nil
      }
      return connection.consent ?? environment.modes[principal]
    }
    return environment.modes[principal]
  }

  private func activeConnection(_ id: String, principal: Principal) -> PermissionConnection? {
    guard !environment.endedConnections.contains(id), let connection = environment.connections[id],
      connection.principal == principal
    else { return nil }
    return connection
  }

  private func consentIsValid(
    _ consent: ModeConsent, principal: Principal, currentProfileDigest: String? = nil
  ) -> Bool {
    guard !retiredConsents.contains(consent.identity) else { return false }
    if consent.mode == .fullAccess(.standing),
      consent.profileDigest != (currentProfileDigest ?? profileDigest(for: principal))
    {
      return false
    }
    if case .fullAccess(.connection(let id)) = consent.mode {
      return !environment.endedConnections.contains(id)
    }
    return consent.mode != .fullAccess(.notGranted)
  }

  private func evaluateCeiling(
    _ ceiling: ManagedPolicy, requirements: InvocationRequirements,
    principal: Principal, requests: [PermissionRequest]
  ) -> InvocationResolution {
    guard
      let (expanded, providerBasis) = providerRequirements(
        requirements, principal: principal, connection: ceiling)
    else { return InvocationResolution(denial: .authorizationRevoked) }
    var result = InvocationEvaluation.evaluate(
      expanded, principal: principal, permissions: permissions(for: principal),
      limits: ManagedLimits(sources: [.connection: .available(ceiling)]),
      trustedHosts: trustedHosts,
      settings: { projectID in
        sandboxSettings.settings(for: principal, sourceProjectID: projectID)
      }, pathResolver: { _ in self.pathResolver }, oneTimeRequests: requests)
    result.basis.formUnion(providerBasis)
    return result
  }

  private func evaluate(
    _ requirements: InvocationRequirements, principal: Principal,
    oneTimeRequests: [PermissionRequest] = [], basis: Set<AuthorizationBasis> = [],
    connectionID: String? = nil, admission: Bool = false
  ) -> InvocationResolution {
    if admission, let connectionID, activeConnection(connectionID, principal: principal) == nil {
      return InvocationResolution(denial: .authorizationRevoked)
    }
    let connection =
      connectionID.flatMap { environment.connections[$0]?.attenuation }
      ?? basis.compactMap { element -> ManagedPolicy? in
        if case .connection(let id, _) = element { return environment.connections[id]?.attenuation }
        return nil
      }.first
    guard
      let (expanded, providerBasis) = providerRequirements(
        requirements, principal: principal, connection: connection)
    else { return InvocationResolution(denial: .authorizationRevoked) }
    var result = InvocationEvaluation.evaluate(
      expanded, principal: principal, permissions: permissions(for: principal),
      limits: currentLimits[principal] ?? .init(), trustedHosts: trustedHosts,
      settings: { projectID in
        sandboxSettings.settings(for: principal, sourceProjectID: projectID)
      }, pathResolver: { _ in self.pathResolver }, oneTimeRequests: oneTimeRequests,
      recordedBasis: basis)
    result.basis.formUnion(providerBasis)
    if admission {
      if !requirements.mode.isSandbox {
        guard let consent = selectedConsent(principal: principal, connectionID: connectionID),
          !consent.mode.isSandbox
        else {
          return InvocationResolution(denial: .fullAccessRequiresConsent)
        }
        guard consentIsValid(consent, principal: principal) else {
          return InvocationResolution(denial: .authorizationRevoked)
        }
        result.basis.insert(.consent(consent.identity))
      }
      if let connectionID, let connection = activeConnection(connectionID, principal: principal) {
        let ceiling = evaluateCeiling(
          connection.attenuation, requirements: expanded,
          principal: principal, requests: oneTimeRequests)
        if let denial = ceiling.denial { return InvocationResolution(denial: denial) }
        result.basis.insert(.connection(id: connectionID, ceiling: connection.attenuation.identity))
      }
    }
    if result.isAllowed {
      for element in basis {
        if case .connection(let id, _) = element, let connection = environment.connections[id] {
          result.basis = restricting(
            result.basis, by: connection.attenuation,
            requirements: expanded, principal: principal, requests: oneTimeRequests)
        }
      }
    }
    return result
  }

  private func restricting(
    _ basis: Set<AuthorizationBasis>, by ceiling: ManagedPolicy,
    requirements: InvocationRequirements, principal: Principal, requests: [PermissionRequest]
  ) -> Set<AuthorizationBasis> {
    let restricted = evaluateCeiling(
      ceiling, requirements: requirements, principal: principal, requests: requests)
    return Set(
      basis.map { element in
        switch element {
        case .sandbox(let original):
          let ceilings = restricted.basis.compactMap { candidate -> SandboxAccessBasis? in
            if case .sandbox(let profile) = candidate, profile.projectID == original.projectID {
              return profile
            }
            return nil
          }
          let hostNames = Set(trustedHosts.map(\.host))
          var network = original.network
          var denied = original.managedDeniedReadLocations
          for limit in ceilings {
            denied.formUnion(limit.managedDeniedReadLocations)
            if let hosts = limit.network.hosts(trustedHosts: hostNames) {
              let combined =
                network.hosts(trustedHosts: hostNames).map { NetworkHost.intersection($0, hosts) }
                ?? hosts
              network = combined.isEmpty ? .none : .custom(hosts: combined, includesTrusted: false)
            }
          }
          return .sandbox(
            SandboxAccessBasis(
              projectID: original.projectID, settings: original.settings,
              managedDeniedReadLocations: denied, network: network))
        case .path(let original):
          guard let exclusions = original.excludedSubtrees else { return element }
          let matches = restricted.basis.compactMap { candidate -> PathAccessBasis? in
            if case .path(let path) = candidate, path.path == original.path,
              path.operation == original.operation,
              path.location == original.location, path.purpose == original.purpose,
              path.readableDescendant == original.readableDescendant
            {
              return path
            }
            return nil
          }
          return .path(
            PathAccessBasis(
              path: original.path, operation: original.operation,
              location: original.location, purpose: original.purpose,
              readableDescendant: original.readableDescendant,
              sandboxProjectID: original.sandboxProjectID,
              excludedSubtrees: matches.reduce(exclusions) { $0.union($1.excludedSubtrees ?? []) },
              ruleIdentities: matches.reduce(original.ruleIdentities) {
                $0.union($1.ruleIdentities)
              }))
        default: return element
        }
      }
    ).union(
      restricted.basis.filter {
        if case .network(let rule) = $0 { return rule.policySource == .connection }
        return false
      })
  }

  private func profileDigest(for principal: Principal, environmentDigest: String? = nil) -> String {
    let permissions = permissions(for: principal)
    let grants = permissions.entries.map { permission, state in
      ProfileDigest.canonical(permission) + ":" + ProfileDigest.canonical(state)
        + ":" + ProfileDigest.canonical(permissions.grantID(for: permission))
    }.sorted()
    let settings = sandboxSettings.entries.filter { $0.key.principal == principal }.map {
      $0.key.projectID + ":" + ProfileDigest.canonical($0.value)
    }.sorted()
    let providerSettings: String
    if case .plugin(let identity) = principal, let provider = sandboxSettings.providers[identity] {
      providerSettings = ProfileDigest.canonical(provider)
    } else {
      providerSettings = ""
    }
    return ProfileDigest.hash(
      providerSettings + ProfileDigest.canonical(grants)
        + ProfileDigest.canonical(settings) + (environmentDigest ?? profileEnvironmentDigest()))
  }

  private func profileEnvironmentDigest() -> String {
    let paths = environment.paths.map {
      // sourceID is projected from the host's durable derived-project records.
      // Derived registrations inherit source authority and do not enlarge saved consent.
      ProfileDigest.ordered($0.registeredProjects.filter { $0.sourceID == nil })
        + ProfileDigest.canonical($0.pathRules)
        + ProfileDigest.canonical($0.outsideUserDataIdentity)
    }
    return ProfileDigest.canonical(paths) + ProfileDigest.canonical(environment.trustedHosts)
  }

  private func inheritedRequests(_ retries: [PermissionRequest]) -> [PermissionRequest] {
    var inherited: [PermissionRequest] = []
    var visited: Set<UUID> = []
    var remaining = retries
    while let request = remaining.popLast() {
      guard visited.insert(request.id).inserted else { continue }
      inherited.append(request)
      remaining.append(
        contentsOf: request.basis.compactMap(\.requestID).compactMap { requests[$0] })
    }
    return inherited
  }

  private func inheritedBasis(_ retries: [PermissionRequest]) -> Set<AuthorizationBasis> {
    inheritedRequests(retries).reduce(into: []) { $0.formUnion($1.basis) }
  }

  private mutating func validateRetries(
    _ retries: [PermissionRequest], basis: Set<AuthorizationBasis>,
    requirements: InvocationRequirements, now: Date
  ) -> Bool {
    guard let first = retries.first else { return true }
    let principal = first.content.principal
    let valid =
      basisRemainsValid(
        basis,
        requirements: requirements,
        principal: principal,
        now: now)
    if !valid {
      for request in retries { requests[request.id]!.status = .revoked }
      propagateRevocations()
    }
    return valid
  }

  private func requireAnsweredDependencies(_ basis: Set<AuthorizationBasis>, retryIDs: Set<UUID>)
    throws
  {
    for id in basis.compactMap(\.requestID) {
      guard let request = requests[id] else { throw PermissionModelError.invalidAuthorization }
      switch request.status {
      case .always: break
      case .onlyThisTime where retryIDs.contains(id): break
      case .consumed where callbackRequestOwner(id, basis: basis) != nil: break
      default: throw PermissionModelError.invalidAuthorization
      }
    }
  }

  private mutating func consumeRetries(_ retries: [PermissionRequest], authorizationID: UUID) {
    guard retries.contains(where: { $0.status == .onlyThisTime }) else { return }
    let ids = Set(retries.map(\.id)).union(inheritedBasis(retries).compactMap(\.requestID))
    let consumed = ids.filter { id in
      guard let request = requests[id] else { return false }
      return request.status == .onlyThisTime
        || inheritedBasis([request]).compactMap(\.requestID).contains {
          requests[$0]?.status == .onlyThisTime
        }
    }
    for id in consumed { requests[id]!.status = .consumed(authorizationID) }
  }

  private func networkBasis(_ content: NetworkRequestContent)
    -> NetworkAccessBasis?
  {
    let network =
      sandboxSettings.settings(for: content.principal, sourceProjectID: content.projectID).network
    return InvocationEvaluation.networkBasis(content, access: network, trustedHosts: trustedHosts)
  }

  private mutating func record(
    _ content: RequestContent, invocation: InvocationIdentity, now: Date,
    requirements: InvocationRequirements, basis: Set<AuthorizationBasis> = []
  ) -> PermissionRequest {
    if let existing = requests.values.first(where: {
      $0.invocation == invocation && $0.content == content && $0.status == .pending
        && $0.requirements == requirements
        && $0.basis.subtracting([.request($0.identity)]) == basis
        && now < $0.expiresAt
    }) {
      return existing
    }
    var request = PermissionRequest(
      identity: allocateIdentity(), invocation: invocation, content: content, now: now,
      requirements: requirements, basis: basis)
    request.basis.insert(.request(request.identity))
    if let requirement = request.requirement {
      request.observedPermission = permissions(for: content.principal).state(
        for: requirement.permission)
    }
    requests[request.id] = request
    return request
  }

  private mutating func pendingRequest(_ id: UUID, now: Date) throws -> PermissionRequest {
    propagateRevocations(now: now)
    guard let original = requests[id] else { throw PermissionModelError.unknownRequest }
    guard now < original.expiresAt else { throw PermissionModelError.expiredRequest }
    propagateRevocations(now: now)
    let request = requests[id]!
    guard request.status != .revoked else { throw PermissionModelError.invalidAuthorization }
    guard request.status == .pending else { throw PermissionModelError.alreadyAnswered }
    return request
  }

  private mutating func matchingRetries(
    _ ids: Set<UUID>, invocation: InvocationIdentity, requirements: InvocationRequirements,
    now: Date
  ) throws -> [PermissionRequest] {
    propagateRevocations(now: now)
    return try ids.compactMap { id in
      guard let request = requests[id] else { throw PermissionModelError.unknownRequest }
      guard request.invocation == invocation else { throw PermissionModelError.retryMismatch }
      guard request.requirements == requirements else { return nil }
      guard now < request.expiresAt else { throw PermissionModelError.expiredRequest }
      switch request.status {
      case .onlyThisTime, .always: return request
      case .consumed: throw PermissionModelError.requestConsumed
      default: throw PermissionModelError.invalidAuthorization
      }
    }
  }
}

/// A transaction commits all grant/request/execution changes and the termination queue
/// (including acknowledgements) or none. Implementations persist the complete ledger and
/// must serialize concurrent transactions, including across processes for durable stores.
/// Before committing, call `candidate.commitTransaction(replacing: current)` using
/// the store's current ledger, then persist the resulting complete candidate.
/// The closure is synchronous so no suspension can split retry consumption from its grant.
package protocol PermissionStore: Sendable {
  func read() async throws -> PermissionLedger
  func transaction<Result: Sendable>(
    _ body: @escaping @Sendable (inout PermissionLedger) throws -> Result
  ) async throws -> Result
}

package actor InMemoryPermissionStore: PermissionStore {
  private var ledger = PermissionLedger()

  package init() {}

  package func read() -> PermissionLedger { ledger }

  package func transaction<Result: Sendable>(
    _ body: @escaping @Sendable (inout PermissionLedger) throws -> Result
  ) throws -> Result {
    var candidate = ledger
    let result = try body(&candidate)
    try candidate.commitTransaction(replacing: ledger)
    ledger = candidate
    return result
  }
}

extension PermissionLedger {
  package mutating func setProviderSandboxSettings(
    _ proposed: ProviderSandboxSettings?, for identity: PluginIdentity, expectedRevision: UInt64
  ) throws -> RevocationResult {
    guard suspendedAuthority == nil else { throw PermissionModelError.authoritySuspended }
    return try commit(expectedRevision: expectedRevision) { ledger in
      var proposed = proposed
      try proposed?.commit(against: ledger.sandboxSettings.providers[identity], in: &ledger)
      ledger.sandboxSettings.providers[identity] = proposed
      return ledger.propagateRevocations()
    }
  }

  package func canApproveReadException(
    at path: CanonicalPath, for identity: PluginIdentity, settings: SandboxSettings,
    limits: ManagedLimits
  ) -> Bool {
    pathResolver?.canApproveReadException(at: path, settings: settings, limits: limits) == true
  }
}
