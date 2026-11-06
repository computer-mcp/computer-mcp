import Foundation
import Testing

@testable import ComputerMCPPermissions

struct WorktreeCallbackAuthorityTests {
  @Test(arguments: ["standing", "borrowed", "fresh"], [false, true])
  func lifecycleKeepsEachPrincipalsExactGrantAfterParentStop(grant: String, providerOnce: Bool)
    throws
  {
    var fixture = try CallbackAuthorityFixture(grant: grant, providerOnce: providerOnce)
    let clientID = fixture.callbackClient.id
    let providerID = fixture.callbackProvider.id
    let ordinary = try fixture.admit(principal: client, tool: "ordinary")
    let owners = fixture.ledger.requests.mapValues(\.status)
    let parentRequests = fixture.ledger.requests.filter {
      $0.value.status == .consumed(fixture.parentClient.id)
        || $0.value.status == .consumed(fixture.parentProvider.id)
    }
    let prepared = try fixture.ledger.prepareWorktreeCallback(
      [clientID, providerID], parentExecutionID: fixture.execution.id)
    #expect(prepared[clientID]?.basis.contains(.worktreeAuthority(fixture.parentClient.id)) == true)
    #expect(
      prepared[providerID]?.basis.contains(.worktreeAuthority(fixture.parentProvider.id)) == true)
    #expect(fixture.ledger.requests.mapValues(\.status) == owners)
    for (id, request) in parentRequests { #expect(fixture.ledger.requests[id] == request) }
    for id in [clientID, providerID] {
      for requestID in try #require(prepared[id]).requestIDs
      where fixture.ledger.requests[requestID]?.status == .consumed(id) {
        #expect(
          fixture.ledger.requests[requestID]?.basis.contains(.execution(fixture.execution.id))
            == false)
      }
    }
    #expect(throws: PermissionModelError.self) {
      try fixture.ledger.startExecution(owner: client, authorizationIDs: [clientID])
    }
    try fixture.ledger.finishInvocation(fixture.parentClient.id)
    try fixture.ledger.finishInvocation(fixture.parentProvider.id)
    try fixture.ledger.finishExecution(
      fixture.execution.id, retainUntil: Date().addingTimeInterval(60))
    try fixture.ledger.authorizeWorktreeHostPath(clientID, path: path("/repo/value"), writing: true)
    try fixture.ledger.authorizeWorktreeHostPath(
      providerID, path: path("/repo/value"), writing: true)
    #expect(throws: PermissionModelError.self) { try fixture.ledger.invocationAccess(ordinary.id) }
    // Own teardown invalidates only the provider's original path authority. Its
    // execution becomes revoked without revoking the original client proof.
    _ = try fixture.ledger.revokeAuthorization(fixture.parentProvider.id)
    #expect(fixture.ledger.authorizations[fixture.parentClient.id]?.revoked == false)
    try fixture.ledger.authorizeWorktreeHostPath(clientID, path: path("/repo/value"), writing: true)
    #expect(throws: PermissionModelError.self) {
      try fixture.ledger.authorizeWorktreeHostPath(
        providerID, path: path("/repo/value"), writing: true)
    }
    _ = try fixture.ledger.revokeAuthorization(fixture.parentClient.id)
    #expect(throws: PermissionModelError.self) {
      try fixture.ledger.authorizeWorktreeHostPath(
        clientID, path: path("/repo/value"), writing: true)
    }
    try fixture.ledger.validatePersistedState()
    let encoded = try JSONEncoder().encode(fixture.ledger)
    try JSONDecoder().decode(PermissionLedger.self, from: encoded).validatePersistedState()
  }

  @Test(arguments: ["borrowed", "fresh"], [false, true])
  func retiringExactOnceGrantStillStopsOnlyItsPrincipal(grant: String, providerOnce: Bool) throws {
    var fixture = try CallbackAuthorityFixture(grant: grant, providerOnce: providerOnce)
    let callback = providerOnce ? fixture.callbackProvider : fixture.callbackClient
    let other = providerOnce ? fixture.callbackClient : fixture.callbackProvider
    let prepared = try fixture.ledger.prepareWorktreeCallback(
      [callback.id, other.id], parentExecutionID: fixture.execution.id)
    let requestID = try #require(prepared[callback.id]?.requestIDs.first)
    let request = try #require(fixture.ledger.requests[requestID])
    let originalOwner =
      grant == "fresh"
      ? callback.id
      : (providerOnce ? fixture.parentProvider.id : fixture.parentClient.id)
    #expect(request.status == .consumed(originalOwner))
    // A consumed answer cannot admit a second call or change consumption owner.
    #expect(throws: PermissionModelError.self) {
      try fixture.ledger.authorize(
        invocation: callback.invocation, requirements: callback.requirements,
        retryIDs: [requestID], callbackExecutionID: fixture.execution.id, now: Date())
    }
    #expect(fixture.ledger.requests[requestID]?.status == .consumed(originalOwner))
    try fixture.ledger.finishExecution(
      fixture.execution.id, retainUntil: Date().addingTimeInterval(60))
    _ = try fixture.ledger.retireRequest(requestID, expectedRevision: fixture.ledger.revision)
    #expect(throws: PermissionModelError.self) {
      try fixture.ledger.authorizeWorktreeHostPath(
        callback.id, path: path("/repo/value"), writing: true)
    }
    try fixture.ledger.authorizeWorktreeHostPath(other.id, path: path("/repo/value"), writing: true)
  }

  @Test(arguments: ["ended", "omitted"])
  func claimedSandboxLifecycleSurvivesNormalConnectionEnd(end: String) throws {
    var fixture = try CallbackAuthorityFixture(grant: "standing", providerOnce: false)
    let prepared = try fixture.ledger.prepareWorktreeCallback(
      [fixture.callbackClient.id, fixture.callbackProvider.id],
      parentExecutionID: fixture.execution.id)
    let clientProof = try #require(prepared[fixture.callbackClient.id])
    #expect(clientProof.mode == .sandbox)
    #expect(
      clientProof.basis.contains {
        if case .connection(let id, _) = $0 { return id == "client-link" }
        return false
      })
    try fixture.ledger.finishInvocation(fixture.parentClient.id)
    try fixture.ledger.finishInvocation(fixture.parentProvider.id)
    try fixture.ledger.finishExecution(
      fixture.execution.id, retainUntil: Date().addingTimeInterval(60))
    var environment = fixture.ledger.environment
    if end == "ended" {
      environment.endedConnections.insert("client-link")
    } else {
      environment.connections.removeValue(forKey: "client-link")
    }
    try fixture.ledger.reconcile(
      environment: environment, expectedRevision: fixture.ledger.revision)
    // Closing a channel retains its authority record for standing work, while
    // refusing a fresh admission on that ended channel.
    #expect(fixture.ledger.environment.connections["client-link"] != nil)
    #expect(fixture.ledger.environment.endedConnections.contains("client-link"))
    try fixture.ledger.authorizeWorktreeHostPath(
      fixture.callbackClient.id, path: path("/repo/value"), writing: true)
    try fixture.ledger.authorizeWorktreeHostPath(
      fixture.callbackProvider.id, path: path("/repo/value"), writing: true)
    #expect(
      try fixture.ledger.authorize(
        invocation: invocation(tool: "new-call", project: "derived"),
        requirements: .init(sandboxProjectID: "project"), connectionID: "client-link", now: Date())
        == .denied(.authorizationRevoked))
  }

  @Test(arguments: ["client-permission", "provider-permission", "client-connection-attenuated"])
  func claimedLifecyclePreservesCurrentPermissionAndConnectionChecks(change: String) throws {
    var fixture = try CallbackAuthorityFixture(grant: "standing", providerOnce: false)
    _ = try fixture.ledger.prepareWorktreeCallback(
      [fixture.callbackClient.id, fixture.callbackProvider.id],
      parentExecutionID: fixture.execution.id)
    try fixture.ledger.finishExecution(
      fixture.execution.id, retainUntil: Date().addingTimeInterval(60))
    let providerChanged = change == "provider-permission"
    if change == "client-connection-attenuated" {
      var environment = fixture.ledger.environment
      environment.connections["client-link"]!.attenuation.deniedReadLocations = [
        path("/repo/value")
      ]
      try fixture.ledger.reconcile(
        environment: environment, expectedRevision: fixture.ledger.revision)
    } else {
      try fixture.ledger.setPermission(
        .denied, for: .project("project"),
        principal: providerChanged ? .plugin(.localServer("fixture")) : client,
        expectedRevision: fixture.ledger.revision)
    }
    let refused = providerChanged ? fixture.callbackProvider : fixture.callbackClient
    let retained = providerChanged ? fixture.callbackClient : fixture.callbackProvider
    #expect(throws: PermissionModelError.self) {
      try fixture.ledger.authorizeWorktreeHostPath(
        refused.id, path: path("/repo/value"), writing: true)
    }
    try fixture.ledger.authorizeWorktreeHostPath(
      retained.id, path: path("/repo/value"), writing: true)
  }

  @Test(arguments: ["unrelated", "ended", "ambiguous"])
  func preparationRejectsInvalidParentsAtomically(attack: String) throws {
    var fixture = try CallbackAuthorityFixture(
      grant: "standing", providerOnce: false, ambiguous: attack == "ambiguous")
    var parentID = fixture.execution.id
    if attack == "unrelated" { parentID = UUID() }
    if attack == "ended" {
      try fixture.ledger.finishExecution(parentID, retainUntil: Date().addingTimeInterval(60))
    }
    let proofs = fixture.ledger.authorizations
    let requests = fixture.ledger.requests
    #expect(throws: PermissionModelError.self) {
      try fixture.ledger.prepareWorktreeCallback(
        [fixture.callbackClient.id, fixture.callbackProvider.id], parentExecutionID: parentID)
    }
    #expect(fixture.ledger.authorizations == proofs)
    #expect(fixture.ledger.requests == requests)
  }

  @Test func lifecycleCannotRetargetItsParentProjectOrPrincipal() throws {
    var fixture = try CallbackAuthorityFixture(grant: "standing", providerOnce: false)
    for identity in [
      invocation(principal: otherClient, project: "derived"), invocation(project: "project"),
    ] {
      #expect(throws: PermissionModelError.self) {
        try fixture.ledger.authorize(
          invocation: identity, requirements: .init(sandboxProjectID: "project"),
          callbackExecutionID: fixture.execution.id, now: Date())
      }
    }
    #expect(
      fixture.ledger.authorizations[fixture.callbackClient.id]?.basis.contains(
        .execution(fixture.execution.id)) == true)
  }
}

