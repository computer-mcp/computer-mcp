import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsAdmissionEvidenceTests {
  @Test(
    arguments: [false, true],
    [false, true].flatMap { pending in [false, true].map { (pending, $0) } })
  func retryRecordsNewTrustedAdmission(restored: Bool, state: (Bool, Bool)) throws {
    let (awaitingAnotherAnswer, completed) = state
    var ledger = PermissionLedger()
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    let requirements = InvocationRequirements(
      actions: awaitingAnotherAnswer ? [action()] : [],
      networks: [NetworkRequirement(host: "local", projectID: "project", isLocalNetwork: true)],
      sandboxProjectID: "project")
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    guard
      case .requests(let pending) = try ledger.authorize(
        invocation: invocation(),
        requirements: requirements,
        now: instant)
    else {
      Issue.record("Expected local permission")
      return
    }
    let local = try #require(pending.first { $0.requirementPermission == .localNetwork })
    try ledger.answer(local.id, with: .onlyThisTime, now: instant)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["local"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .trusted),
      for: key, expectedRevision: ledger.revision)
    if restored { ledger = try roundTrip(ledger) }
    if awaitingAnotherAnswer {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          ["local"], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.authorize(
        invocation: invocation(),
        requirements: requirements,
        retryIDs: [local.id],
        now: instant)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          ["local"], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.setSandboxSettings(
        SandboxSettings(network: ledger.sandboxSettings.entries[key]!.network.adding("local")),
        for: key, expectedRevision: ledger.revision)
      _ = try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }()
      for request in pending { #expect(ledger.requests[request.id]?.status == .revoked) }
      return
    }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["local"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: requirements,
        retryIDs: [local.id],
        now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    if completed {
      try ledger.finishExecution(execution.id, retainUntil: instant.addingTimeInterval(60))
    }
    let terminations: Set<UUID> = completed ? [] : [execution.id]
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["local"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: ledger.sandboxSettings.entries[key]!.network.adding("local")),
      for: key, expectedRevision: ledger.revision)
    #expect(ledger.pendingExecutionTerminations.isEmpty)
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate == terminations)
    #expect(ledger.requests[local.id]?.status == .revoked)
    if restored { ledger = try roundTrip(ledger) }
    for execution in [execution] {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          ["local"], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      #expect(
        ledger.executionAccess(
          execution.id,
          principal: client,
          operation: .readResult,
          now: instant) == .denied(.authorizationRevoked))
    }
    #expect(ledger.pendingExecutionTerminations == terminations)
  }

  @Test(
    arguments: [false, true],
    [NetworkAccess.trusted, .custom(hosts: ["host"], includesTrusted: false), .full])
  func networkSourceCannotBeReplaced(restored: Bool, source: NetworkAccess) throws {
    var ledger = PermissionLedger()
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["host"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: source),
      for: key, expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["host"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "host",
        sourceProjectID: "project",
        isLocalNetwork: false,
        now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    if restored { ledger = try roundTrip(ledger) }
    let replacement: NetworkAccess =
      source.configuration == .full ? .custom(hosts: ["host"], includesTrusted: false) : .full
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["host"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.setSandboxSettings(
        SandboxSettings(network: replacement),
        for: key, expectedRevision: ledger.revision
      ).executionsToTerminate == [running.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["host"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(digest: "fresh"),
        host: "host",
        sourceProjectID: "project",
        isLocalNetwork: false,
        now: instant))
    #expect(
      ledger.executionAccess(
        running.id, principal: client, operation: .readResult,
        now: instant) == .denied(.authorizationRevoked))
  }

  @Test(arguments: [false, true], [PermissionAnswer.always, .onlyThisTime])
  func replacementGrantCannotReviveAnExecution(restored: Bool, answer: PermissionAnswer) throws {
    var ledger = PermissionLedger()
    let first = try request(
      from: ledger.authorize(invocation: invocation(), actions: [action()], now: instant))
    try ledger.answer(first.id, with: answer, now: instant)
    let old = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action()], retryIDs: [first.id], now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [old.id])
    if restored { ledger = try roundTrip(ledger) }
    if case .always = answer {
      try ledger.setPermission(
        .notGranted, for: .screen, principal: client, expectedRevision: ledger.revision)
    } else {
      _ = try ledger.revokeAuthorization(old.id)
    }
    let second = try request(
      from: ledger.authorize(invocation: invocation(), actions: [action()], now: instant))
    try ledger.answer(second.id, with: answer, now: instant)
    let replacement = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action()], retryIDs: [second.id], now: instant))
    #expect(first.id != second.id)
    let oldGrants = old.basis.compactMap {
      if case .permission(let grant) = $0 { return grant }
      return nil
    }
    let newGrants = replacement.basis.compactMap {
      if case .permission(let grant) = $0 { return grant }
      return nil
    }
    #expect(Set(oldGrants).isDisjoint(with: newGrants))
    _ = try ledger.startExecution(owner: client, authorizationIDs: [replacement.id])
    if restored { ledger = try roundTrip(ledger) }
    #expect(
      ledger.executionAccess(
        running.id, principal: client, operation: .readResult,
        now: instant) == .denied(.authorizationRevoked))
    #expect(ledger.pendingExecutionTerminations == [running.id])
  }

  @Test(arguments: [false, true], ["project", "folder", "developer", "system"])
  func pathRuleReplacementCannotSupplyRecordedAccess(restored: Bool, source: String) throws {
    var environment = TestPathEnvironment()
    let root = path("/people/me/rules")
    let target = path("/people/me/rules/child/file")
    switch source {
    case "project":
      environment.projects = try ProjectCatalog([RegisteredProject(id: "project", root: root)])
    case "folder": environment.folders = [.documents: [root]]
    case "developer": environment.developerLocations = [root]
    default: environment.systemLocations = [root]
    }
    let original = PathPermissions(environment: environment)
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    try ledger.setPermission(
      .granted(.read), for: .filesAndFolders(.documents), principal: client,
      expectedRevision: ledger.revision)
    let requirements = InvocationRequirements(paths: [
      PathRequirement(path: target, operation: .read)
    ])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (original).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: requirements,
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
    if restored { ledger = try roundTrip(ledger) }
    let replacementRoot = path("/people/me/rules/child")
    switch source {
    case "project":
      environment.projects = try ProjectCatalog([RegisteredProject(id: "project", root: root)])
    case "folder": environment.folders = [.documents: [replacementRoot]]
    case "developer": environment.developerLocations = [replacementRoot]
    default: environment.systemLocations = [replacementRoot]
    }
    let replacement = PathPermissions(environment: environment)
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (replacement).environment.snapshot(
          preserving: updatedEnvironment.paths)
        if source == "project" {
          try updatedEnvironment.paths!.setProjects(environment.projects.projects)
        }
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate == [running.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (replacement).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try authorization(
      from: ledger.authorize(
        invocation: invocation(digest: "fresh"),
        requirements: requirements,
        now: instant))
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (original).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        running.id,
        principal: client,
        operation: .readResult,
        now: instant) == .denied(.authorizationRevoked))
  }

  @Test(arguments: [false, true], ["revision", "permission", "network"])
  func managedSourceReplacementCannotAuthorizeExistingExecution(restored: Bool, change: String)
    throws
  {
    var ledger = PermissionLedger()
    var policy = ManagedPolicy(network: .trusted)
    try policy.permissionCeilings.set(.granted(.access), for: .skills)
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["host"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .full),
      for: key, expectedRevision: ledger.revision)
    let requirements = InvocationRequirements(
      actions: [action(.skills)],
      networks: [NetworkRequirement(host: "host", projectID: "project", isLocalNetwork: false)])
    let limits = ManagedLimits(owner: .available(policy))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits[(invocation()).principal] = limits
      updatedEnvironment.trustedHosts = hostRules(
        ["host"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        requirements: requirements,
        now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    if restored { ledger = try roundTrip(ledger) }
    switch change {
    case "revision":
      policy = ManagedPolicy(permissionCeilings: policy.permissionCeilings, network: .trusted)
    case "permission":
      try policy.permissionCeilings.set(.notGranted, for: .skills)
      try policy.permissionCeilings.set(.granted(.access), for: .skills)
    default: policy.network = .custom(hosts: ["host"], includesTrusted: false)
    }
    let replacement = ManagedLimits(owner: .available(policy))
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits = [client: replacement]
        updatedEnvironment.trustedHosts = hostRules(
          ["host"], preserving: ledger.environment.trustedHosts)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate
        == [running.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits[(invocation(digest: "fresh")).principal] = replacement
      updatedEnvironment.trustedHosts = hostRules(
        ["host"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try authorization(
      from: ledger.authorize(
        invocation: invocation(digest: "fresh"),
        requirements: requirements,
        now: instant))
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits = [client: limits]
      updatedEnvironment.trustedHosts = hostRules(
        ["host"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        running.id,
        principal: client,
        operation: .readResult,
        now: instant)
        == .denied(.authorizationRevoked))
  }

  @Test(arguments: [false, true])
  func allRequirementCollectionsHaveCanonicalIdentity(restored: Bool) throws {
    let actions = [action(), action(.unifiedLogs)]
    let paths = [
      PathRequirement(path: path("/people/me/tasks/job/a"), operation: .read),
      PathRequirement(path: path("/people/me/tasks/job/b"), operation: .read),
    ]
    let networks = [
      NetworkRequirement(host: "EXAMPLE.COM.", projectID: "project", isLocalNetwork: false),
      NetworkRequirement(host: "SECOND.EXAMPLE.", projectID: "project", isLocalNetwork: false),
    ]
    let first = InvocationRequirements(actions: actions, paths: paths, networks: networks)
    let second = InvocationRequirements(
      actions: Array(actions.reversed()) + actions,
      paths: Array(paths.reversed()) + paths, networks: Array(networks.reversed()) + networks)
    #expect(first == second)
    #expect(Set([first, second]).count == 1)
    #expect(first.networks.map(\.host) == ["example.com", "second.example"])
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
    for key in ["actions", "paths", "networks"] {
      let values = try #require(object[key] as? [Any])
      object[key] = Array(values.reversed()) + values
    }
    let decoded = try JSONDecoder().decode(
      InvocationRequirements.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded == first)
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    guard
      case .requests(let pending) = try ledger.authorize(
        invocation: invocation(),
        requirements: first,
        now: instant)
    else {
      Issue.record("Expected requests")
      return
    }
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    guard
      case .requests(let reused) = try ledger.authorize(
        invocation: invocation(),
        requirements: decoded,
        now: instant)
    else {
      Issue.record("Expected reused requests")
      return
    }
    #expect(Set(pending.map(\.id)) == Set(reused.map(\.id)))
    for request in pending { try ledger.answer(request.id, with: .onlyThisTime, now: instant) }
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
        requirements: second,
        retryIDs: Set(pending.map(\.id)),
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
  func executionStartRecordsTheCurrentImplicitNetworkProfile(restored: Bool) throws {
    var ledger = PermissionLedger()
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action(.skills)], now: instant))
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["host"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .trusted),
      for: key, expectedRevision: ledger.revision)
    if restored { ledger = try roundTrip(ledger) }
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["host"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: ledger.sandboxSettings.entries[key]!.network.adding("host")),
      for: key, expectedRevision: ledger.revision)
    #expect(ledger.pendingExecutionTerminations.isEmpty)
    if restored { ledger = try roundTrip(ledger) }
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate == [running.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["host"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        running.id,
        principal: client,
        operation: .readResult,
        now: instant) == .denied(.authorizationRevoked))
  }

  @Test(arguments: [false, true])
  func modeRevocationPersistsTerminationAndCannotUseNewConsent(restored: Bool) throws {
    var ledger = PermissionLedger()
    do {
      var updatedEnvironment = ledger.environment
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
      updatedEnvironment = ledger.environment
      if updatedEnvironment.modes[(invocation()).principal]?.mode
        != .fullAccess(.connection("original"))
      {
        updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
          for: (invocation()).principal, mode: .fullAccess(.connection("original")))
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.skills)],
        now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    if restored { ledger = try roundTrip(ledger) }
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.endedConnections.insert("original")
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate == [running.id])
    do {
      var updatedEnvironment = ledger.environment
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
      updatedEnvironment = ledger.environment
      if updatedEnvironment.modes[(invocation()).principal]?.mode
        != .fullAccess(.connection("replacement"))
      {
        updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
          for: (invocation()).principal, mode: .fullAccess(.connection("replacement")))
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
    }
    let fresh = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.skills)],
        now: instant))
    _ = try ledger.startExecution(owner: client, authorizationIDs: [fresh.id])
    if restored { ledger = try roundTrip(ledger) }
    #expect(
      ledger.executionAccess(
        running.id, principal: client, operation: .readResult,
        now: instant) == .denied(.authorizationRevoked))
    #expect(
      try ledger.reconcile(environment: ledger.environment, expectedRevision: ledger.revision)
        .executionsToTerminate == [running.id])
    ledger.acknowledgeExecutionTerminations([running.id])
    #expect(
      try ledger.reconcile(environment: ledger.environment, expectedRevision: ledger.revision)
        .executionsToTerminate.isEmpty)
  }

  @Test(arguments: [false, true], ["expire", "consume", "revoke"])
  func chainedPathAndNetworkConditionsRetireTogether(restored: Bool, change: String) throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let requirements = InvocationRequirements(
      paths: [PathRequirement(path: path("/people/me/tasks/job"), operation: .read)],
      networks: [NetworkRequirement(host: "local", projectID: "project", isLocalNetwork: true)])
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
      Issue.record("Expected initial requests")
      return
    }
    #expect(initial.count == 2)
    for request in initial { try ledger.answer(request.id, with: .onlyThisTime, now: instant) }
    let initialIDs = Set(initial.map(\.id))
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
        retryIDs: initialIDs,
        now: instant.addingTimeInterval(1)))
    if restored { ledger = try roundTrip(ledger) }
    if change == "expire" {
      #expect(throws: PermissionModelError.invalidAuthorization) {
        try ledger.answer(host.id, with: .always, now: instant.addingTimeInterval(86_400))
      }
      #expect(ledger.requests[host.id]?.status == .revoked)
      #expect(ledger.permissions(for: client).state(for: .project("project")) == .notGranted)
      #expect(ledger.sandboxSettings.entries.isEmpty)
      return
    }
    try ledger.answer(host.id, with: .onlyThisTime, now: instant.addingTimeInterval(1))
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
        retryIDs: initialIDs.union([host.id]),
        now: instant.addingTimeInterval(1)))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let running = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    if change == "consume" {
      try ledger.setPermission(
        .granted(.read), for: .project("project"), principal: client,
        expectedRevision: ledger.revision)
      try ledger.setPermission(
        .granted(.access), for: .localNetwork, principal: client, expectedRevision: ledger.revision)
      #expect(throws: PermissionModelError.requestConsumed) {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (resolver).environment.snapshot(
            preserving: updatedEnvironment.paths)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        _ = try ledger.authorize(
          invocation: invocation(),
          requirements: requirements,
          retryIDs: [host.id],
          now: instant.addingTimeInterval(1))
      }
    }
    if restored { ledger = try roundTrip(ledger) }
    #expect(try ledger.revokeAuthorization(allowed.id).executionsToTerminate == [running.id])
    for request in initial + [host] { #expect(ledger.requests[request.id]?.status == .revoked) }
  }

  @Test(arguments: [false, true])
  func expandedRequirementsCreateAnIndependentGroupWithPathEvidence(restored: Bool) throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let actions = [action(), action(.unifiedLogs)]
    guard
      case .requests(let initial) = try ledger.authorize(
        invocation: invocation(), actions: actions,
        now: instant)
    else {
      Issue.record("Expected initial group")
      return
    }
    try ledger.answer(initial[0].id, with: .onlyThisTime, now: instant)
    let traversal = PermissionAction(
      requirement: requirement(.filesAndFolders(.downloads), .read),
      scope: .path(path("/people/me/Downloads")), pathOperation: .listDirectory)
    let expanded = actions + [traversal]
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    guard
      case .requests(let pending) = try ledger.authorize(
        invocation: invocation(),
        actions: expanded,
        retryIDs: [initial[0].id],
        now: instant)
    else {
      Issue.record("Expected expanded group")
      return
    }
    #expect(Set(initial.map(\.id)).isDisjoint(with: pending.map(\.id)))
    for request in pending { try ledger.answer(request.id, with: .onlyThisTime, now: instant) }
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
        actions: expanded.reversed(),
        retryIDs: Set(pending.map(\.id)),
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let running = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    #expect(
      try ledger.revoke(
        principal: client, permission: .project("project"), expectedRevision: ledger.revision
      ).executionsToTerminate
        == [running.id])
    #expect(ledger.requests[initial[0].id]?.status == .onlyThisTime)
    for request in pending { #expect(ledger.requests[request.id]?.status == .revoked) }
  }

  private func roundTrip(_ ledger: PermissionLedger) throws -> PermissionLedger {
    try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
  }
}

extension PermissionRequest {
  fileprivate var requirementPermission: Permission? {
    if case .permission(let content) = content { return content.requirement.permission }
    return nil
  }
}
