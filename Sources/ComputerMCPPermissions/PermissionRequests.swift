import Foundation

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
}

package enum AuthorizationDecision: Equatable, Sendable {
  case allowed(InvocationAuthorization)
  case requests([PermissionRequest])
  case denied(DenialReason)
}

package enum ExecutionOperation: Sendable {
  case readResult, writeInput, cancel
}

package struct AuthorizedExecution: Equatable, Sendable, Codable {
  package let id: UUID
  package let owner: Principal
  package let delegatedTo: PluginIdentity?
  package let authorizationIDs: Set<UUID>
  package internal(set) var isRunning = true
  package internal(set) var retainUntil: Date?
  package internal(set) var revoked = false
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
package struct PermissionLedger: Sendable, Codable {
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
  private var pathResolver: PathPermissions<PathEnvironmentSnapshot>? {
    environment.paths.map(PathPermissions.init)
  }

  package init() {}

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

  package func permissions(for principal: Principal) -> Permissions {
    rules[principal] ?? .newPrincipal
  }

  package mutating func register(_ principal: Principal) {
    guard rules[principal] == nil else { return }
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
    try commit(expectedRevision: expectedRevision) { ledger in
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
    retryIDs: Set<UUID> = [], sourceProjectID: String? = nil, now: Date
  ) throws -> AuthorizationDecision {
    let resolvedSource = invocation.projectID.flatMap { pathResolver?.sourceProjectID(for: $0) }
    let requirements = InvocationRequirements(
      actions: actions, networks: networks,
      mode: environment.modes[invocation.principal]?.mode ?? .sandbox,
      sandboxProjectID: sourceProjectID ?? resolvedSource ?? invocation.projectID)
    return try authorize(
      invocation: invocation, requirements: requirements, retryIDs: retryIDs, now: now)
  }

  /// A request matches only the same invocation and exactly equal requirements.
  /// IDs for different requirements supply no authority and the call is evaluated afresh.
  package mutating func authorize(
    invocation: InvocationIdentity, requirements: InvocationRequirements,
    retryIDs: Set<UUID> = [], now: Date
  ) throws -> AuthorizationDecision {
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
      principal: invocation.principal)
    if let denial = preliminary.denial, denial != .authorizationRevoked,
      denial != .fullAccessRequiresConsent
    {
      return .denied(denial)
    }
    let retries = try matchingRetries(
      retryIDs, invocation: invocation, requirements: requirements, now: now)
    defer { propagateRevocations() }
    let inherited = inheritedBasis(retries)
    let resolution = evaluate(
      requirements,
      principal: invocation.principal,
      oneTimeRequests: retries,
      basis: inherited)
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
        if requests[id]?.requirements == requirements { requests[id]!.basis.formUnion(basis) }
      }
      return .requests(missing.map { requests[$0.id]! })
    }
    try requireAnsweredDependencies(basis, retryIDs: Set(retries.map(\.id)))
    for id in basis.compactMap(\.requestID) where requests[id]?.status == .onlyThisTime {
      requests[id]!.basis.formUnion(basis)
    }
    let identity = allocateIdentity()
    let id = identity.id
    consumeRetries(retries, authorizationID: id)
    let authorization = InvocationAuthorization(
      identity: identity, invocation: invocation, requirements: requirements, basis: basis)
    authorizations[id] = authorization
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
    try commit(expectedRevision: expectedRevision) { ledger in
      var settings = settings
      try settings.commit(against: ledger.sandboxSettings.entries[key], in: &ledger)
      ledger.sandboxSettings.entries[key] = settings
      return ledger.propagateRevocations()
    }
  }

  /// Retry validation has the same transaction contract as `authorize`.
  package mutating func authorizeNetwork(
    invocation: InvocationIdentity, host: String, sourceProjectID: String, isLocalNetwork: Bool,
    retryIDs: Set<UUID> = [], pluginPurpose: String? = nil, now: Date
  ) throws -> AuthorizationDecision {
    try authorize(
      invocation: invocation,
      requirements: InvocationRequirements(
        networks: [
          NetworkRequirement(
            host: host, projectID: sourceProjectID, isLocalNetwork: isLocalNetwork,
            pluginPurpose: pluginPurpose)
        ],
        mode: environment.modes[invocation.principal]?.mode ?? .sandbox,
        sandboxProjectID: sourceProjectID),
      retryIDs: retryIDs, now: now)
  }

  package mutating func revokeAuthorization(_ id: UUID) throws -> RevocationResult {
    guard authorizations[id] != nil else { throw PermissionModelError.unknownAuthorization }
    authorizations[id]!.revoked = true
    return propagateRevocations()
  }

  /// Invalid dependency evidence retires the request. Catch validation errors
  /// inside store transactions so that retirement commits without granting access.
  @discardableResult
  package mutating func answer(
    _ id: UUID, with answer: PermissionAnswer, now: Date
  ) throws -> RevocationResult {
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
        let key = SandboxSettingsKey(principal: content.principal, projectID: content.projectID)
        var settings = sandboxSettings.entries[key] ?? SandboxSettings()
        settings.network = settings.network.adding(content.host)
        try settings.commit(against: sandboxSettings.entries[key], in: &self)
        sandboxSettings.entries[key] = settings
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
    if let existing { return .registered(existing.projectID) }
    guard paths.projects.sourceID(for: content.projectID) == nil else {
      throw PermissionModelError.invalidProjectGraph
    }
    let request = record(
      .projectRegistration(content), invocation: invocation, now: now,
      requirements: InvocationRequirements(registration: content), basis: resolution.basis)
    requests[request.id] = request
    return .request(request)
  }

  /// The caller verifies the canonical path and registers the project in the same
  /// durable transaction. Nil means Don't Allow; registration has no one-time answer.
  @discardableResult
  package mutating func answerProjectRegistration(
    _ id: UUID, registeredProject: RegisteredProject?, now: Date
  ) throws -> RevocationResult {
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
    guard project.id == content.projectID, project.root == content.path, project.sourceID == nil
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
    owner: Principal, delegatedTo: PluginIdentity? = nil, authorizationIDs: Set<UUID>
  ) throws -> AuthorizedExecution {
    propagateRevocations()
    guard !authorizationIDs.isEmpty else { throw PermissionModelError.invalidAuthorization }
    let authorizations = try authorizationIDs.map { id in
      guard let authorization = self.authorizations[id] else {
        throw PermissionModelError.unknownAuthorization
      }
      guard !authorization.finished, authorization.executionID == nil,
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
        requests[requestID]!.basis.formUnion(resolution.basis)
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
    let execution = AuthorizedExecution(
      id: allocateIdentity().id, owner: owner, delegatedTo: delegatedTo,
      authorizationIDs: authorizationIDs)
    for id in authorizationIDs { self.authorizations[id]!.executionID = execution.id }
    executions[execution.id] = execution
    return execution
  }

  package mutating func finishExecution(_ id: UUID, retainUntil: Date) throws {
    guard executions[id] != nil else { throw PermissionModelError.unknownExecution }
    executions[id]!.isRunning = false
    executions[id]!.retainUntil = retainUntil
  }

  /// Failed revalidation revokes dependent executions and queues termination atomically.
  package mutating func executionAccess(
    _ id: UUID, principal: Principal, operation: ExecutionOperation, now: Date
  ) -> PermissionDecision {
    propagateRevocations()
    guard let execution = executions[id], execution.owner == principal else {
      return .denied(.executionOwner)
    }
    guard !execution.revoked else { return .denied(.authorizationRevoked) }
    var valid = true
    for id in execution.authorizationIDs {
      if !validateAuthorization(id) {
        valid = false
      }
    }
    guard valid else { return .denied(.authorizationRevoked) }
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
    environment: PermissionEnvironment, expectedRevision: UInt64
  ) throws -> RevocationResult {
    try commit(expectedRevision: expectedRevision) { ledger in
      var environment = environment
      for (principal, consent) in environment.modes {
        guard ledger.issuedConsents[principal]?.contains(consent) == true else {
          throw PermissionModelError.invalidAuthorization
        }
      }
      try environment.commit(against: ledger.environment, in: &ledger)
      for (principal, consent) in ledger.environment.modes
      where environment.modes[principal]?.identity != consent.identity {
        ledger.retiredConsents.insert(consent.identity)
      }
      ledger.environment = environment
      return ledger.propagateRevocations()
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

  /// Every state transition re-evaluates every live proof to a fixed point. Revocation
  /// and its durable execution notification commit together and are never undone.
  @discardableResult
  private mutating func propagateRevocations(
    now: Date? = nil
  ) -> RevocationResult {
    for (principal, consent) in environment.modes where !consent.mode.isSandbox {
      if consent.profileDigest != profileDigest(for: principal)
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
            now: now)
        {
          requests[id]!.status = .revoked
          changed = true
        }
      }
      for (id, authorization) in authorizations where !authorization.revoked {
        if !isValid(authorization) {
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
    return authorizations[id]?.revoked == false
  }

  private func isValid(
    _ authorization: InvocationAuthorization
  ) -> Bool {
    guard !authorization.revoked,
      basisRemainsValid(
        authorization.basis,
        requirements: authorization.requirements,
        principal: authorization.invocation.principal,
        authorizationID: authorization.id)
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
      }
      return grant
    }
  }

  private func basisRemainsValid(
    _ basis: Set<AuthorizationBasis>, requirements: InvocationRequirements, principal: Principal,
    authorizationID: UUID? = nil, now: Date? = nil
  ) -> Bool {
    let limits = currentLimits[principal] ?? .init()
    let mode = requirements.mode
    let evidenceRequests = evidenceRequests(basis, authorizationID: authorizationID)
    let resolution = evaluate(
      requirements,
      principal: principal,
      oneTimeRequests: evidenceRequests,
      basis: basis)
    guard resolution.denial == nil, authorizationID == nil || resolution.isAllowed else {
      return false
    }
    let permissions = permissions(for: principal)
    return basis.allSatisfy { basis in
      switch basis {
      case .permission(let grant):
        if authorizationID == nil, let now, let id = grant.source.requestID,
          requests[id].map({ now >= $0.expiresAt }) != false
        {
          return false
        }
        return PermissionEvaluation.resolveRequirement(
          principal: principal,
          action: PermissionAction(
            requirement: grant.requirement, scope: grant.scope, pluginPurpose: grant.pluginPurpose),
          permissions: permissions, mode: mode, limits: limits,
          oneTimeRequests: grant.source.requestID.flatMap { requests[$0] }.map { [$0] } ?? [],
          recordedGrant: grant, authorizationID: authorizationID
        ).decision == .allowed
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
        return recorded == mode
          && modeDenial(
            recorded,
            principal: principal) == nil
      case .consent(let identity):
        return environment.modes[principal]?.identity == identity
      case .network(let network):
        if let source = network.policySource {
          guard case .available(let policy) = limits.sources[source] else { return false }
          return network.isValid(access: policy.network, trustedHosts: trustedHosts)
        }
        let settings =
          sandboxSettings.entries[
            SandboxSettingsKey(principal: principal, projectID: network.projectID)
          ] ?? SandboxSettings()
        return network.isValid(access: settings.network, trustedHosts: trustedHosts)
      case .path(let path):
        guard let resolver = self.pathResolver else { return false }
        let sandbox =
          path.sandboxProjectID.flatMap {
            sandboxSettings.entries[SandboxSettingsKey(principal: principal, projectID: $0)]
          } ?? .init()
        return resolver.validate(
          path, principal: principal, permissions: permissions, mode: mode,
          limits: limits, sandbox: sandbox)
      case .sandbox(let original):
        guard mode.isSandbox else { return true }
        let current =
          original.projectID.flatMap {
            sandboxSettings.entries[SandboxSettingsKey(principal: principal, projectID: $0)]
          } ?? .init()
        return current.network.preservesUnboundedRule(of: original.settings.network)
          && Set(original.settings.deniedReadRules.map(\.identity)).isSubset(
            of: Set(current.deniedReadRules.map(\.identity)))
          && !current.isMoreRestrictive(
            than: original.settings, trustedHosts: Set(trustedHosts.map(\.host)))
          && !limits.deniedReadLocations.contains { path in
            !original.managedDeniedReadLocations.contains { $0.contains(path) }
          }
          && !limits.network(applying: current.network, trustedHosts: Set(trustedHosts.map(\.host)))
            .isMoreRestrictive(than: original.network, trustedHosts: Set(trustedHosts.map(\.host)))
      }
    }
  }

  private func evaluate(
    _ requirements: InvocationRequirements, principal: Principal,
    oneTimeRequests: [PermissionRequest] = [], basis: Set<AuthorizationBasis> = []
  ) -> InvocationResolution {
    let limits = currentLimits[principal] ?? .init()
    if let denial = modeDenial(
      requirements.mode,
      principal: principal)
    {
      return InvocationResolution(denial: denial)
    }
    var result = InvocationEvaluation.evaluate(
      requirements, principal: principal, permissions: permissions(for: principal),
      limits: limits, trustedHosts: trustedHosts,
      settings: { projectID in
        projectID.flatMap {
          sandboxSettings.entries[SandboxSettingsKey(principal: principal, projectID: $0)]
        } ?? .init()
      },
      pathResolver: { _ in self.pathResolver }, oneTimeRequests: oneTimeRequests,
      recordedBasis: basis)
    if let consent = environment.modes[principal], !requirements.mode.isSandbox {
      result.basis.insert(.consent(consent.identity))
    }
    return result
  }

  private func profileDigest(for principal: Principal) -> String {
    let permissions = permissions(for: principal)
    let grants = permissions.entries.map { permission, state in
      ProfileDigest.canonical(permission) + ":" + ProfileDigest.canonical(state)
        + ":" + ProfileDigest.canonical(permissions.grantID(for: permission))
    }.sorted()
    let settings = sandboxSettings.entries.filter { $0.key.principal == principal }.map {
      $0.key.projectID + ":" + ProfileDigest.canonical($0.value)
    }.sorted()
    let paths = environment.paths.map {
      ProfileDigest.ordered($0.registeredProjects) + ProfileDigest.canonical($0.pathRules)
        + ProfileDigest.canonical($0.outsideUserDataIdentity)
    }
    return ProfileDigest.hash(
      ProfileDigest.canonical(grants)
        + ProfileDigest.canonical(settings) + ProfileDigest.canonical(paths)
        + ProfileDigest.canonical(environment.trustedHosts))
  }

  private func modeDenial(_ mode: ExecutionMode, principal: Principal)
    -> DenialReason?
  {
    guard mode == (environment.modes[principal]?.mode ?? .sandbox) else {
      return .authorizationRevoked
    }
    if !mode.isSandbox {
      if let consent = environment.modes[principal], retiredConsents.contains(consent.identity) {
        return .authorizationRevoked
      }
      guard let consent = environment.modes[principal],
        consent.profileDigest == profileDigest(for: principal)
      else {
        return .fullAccessRequiresConsent
      }
    }
    if let denial = (currentLimits[principal] ?? .init()).modeDenial(mode) { return denial }
    if case .fullAccess(.connection(let id)) = mode, environment.endedConnections.contains(id) {
      return .authorizationRevoked
    }
    return nil
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
      sandboxSettings.entries[
        SandboxSettingsKey(principal: content.principal, projectID: content.projectID)
      ]?.network ?? .none
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
    _ body: @Sendable (inout PermissionLedger) throws -> Result
  ) async throws -> Result
}

package actor InMemoryPermissionStore: PermissionStore {
  private var ledger = PermissionLedger()

  package init() {}

  package func read() -> PermissionLedger { ledger }

  package func transaction<Result: Sendable>(
    _ body: @Sendable (inout PermissionLedger) throws -> Result
  ) throws -> Result {
    var candidate = ledger
    let result = try body(&candidate)
    try candidate.commitTransaction(replacing: ledger)
    ledger = candidate
    return result
  }
}