private struct CallbackAuthorityFixture {
  var ledger = PermissionLedger()
  let parentClient: InvocationAuthorization
  let parentProvider: InvocationAuthorization
  let execution: AuthorizedExecution
  var callbackClient: InvocationAuthorization
  var callbackProvider: InvocationAuthorization

  init(grant: String, providerOnce: Bool, ambiguous: Bool = false) throws {
    let provider = Principal.plugin(.localServer("fixture"))
    var ledger = PermissionLedger()
    var environment = ledger.environment
    environment.connections["client-link"] = .init(principal: client, attenuation: .init())
    environment.paths = try PathEnvironmentSnapshot(projects: [
      .init(id: "project", root: path("/repo")),
      .init(
        id: "derived", root: path("/work/job"), sourceID: "project", hostContentIdentity: UUID()),
    ])
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    let once = providerOnce ? provider : client
    for principal in [client, provider] {
      try ledger.setPermission(
        .granted(.all), for: .mcpServer("fixture"), principal: principal,
        expectedRevision: ledger.revision)
    }
    for principal in [client, provider] where grant == "standing" || principal != once {
      try ledger.setPermission(
        .granted(.write), for: .project("project"), principal: principal,
        expectedRevision: ledger.revision)
    }
    parentClient = try Self.admit(
      &ledger, principal: client, tool: "provider", writes: grant != "fresh", parent: nil)
    parentProvider = try Self.admit(
      &ledger, principal: provider, tool: "provider", writes: grant != "fresh", parent: nil)
    var parents: Set<UUID> = [parentClient.id, parentProvider.id]
    if ambiguous {
      parents.insert(
        try Self.admit(&ledger, principal: client, tool: "provider", writes: true, parent: nil)
          .id)
    }
    execution = try ledger.startExecution(
      owner: client, delegatedTo: .localServer("fixture"), authorizationIDs: parents)
    callbackClient = try Self.admit(
      &ledger, principal: client, tool: "git.worktree_remove", writes: true, parent: execution.id)
    callbackProvider = try Self.admit(
      &ledger, principal: provider, tool: "git.worktree_remove", writes: true, parent: execution.id)
    self.ledger = ledger
  }

