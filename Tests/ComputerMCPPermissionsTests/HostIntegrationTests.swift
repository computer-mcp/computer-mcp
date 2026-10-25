import Foundation
import Testing

@testable import ComputerMCPPermissions

struct HostIntegrationTests {
  @Test func simultaneousConnectionConsentsKeepIndependentLifetimes() throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.access), for: .screen, principal: client, expectedRevision: ledger.revision)
    let standing = ledger.consent(for: client, mode: .fullAccess(.standing))
    let temporary = ledger.consent(for: client, mode: .fullAccess(.connection("A")))
    var environment = ledger.environment
    environment.connections["A"] = PermissionConnection(principal: client, consent: temporary)
    environment.connections["B"] = PermissionConnection(principal: client, consent: standing)
    environment.connections["C"] = PermissionConnection(principal: client)
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    let full = InvocationRequirements(actions: [action()], mode: .fullAccess(.standing))
    var executions: [String: AuthorizedExecution] = [:]
    for id in ["A", "B"] {
      let proof = try authorization(
        from: ledger.authorize(
          invocation: invocation(), requirements: full,
          connectionID: id, now: instant))
      executions[id] = try ledger.startExecution(
        owner: client, authorizationIDs: [proof.id], now: instant)
    }
    #expect(
      try ledger.authorize(
        invocation: invocation(), requirements: full, connectionID: "C", now: instant)
        == .denied(.fullAccessRequiresConsent))
    let sandbox = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: InvocationRequirements(actions: [action()]), connectionID: "A", now: instant))
    let ordinary = try ledger.startExecution(
      owner: client, authorizationIDs: [sandbox.id], now: instant)
    environment = ledger.environment
    environment.endedConnections.insert("A")
    let result = try ledger.reconcile(
      environment: environment, expectedRevision: ledger.revision, now: instant)
    #expect(result.executionsToTerminate == [executions["A"]!.id])
    for execution in [ordinary, executions["B"]!] {
      #expect(
        ledger.executionAccess(
          execution.id, principal: client, operation: .readResult,
          connectionID: "B", now: instant) == .allowed)
    }
    #expect(
      ledger.executionAccess(
        executions["A"]!.id, principal: client, operation: .readResult,
        connectionID: "B", now: instant) == .denied(.authorizationRevoked))
    #expect(
      try ledger.authorize(
        invocation: invocation(), requirements: .init(), connectionID: "A", now: instant)
        == .denied(.authorizationRevoked))
    #expect(
      try ledger.authorize(
        invocation: invocation(principal: otherClient), requirements: .init(),
        connectionID: "B", now: instant) == .denied(.authorizationRevoked))
  }

  @Test func reconnectingRetryKeepsAnswersButChecksDestinationCeiling() throws {
    var ledger = PermissionLedger()
    var environment = ledger.environment
    environment.connections["A"] = PermissionConnection(principal: client)
    environment.connections["B"] = PermissionConnection(principal: client)
    var denied = Permissions()
    try denied.set(.denied, for: .screen)
    environment.connections["C"] = PermissionConnection(
      principal: client,
      attenuation: ManagedPolicy(permissionCeilings: denied))
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(), actions: [action()],
        connectionID: "A", now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    environment = ledger.environment
    environment.endedConnections.insert("A")
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    #expect(
      try ledger.authorize(
        invocation: invocation(), actions: [action()], retryIDs: [pending.id],
        connectionID: "C", now: instant) == .denied(.managedLimit([.connection])))
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action()],
        retryIDs: [pending.id], connectionID: "B", now: instant))
    let execution = try ledger.startExecution(
      owner: client, authorizationIDs: [proof.id], now: instant)
    #expect(
      ledger.executionAccess(
        execution.id, principal: client, operation: .readResult,
        connectionID: "C", now: instant) == .denied(.managedLimit([.connection])))
    #expect(ledger.permissions(for: client).state(for: .screen) == .notGranted)
  }

  @Test func connectionFullAccessNeverManufacturesPrivacyGrants() throws {
    var ledger = PermissionLedger()
    let consent = ledger.consent(for: client, mode: .fullAccess(.connection("A")))
    var environment = ledger.environment
    environment.connections["A"] = PermissionConnection(principal: client, consent: consent)
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: InvocationRequirements(actions: [action()], mode: .fullAccess(.standing)),
        connectionID: "A", now: instant))
    #expect(pending.requirement == requirement(.screen, .access))
  }

  @Test func actualDestinationsIntersectAcrossIndependentSources() throws {
    let source = NetworkAccess.custom(hosts: ["*.Example.COM."], includesTrusted: false)
    let limits = ManagedLimits(sources: [
      .owner: .available(ManagedPolicy(network: source)),
      .machine: .available(
        ManagedPolicy(
          network: .custom(
            hosts: ["api.example.com", "*.packages.example.com"], includesTrusted: false))),
      .managedPreferences: .available(ManagedPolicy(network: .trusted)),
    ])
    let trusted: Set<String> = ["API.EXAMPLE.COM.", "cdn.packages.example.com", "example.com"]
    #expect(
      limits.network(applying: .full, trustedHosts: trusted)
        == .custom(hosts: ["api.example.com", "cdn.packages.example.com"], includesTrusted: false))
    #expect(limits.restrictingNetwork(host: "API.EXAMPLE.COM.", trustedHosts: trusted).isEmpty)
    #expect(
      limits.restrictingNetwork(host: "example.com", trustedHosts: trusted) == [.owner, .machine])
    #expect(
      limits.restrictingNetwork(host: "notexample.com", trustedHosts: trusted) == [
        .owner, .machine, .managedPreferences,
      ])
    var owner = Permissions()
    try owner.set(.denied, for: .project("*"))
    try owner.set(.granted(.write), for: .project("a"))
    var machine = Permissions()
    try machine.set(.granted(.write), for: .project("*"))
    try machine.set(.denied, for: .project("a"))
    #expect(
      ManagedLimits(
        owner: .available(ManagedPolicy(permissionCeilings: owner)),
        machine: .available(ManagedPolicy(permissionCeilings: machine))
      )
      .restrictingSources(for: requirement(.project("a"), .read)) == [.machine])
  }

  @Test func lexicalHostIdentityAndInvalidNumericForms() throws {
    #expect(try NetworkHost.normalize("[2001:0DB8:0:0:0:0:0:1]") == "2001:db8::1")
    #expect(try NetworkHost.normalize("[::FFFF:192.0.2.1]") == "::ffff:192.0.2.1")
    #expect(NetworkHost.matches("x.example.com", rule: "*.EXAMPLE.COM."))
    #expect(!NetworkHost.matches("example.com", rule: "*.example.com"))
    #expect(!NetworkHost.matches("x.notexample.com", rule: "*.example.com"))
    for invalid in [
      "127.1", "0177.0.0.1", "0x7f.1", "2130706433", "127.0.0.1.", "fe80::1%en0", "bad..host",
      "[example.com]",
    ] {
      #expect(throws: (any Error).self) { try NetworkHost.normalize(invalid) }
    }
    #expect(!NetworkAccess.full.allows("bad..host", trustedHosts: []))
  }

  @Test func wildcardRuleGenerationPinsExistingExecution() throws {
    var ledger = PermissionLedger()
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .custom(hosts: ["*.example.com"], includesTrusted: false)),
      for: key, expectedRevision: ledger.revision)
    let proof = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(), host: "api.example.com",
        sourceProjectID: "project", isLocalNetwork: false, now: instant))
    let execution = try ledger.startExecution(
      owner: client, authorizationIDs: [proof.id], now: instant)
    var settings = ledger.sandboxSettings.entries[key]!
    settings.network = settings.network.adding("api.example.com")
    #expect(
      try ledger.setSandboxSettings(settings, for: key, expectedRevision: ledger.revision)
        .executionsToTerminate.isEmpty)
    settings = ledger.sandboxSettings.entries[key]!
    settings.network = settings.network.removing("*.example.com").adding("*.example.com")
    #expect(
      try ledger.setSandboxSettings(settings, for: key, expectedRevision: ledger.revision)
        .executionsToTerminate == [execution.id])
  }

  @Test func resourceLimitsRequireBackendGuaranteesAndTightenRunningWork() throws {
    var ledger = PermissionLedger()
    var environment = ledger.environment
    environment.limits[client] = ManagedLimits(
      owner: .available(
        ManagedPolicy(
          executionLimits: try ExecutionLimitCeilings(
            timeMilliseconds: 60_000, outputBytes: 100, memoryBytes: 1000))))
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    let proof = try authorization(
      from: ledger.authorize(invocation: invocation(), requirements: .init(), now: instant))
    #expect(throws: PermissionModelError.unenforceableMemoryLimit) {
      try ledger.startExecution(owner: client, authorizationIDs: [proof.id], now: instant)
    }
    #expect(ledger.authorizations[proof.id]?.executionID == nil)
    let execution = try ledger.startExecution(
      owner: client, authorizationIDs: [proof.id],
      capabilities: .init(memory: true), now: instant)
    #expect(execution.limits.outputBytes == 100)
    environment = ledger.environment
    guard case .available(var policy) = environment.limits[client]?.sources[.owner] else { return }
    policy.executionLimits = try ExecutionLimitCeilings(
      timeMilliseconds: 60_000, outputBytes: 20, memoryBytes: 1000)
    environment.limits[client] = ManagedLimits(owner: .available(policy))
    #expect(
      try ledger.reconcile(
        environment: environment, expectedRevision: ledger.revision,
        now: instant.addingTimeInterval(2)
      ).executionsToTerminate.isEmpty)
    #expect(ledger.executions[execution.id]?.limits.outputBytes == 20)
    environment = ledger.environment
    guard case .available(var tightened) = environment.limits[client]?.sources[.owner] else {
      return
    }
    tightened.executionLimits = try ExecutionLimitCeilings(memoryBytes: 500)
    environment.limits[client] = ManagedLimits(owner: .available(tightened))
    #expect(
      try ledger.reconcile(
        environment: environment, expectedRevision: ledger.revision,
        now: instant.addingTimeInterval(3)
      ).executionsToTerminate == [execution.id])
    #expect(ledger.executions[execution.id]?.limitEndReason == .memoryLimitUnavailable)
    #expect(
      ledger.executionAccess(
        execution.id, principal: client, operation: .readResult,
        now: instant.addingTimeInterval(4)) == .allowed)
  }

  @Test func timeAndRetentionCeilingsAreEffectiveAndRequirementsIncludeOptions() throws {
    let limits = try EffectiveExecutionLimits.resolve(
      .background,
      limits: [
        .init(sources: [
          .machine: .available(
            ManagedPolicy(executionLimits: try .init(timeMilliseconds: 200, outputBytes: 90))),
          .owner: .available(
            ManagedPolicy(executionLimits: try .init(timeMilliseconds: 100, outputBytes: 100))),
        ])
      ])
    #expect(limits.timeMilliseconds == 100)
    #expect(limits.outputBytes == 90)
    #expect(
      try EffectiveExecutionLimits.resolve(.foreground, limits: []).timeMilliseconds == 120_000)
    #expect(try EffectiveExecutionLimits.resolve(.background, limits: []).timeMilliseconds == nil)
    #expect(
      InvocationRequirements(execution: .foreground)
        != InvocationRequirements(execution: .background))
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        ExecutionLimitRequest.self,
        from: Data(#"{"background":false,"timeMilliseconds":700000}"#.utf8))
    }
    var ledger = PermissionLedger()
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: .init(execution: try .init(timeMilliseconds: 1000)), now: instant))
    let execution = try ledger.startExecution(
      owner: client, authorizationIDs: [proof.id], now: instant)
    #expect(
      ledger.reconcileExecutionLimits(now: instant.addingTimeInterval(1)).executionsToTerminate == [
        execution.id
      ])
    #expect(ledger.executions[execution.id]?.limitEndReason == .timeLimit)
    #expect(ledger.executions[execution.id]?.retainUntil == instant.addingTimeInterval(86_401))
  }

  @Test func lateNeedsCarryEarlierOneTimeAnswersAcrossDurableRetryChains() throws {
    var ledger = PermissionLedger()
    var environment = ledger.environment
    environment.paths = PathEnvironmentSnapshot(TestPathEnvironment())
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    let original = InvocationRequirements(actions: [action()], sandboxProjectID: "project")
    let screen = try request(
      from: ledger.authorize(invocation: invocation(), requirements: original, now: instant))
    try ledger.answer(screen.id, with: .onlyThisTime, now: instant)
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: original,
        retryIDs: [screen.id], now: instant))
    let first = try ledger.startExecution(owner: client, authorizationIDs: [proof.id], now: instant)
    let host = DiscoveredRequirement.network(
      NetworkRequirement(host: "api.example.com", projectID: "project", isLocalNetwork: false))
    guard
      case .requests(let hostRequests) = try ledger.recordDiscoveredNeeds(
        executionID: first.id,
        principal: client, needs: [host], now: instant)
    else {
      Issue.record("Missing runtime host request")
      return
    }
    let hostRequest = try #require(hostRequests.first)
    #expect(ledger.authorizations[proof.id]?.requirements == original)
    try ledger.answer(hostRequest.id, with: .onlyThisTime, now: instant)
    ledger = try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
    for wrong in [
      invocation(principal: otherClient), invocation(tool: "other"), invocation(project: "other"),
      invocation(digest: "other"),
    ] {
      #expect(throws: PermissionModelError.retryMismatch) {
        try ledger.authorize(
          invocation: wrong, requirements: original, retryIDs: [hostRequest.id], now: instant)
      }
    }
    #expect(throws: PermissionModelError.retryMismatch) {
      try ledger.authorize(
        invocation: invocation(), requirements: .init(), retryIDs: [hostRequest.id], now: instant)
    }
    let retry = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: original,
        retryIDs: [hostRequest.id], now: instant))
    let second = try ledger.startExecution(
      owner: client, authorizationIDs: [retry.id], now: instant)
    guard
      case .requests(let folders) = try ledger.recordDiscoveredNeeds(
        executionID: second.id,
        principal: client,
        needs: [.path(.init(path: path("/people/me/Downloads/file"), operation: .read))],
        now: instant)
    else {
      Issue.record("Missing runtime folder request")
      return
    }
    let folder = try #require(folders.first)
    try ledger.answer(folder.id, with: .onlyThisTime, now: instant)
    let final = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: original,
        retryIDs: [folder.id], now: instant))
    #expect(final.requirements.networks.count == 1)
    #expect(final.requirements.paths.count == 1)
    #expect(final.requestIDs.count == 3)
    #expect(throws: PermissionModelError.requestConsumed) {
      try ledger.authorize(
        invocation: invocation(), requirements: original, retryIDs: [folder.id], now: instant)
    }
    #expect(ledger.permissions(for: client).state(for: .screen) == .notGranted)
    let finalExecution = try ledger.startExecution(
      owner: client, authorizationIDs: [final.id], now: instant)
    #expect(
      try ledger.revoke(principal: client, permission: .screen, expectedRevision: ledger.revision)
        .executionsToTerminate == [first.id, second.id, finalExecution.id])
  }

  @Test func forbiddenRuntimeNeedsNeverCreateRequests() throws {
    var ledger = PermissionLedger()
    var environment = ledger.environment
    environment.paths = PathEnvironmentSnapshot(TestPathEnvironment())
    environment.limits[client] = ManagedLimits(machine: .available(ManagedPolicy(network: .none)))
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: .init(sandboxProjectID: "project"), now: instant))
    let execution = try ledger.startExecution(
      owner: client, authorizationIDs: [proof.id], now: instant)
    #expect(
      try ledger.recordDiscoveredNeeds(
        executionID: execution.id, principal: client,
        needs: [.path(.init(path: path("/people/me/private/host/secret"), operation: .read))],
        now: instant) == .denied(.hostData))
    #expect(
      try ledger.recordDiscoveredNeeds(
        executionID: execution.id, principal: client,
        needs: [.network(.init(host: "example.com", projectID: "project", isLocalNetwork: false))],
        now: instant)
        == .denied(.managedLimit([.machine])))
    #expect(ledger.requests.isEmpty)
  }
  @Test func connectionCeilingRestrictsImplicitSandboxAndLateSatisfiedNeeds() throws {
    var ledger = PermissionLedger()
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .full), for: key, expectedRevision: ledger.revision)
    var environment = ledger.environment
    environment.paths = PathEnvironmentSnapshot(TestPathEnvironment())
    environment.connections["A"] = PermissionConnection(
      principal: client,
      attenuation: ManagedPolicy(network: .none, deniedReadLocations: [path("/system/private")]))
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: .init(
          paths: [.init(path: path("/system"), operation: .read)], sandboxProjectID: "project"),
        connectionID: "A", now: instant))
    let execution = try ledger.startExecution(
      owner: client, authorizationIDs: [proof.id], now: instant)
    let stored = try #require(ledger.authorizations[proof.id])
    let profiles = stored.basis.compactMap { element -> SandboxAccessBasis? in
      if case .sandbox(let profile) = element { return profile }
      return nil
    }
    #expect(!profiles.isEmpty)
    #expect(
      profiles.allSatisfy {
        $0.network == .none && $0.managedDeniedReadLocations.contains(path("/system/private"))
      })
    #expect(
      stored.basis.contains { element in
        if case .path(let basis) = element {
          return basis.excludedSubtrees?.contains(path("/system/private")) == true
        }
        return false
      })
    #expect(
      try ledger.recordDiscoveredNeeds(
        executionID: execution.id, principal: client,
        needs: [.network(.init(host: "example.com", projectID: "project", isLocalNetwork: false))],
        now: instant)
        == .denied(.managedLimit([.connection])))
    #expect(
      try ledger.recordDiscoveredNeeds(
        executionID: execution.id, principal: client,
        needs: [.path(.init(path: path("/system/private"), operation: .read))], now: instant)
        == .denied(.managedLimit([.connection])))
  }

  @Test func successiveLateNeedsAfterOriginalRequestExpiryShareOneContinuation() throws {
    var ledger = PermissionLedger()
    let original = InvocationRequirements(
      actions: [action()], sandboxProjectID: "project", execution: .background)
    let pending = try request(
      from: ledger.authorize(invocation: invocation(), requirements: original, now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: original,
        retryIDs: [pending.id], now: instant))
    let execution = try ledger.startExecution(
      owner: client, authorizationIDs: [proof.id], now: instant)
    let later = instant.addingTimeInterval(100_000)
    guard
      case .requests(let first) = try ledger.recordDiscoveredNeeds(
        executionID: execution.id,
        principal: client,
        needs: [.network(.init(host: "one.example", projectID: "project", isLocalNetwork: false))],
        now: later)
    else {
      Issue.record("Missing first late request")
      return
    }
    let firstID = try #require(first.first?.id)
    try ledger.answer(firstID, with: .onlyThisTime, now: later)
    guard
      case .requests(let all) = try ledger.recordDiscoveredNeeds(
        executionID: execution.id,
        principal: client,
        needs: [.network(.init(host: "two.example", projectID: "project", isLocalNetwork: false))],
        now: later)
    else {
      Issue.record("Missing accumulated request")
      return
    }
    #expect(all.count == 2)
    let second = try #require(all.first { $0.id != firstID })
    #expect(second.expiresAt == later.addingTimeInterval(86_400))
    try ledger.answer(second.id, with: .onlyThisTime, now: later)
    ledger = try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
    let retried = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: original,
        retryIDs: [second.id], now: later))
    #expect(retried.requirements.networks.count == 2)
    #expect(retried.requestIDs.count == 3)
    #expect(ledger.authorizations[proof.id]?.requirements.networks.isEmpty == true)
    #expect(throws: PermissionModelError.requestConsumed) {
      try ledger.authorize(
        invocation: invocation(), requirements: original, retryIDs: [firstID], now: later)
    }
  }

  @Test func delegatedRuntimeNeedsRemainBoundToEachPrincipal() throws {
    var ledger = PermissionLedger()
    let plugin = PluginIdentity.package("worker")
    try ledger.setPermission(
      .granted(.use), for: .plugin("worker"), principal: client, expectedRevision: ledger.revision)
    let clientRequirements = InvocationRequirements(
      actions: [action(.plugin("worker"), .use)], sandboxProjectID: "project")
    let pluginRequirements = InvocationRequirements(sandboxProjectID: "project")
    let caller = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: clientRequirements, now: instant))
    let worker = try authorization(
      from: ledger.authorize(
        invocation: invocation(principal: .plugin(plugin)),
        requirements: pluginRequirements, now: instant))
    let execution = try ledger.startExecution(
      owner: client, delegatedTo: plugin, authorizationIDs: [caller.id, worker.id], now: instant)
    let need = DiscoveredRequirement.network(
      .init(host: "example.com", projectID: "project", isLocalNetwork: false))
    guard
      case .requests(let clientRequests) = try ledger.recordDiscoveredNeeds(
        executionID: execution.id,
        principal: client, needs: [need], now: instant),
      case .requests(let pluginRequests) = try ledger.recordDiscoveredNeeds(
        executionID: execution.id,
        principal: .plugin(plugin), needs: [need], now: instant)
    else {
      Issue.record("Missing principal-specific requests")
      return
    }
    let a = try #require(clientRequests.first)
    let b = try #require(pluginRequests.first)
    #expect(a.id != b.id)
    #expect(a.invocation.principal == client)
    #expect(b.invocation.principal == .plugin(plugin))
    try ledger.answer(a.id, with: .onlyThisTime, now: instant)
    try ledger.answer(b.id, with: .onlyThisTime, now: instant)
    let nextCaller = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: clientRequirements,
        retryIDs: [a.id], now: instant))
    let nextWorker = try authorization(
      from: ledger.authorize(
        invocation: invocation(principal: .plugin(plugin)),
        requirements: pluginRequirements, retryIDs: [b.id], now: instant))
    _ = try ledger.startExecution(
      owner: client, delegatedTo: plugin, authorizationIDs: [nextCaller.id, nextWorker.id],
      now: instant)
  }

  @Test func fullAccessPendingRequestNeedsNewConnectionConsentOnRetry() throws {
    var ledger = PermissionLedger()
    let a = ledger.consent(for: client, mode: .fullAccess(.connection("A")))
    let b = ledger.consent(for: client, mode: .fullAccess(.connection("B")))
    var environment = ledger.environment
    environment.connections["A"] = PermissionConnection(principal: client, consent: a)
    environment.connections["B"] = PermissionConnection(principal: client, consent: b)
    environment.connections["C"] = PermissionConnection(principal: client)
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    let requirements = InvocationRequirements(actions: [action()], mode: .fullAccess(.standing))
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(), requirements: requirements,
        connectionID: "A", now: instant))
    environment = ledger.environment
    environment.endedConnections.insert("A")
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    #expect(
      try ledger.authorize(
        invocation: invocation(), requirements: requirements, retryIDs: [pending.id],
        connectionID: "C", now: instant) == .denied(.fullAccessRequiresConsent))
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: requirements,
        retryIDs: [pending.id], connectionID: "B", now: instant))
    #expect(proof.basis.contains(.consent(b.identity)))
    #expect(!proof.basis.contains(.consent(a.identity)))
  }

  @Test func unsandboxedInputRequiresCallingConnectionConsent() throws {
    var ledger = PermissionLedger()
    let a = ledger.consent(for: client, mode: .fullAccess(.connection("A")))
    var environment = ledger.environment
    environment.connections["A"] = PermissionConnection(principal: client, consent: a)
    environment.connections["B"] = PermissionConnection(principal: client)
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    let proof = try authorization(
      from: ledger.authorize(invocation: invocation(), actions: [], connectionID: "A", now: instant)
    )
    let execution = try ledger.startExecution(
      owner: client, authorizationIDs: [proof.id], now: instant)
    #expect(
      ledger.executionAccess(
        execution.id, principal: client, operation: .readResult,
        connectionID: "B", now: instant) == .allowed)
    for selector in [String?.none, "B"] {
      #expect(
        ledger.executionAccess(
          execution.id, principal: client, operation: .writeInput,
          connectionID: selector, now: instant) == .denied(.fullAccessRequiresConsent))
    }
    #expect(
      ledger.executionAccess(
        execution.id, principal: client, operation: .writeInput,
        connectionID: "A", now: instant) == .allowed)
  }

  @Test func explicitInvocationRevocationReachesCarriedRetryAuthority() throws {
    var ledger = PermissionLedger()
    let requirements = InvocationRequirements(actions: [action()], sandboxProjectID: "project")
    let pending = try request(
      from: ledger.authorize(invocation: invocation(), requirements: requirements, now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: requirements,
        retryIDs: [pending.id], now: instant))
    let execution = try ledger.startExecution(
      owner: client, authorizationIDs: [proof.id], now: instant)
    guard
      case .requests(let discovered) = try ledger.recordDiscoveredNeeds(
        executionID: execution.id, principal: client,
        needs: [.network(.init(host: "example.com", projectID: "project", isLocalNetwork: false))],
        now: instant)
    else {
      Issue.record("Missing discovered request")
      return
    }
    let next = try #require(discovered.first)
    try ledger.answer(next.id, with: .onlyThisTime, now: instant)
    #expect(try ledger.revokeAuthorization(proof.id).executionsToTerminate == [execution.id])
    ledger = try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
    #expect(ledger.requests[next.id]?.status == .revoked)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.authorize(
        invocation: invocation(), requirements: requirements, retryIDs: [next.id], now: instant)
    }
  }

  @Test func requestHostsAreConcreteDestinationsAndExecutionDefaultsAreCanonical() throws {
    #expect(InvocationRequirements() == InvocationRequirements(execution: .foreground))
    var ledger = PermissionLedger()
    _ = try ledger.setSandboxSettings(
      .init(network: .full),
      for: .init(principal: client, projectID: "project"), expectedRevision: ledger.revision)
    for host in ["*.example.com", "bad..host", "0x7f.1"] {
      #expect(
        try ledger.authorizeNetwork(
          invocation: invocation(), host: host, sourceProjectID: "project",
          isLocalNetwork: false, now: instant) == .denied(.invalidNetworkRequirement))
    }
    #expect(ledger.requests.isEmpty)
  }

  @Test func connectionTrustedNetworkPinsImplicitRuleGeneration() throws {
    var ledger = PermissionLedger()
    _ = try ledger.setSandboxSettings(
      .init(network: .full),
      for: .init(principal: client, projectID: "project"), expectedRevision: ledger.revision)
    var environment = ledger.environment
    environment.trustedHosts = [HostRule("example.com")]
    environment.connections["A"] = PermissionConnection(
      principal: client, attenuation: .init(network: .trusted))
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: .init(sandboxProjectID: "project"), connectionID: "A", now: instant))
    let execution = try ledger.startExecution(
      owner: client, authorizationIDs: [proof.id], now: instant)
    environment = ledger.environment
    environment.trustedHosts = []
    #expect(
      try ledger.reconcile(
        environment: environment, expectedRevision: ledger.revision, now: instant
      )
      .executionsToTerminate == [execution.id])
  }

  @Test(arguments: [72_000.0, 86_401.0])
  func unansweredRuntimeBatchGetsFreshWindowForLaterNeeds(delay: Double) throws {
    var ledger = PermissionLedger()
    let original = InvocationRequirements(sandboxProjectID: "project", execution: .background)
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: original, now: instant))
    let execution = try ledger.startExecution(
      owner: client, authorizationIDs: [proof.id], now: instant)
    let firstNeed = DiscoveredRequirement.network(
      .init(host: "one.example", projectID: "project", isLocalNetwork: false))
    guard
      case .requests(let first) = try ledger.recordDiscoveredNeeds(
        executionID: execution.id, principal: client, needs: [firstNeed], now: instant)
    else {
      Issue.record("Missing first need")
      return
    }
    let later = instant.addingTimeInterval(delay)
    guard
      case .requests(let next) = try ledger.recordDiscoveredNeeds(
        executionID: execution.id, principal: client,
        needs: [
          .network(
            .init(host: "two.example", projectID: "project", isLocalNetwork: false))
        ], now: later)
    else {
      Issue.record("Missing next batch")
      return
    }
    #expect(next.count == 2)
    #expect(Set(next.map(\.id)).isDisjoint(with: first.map(\.id)))
    let answered = later.addingTimeInterval(30_000)
    for request in next {
      #expect(request.expiresAt == later.addingTimeInterval(86_400))
      try ledger.answer(request.id, with: .onlyThisTime, now: answered)
    }
    let retried = try authorization(
      from: ledger.authorize(
        invocation: invocation(), requirements: original, retryIDs: Set(next.map(\.id)),
        now: answered))
    #expect(retried.requirements.networks.count == 2)
  }

}
