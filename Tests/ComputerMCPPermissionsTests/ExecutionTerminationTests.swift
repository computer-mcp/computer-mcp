import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsExecutionTerminationTests {
  @Test func failedPolicyRetryPersistsTerminationUntilAcknowledged() async throws {
    let store = InMemoryPermissionStore()
    let (requestID, authorizationID, executionID) = try await store.transaction { ledger in
      let pending = try request(
        from: ledger.authorize(invocation: invocation(), actions: [action()], now: instant))
      try ledger.answer(pending.id, with: .always, now: instant)
      let allowed = try authorization(
        from: ledger.authorize(
          invocation: invocation(), actions: [action()], retryIDs: [pending.id], now: instant))
      let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
      return (pending.id, allowed.id, running.id)
    }
    let result = try await store.transaction { ledger in
      Result {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits[(invocation()).principal] = ManagedLimits(owner: .unreadable)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        return try ledger.authorize(
          invocation: invocation(),
          actions: [action()],
          retryIDs: [requestID],
          now: instant)
      }
    }
    #expect(try result.get() == .denied(.managedLimit([.owner])))
    let snapshot = await store.read()
    #expect(snapshot.requests[requestID]?.status == .revoked)
    #expect(snapshot.executions[executionID]?.revoked == true)
    #expect(snapshot.pendingExecutionTerminations == [executionID])
    #expect(await store.read().pendingExecutionTerminations == [executionID])
    #expect(
      try await store.transaction {
        try $0.reconcile(environment: PermissionEnvironment(), expectedRevision: $0.revision)
          .executionsToTerminate
      } == [executionID])
    var restored = try roundTrip(await store.read())
    #expect(restored.pendingExecutionTerminations == [executionID])
    #expect(
      try restored.reconcile(
        environment: PermissionEnvironment(), expectedRevision: restored.revision
      ).executionsToTerminate == [
        executionID
      ])
    try restored.finishExecution(executionID, retainUntil: instant.addingTimeInterval(100))
    #expect(restored.pendingExecutionTerminations == [executionID])
    restored.acknowledgeExecutionTerminations([executionID])
    restored.acknowledgeExecutionTerminations([executionID, UUID()])
    restored = try roundTrip(restored)
    #expect(restored.pendingExecutionTerminations.isEmpty)
    #expect(
      try restored.reconcile(
        environment: PermissionEnvironment(), expectedRevision: restored.revision
      ).executionsToTerminate.isEmpty)
    #expect(try restored.revokeAuthorization(authorizationID).executionsToTerminate.isEmpty)
    #expect(
      restored.executionAccess(
        executionID, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
  }

  enum Invalidation: CaseIterable, Sendable {
    case revokePermission, denyPermission, lowerPermission, clearPermission, revokeAuthorization
    case sandboxRead, sandboxNetwork, ownerCeiling, machineCeiling, ownerUnreadable,
      machineUnreadable
    case managedRead, managedNetwork, managedMode, endConnection
  }

  @Test(arguments: Invalidation.allCases)
  func invalidationQueuesEveryRunningDependent(source: Invalidation) async throws {
    let store = InMemoryPermissionStore()
    let ids = try await store.transaction { ledger in
      let key = SandboxSettingsKey(principal: client, projectID: "project")
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.setSandboxSettings(
        SandboxSettings(network: .full),
        for: key, expectedRevision: ledger.revision)
      try ledger.setPermission(
        .granted(.write), for: .project("project"), principal: client,
        expectedRevision: ledger.revision)
      let mode: ExecutionMode =
        source == .endConnection || source == .managedMode
        ? .fullAccess(.connection("connection")) : .sandbox
      do {
        var updatedEnvironment = ledger.environment
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
        updatedEnvironment = ledger.environment
        if updatedEnvironment.modes[(invocation()).principal]?.mode != mode {
          updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
            for: (invocation()).principal, mode: mode)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
      }
      let allowed = try authorization(
        from: ledger.authorize(
          invocation: invocation(),
          actions: [action(.project("project"), .write)],
          now: instant))
      let first = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
      let secondGrant = try authorization(
        from: ledger.authorize(
          invocation: invocation(digest: "second"), actions: [action(.project("project"), .write)],
          now: instant))
      let second = try ledger.startExecution(owner: client, authorizationIDs: [secondGrant.id])
      let finishedGrant = try authorization(
        from: ledger.authorize(
          invocation: invocation(digest: "finished"),
          actions: [action(.project("project"), .write)], now: instant))
      let finished = try ledger.startExecution(owner: client, authorizationIDs: [finishedGrant.id])
      try ledger.finishExecution(finished.id, retainUntil: instant.addingTimeInterval(100))
      let independent = try authorization(
        from: ledger.authorize(
          invocation: invocation(principal: otherClient), actions: [action(.skills)], now: instant))
      let other = try ledger.startExecution(owner: otherClient, authorizationIDs: [independent.id])
      return (
        authorizations: [allowed.id, secondGrant.id, finishedGrant.id], first: first.id,
        second: second.id, other: other.id
      )
    }
    let effect = try await store.transaction { ledger in
      let key = SandboxSettingsKey(principal: client, projectID: "project")
      switch source {
      case .revokePermission:
        return try ledger.revoke(
          principal: client, permission: .project("project"), expectedRevision: ledger.revision)
      case .denyPermission:
        return try ledger.setPermission(
          .denied, for: .project("project"), principal: client, expectedRevision: ledger.revision)
      case .lowerPermission:
        return try ledger.setPermission(
          .granted(.read), for: .project("project"), principal: client,
          expectedRevision: ledger.revision)
      case .clearPermission:
        return try ledger.setPermission(
          .notGranted, for: .project("project"), principal: client,
          expectedRevision: ledger.revision)
      case .revokeAuthorization:
        for id in ids.authorizations { _ = try ledger.revokeAuthorization(id) }
        return RevocationResult(executionsToTerminate: ledger.pendingExecutionTerminations)
      case .sandboxRead:
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            [], preserving: ledger.environment.trustedHosts)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        return try ledger.setSandboxSettings(
          SandboxSettings(network: .full, deniedReadLocations: [path("/private")]),
          for: key, expectedRevision: ledger.revision)
      case .sandboxNetwork:
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            [], preserving: ledger.environment.trustedHosts)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        return try ledger.setSandboxSettings(
          SandboxSettings(network: .none),
          for: key, expectedRevision: ledger.revision)
      case .ownerCeiling, .machineCeiling:
        var ceilings = Permissions()
        try ceilings.set(.granted(.read), for: .project("project"))
        let policy = ManagedPolicy(permissionCeilings: ceilings)
        return try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [
            client: source == .ownerCeiling
              ? ManagedLimits(owner: .available(policy))
              : ManagedLimits(machine: .available(policy))
          ]
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      case .ownerUnreadable:
        return try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [client: ManagedLimits(owner: .unreadable)]
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      case .machineUnreadable:
        return try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [client: ManagedLimits(machine: .unreadable)]
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      case .managedRead:
        return try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [
            client: ManagedLimits(
              owner: .available(ManagedPolicy(deniedReadLocations: [path("/private")])))
          ]
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      case .managedNetwork:
        return try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [
            client: ManagedLimits(owner: .available(ManagedPolicy(network: .none)))
          ]
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      case .managedMode:
        return try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [
            client: ManagedLimits(owner: .available(ManagedPolicy(allowsFullAccess: false)))
          ]
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      case .endConnection:
        return try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.endedConnections.insert("connection")
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      }
    }
    let expected: Set<UUID> = [ids.first, ids.second]
    #expect(effect.executionsToTerminate == expected)
    let snapshot = await store.read()
    #expect(snapshot.pendingExecutionTerminations == expected)
    #expect(snapshot.executions[ids.first]?.revoked == true)
    #expect(snapshot.executions[ids.second]?.revoked == true)
    #expect(snapshot.executions[ids.other]?.revoked == false)
    var restored = try roundTrip(snapshot)
    #expect(restored.pendingExecutionTerminations == expected)
    #expect(
      try restored.reconcile(
        environment: PermissionEnvironment(), expectedRevision: restored.revision
      ).executionsToTerminate == expected)
    restored.acknowledgeExecutionTerminations([ids.first])
    #expect(restored.pendingExecutionTerminations == [ids.second])
    restored.acknowledgeExecutionTerminations([ids.first])
    #expect(
      try restored.reconcile(
        environment: PermissionEnvironment(), expectedRevision: restored.revision
      ).executionsToTerminate == [ids.second]
    )
    restored.acknowledgeExecutionTerminations([ids.second])
    restored = try roundTrip(restored)
    #expect(
      try restored.reconcile(
        environment: PermissionEnvironment(), expectedRevision: restored.revision
      ).executionsToTerminate.isEmpty)
  }

  @Test(arguments: ["start", "access", "reconcile"])
  func pathRevalidationQueuesTerminationInTheSameTransaction(entry: String) async throws {
    let store = InMemoryPermissionStore()
    let original = PathPermissions(environment: TestPathEnvironment())
    let (authorizationID, executionID) = try await store.transaction { ledger in
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (original).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      let allowed = try authorization(
        from: ledger.authorize(
          invocation: invocation(),
          actions: [action(.skills, scope: .path(path("/people/me/toolchains/swift")))],
          now: instant))
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (original).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      let running = try ledger.startExecution(
        owner: client,
        authorizationIDs: [allowed.id])
      return (allowed.id, running.id)
    }
    try await store.transaction { ledger in
      var environment = TestPathEnvironment()
      environment.developerLocations = []
      let changed = PathPermissions(environment: environment)
      switch entry {
      case "start":
        let result = Result {
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.paths = (changed).environment.snapshot(
              preserving: updatedEnvironment.paths)
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

          }
          return try ledger.startExecution(
            owner: client,
            authorizationIDs: [authorizationID])
        }
        #expect(throws: PermissionModelError.invalidAuthorization) { try result.get() }
      case "access":
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (changed).environment.snapshot(
            preserving: updatedEnvironment.paths)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        #expect(
          ledger.executionAccess(
            executionID,
            principal: client,
            operation: .readResult,
            now: instant) == .denied(.authorizationRevoked))
      default:
        _ = try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (changed).environment.snapshot(
            preserving: updatedEnvironment.paths)
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      }
    }
    let snapshot = await store.read()
    #expect(snapshot.executions[executionID]?.revoked == true)
    #expect(snapshot.pendingExecutionTerminations == [executionID])
    var restored = try roundTrip(snapshot)
    #expect(restored.pendingExecutionTerminations == [executionID])
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = restored.environment
        updatedEnvironment.paths = (original).environment.snapshot(
          preserving: updatedEnvironment.paths)
        return try restored.reconcile(
          environment: updatedEnvironment, expectedRevision: restored.revision)
      }().executionsToTerminate == [executionID])
  }

  @Test(arguments: ["networkRetry", "permissionRetry", "reconcile"])
  func lostNetworkEvidenceQueuesDependentExecutions(entry: String) throws {
    var ledger = PermissionLedger()
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["local"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .trusted),
      for: SandboxSettingsKey(principal: client, projectID: "project"),
      expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["local"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "local",
        sourceProjectID: "project",
        isLocalNetwork: true,
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["local"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    try ledger.answer(
      pending.id,
      with: .always,
      now: instant)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["local"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "local",
        sourceProjectID: "project",
        isLocalNetwork: true,
        retryIDs: [pending.id],
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["local"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let running = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    switch entry {
    case "networkRetry":
      #expect(throws: PermissionModelError.invalidAuthorization) {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            [], preserving: ledger.environment.trustedHosts)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        _ = try ledger.authorizeNetwork(
          invocation: invocation(),
          host: "local",
          sourceProjectID: "project",
          isLocalNetwork: true,
          retryIDs: [pending.id],
          now: instant)
      }
    case "permissionRetry":
      #expect(throws: PermissionModelError.invalidAuthorization) {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            [], preserving: ledger.environment.trustedHosts)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        _ = try ledger.authorize(
          invocation: invocation(),
          requirements: pending.requirements,
          retryIDs: [pending.id],
          now: instant)
      }
    default:
      _ = try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }()
    }
    #expect(ledger.pendingExecutionTerminations == [running.id])
    ledger = try roundTrip(ledger)
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          ["local"], preserving: ledger.environment.trustedHosts)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate == [running.id])
  }

  @Test func revokingOneTimeAuthorizationQueuesItsRequestDependents() throws {
    var ledger = PermissionLedger()
    guard
      case .requests(let pending) = try ledger.authorize(
        invocation: invocation(), actions: [action(), action(.unifiedLogs)], now: instant)
    else {
      Issue.record("Expected requests")
      return
    }
    for request in pending { try ledger.answer(request.id, with: .onlyThisTime, now: instant) }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action(), action(.unifiedLogs)],
        retryIDs: Set(pending.map(\.id)), now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    _ = try ledger.revokeAuthorization(allowed.id)
    for request in pending { #expect(ledger.requests[request.id]?.status == .revoked) }
    #expect(ledger.pendingExecutionTerminations == [running.id])
    ledger = try roundTrip(ledger)
    #expect(
      try ledger.reconcile(environment: PermissionEnvironment(), expectedRevision: ledger.revision)
        .executionsToTerminate == [running.id])
  }

  @Test func rollbackIncludesRevocationQueueAndAcknowledgement() async throws {
    let store = InMemoryPermissionStore()
    let (authorizationID, executionID) = try await store.transaction { ledger in
      let allowed = try authorization(
        from: ledger.authorize(invocation: invocation(), actions: [action(.skills)], now: instant))
      let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
      ledger.acknowledgeExecutionTerminations([running.id])
      return (allowed.id, running.id)
    }
    await #expect(throws: PermissionModelError.invalidAuthorization) {
      try await store.transaction { ledger in
        _ = try ledger.revokeAuthorization(authorizationID)
        throw PermissionModelError.invalidAuthorization
      }
    }
    #expect(await store.read().pendingExecutionTerminations.isEmpty)
    #expect(await store.read().executions[executionID]?.revoked == false)
    _ = try await store.transaction { try $0.revokeAuthorization(authorizationID) }
    await #expect(throws: PermissionModelError.invalidAuthorization) {
      try await store.transaction { ledger in
        ledger.acknowledgeExecutionTerminations([executionID])
        throw PermissionModelError.invalidAuthorization
      }
    }
    #expect(await store.read().pendingExecutionTerminations == [executionID])
  }

  @Test func concurrentInvalidationAndAcknowledgementPreserveOtherPendingItems() async throws {
    let store = InMemoryPermissionStore()
    let records = try await store.transaction { ledger in
      try (0..<32).map { index in
        let allowed = try authorization(
          from: ledger.authorize(
            invocation: invocation(digest: String(index)), actions: [action(.skills)], now: instant)
        )
        let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
        return (authorization: allowed.id, execution: running.id)
      }
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for (index, record) in records.enumerated() {
        group.addTask {
          _ = try await store.transaction { try $0.revokeAuthorization(record.authorization) }
          #expect(await store.read().pendingExecutionTerminations.contains(record.execution))
          if index.isMultiple(of: 2) {
            try await store.transaction { $0.acknowledgeExecutionTerminations([record.execution]) }
            try await store.transaction { $0.acknowledgeExecutionTerminations([record.execution]) }
          }
          _ = try await store.transaction { try $0.revokeAuthorization(record.authorization) }
          _ = try await store.transaction {
            try $0.reconcile(environment: PermissionEnvironment(), expectedRevision: $0.revision)
          }
        }
      }
      try await group.waitForAll()
    }
    let expected = Set(
      records.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map { $0.element.execution })
    let snapshot = await store.read()
    #expect(snapshot.pendingExecutionTerminations == expected)
    #expect(snapshot.executions.values.allSatisfy { $0.revoked })
    var restored = try roundTrip(snapshot)
    #expect(
      try restored.reconcile(
        environment: PermissionEnvironment(), expectedRevision: restored.revision
      ).executionsToTerminate == expected)
    restored.acknowledgeExecutionTerminations(expected)
    restored = try roundTrip(restored)
    #expect(
      try restored.reconcile(
        environment: PermissionEnvironment(), expectedRevision: restored.revision
      ).executionsToTerminate.isEmpty)
  }

  private func roundTrip(_ ledger: PermissionLedger) throws -> PermissionLedger {
    try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
  }
}
