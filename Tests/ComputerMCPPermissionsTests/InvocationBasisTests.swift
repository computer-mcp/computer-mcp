import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsInvocationBasisTests {
  @Test(arguments: [false, true], [false, true])
  func otherGrantedPermissionInvalidatesTheWholeRequest(restored: Bool, answered: Bool) throws {
    var ledger = PermissionLedger()
    let actions = [action(.skills), action(.screen)]
    let pending = try request(
      from: ledger.authorize(invocation: invocation(), actions: actions, now: instant))
    if answered { try ledger.answer(pending.id, with: .onlyThisTime, now: instant) }
    if restored { ledger = try roundTrip(ledger) }
    try ledger.setPermission(
      .notGranted, for: .skills, principal: client, expectedRevision: ledger.revision)
    #expect(ledger.requests[pending.id]?.status == .revoked)
    if restored { ledger = try roundTrip(ledger) }
    try ledger.setPermission(
      .granted(.access), for: .skills, principal: client, expectedRevision: ledger.revision)
    _ = try ledger.reconcile(
      environment: PermissionEnvironment(), expectedRevision: ledger.revision)
    if restored { ledger = try roundTrip(ledger) }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.authorize(
        invocation: invocation(), actions: actions, retryIDs: [pending.id], now: instant)
    }
    let fresh = try request(
      from: ledger.authorize(invocation: invocation(), actions: actions, now: instant))
    #expect(fresh.id != pending.id)
  }

  @Test(arguments: [false, true])
  func grantedCombinationAndPartialRetryRetainEveryGrant(restored: Bool) throws {
    for (needsRequest, completed) in [false, true].flatMap({ needs in
      [false, true].map { (needs, $0) }
    }) {
      var ledger = PermissionLedger()
      let actions = [action(.skills), action(.screen), action(.project("project"), .read)]
      try ledger.setPermission(
        .granted(.read), for: .project("*"), principal: client, expectedRevision: ledger.revision)
      var ids: Set<UUID> = []
      if needsRequest {
        let pending = try request(
          from: ledger.authorize(invocation: invocation(), actions: actions, now: instant))
        try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
        ids = [pending.id]
        // An explicit entry cannot replace the wildcard that admitted the original call.
        try ledger.setPermission(
          .granted(.read), for: .project("project"), principal: client,
          expectedRevision: ledger.revision)
      } else {
        try ledger.setPermission(
          .granted(.access), for: .screen, principal: client, expectedRevision: ledger.revision)
      }
      let allowed = try authorization(
        from: ledger.authorize(
          invocation: invocation(), actions: actions, retryIDs: ids, now: instant))
      let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
      if completed {
        try ledger.finishExecution(execution.id, retainUntil: instant.addingTimeInterval(60))
      }
      let terminations: Set<UUID> = completed ? [] : [execution.id]
      if restored { ledger = try roundTrip(ledger) }
      #expect(
        try ledger.revoke(
          principal: client, permission: .project("*"), expectedRevision: ledger.revision
        ).executionsToTerminate
          == terminations)
      try ledger.setPermission(
        .granted(.read), for: .project("*"), principal: client, expectedRevision: ledger.revision)
      if restored { ledger = try roundTrip(ledger) }
      for execution in [execution] {
        #expect(
          ledger.executionAccess(
            execution.id, principal: client, operation: .readResult, now: instant)
            == .denied(.authorizationRevoked))
      }
    }
  }

  @Test(arguments: [false, true], [false, true])
  func siblingRequestsShareAnsweredConditions(restored: Bool, always: Bool) throws {
    var ledger = PermissionLedger()
    let actions = [action(.screen), action(.unifiedLogs)]
    guard
      case .requests(let pending) = try ledger.authorize(
        invocation: invocation(), actions: actions, now: instant)
    else {
      Issue.record("Expected two pending requests")
      return
    }
    #expect(pending.count == 2)
    try ledger.answer(pending[0].id, with: always ? .always : .onlyThisTime, now: instant)
    if restored { ledger = try roundTrip(ledger) }
    var invalid = ledger
    _ = try invalid.revoke(
      principal: client, permission: .screen, expectedRevision: invalid.revision)
    try invalid.setPermission(
      .granted(.access), for: .screen, principal: client, expectedRevision: invalid.revision)
    if restored { invalid = try roundTrip(invalid) }
    #expect(invalid.requests[pending[1].id]?.status == .revoked)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try invalid.answer(pending[1].id, with: .onlyThisTime, now: instant)
    }
    try ledger.answer(pending[1].id, with: .onlyThisTime, now: instant)
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: actions, retryIDs: Set(pending.map(\.id)), now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    if restored { ledger = try roundTrip(ledger) }
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .readResult, now: instant)
        == .allowed)
    #expect(try ledger.revokeAuthorization(allowed.id).executionsToTerminate == [running.id])
    for request in pending { #expect(ledger.requests[request.id]?.status == .revoked) }
  }

  @Test(arguments: [false, true], [false, true])
  func oneTimeConditionsRequireEveryAnswer(restored: Bool, consumeTogether: Bool) throws {
    var ledger = PermissionLedger()
    let actions = [action(.screen), action(.desktopControl), action(.unifiedLogs)]
    guard
      case .requests(let pending) = try ledger.authorize(
        invocation: invocation(), actions: actions, now: instant)
    else {
      Issue.record("Expected all requests")
      return
    }
    for request in pending { try ledger.answer(request.id, with: .onlyThisTime, now: instant) }
    if restored { ledger = try roundTrip(ledger) }
    let ids = Set(pending.map(\.id))
    if !consumeTogether {
      #expect(throws: PermissionModelError.invalidAuthorization) {
        try ledger.authorize(
          invocation: invocation(), actions: actions, retryIDs: [pending[0].id], now: instant)
      }
      #expect(pending.allSatisfy { ledger.requests[$0.id]?.status == .onlyThisTime })
    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: actions, retryIDs: ids, now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    #expect(try ledger.revokeAuthorization(allowed.id).executionsToTerminate == [running.id])
    for request in pending { #expect(ledger.requests[request.id]?.status == .revoked) }
  }

  @Test(arguments: [false, true])
  func dependencyCannotBeOmittedAfterAStandingGrantAppears(restored: Bool) throws {
    var ledger = PermissionLedger()
    let actions = [action(), action(.unifiedLogs)]
    guard
      case .requests(let pending) = try ledger.authorize(
        invocation: invocation(), actions: actions, now: instant)
    else {
      Issue.record("Expected two requests")
      return
    }
    let first = pending[0]
    let second = pending[1]
    try ledger.answer(first.id, with: .onlyThisTime, now: instant)
    try ledger.answer(second.id, with: .onlyThisTime, now: instant)
    try ledger.setPermission(
      .granted(.access), for: .screen, principal: client, expectedRevision: ledger.revision)
    if restored { ledger = try roundTrip(ledger) }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.authorize(
        invocation: invocation(), actions: [action(), action(.unifiedLogs)],
        retryIDs: [second.id], now: instant)
    }
    #expect(ledger.requests[first.id]?.status == .onlyThisTime)
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action(), action(.unifiedLogs)],
        retryIDs: [first.id, second.id], now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    // The one-time source remains authoritative despite the new standing grant.
    #expect(
      try ledger.setPermission(
        .notGranted, for: .screen, principal: client, expectedRevision: ledger.revision
      ).executionsToTerminate
        .isEmpty)
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .readResult, now: instant)
        == .allowed)
  }

  @Test(arguments: [false, true])
  func otherActionsPathEvidenceCannotBeReplacedDuringRetry(restored: Bool) throws {
    var ledger = PermissionLedger()
    var environment = TestPathEnvironment()
    let root = path("/people/me/toolchains/swift")
    let actions = [action(.skills, scope: .path(root)), action(.screen)]
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = PathEnvironmentSnapshot(
        (PathPermissions(environment: environment)).environment)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(),
        actions: actions,
        now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    if restored { ledger = try roundTrip(ledger) }
    environment.developerLocations = [path("/people/me/toolchains")]
    #expect(throws: PermissionModelError.invalidAuthorization) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = PathEnvironmentSnapshot(
          (PathPermissions(environment: environment)).environment)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.authorize(
        invocation: invocation(),
        actions: actions,
        retryIDs: [pending.id],
        now: instant)
    }
    #expect(ledger.requests[pending.id]?.status == .revoked)
    if restored { ledger = try roundTrip(ledger) }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = PathEnvironmentSnapshot(
          (PathPermissions(environment: TestPathEnvironment())).environment)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.authorize(
        invocation: invocation(),
        actions: actions,
        retryIDs: [pending.id],
        now: instant)
    }
  }

  @Test(arguments: [false, true])
  func networkConditionKeepsItsOriginalAdmissionRule(restored: Bool) throws {
    var ledger = PermissionLedger()
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["local"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .trusted),
      for: key, expectedRevision: ledger.revision)
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
      with: .onlyThisTime,
      now: instant)
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
    _ = try { () throws -> RevocationResult in
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      return try ledger.reconcile(
        environment: updatedEnvironment, expectedRevision: ledger.revision)
    }()
    #expect(ledger.requests[pending.id]?.status == .revoked)
    if restored { ledger = try roundTrip(ledger) }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          ["local"], preserving: ledger.environment.trustedHosts)
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
  }

  @Test(arguments: [false, true])
  func independentAlwaysAnswerSurvivesLaterOneTimeConsumption(restored: Bool) throws {
    var ledger = PermissionLedger()
    let first = try request(
      from: ledger.authorize(invocation: invocation(), actions: [action()], now: instant))
    try ledger.answer(first.id, with: .always, now: instant)
    let earlier = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action()], retryIDs: [first.id], now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [earlier.id])
    let second = try request(
      from: ledger.authorize(
        invocation: invocation(), actions: [action(), action(.unifiedLogs)],
        retryIDs: [first.id], now: instant))
    try ledger.answer(second.id, with: .onlyThisTime, now: instant)
    if restored { ledger = try roundTrip(ledger) }
    let later = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action(), action(.unifiedLogs)],
        retryIDs: [first.id, second.id], now: instant))
    let another = try ledger.startExecution(owner: client, authorizationIDs: [later.id])
    #expect(ledger.requests[first.id]?.status == .always)
    if restored { ledger = try roundTrip(ledger) }
    for execution in [running, another] {
      #expect(
        ledger.executionAccess(
          execution.id, principal: client, operation: .readResult, now: instant) == .allowed)
    }
    #expect(try ledger.revokeAuthorization(later.id).executionsToTerminate == [another.id])
    #expect(
      ledger.executionAccess(
        running.id, principal: client, operation: .readResult, now: instant) == .allowed)
  }

  @Test(arguments: [false, true], [false, true])
  func deniedRetryPermanentlyInvalidatesItsOriginalConditions(restored: Bool, managed: Bool) throws
  {
    var ledger = PermissionLedger()
    let original = TestPathEnvironment()
    let root = path("/people/me/toolchains/swift")
    let actions = [action(.skills, scope: .path(root)), action(.screen)]
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = PathEnvironmentSnapshot(
        (PathPermissions(environment: original)).environment)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(),
        actions: actions,
        now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    if restored { ledger = try roundTrip(ledger) }
    var environment = original
    var limits = ManagedLimits()
    if managed {
      var ceilings = Permissions()
      try ceilings.set(.denied, for: .skills)
      limits = ManagedLimits(owner: .available(ManagedPolicy(permissionCeilings: ceilings)))
    } else {
      environment.hostDataLocations.insert(root)
    }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits[(invocation()).principal] = limits
      updatedEnvironment.paths = PathEnvironmentSnapshot(
        (PathPermissions(environment: environment)).environment)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let result = try ledger.authorize(
      invocation: invocation(),
      actions: actions,
      retryIDs: [pending.id],
      now: instant)
    #expect(result == .denied(managed ? .managedLimit([.owner]) : .hostData))
    #expect(ledger.requests[pending.id]?.status == .revoked)
    if restored { ledger = try roundTrip(ledger) }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits = [:]
        updatedEnvironment.paths = PathEnvironmentSnapshot(
          (PathPermissions(environment: original)).environment)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.authorize(
        invocation: invocation(),
        actions: actions,
        retryIDs: [pending.id],
        now: instant)
    }
  }

  @Test func pendingCombinationIsReused() throws {
    var ledger = PermissionLedger()
    let actions = [action(), action(.unifiedLogs)]
    guard
      case .requests(let first) = try ledger.authorize(
        invocation: invocation(), actions: actions, now: instant),
      case .requests(let second) = try ledger.authorize(
        invocation: invocation(), actions: actions.reversed(), now: instant)
    else {
      Issue.record("Expected pending requests")
      return
    }
    #expect(Set(first.map(\.id)) == Set(second.map(\.id)))
    #expect(ledger.requests.count == 2)
    guard
      case .requests(let renewed) = try ledger.authorize(
        invocation: invocation(), actions: actions, now: instant.addingTimeInterval(86_400))
    else {
      Issue.record("Expected renewed requests")
      return
    }
    #expect(Set(renewed.map(\.id)).isDisjoint(with: first.map(\.id)))
  }

  @Test(arguments: [
    NetworkAccess.trusted, .full, .custom(hosts: ["registry"], includesTrusted: false),
  ])
  func admittedNetworkHonorsManagedTrustedHosts(network: NetworkAccess) throws {
    var ledger = PermissionLedger()
    var limits = ManagedLimits(owner: .available(ManagedPolicy(network: .trusted)))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: network),
      for: SandboxSettingsKey(principal: client, projectID: "project"),
      expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits[(invocation()).principal] = limits
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
      updatedEnvironment = ledger.environment
      limits = ledger.environment.limits[client]!
    }
    let allowed = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "registry",
        sourceProjectID: "project",
        isLocalNetwork: false,
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits = [client: limits]
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let running = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits = [client: limits]
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        running.id,
        principal: client,
        operation: .readResult,
        now: instant) == .allowed)
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits = [client: limits]
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate == [
        running.id
      ])
  }

  @Test func unlistedHostCanUseAOneTimeNetworkAnswer() throws {
    var ledger = PermissionLedger()
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .trusted),
      for: SandboxSettingsKey(principal: client, projectID: "project"),
      expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "example",
        sourceProjectID: "project",
        isLocalNetwork: false,
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    try ledger.answer(
      pending.id,
      with: .onlyThisTime,
      now: instant)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "example",
        sourceProjectID: "project",
        isLocalNetwork: false,
        retryIDs: [pending.id],
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
  }

  @Test(arguments: [false, true])
  func answeringChecksOtherConditionsAgainstCurrentLimits(network: Bool) throws {
    var ledger = PermissionLedger()
    let pending: PermissionRequest
    let limits: ManagedLimits
    if network {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.setSandboxSettings(
        SandboxSettings(network: .full),
        for: SandboxSettingsKey(principal: client, projectID: "project"),
        expectedRevision: ledger.revision)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          [], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      pending = try request(
        from: ledger.authorizeNetwork(
          invocation: invocation(),
          host: "local",
          sourceProjectID: "project",
          isLocalNetwork: true,
          now: instant))
      limits = ManagedLimits(owner: .available(ManagedPolicy(network: .none)))
    } else {
      pending = try request(
        from: ledger.authorize(
          invocation: invocation(), actions: [action(.skills), action()], now: instant))
      var ceilings = Permissions()
      try ceilings.set(.denied, for: .skills)
      limits = ManagedLimits(owner: .available(ManagedPolicy(permissionCeilings: ceilings)))
    }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits[ledger.requests[pending.id]!.invocation.principal] = limits
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      try ledger.answer(
        pending.id,
        with: .always,
        now: instant)
    }
    ledger = try roundTrip(ledger)
    #expect(ledger.requests[pending.id]?.status == .revoked)
    #expect(
      ledger.permissions(for: client).state(for: network ? .localNetwork : .screen) == .notGranted)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.answer(pending.id, with: .always, now: instant)
    }
  }

  @Test func alwaysCombinationSurvivesExpiryAndLaterOneTimeConsumption() throws {
    var ledger = PermissionLedger()
    let actions = [action(), action(.unifiedLogs)]
    guard
      case .requests(let pending) = try ledger.authorize(
        invocation: invocation(), actions: actions, now: instant)
    else {
      Issue.record("Expected pending requests")
      return
    }
    for request in pending { try ledger.answer(request.id, with: .always, now: instant) }
    let ids = Set(pending.map(\.id))
    let first = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: actions, retryIDs: ids, now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [first.id])
    let extra = try request(
      from: ledger.authorize(
        invocation: invocation(), actions: actions + [action(.desktopControl)], retryIDs: ids,
        now: instant))
    try ledger.answer(extra.id, with: .onlyThisTime, now: instant)
    let second = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: actions + [action(.desktopControl)],
        retryIDs: ids.union([extra.id]), now: instant))
    _ = try ledger.revokeAuthorization(second.id)
    _ = try ledger.authorize(
      invocation: invocation(), actions: actions, now: instant.addingTimeInterval(86_400))
    ledger = try roundTrip(ledger)
    #expect(
      ledger.executionAccess(
        running.id, principal: client, operation: .readResult,
        now: instant.addingTimeInterval(86_400)) == .allowed)
  }

  @Test func failedRetryRetirementCommitsThroughStore() async throws {
    let store = InMemoryPermissionStore()
    let actions = [action(.skills, scope: .path(path("/people/me/toolchains/swift"))), action()]
    let id = try await store.transaction { ledger in
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = PathEnvironmentSnapshot(
          (PathPermissions(environment: TestPathEnvironment())).environment)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      let pending = try request(
        from: ledger.authorize(
          invocation: invocation(),
          actions: actions,
          now: instant))
      try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
      return pending.id
    }
    let failure = try await store.transaction { ledger -> PermissionModelError? in
      var changed = TestPathEnvironment()
      changed.developerLocations = [path("/people/me/toolchains")]
      do {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = PathEnvironmentSnapshot(
            (PathPermissions(environment: changed)).environment)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        _ = try ledger.authorize(
          invocation: invocation(),
          actions: actions,
          retryIDs: [id],
          now: instant)
        return nil
      } catch { return error as? PermissionModelError }
    }
    #expect(failure == .invalidAuthorization)
    let restored = try roundTrip(await store.read())
    #expect(restored.requests[id]?.status == .revoked)
  }

  @Test(arguments: [false, true])
  func permissionEntryPointValidatesInheritedNetworkConditions(trusted: Bool) throws {
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
      with: .onlyThisTime,
      now: instant)
    ledger = try roundTrip(ledger)
    if trusted {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          ["local"], preserving: ledger.environment.trustedHosts)
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
        updatedEnvironment.trustedHosts = hostRules(
          ["local"], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.startExecution(
        owner: client,
        authorizationIDs: [allowed.id])
    } else {
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
      ledger = try roundTrip(ledger)
      #expect(ledger.requests[pending.id]?.status == .revoked)
      #expect(throws: PermissionModelError.invalidAuthorization) {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            ["local"], preserving: ledger.environment.trustedHosts)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        _ = try ledger.authorize(
          invocation: invocation(),
          requirements: pending.requirements,
          retryIDs: [pending.id],
          now: instant)
      }
    }
  }

  @Test(arguments: [false, true])
  func retryRetainsItsOriginalTraversalInsteadOfAddingAnotherRoute(restored: Bool) throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let traversal = PermissionAction(
      requirement: requirement(.filesAndFolders(.downloads), .read),
      scope: .path(path("/people/me/Downloads")), pathOperation: .listDirectory)
    let actions = [traversal, action()]
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(),
        actions: actions,
        now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    try ledger.setPermission(
      .granted(.read), for: .filesAndFolders(.downloads), principal: client,
      expectedRevision: ledger.revision)
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
        actions: actions,
        retryIDs: [pending.id],
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
      try ledger.setPermission(
        .notGranted, for: .filesAndFolders(.downloads), principal: client,
        expectedRevision: ledger.revision
      ).executionsToTerminate.isEmpty)
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        running.id,
        principal: client,
        operation: .readResult,
        now: instant) == .allowed)
    #expect(
      try ledger.revoke(
        principal: client, permission: .project("project"), expectedRevision: ledger.revision
      ).executionsToTerminate
        == [running.id])
  }

  @Test(arguments: [false, true])
  func networkRetryKeepsItsTrustedSourceWhenACustomRouteAppears(restored: Bool) throws {
    var ledger = PermissionLedger()
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["local"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .trusted),
      for: key, expectedRevision: ledger.revision)
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
      with: .onlyThisTime,
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
    if restored { ledger = try roundTrip(ledger) }
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
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["local"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.setSandboxSettings(
        SandboxSettings(network: ledger.sandboxSettings.entries[key]!.network.removing("local")),
        for: key, expectedRevision: ledger.revision
      ).executionsToTerminate.isEmpty)
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["local"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        running.id,
        principal: client,
        operation: .readResult,
        now: instant) == .allowed)
  }

  @Test func mixedAnswersKeepTheirOriginalActions() throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let traversal = PermissionAction(
      requirement: requirement(.filesAndFolders(.downloads), .read),
      scope: .path(path("/people/me/Downloads")), pathOperation: .listDirectory)
    let actions = [traversal, action(), action(.unifiedLogs)]
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    guard
      case .requests(let pending) = try ledger.authorize(
        invocation: invocation(),
        actions: actions,
        now: instant)
    else {
      Issue.record("Expected requests")
      return
    }
    try ledger.answer(pending[0].id, with: .always, now: instant)
    try ledger.setPermission(
      .granted(.read), for: .filesAndFolders(.downloads), principal: client,
      expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.authorize(
      invocation: invocation(),
      actions: actions,
      retryIDs: [pending[0].id],
      now: instant)
    try ledger.answer(pending[1].id, with: .onlyThisTime, now: instant)
    ledger = try roundTrip(ledger)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: actions,
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
      try ledger.setPermission(
        .notGranted, for: .filesAndFolders(.downloads), principal: client,
        expectedRevision: ledger.revision
      ).executionsToTerminate.isEmpty)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        running.id,
        principal: client,
        operation: .readResult,
        now: instant)
        == .allowed)
  }

  @Test func pendingConditionKeepsItsOriginalReadableDescendant() throws {
    var ledger = PermissionLedger()
    var environment = TestPathEnvironment()
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let traversal = PermissionAction(
      requirement: requirement(.mcpServer("server"), .all),
      scope: .path(path("/people/me/tasks")), pathOperation: .listDirectory)
    let actions = [action(), traversal]
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = PathEnvironmentSnapshot(
        (PathPermissions(environment: environment)).environment)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    guard
      case .requests(let pending) = try ledger.authorize(
        invocation: invocation(),
        actions: actions,
        now: instant)
    else {
      Issue.record("Expected two requests")
      return
    }
    try ledger.answer(pending[0].id, with: .onlyThisTime, now: instant)
    environment.projects = try ProjectCatalog(
      environment.projects.projects + [
        RegisteredProject(id: "another", root: path("/people/me/tasks/aaa"))
      ])
    try ledger.setPermission(
      .granted(.read), for: .project("another"), principal: client,
      expectedRevision: ledger.revision)
    let resolver = PathPermissions(environment: environment)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.authorize(
      invocation: invocation(),
      actions: actions,
      retryIDs: [pending[0].id],
      now: instant)
    try ledger.answer(pending[1].id, with: .onlyThisTime, now: instant)
    ledger = try roundTrip(ledger)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: actions,
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
        principal: client, permission: .project("another"), expectedRevision: ledger.revision
      ).executionsToTerminate
        .isEmpty)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        running.id,
        principal: client,
        operation: .readResult,
        now: instant)
        == .allowed)
    #expect(
      try ledger.revoke(
        principal: client, permission: .project("project"), expectedRevision: ledger.revision
      ).executionsToTerminate
        == [running.id])
  }

  @Test func pendingGroupRetainsPathEvidenceWhileWaiting() throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let traversal = PermissionAction(
      requirement: requirement(.filesAndFolders(.downloads), .read),
      scope: .path(path("/people/me/Downloads")), pathOperation: .listDirectory)
    let expanded = [action(), action(.unifiedLogs), traversal]
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
        now: instant)
    else {
      Issue.record("Expected two requests")
      return
    }
    try ledger.answer(pending[0].id, with: .onlyThisTime, now: instant)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.authorize(
      invocation: invocation(),
      actions: expanded,
      retryIDs: [pending[0].id],
      now: instant)
    try ledger.setPermission(
      .granted(.read), for: .filesAndFolders(.downloads), principal: client,
      expectedRevision: ledger.revision)
    try ledger.answer(pending[1].id, with: .onlyThisTime, now: instant)
    ledger = try roundTrip(ledger)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: expanded,
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
      try ledger.setPermission(
        .notGranted, for: .filesAndFolders(.downloads), principal: client,
        expectedRevision: ledger.revision
      ).executionsToTerminate.isEmpty)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        running.id,
        principal: client,
        operation: .readResult,
        now: instant)
        == .allowed)
  }

  @Test func concurrentCombinedRetriesHaveOneWinner() async throws {
    let store = InMemoryPermissionStore()
    let ids = try await store.transaction { ledger in
      guard
        case .requests(let pending) = try ledger.authorize(
          invocation: invocation(), actions: [action(.skills), action(), action(.unifiedLogs)],
          now: instant)
      else { throw PermissionModelError.unknownRequest }
      for request in pending { try ledger.answer(request.id, with: .onlyThisTime, now: instant) }
      return Set(pending.map(\.id))
    }
    let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
      for _ in 0..<32 {
        group.addTask {
          do {
            return try await store.transaction { ledger in
              _ = try authorization(
                from: ledger.authorize(
                  invocation: invocation(),
                  actions: [action(.skills), action(), action(.unifiedLogs)],
                  retryIDs: ids, now: instant))
              return true
            }
          } catch { return false }
        }
      }
      var count = 0
      for await winner in group { if winner { count += 1 } }
      return count
    }
    #expect(winners == 1)
    let ledger = try roundTrip(await store.read())
    #expect(ledger.authorizations.count == 1)
    #expect(
      ledger.requests.values.allSatisfy {
        if case .consumed = $0.status { return true }
        return false
      })
  }

  private func roundTrip(_ ledger: PermissionLedger) throws -> PermissionLedger {
    try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
  }
}
