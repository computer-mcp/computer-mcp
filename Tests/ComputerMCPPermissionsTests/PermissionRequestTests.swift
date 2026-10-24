import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsRequestTests {
  @Test func permissionAnswersPreserveHigherGrantsAndReturnRevocationResults() throws {
    var ledger = PermissionLedger()
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.project("project"), .read)], now: instant))
    try ledger.setPermission(
      .granted(.write), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.project("project"), .write)], now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    let answer = try ledger.answer(pending.id, with: .always, now: instant)
    #expect(answer.executionsToTerminate.isEmpty)
    #expect(ledger.permissions(for: client).state(for: .project("project")) == .granted(.write))
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .readResult, now: instant)
        == .allowed)
    #expect(
      try ledger.setPermission(
        .granted(.read), for: .project("project"), principal: client,
        expectedRevision: ledger.revision
      )
      .executionsToTerminate == [running.id])
  }

  @Test func managedDenialPreventsRecordingAnyPermissionRequest() throws {
    var ledger = PermissionLedger()
    var ceilings = Permissions()
    try ceilings.set(.denied, for: .screen)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits[(invocation()).principal] = ManagedLimits(
        owner: .available(ManagedPolicy(permissionCeilings: ceilings)))
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.authorize(
        invocation: invocation(),
        actions: [action(.unifiedLogs), action()],
        now: instant)
        == .denied(.managedLimit([.owner])))
    #expect(ledger.requests.isEmpty)
  }

  @Test func oneTimeMatchesExactlyAndRetainsResultsUntilRevoked() throws {
    var ledger = PermissionLedger()
    let call = invocation()
    let pending = try request(
      from: ledger.authorize(invocation: call, actions: [action()], now: instant))
    #expect(pending.expiresAt == instant.addingTimeInterval(86_400))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    for mismatch in [
      invocation(principal: otherClient), invocation(tool: "other"),
      invocation(project: "other"), invocation(digest: "different"),
    ] {
      #expect(throws: PermissionModelError.retryMismatch) {
        try ledger.authorize(
          invocation: mismatch, actions: [action()], retryIDs: [pending.id], now: instant)
      }
    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: call, actions: [action()],
        retryIDs: [pending.id], now: instant))
    #expect(ledger.permissions(for: client).state(for: .screen) == .notGranted)
    #expect(throws: PermissionModelError.requestConsumed) {
      try ledger.authorize(
        invocation: call, actions: [action()], retryIDs: [pending.id], now: instant)
    }
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    try ledger.finishInvocation(allowed.id)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    }
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .writeInput, now: instant)
        == .allowed)
    #expect(
      ledger.executionAccess(
        running.id, principal: otherClient, operation: .readResult, now: instant)
        == .denied(.executionOwner))
    let later = instant.addingTimeInterval(100_000)
    try ledger.finishExecution(running.id, retainUntil: later.addingTimeInterval(100))
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .readResult, now: later)
        == .allowed)
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .writeInput, now: later)
        == .denied(.executionEnded))
    #expect(
      ledger.executionAccess(
        running.id, principal: client, operation: .readResult, now: later.addingTimeInterval(100))
        == .denied(.resultExpired))
    let revoked = try ledger.revoke(
      principal: client, permission: .screen, expectedRevision: ledger.revision)
    #expect(revoked.executionsToTerminate.isEmpty)
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .readResult, now: later)
        == .denied(.authorizationRevoked))
    try ledger.setPermission(
      .granted(.access), for: .screen, principal: client, expectedRevision: ledger.revision)
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .readResult, now: later)
        == .denied(.authorizationRevoked))
  }

  @Test func concurrentReplayHasExactlyOneWinner() async throws {
    let store = InMemoryPermissionStore()
    let pending = try await store.transaction { ledger in
      try request(
        from: ledger.authorize(invocation: invocation(), actions: [action()], now: instant))
    }
    let answer = try await store.transaction {
      try $0.answer(pending.id, with: .onlyThisTime, now: instant)
    }
    #expect(answer.executionsToTerminate.isEmpty)
    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
      for _ in 0..<32 {
        group.addTask {
          do {
            return try await store.transaction { ledger in
              let decision = try ledger.authorize(
                invocation: invocation(), actions: [action()],
                retryIDs: [pending.id], now: instant)
              if case .allowed = decision { return true }
              return false
            }
          } catch {
            #expect(error as? PermissionModelError == .requestConsumed)
            return false
          }
        }
      }
      var count = 0
      for await success in group { if success { count += 1 } }
      return count
    }
    #expect(successes == 1)
    #expect(await store.read().authorizations.count == 1)
  }

  @Test func transactionRollsBackOnFailure() async throws {
    let store = InMemoryPermissionStore()
    await #expect(throws: PermissionModelError.invalidAuthorization) {
      try await store.transaction { ledger in
        try ledger.setPermission(
          .granted(.access), for: .screen, principal: client, expectedRevision: ledger.revision)
        throw PermissionModelError.invalidAuthorization
      }
    }
    #expect(await store.read().permissions(for: client).state(for: .screen) == .notGranted)
  }

  @Test func expiresAtExactlyOneDayAndAlwaysSurvivesRequestExpiry() throws {
    var ledger = PermissionLedger()
    let pending = try request(
      from: ledger.authorize(invocation: invocation(), actions: [action()], now: instant))
    var expired = ledger
    #expect(throws: PermissionModelError.expiredRequest) {
      try expired.answer(pending.id, with: .always, now: pending.expiresAt)
    }
    #expect(expired.requests[pending.id]?.status == .revoked)
    try ledger.answer(pending.id, with: .always, now: instant)
    #expect(throws: PermissionModelError.alreadyAnswered) {
      try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    }
    let allowed = try authorization(
      from: ledger.authorize(invocation: invocation(), actions: [action()], now: pending.expiresAt))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    #expect(
      try ledger.revoke(principal: client, permission: .screen, expectedRevision: ledger.revision)
        .executionsToTerminate == [
          execution.id
        ])
    #expect(
      try ledger.authorize(invocation: invocation(), actions: [action()], now: instant)
        == .denied(.permissionDenied(.screen)))
  }

  @Test func deniedRequirementPreventsRequestsAndOneTimeConsumption() throws {
    var ledger = PermissionLedger()
    let pending = try request(
      from: ledger.authorize(invocation: invocation(), actions: [action()], now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    try ledger.setPermission(
      .denied, for: .skills, principal: client, expectedRevision: ledger.revision)
    let count = ledger.requests.count
    #expect(
      try ledger.authorize(
        invocation: invocation(), actions: [action(), action(.skills), action(.unifiedLogs)],
        retryIDs: [pending.id], now: instant) == .denied(.permissionDenied(.skills)))
    #expect(ledger.requests.count == count)
    #expect(ledger.requests[pending.id]?.status == .onlyThisTime)
  }

  @Test func multipleMissingPermissionsAreConsumedAtomically() throws {
    var ledger = PermissionLedger()
    let actions = [action(), action(.unifiedLogs)]
    let decision = try ledger.authorize(invocation: invocation(), actions: actions, now: instant)
    guard case .requests(let pending) = decision else {
      Issue.record("Expected two requests")
      return
    }
    #expect(pending.count == 2)
    try ledger.answer(pending[0].id, with: .onlyThisTime, now: instant)
    _ = try ledger.authorize(
      invocation: invocation(), actions: actions, retryIDs: [pending[0].id], now: instant)
    #expect(ledger.requests[pending[0].id]?.status == .onlyThisTime)
    try ledger.answer(pending[1].id, with: .onlyThisTime, now: instant)
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: actions,
        retryIDs: Set(pending.map(\.id)), now: instant))
    #expect(allowed.requestIDs.count == 2)
  }

  @Test(arguments: [PluginIdentity.package("plugin"), .localServer("server")])
  func revokingDelegationAffectsOnlyItsClient(target: PluginIdentity) throws {
    var ledger = PermissionLedger()
    let permission: Permission
    let value: PermissionValue
    switch target {
    case .package(let id):
      permission = .plugin(id)
      value = .use
    case .localServer(let id):
      permission = .mcpServer(id)
      value = .all
    }
    var executions: [Principal: AuthorizedExecution] = [:]
    for principal in [client, otherClient] {
      try ledger.setPermission(
        .granted(value), for: permission, principal: principal, expectedRevision: ledger.revision)
      let allowed = try authorization(
        from: ledger.authorize(
          invocation: invocation(principal: principal),
          actions: [action(permission, value)], now: instant))
      let plugin = try authorization(
        from: ledger.authorize(
          invocation: invocation(principal: .plugin(target)), actions: [action(.skills)],
          now: instant))
      executions[principal] = try ledger.startExecution(
        owner: principal, delegatedTo: target, authorizationIDs: [allowed.id, plugin.id])
    }
    let own = try #require(executions[client])
    let other = try #require(executions[otherClient])
    #expect(
      try ledger.revoke(
        principal: client, permission: permission, expectedRevision: ledger.revision
      ).executionsToTerminate == [own.id]
    )
    #expect(
      ledger.executionAccess(other.id, principal: otherClient, operation: .readResult, now: instant)
        == .allowed)
  }

  @Test func managedTighteningInvalidatesRunningAndLaterCalls() throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.write), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let write = action(.project("project"), .write)
    let allowed = try authorization(
      from: ledger.authorize(invocation: invocation(), actions: [write], now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    let cap = ManagedLimits(
      machine: .available(ManagedPolicy(permissionCeilings: try granted([(.project("*"), .read)]))))
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits = [client: cap]
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate == [execution.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits[(invocation()).principal] = cap
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.authorize(
        invocation: invocation(),
        actions: [write],
        now: instant)
        == .denied(.managedLimit([.machine])))
    #expect(
      ledger.executionAccess(execution.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
  }

  @Test func connectionConsentEndsExecutionAndResultAccess() throws {
    var ledger = PermissionLedger()
    do {
      var updatedEnvironment = ledger.environment
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
      updatedEnvironment = ledger.environment
      if updatedEnvironment.modes[(invocation()).principal]?.mode
        != .fullAccess(.connection("connection"))
      {
        updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
          for: (invocation()).principal, mode: .fullAccess(.connection("connection")))
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.skills)],
        now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.endedConnections.insert("other")
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate.isEmpty)
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.endedConnections.insert("connection")
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate == [execution.id])
    #expect(
      ledger.executionAccess(execution.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
  }

  @Test func wildcardRevocationPreservesExplicitGrantAndRegrantCreatesFreshAuthority() throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.use), for: .plugin("*"), principal: client, expectedRevision: ledger.revision)
    try ledger.setPermission(
      .granted(.use), for: .plugin("explicit"), principal: client, expectedRevision: ledger.revision
    )
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action(.plugin("explicit"), .use)], now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    #expect(
      try ledger.revoke(
        principal: client, permission: .plugin("*"), expectedRevision: ledger.revision
      ).executionsToTerminate.isEmpty)
    #expect(
      ledger.executionAccess(execution.id, principal: client, operation: .readResult, now: instant)
        == .allowed)
    _ = try ledger.revoke(
      principal: client, permission: .plugin("explicit"), expectedRevision: ledger.revision)
    try ledger.setPermission(
      .granted(.use), for: .plugin("explicit"), principal: client, expectedRevision: ledger.revision
    )
    let fresh = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action(.plugin("explicit"), .use)], now: instant))
    _ = try ledger.startExecution(owner: client, authorizationIDs: [fresh.id])
  }

  @Test func registrationHasOnlyAllowOrDeclineAndCannotRequestHostData() throws {
    var ledger = PermissionLedger()
    let content = try ProjectRegistrationRequest(
      principal: client, projectID: "new", path: path("/people/me/new"), access: .write)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = TestPathEnvironment().snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.requestProjectRegistration(
        content,
        invocation: invocation(),
        now: instant))
    #expect(throws: PermissionModelError.invalidRegistrationAnswer) {
      try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    }
    #expect(throws: PermissionModelError.invalidRegistrationAnswer) {
      try ledger.answer(pending.id, with: .always, now: instant)
    }
    #expect(throws: PermissionModelError.invalidRegistrationAnswer) {
      try ledger.answerProjectRegistration(
        pending.id, registeredProject: RegisteredProject(id: "new", root: path("/other")),
        now: instant)
    }
    try ledger.answerProjectRegistration(
      pending.id, registeredProject: RegisteredProject(id: "new", root: content.path), now: instant)
    #expect(ledger.permissions(for: client).state(for: .project("new")) == .granted(.write))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = TestPathEnvironment().snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let declined = try request(
      from: ledger.requestProjectRegistration(
        content,
        invocation: invocation(),
        now: instant))
    try ledger.answerProjectRegistration(declined.id, registeredProject: nil, now: instant)
    #expect(ledger.requests[declined.id]?.status == .declined)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = TestPathEnvironment().snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.requestProjectRegistration(
        ProjectRegistrationRequest(
          principal: client, projectID: "host",
          path: path("/people/me/private/host"), access: .read),
        invocation: invocation(),
        now: instant) == .denied(.hostData))
  }
  @Test func durableStatePreservesConsumedRequestsAndExecutionProvenance() throws {
    var ledger = PermissionLedger()
    let pending = try request(
      from: ledger.authorize(invocation: invocation(), actions: [action()], now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action()],
        retryIDs: [pending.id], now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    var restored = try JSONDecoder().decode(
      PermissionLedger.self, from: JSONEncoder().encode(ledger))
    #expect(throws: PermissionModelError.requestConsumed) {
      try restored.authorize(
        invocation: invocation(), actions: [action()], retryIDs: [pending.id], now: instant)
    }
    #expect(
      try restored.revoke(
        principal: client, permission: .screen, expectedRevision: restored.revision
      ).executionsToTerminate == [
        execution.id
      ])
    #expect(
      restored.executionAccess(
        execution.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
    #expect(throws: PermissionModelError.invalidPath) {
      try JSONDecoder().decode(CanonicalPath.self, from: Data(#""/a/../secret""#.utf8))
    }
  }

  @Test func delegationRequiresPluginAuthorityAndSameInvocation() throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.use), for: .plugin("plugin"), principal: client, expectedRevision: ledger.revision)
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.plugin("plugin"), .use)], now: instant))
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.startExecution(
        owner: client, delegatedTo: .package("plugin"), authorizationIDs: [allowed.id])
    }
    let otherCall = try authorization(
      from: ledger.authorize(
        invocation: invocation(principal: .plugin(.package("plugin")), digest: "other"),
        actions: [action(.skills)], now: instant))
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.startExecution(
        owner: client, delegatedTo: .package("plugin"),
        authorizationIDs: [allowed.id, otherCall.id])
    }
  }

}
