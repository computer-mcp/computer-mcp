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
  var revokesRetries = false
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
  package let startedAt: Date
  package let limitRequest: ExecutionLimitRequest
  package let limitCapabilities: ExecutionLimitCapabilities
  package internal(set) var limits: EffectiveExecutionLimits
  package internal(set) var limitEndReason: ExecutionLimitEndReason?
  package internal(set) var endedAt: Date?
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
    retryIDs: Set<UUID> = [], connectionID: String? = nil, now: Date
  ) throws -> AuthorizationDecision {
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
    let inherited = inheritedBasis(retries)
    let resolution = evaluate(
      requirements,
      principal: invocation.principal,
      oneTimeRequests: retries,
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
        principal: invocation.principal, requests: retries)
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
    owner: Principal, delegatedTo: PluginIdentity? = nil, authorizationIDs: Set<UUID>,
    capabilities: ExecutionLimitCapabilities = .init(), now: Date = Date()
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

  package mutating func finishExecution(_ id: UUID, retainUntil: Date, now: Date = Date()) throws {
    guard executions[id] != nil else { throw PermissionModelError.unknownExecution }
    let end = executions[id]!.endedAt ?? now
    executions[id]!.isRunning = false
    executions[id]!.endedAt = end
    executions[id]!.retainUntil = min(
      executions[id]!.retainUntil ?? retainUntil, retainUntil,
      end.addingTimeInterval(TimeInterval(executions[id]!.limits.retentionSeconds)))
  }

  /// Failed revalidation revokes dependent executions and queues termination atomically.
  package mutating func executionAccess(
    _ id: UUID, principal: Principal, operation: ExecutionOperation, connectionID: String? = nil,
    now: Date
  ) -> PermissionDecision {
    propagateRevocations()
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
    environment: PermissionEnvironment, expectedRevision: UInt64, now: Date? = nil
  ) throws -> RevocationResult {
    try commit(expectedRevision: expectedRevision) { ledger in
      var environment = environment
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
      ledger.reconcileExecutionLimits(now: now ?? Date())
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

  /// Every state transition re-evaluates every live proof to a fixed point. Revocation
  /// and its durable execution notification commit together and are never undone.
  @discardableResult
  private mutating func propagateRevocations(
    now: Date? = nil
  ) -> RevocationResult {
    for (principal, consents) in issuedConsents {
      for consent in consents where !consent.mode.isSandbox {
        if (consent.mode == .fullAccess(.standing)
          && consent.profileDigest != profileDigest(for: principal))
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
      authorization.mode.isSandbox
        || authorization.basis.contains(where: {
          if case .consent = $0 { return true }
          return false
        }),
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
    let connectionCeiling = basis.compactMap { element -> ManagedPolicy? in
      if case .connection(let id, _) = element { return environment.connections[id]?.attenuation }
      return nil
    }.first
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
        return recorded == mode && limits.modeDenial(mode) == nil
      case .consent(let identity):
        return issuedConsents[principal]?.contains {
          $0.identity == identity && consentIsValid($0, principal: principal)
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
    guard !needs.isEmpty, let execution = executions[executionID], execution.isRunning,
      !execution.revoked,
      execution.owner == principal
        || execution.delegatedTo.map({ principal == .plugin($0) }) == true,
      let proof = execution.authorizationIDs.compactMap({ authorizations[$0] }).first(where: {
        $0.invocation.principal == principal
      }), isValid(proof)
    else { throw PermissionModelError.invalidAuthorization }
    let existingIDs = runtimeSuccessors[proof.id] ?? []
    var existingChain = existingIDs.compactMap { runtimeChains[$0] }.first
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
      sandboxProjectID: proof.sandboxProjectID, execution: proof.requirements.execution)
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
        for id in ids where requests[id]?.status.isUnconsumed == true {
          requests[id]!.status = .revoked
        }
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
    return propagateRevocations()
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

  private func consentIsValid(_ consent: ModeConsent, principal: Principal) -> Bool {
    guard !retiredConsents.contains(consent.identity) else { return false }
    if consent.mode == .fullAccess(.standing),
      consent.profileDigest != profileDigest(for: principal)
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
    InvocationEvaluation.evaluate(
      requirements, principal: principal, permissions: permissions(for: principal),
      limits: ManagedLimits(sources: [.connection: .available(ceiling)]),
      trustedHosts: trustedHosts,
      settings: { projectID in
        projectID.flatMap {
          sandboxSettings.entries[SandboxSettingsKey(principal: principal, projectID: $0)]
        } ?? .init()
      }, pathResolver: { _ in self.pathResolver }, oneTimeRequests: requests)
  }

  private func evaluate(
    _ requirements: InvocationRequirements, principal: Principal,
    oneTimeRequests: [PermissionRequest] = [], basis: Set<AuthorizationBasis> = [],
    connectionID: String? = nil, admission: Bool = false
  ) -> InvocationResolution {
    if admission, let connectionID, activeConnection(connectionID, principal: principal) == nil {
      return InvocationResolution(denial: .authorizationRevoked)
    }
    var result = InvocationEvaluation.evaluate(
      requirements, principal: principal, permissions: permissions(for: principal),
      limits: currentLimits[principal] ?? .init(), trustedHosts: trustedHosts,
      settings: { projectID in
        projectID.flatMap {
          sandboxSettings.entries[SandboxSettingsKey(principal: principal, projectID: $0)]
        } ?? .init()
      }, pathResolver: { _ in self.pathResolver }, oneTimeRequests: oneTimeRequests,
      recordedBasis: basis)
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
          connection.attenuation, requirements: requirements,
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
            requirements: requirements, principal: principal, requests: oneTimeRequests)
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
              path.location == original.location,
              path.readableDescendant == original.readableDescendant
            {
              return path
            }
            return nil
          }
          return .path(
            PathAccessBasis(
              path: original.path, operation: original.operation,
              location: original.location, readableDescendant: original.readableDescendant,
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
