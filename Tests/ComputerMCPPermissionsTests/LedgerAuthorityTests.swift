import ComputerMCPPermissions
import Foundation
import Testing

struct ComputerMCPPermissionsLedgerAuthorityTests {
  private func restore(_ ledger: PermissionLedger) throws -> PermissionLedger {
    try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
  }

  private func policy(_ environment: PermissionEnvironment, source: PolicySource = .owner) throws
    -> ManagedPolicy
  {
    guard case .available(let policy) = environment.limits[client]?.sources[source] else {
      throw PermissionModelError.invalidAuthorization
    }
    return policy
  }

  private func sameState(_ lhs: PermissionLedger, _ rhs: PermissionLedger) throws -> Bool {
    let left = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lhs)) as! NSDictionary
    let right = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rhs)) as! NSDictionary
    return left == right
  }

  @Test func managedCopiesCannotShareACommittedGeneration() throws {
    var ledger = PermissionLedger()
    var environment = ledger.environment
    environment.limits[client] = ManagedLimits(owner: .available(ManagedPolicy()))
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    let original = try policy(ledger.environment)
    let revision = ledger.revision
    var first = original
    var second = original
    first.allowsFullAccess = false
    second.network = .none
    #expect(first.identity.id == original.identity.id)
    #expect(first.identity.generation == original.identity.generation)
    #expect(second.identity.generation == original.identity.generation)
    environment = ledger.environment
    environment.limits[client] = ManagedLimits(owner: .available(first))
    try ledger.reconcile(environment: environment, expectedRevision: revision)
    let committed = try policy(ledger.environment)
    #expect(committed.identity.id == original.identity.id)
    #expect(committed.identity.generation > original.identity.generation)
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action(.skills)], now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    environment = ledger.environment
    environment.limits[client] = ManagedLimits(owner: .available(second))
    let before = ledger
    #expect(throws: PermissionModelError.revisionConflict) {
      try ledger.reconcile(environment: environment, expectedRevision: revision)
    }
    // Even a fresh outer revision cannot disguise a stale record generation.
    #expect(throws: PermissionModelError.revisionConflict) {
      try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    #expect(try sameState(ledger, before))
    var fresh = try policy(ledger.environment)
    fresh.network = .none
    environment = ledger.environment
    environment.limits[client] = ManagedLimits(owner: .available(fresh))
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    #expect(try policy(ledger.environment).identity.generation > committed.identity.generation)
    #expect(ledger.pendingExecutionTerminations == [running.id])
  }

  @Test(arguments: [PermissionAnswer.onlyThisTime, .always], [false, true])
  func authorizationIsConsumedByExecution(answer: PermissionAnswer, completed: Bool) throws {
    var ledger = PermissionLedger()
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(), actions: [action()], now: instant))
    try ledger.answer(pending.id, with: answer, now: instant)
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action()], retryIDs: [pending.id], now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    if completed {
      try ledger.finishExecution(execution.id, retainUntil: instant.addingTimeInterval(60))
    }
    #expect(ledger.authorizations[allowed.id]?.executionID == execution.id)
    for _ in 0..<2 {
      #expect(throws: PermissionModelError.invalidAuthorization) {
        try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
      }
      #expect(ledger.executions.count == 1)
      #expect(
        ledger.executionAccess(
          execution.id, principal: client, operation: .readResult, now: instant) == .allowed)
      ledger = try restore(ledger)
    }
    _ = try ledger.revokeAuthorization(allowed.id)
    #expect(
      ledger.executionAccess(
        execution.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
  }

  @Test(arguments: [PermissionAnswer.onlyThisTime, .always])
  func concurrentExecutionStartsConsumeOnce(answer: PermissionAnswer) async throws {
    let store = InMemoryPermissionStore()
    let allowed = try await store.transaction { ledger in
      let pending = try request(
        from: ledger.authorize(
          invocation: invocation(), actions: [action()], now: instant))
      try ledger.answer(pending.id, with: answer, now: instant)
      return try authorization(
        from: ledger.authorize(
          invocation: invocation(), actions: [action()], retryIDs: [pending.id], now: instant))
    }
    let successes = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<16 {
        group.addTask {
          do {
            _ = try await store.transaction {
              try $0.startExecution(owner: client, authorizationIDs: [allowed.id])
            }
            return true
          } catch {
            #expect(error as? PermissionModelError == .invalidAuthorization)
            return false
          }
        }
      }
      var count = 0
      for await success in group where success { count += 1 }
      return count
    }
    #expect(successes == 1)
    var restored = try restore(await store.read())
    #expect(restored.executions.count == 1)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try restored.startExecution(owner: client, authorizationIDs: [allowed.id])
    }
  }

  @Test(arguments: ["environment", "permissions", "sandbox"])
  func concurrentEditsHaveOneWinner(kind: String) async throws {
    let store = InMemoryPermissionStore()
    let snapshot = await store.read()
    let successes = await withTaskGroup(of: Bool.self) { group in
      for index in 0..<16 {
        group.addTask {
          do {
            _ = try await store.transaction { ledger in
              switch kind {
              case "environment":
                var environment = snapshot.environment
                environment.trustedHosts = [HostRule("host-\(index)")]
                return try ledger.reconcile(
                  environment: environment, expectedRevision: snapshot.revision)
              case "permissions":
                var permissions = snapshot.permissions(for: client)
                try permissions.set(.granted(.read), for: .project("\(index)"))
                return try ledger.setPermissions(
                  permissions, for: client, expectedRevision: snapshot.revision)
              default:
                return try ledger.setSandboxSettings(
                  SandboxSettings(
                    network: .custom(hosts: ["host-\(index)"], includesTrusted: false)),
                  for: SandboxSettingsKey(principal: client, projectID: "project"),
                  expectedRevision: snapshot.revision)
              }
            }
            return true
          } catch {
            #expect(error as? PermissionModelError == .revisionConflict)
            return false
          }
        }
      }
      var count = 0
      for await success in group where success { count += 1 }
      return count
    }
    #expect(successes == 1)
  }

  @Test(
    arguments: [false, true],
    [
      "owner", "machine", "ceiling", "managedNetwork", "managedDenied", "trustedHost",
      "project", "folder", "developer", "system", "userData", "hostData", "denied", "outside",
      "full", "trusted", "custom", "sandboxDenied", "grant",
    ])
  func basisCopiesConflictAndCommittedEditsTerminate(restored: Bool, kind: String) throws {
    var ledger = PermissionLedger()
    var environment = ledger.environment
    environment.trustedHosts = [HostRule("service")]
    environment.paths = try PathEnvironmentSnapshot(
      projects: [RegisteredProject(id: "project", root: path("/project"))],
      rules: [
        PathRule(root: path("/documents"), kind: .folder(.documents)),
        PathRule(root: path("/developer"), kind: .developer),
        PathRule(root: path("/developer/secret"), kind: .hostData),
        PathRule(root: path("/developer/denied"), kind: .denied),
        PathRule(root: path("/system"), kind: .systemOrApplication),
        PathRule(root: path("/user"), kind: .userData),
        PathRule(root: path("/user/tools"), kind: .developer),
      ])
    let ceilings = try granted([(.project("project"), .write)])
    environment.limits[client] = ManagedLimits(
      owner: .available(
        ManagedPolicy(permissionCeilings: ceilings, deniedReadLocations: [path("/secret")])),
      machine: .available(ManagedPolicy()))
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    try ledger.setPermission(
      .granted(.write), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    try ledger.setPermission(
      .granted(.read), for: .filesAndFolders(.documents), principal: client,
      expectedRevision: ledger.revision)
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    let network: NetworkAccess =
      kind == "full"
      ? .full
      : kind == "custom"
        ? .custom(hosts: ["service"], includesTrusted: false) : .trusted
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: network, deniedReadLocations: [path("/secret")]),
      for: key, expectedRevision: ledger.revision)
    let requirements: InvocationRequirements
    switch kind {
    case "full", "trusted", "custom", "trustedHost":
      requirements = InvocationRequirements(
        networks: [
          NetworkRequirement(host: "service", projectID: "project", isLocalNetwork: false)
        ], sandboxProjectID: "project")
    case "project", "folder", "developer", "system", "userData", "hostData", "denied", "outside":
      let location =
        kind == "folder"
        ? "/documents"
        : kind == "userData"
          ? "/user"
          : kind == "hostData" || kind == "denied" ? "/developer" : "/\(kind)"
      requirements = InvocationRequirements(
        paths: [
          PathRequirement(
            path: path(location), operation: kind == "userData" ? .listDirectory : .read)
        ], sandboxProjectID: "project")
    default:
      requirements = InvocationRequirements(
        actions: [action(.project("project"), .read)], sandboxProjectID: "project")
    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: requirements, now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    if restored { ledger = try restore(ledger) }
    let base = ledger
    func edit(_ ledger: inout PermissionLedger) throws -> RevocationResult {
      switch kind {
      case "grant":
        var permissions = base.permissions(for: client)
        try permissions.set(.granted(.read), for: .project("project"))
        return try ledger.setPermissions(permissions, for: client, expectedRevision: base.revision)
      case "full", "trusted", "custom", "sandboxDenied":
        var settings = try #require(base.sandboxSettings.entries[key])
        switch kind {
        case "full": settings.network = .full
        case "trusted": settings.network = .trusted
        case "custom": settings.network = settings.network.removing("service").adding("service")
        default:
          settings.deniedReadLocations = []
          settings.deniedReadLocations = [path("/secret")]
        }
        return try ledger.setSandboxSettings(settings, for: key, expectedRevision: base.revision)
      default:
        var environment = base.environment
        switch kind {
        case "owner", "machine", "ceiling", "managedNetwork", "managedDenied":
          let source: PolicySource = kind == "machine" ? .machine : .owner
          var changed = try policy(environment, source: source)
          switch kind {
          case "ceiling":
            try changed.permissionCeilings.set(.granted(.read), for: .project("project"))
          case "managedNetwork": changed.network = .full
          case "managedDenied":
            changed.deniedReadLocations = []
            changed.deniedReadLocations = [path("/secret")]
          default: changed.allowsFullAccess = false
          }
          environment.limits[client] = ManagedLimits(
            owner: .available(source == .owner ? changed : try policy(environment)),
            machine: .available(
              source == .machine ? changed : try policy(environment, source: .machine)))
        case "trustedHost":
          var host = try #require(environment.trustedHosts.first)
          host.host = "other"
          host.host = "service"
          environment.trustedHosts = [host]
        case "project":
          var project = try #require(environment.paths?.registeredProjects.first)
          project.root = path("/other")
          project.root = path("/project")
          try environment.paths!.setProjects([project])
        case "outside":
          environment.paths = try PathEnvironmentSnapshot(
            projects: environment.paths!.registeredProjects, rules: environment.paths!.pathRules)
        default:
          let root =
            kind == "folder"
            ? "/documents"
            : kind == "userData"
              ? "/user"
              : kind == "hostData"
                ? "/developer/secret" : kind == "denied" ? "/developer/denied" : "/\(kind)"
          let old = try #require(environment.paths?.pathRules.first { $0.root == path(root) })
          var rule = old
          rule.root = path("/other")
          rule.root = old.root
          environment.paths!.pathRules.remove(old)
          environment.paths!.pathRules.insert(rule)
        }
        return try ledger.reconcile(environment: environment, expectedRevision: base.revision)
      }
    }
    #expect(try edit(&ledger).executionsToTerminate == [running.id])
    let committed = ledger
    #expect(throws: PermissionModelError.revisionConflict) { try edit(&ledger) }
    #expect(try sameState(ledger, committed))
    #expect(ledger.revision > base.revision)
    ledger = try restore(ledger)
    #expect(
      ledger.executionAccess(
        running.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
    let before = ledger.revision
    let fresh = try authorization(
      from: ledger.authorize(
        invocation: invocation(digest: "fresh"), requirements: requirements, now: instant))
    #expect(fresh.identity.generation > before)
  }

  @Test func staleWholeLedgerCannotRestoreConsumedAuthorization() async throws {
    let store = InMemoryPermissionStore()
    let allowed = try await store.transaction { ledger in
      try authorization(
        from: ledger.authorize(
          invocation: invocation(), actions: [action(.skills)], now: instant))
    }
    let stale = try restore(await store.read())
    let execution = try await store.transaction {
      try $0.startExecution(owner: client, authorizationIDs: [allowed.id])
    }
    let committed = await store.read()
    await #expect(throws: PermissionModelError.revisionConflict) {
      try await store.transaction { $0 = stale }
    }
    #expect(try sameState(await store.read(), committed))
    await #expect(throws: PermissionModelError.invalidAuthorization) {
      try await store.transaction {
        try $0.startExecution(owner: client, authorizationIDs: [allowed.id])
      }
    }
    #expect(await store.read().authorizations[allowed.id]?.executionID == execution.id)
  }

  @Test func failedCombinedStartLeavesUnusedAuthorizationsAvailable() throws {
    var ledger = PermissionLedger()
    let plugin = PluginIdentity.package("worker")
    try ledger.setPermission(
      .granted(.use), for: .plugin("worker"), principal: client,
      expectedRevision: ledger.revision)
    let first = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action(.plugin("worker"), .use)], now: instant))
    let used = try ledger.startExecution(owner: client, authorizationIDs: [first.id])
    let next = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action(.plugin("worker"), .use)], now: instant))
    let worker = try authorization(
      from: ledger.authorize(
        invocation: invocation(principal: .plugin(plugin)), actions: [action(.skills)], now: instant
      ))
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.startExecution(
        owner: client, delegatedTo: plugin, authorizationIDs: [first.id, worker.id])
    }
    #expect(ledger.authorizations[worker.id]?.executionID == nil)
    #expect(ledger.authorizations[first.id]?.executionID == used.id)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.startExecution(
        owner: client, delegatedTo: .package("different"), authorizationIDs: [next.id, worker.id])
    }
    #expect(ledger.authorizations[next.id]?.executionID == nil)
    #expect(ledger.authorizations[worker.id]?.executionID == nil)
    ledger = try restore(ledger)
    let execution = try ledger.startExecution(
      owner: client, delegatedTo: plugin,
      authorizationIDs: [next.id, worker.id])
    #expect(ledger.authorizations[next.id]?.executionID == execution.id)
    #expect(ledger.authorizations[worker.id]?.executionID == execution.id)
  }

  @Test func nestedConflictRollsBackAllocatedIdentitiesAndRevocations() throws {
    var ledger = PermissionLedger()
    var initial = ledger.environment
    initial.paths = try PathEnvironmentSnapshot(rules: [
      PathRule(root: path("/tools"), kind: .developer)
    ])
    try ledger.reconcile(environment: initial, expectedRevision: ledger.revision)
    let baseline = ledger.environment
    var first = baseline
    var rule = try #require(first.paths?.pathRules.first)
    rule.root = path("/other")
    first.paths!.pathRules = [rule]
    try ledger.reconcile(environment: first, expectedRevision: ledger.revision)
    let before = ledger
    var stale = baseline
    // Trusted hosts are committed before paths; the nested conflict must discard their allocations.
    stale.trustedHosts = [HostRule("new")]
    #expect(throws: PermissionModelError.revisionConflict) {
      try ledger.reconcile(environment: stale, expectedRevision: ledger.revision)
    }
    #expect(try sameState(before, ledger))
  }

  @Test(arguments: ["permission", "policy", "network"])
  func committedIdentitiesCannotMoveAcrossOwners(kind: String) throws {
    var ledger = PermissionLedger()
    ledger.register(client)
    var environment = ledger.environment
    environment.limits[client] = ManagedLimits(owner: .available(ManagedPolicy()))
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .full), for: key,
      expectedRevision: ledger.revision)
    let before = ledger
    #expect(throws: PermissionModelError.revisionConflict) {
      switch kind {
      case "permission":
        try ledger.setPermissions(
          ledger.permissions(for: client), for: otherClient,
          expectedRevision: ledger.revision)
      case "policy":
        var environment = ledger.environment
        environment.limits[client] = ManagedLimits(machine: .available(try policy(environment)))
        try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      default:
        _ = try ledger.setSandboxSettings(
          try #require(ledger.sandboxSettings.entries[key]),
          for: SandboxSettingsKey(principal: otherClient, projectID: "project"),
          expectedRevision: ledger.revision)
      }
    }
    #expect(try sameState(before, ledger))
  }

  @Test func decodedEditsCannotPreserveACommittedGeneration() throws {
    var ledger = PermissionLedger()
    var environment = ledger.environment
    environment.trustedHosts = [HostRule("service")]
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    let original = try #require(ledger.environment.trustedHosts.first)
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object["host"] = "other"
    let decoded = try JSONDecoder().decode(
      HostRule.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.identity == original.identity)
    environment = ledger.environment
    environment.trustedHosts = [decoded]
    let before = ledger.revision
    try ledger.reconcile(environment: environment, expectedRevision: before)
    let committed = try #require(ledger.environment.trustedHosts.first)
    #expect(committed.identity.id == original.identity.id)
    #expect(committed.identity.generation > before)
  }

  @Test func inconsistentDecodedNetworkCannotEnterTheLedger() throws {
    var ledger = PermissionLedger()
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(NetworkAccess.full)) as? [String: Any]
    )
    object.removeValue(forKey: "fullRule")
    let network = try JSONDecoder().decode(
      NetworkAccess.self, from: JSONSerialization.data(withJSONObject: object))
    let before = ledger
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.setSandboxSettings(
        SandboxSettings(network: network),
        for: SandboxSettingsKey(principal: client, projectID: "project"),
        expectedRevision: ledger.revision)
    }
    #expect(try sameState(before, ledger))
  }
}
