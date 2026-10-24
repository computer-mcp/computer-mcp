import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsInvocationRequirementsTests {
  private let network = NetworkRequirement(
    host: "local", projectID: "project", isLocalNetwork: true)

  @Test(arguments: [false, true])
  func localAnswerCannotAuthorizeAPartialHostAction(restored: Bool) throws {
    var ledger = PermissionLedger()
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "local",
        sourceProjectID: "project",
        isLocalNetwork: true,
        now: instant))
    #expect(pending.requirements.networks == [network])
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    if restored { ledger = try roundTrip(ledger) }
    let partial = try request(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.localNetwork, scope: .host("local", project: "project"))],
        retryIDs: [pending.id], now: instant))
    #expect(partial.id != pending.id)
    #expect(ledger.requests[pending.id]?.status == .onlyThisTime)
    #expect(ledger.authorizations.isEmpty)
    #expect(ledger.executions.isEmpty)

    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let host = try request(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: pending.requirements,
        retryIDs: [pending.id],
        now: instant))
    guard case .network(let content) = host.content else {
      Issue.record("The full retry must still request host admission")
      return
    }
    #expect(content.host == "local")
    #expect(host.requirements == pending.requirements)
    #expect(ledger.authorizations.isEmpty)
    try ledger.answer(host.id, with: .onlyThisTime, now: instant)
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "local",
        sourceProjectID: "project",
        isLocalNetwork: true,
        retryIDs: [pending.id, host.id],
        now: instant))
    #expect(allowed.requirements == pending.requirements)
    #expect(allowed.requestIDs == [pending.id, host.id])
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    if restored { ledger = try roundTrip(ledger) }
    #expect(
      ledger.executionAccess(
        execution.id, principal: client, operation: .readResult, now: instant) == .allowed)
  }

  @Test(arguments: [false, true])
  func equalRequirementsMatchAcrossConvenienceEntrypoints(restored: Bool) throws {
    var ledger = PermissionLedger()
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(), actions: [], networks: [network], now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let host = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "local",
        sourceProjectID: "project",
        isLocalNetwork: true,
        retryIDs: [pending.id],
        now: instant))
    try ledger.answer(host.id, with: .onlyThisTime, now: instant)
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [],
        networks: [network],
        retryIDs: [pending.id, host.id],
        now: instant))
    #expect(allowed.requirements == pending.requirements)
    #expect(allowed.requestIDs == [pending.id, host.id])
    _ = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
  }

  @Test(arguments: [false, true])
  func differentRequirementsNeverMatchAcrossEntrypoints(restored: Bool) throws {
    var original = PermissionLedger()
    do {
      var updatedEnvironment = original.environment
      updatedEnvironment.trustedHosts = hostRules(
        [], preserving: original.environment.trustedHosts)
      try original.reconcile(environment: updatedEnvironment, expectedRevision: original.revision)

    }
    let pending = try request(
      from: original.authorizeNetwork(
        invocation: invocation(),
        host: "local",
        sourceProjectID: "project",
        isLocalNetwork: true,
        now: instant))
    try original.answer(pending.id, with: .onlyThisTime, now: instant)
    if restored { original = try roundTrip(original) }
    let variations = [
      InvocationRequirements(
        actions: [action(.localNetwork, scope: .host("local", project: "project"))],
        sandboxProjectID: "project"),
      InvocationRequirements(
        networks: [NetworkRequirement(host: "other", projectID: "project", isLocalNetwork: true)],
        sandboxProjectID: "project"),
      InvocationRequirements(
        networks: [NetworkRequirement(host: "local", projectID: "other", isLocalNetwork: true)],
        sandboxProjectID: "other"),
      InvocationRequirements(
        networks: [NetworkRequirement(host: "local", projectID: "project", isLocalNetwork: false)],
        sandboxProjectID: "project"),
      InvocationRequirements(
        networks: [network], mode: .fullAccess(.standing), sandboxProjectID: "project"),
      InvocationRequirements(actions: [action()], networks: [network], sandboxProjectID: "project"),
      InvocationRequirements(
        paths: [PathRequirement(path: path("/system"), operation: .read)], networks: [network],
        sandboxProjectID: "project"),
      InvocationRequirements(
        networks: [
          NetworkRequirement(
            host: "local", projectID: "project", isLocalNetwork: true, pluginPurpose: "discovery")
        ], sandboxProjectID: "project"),
      InvocationRequirements(sandboxProjectID: "project"),
    ]
    for requirements in variations {
      var ledger = original
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        updatedEnvironment.paths =
          requirements.paths.isEmpty
          ? nil : TestPathEnvironment().snapshot(preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
        updatedEnvironment = ledger.environment
        if requirements.mode != .sandbox {
          updatedEnvironment.modes[client] = ledger.consent(for: client, mode: requirements.mode)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
      }
      let decision = try ledger.authorize(
        invocation: invocation(),
        requirements: requirements,
        retryIDs: [pending.id],
        now: instant)
      switch decision {
      case .allowed(let authorization): #expect(!authorization.requestIDs.contains(pending.id))
      case .requests(let requests): #expect(requests.allSatisfy { $0.id != pending.id })
      case .denied:
        Issue.record("These fresh requirements should be requestable or already allowed")
      }
      #expect(
        ledger.requests[pending.id]?.status
          == (requirements.mode == .sandbox ? .onlyThisTime : .revoked))
    }

    var ledger = PermissionLedger()
    let local = try request(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.localNetwork, scope: .host("local", project: "project"))], now: instant))
    try ledger.answer(local.id, with: .onlyThisTime, now: instant)
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let outbound = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "local",
        sourceProjectID: "project",
        isLocalNetwork: true,
        retryIDs: [local.id],
        now: instant))
    #expect(outbound.id != local.id)
    #expect(ledger.authorizations.isEmpty)
  }

  @Test(arguments: [false, true], [false, true])
  func hostAdmissionAndLocalPermissionAreBothNecessary(hostGranted: Bool, localGranted: Bool) throws
  {
    for restored in [false, true] {
      for access in [
        NetworkAccess.none, .trusted, .custom(hosts: ["other"], includesTrusted: false),
      ] {
        var ledger = PermissionLedger()
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            [], preserving: ledger.environment.trustedHosts)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        _ = try ledger.setSandboxSettings(
          SandboxSettings(network: hostGranted ? access.adding("local") : access),
          for: SandboxSettingsKey(principal: client, projectID: "project"),
          expectedRevision: ledger.revision)
        if localGranted {
          try ledger.setPermission(
            .granted(.access), for: .localNetwork, principal: client,
            expectedRevision: ledger.revision)
        }
        if restored { ledger = try roundTrip(ledger) }
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            [], preserving: ledger.environment.trustedHosts)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        let decision = try ledger.authorizeNetwork(
          invocation: invocation(),
          host: "local",
          sourceProjectID: "project",
          isLocalNetwork: true,
          now: instant)
        if hostGranted && localGranted {
          _ = try authorization(from: decision)
        } else {
          let pending = try request(from: decision)
          #expect(pending.requirements.networks == [network])
          #expect(ledger.authorizations.isEmpty)
        }
      }
    }
  }

  @Test(arguments: [false, true], ["owner", "machine", "local", "unreadable"])
  func managedCeilingsConstrainCompleteRetriesAndExecutions(restored: Bool, ceiling: String) throws
  {
    var ledger = PermissionLedger()
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let local = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "local",
        sourceProjectID: "project",
        isLocalNetwork: true,
        now: instant))
    try ledger.answer(local.id, with: .onlyThisTime, now: instant)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let host = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "local",
        sourceProjectID: "project",
        isLocalNetwork: true,
        retryIDs: [local.id],
        now: instant))
    try ledger.answer(host.id, with: .onlyThisTime, now: instant)
    if restored { ledger = try roundTrip(ledger) }
    let limits: ManagedLimits
    switch ceiling {
    case "owner": limits = ManagedLimits(owner: .available(ManagedPolicy(network: .none)))
    case "machine": limits = ManagedLimits(machine: .available(ManagedPolicy(network: .trusted)))
    case "local":
      var permissions = Permissions()
      try permissions.set(.denied, for: .localNetwork)
      limits = ManagedLimits(owner: .available(ManagedPolicy(permissionCeilings: permissions)))
    default: limits = ManagedLimits(machine: .unreadable)
    }
    var retry = ledger
    do {
      var updatedEnvironment = retry.environment
      updatedEnvironment.limits[(invocation()).principal] = limits
      updatedEnvironment.trustedHosts = hostRules([], preserving: retry.environment.trustedHosts)
      try retry.reconcile(environment: updatedEnvironment, expectedRevision: retry.revision)

    }
    let decision = try retry.authorize(
      invocation: invocation(),
      requirements: local.requirements,
      retryIDs: [local.id, host.id],
      now: instant)
    guard case .denied = decision else {
      Issue.record("Managed limits must deny the retry")
      return
    }
    #expect(retry.authorizations.isEmpty)
    #expect(retry.requests[local.id]?.status == .revoked)
    #expect(retry.requests[host.id]?.status == .revoked)

    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "local",
        sourceProjectID: "project",
        isLocalNetwork: true,
        retryIDs: [local.id, host.id],
        now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits = [client: limits]
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        execution.id,
        principal: client,
        operation: .readResult,
        now: instant) == .denied(.authorizationRevoked))
    #expect(ledger.pendingExecutionTerminations == [execution.id])
    #expect(throws: PermissionModelError.invalidAuthorization) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits = [client: limits]
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.startExecution(
        owner: client,
        authorizationIDs: [allowed.id])
    }
  }

  @Test(arguments: [false, true])
  func pathRangeAndAdditionalPermissionsArePartOfRequestIdentity(restored: Bool) throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let root = path("/people/me/tasks/job")
    let directory = PermissionAction(
      requirement: requirement(.project("project"), .read),
      scope: .path(root), pathOperation: .listDirectory)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [directory],
        now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    if restored { ledger = try roundTrip(ledger) }
    let changed = [
      [action(.project("project"), .read, scope: .path(root))],
      [action(.project("project"), .read, scope: .path(path("/people/me/tasks/job/sub")))],
      [directory, action()],
    ]
    for actions in changed {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      let replacement = try request(
        from: ledger.authorize(
          invocation: invocation(),
          actions: actions,
          retryIDs: [pending.id],
          now: instant))
      #expect(replacement.id != pending.id)
      #expect(ledger.authorizations.isEmpty)
    }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: pending.requirements,
        retryIDs: [pending.id],
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
  }

  @Test(arguments: [false, true])
  func oneCallRetainsPermissionPathAndOutboundRequirements(restored: Bool) throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let requirements = InvocationRequirements(
      actions: [action()],
      paths: [PathRequirement(path: path("/people/me/tasks/job"), operation: .read)],
      networks: [network], sandboxProjectID: "project")
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    guard
      case .requests(let initial) = try ledger.authorize(
        invocation: invocation(),
        requirements: requirements,
        now: instant)
    else {
      Issue.record("Expected missing permissions")
      return
    }
    #expect(initial.count == 3)
    for pending in initial {
      #expect(pending.requirements == requirements)
      try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    }
    let ids = Set(initial.map(\.id))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let host = try request(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: requirements,
        retryIDs: ids,
        now: instant))
    #expect(host.requirements == requirements)
    try ledger.answer(host.id, with: .onlyThisTime, now: instant)
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: requirements,
        retryIDs: ids.union([host.id]),
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let execution = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    #expect(
      try ledger.revoke(
        principal: client, permission: .project("project"), expectedRevision: ledger.revision
      ).executionsToTerminate
        == [execution.id])
  }

  private func roundTrip(_ ledger: PermissionLedger) throws -> PermissionLedger {
    try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
  }
}