  mutating func admit(principal: Principal, tool: String) throws -> InvocationAuthorization {
    try Self.admit(&ledger, principal: principal, tool: tool, writes: true, parent: execution.id)
  }

  private static func admit(
    _ ledger: inout PermissionLedger, principal: Principal, tool: String, writes: Bool,
    parent: UUID?
  ) throws -> InvocationAuthorization {
    let identity = invocation(principal: principal, tool: tool, project: "derived")
    var actions = writes ? [action(.project("project"), .write, scope: .project("project"))] : []
    if parent == nil { actions.append(action(.mcpServer("fixture"), .all)) }
    let requirements = InvocationRequirements(actions: actions, sandboxProjectID: "project")
    var decision = try ledger.authorize(
      invocation: identity, requirements: requirements,
      connectionID: principal == client ? "client-link" : nil, callbackExecutionID: parent,
      now: Date())
    if case .requests(let requests) = decision {
      for request in requests { try ledger.answer(request.id, with: .onlyThisTime, now: Date()) }
      decision = try ledger.authorize(
        invocation: identity, requirements: requirements,
        retryIDs: Set(requests.map(\.id)), connectionID: principal == client ? "client-link" : nil,
        callbackExecutionID: parent, now: Date())
    }
    return try authorization(from: decision)
  }
}
