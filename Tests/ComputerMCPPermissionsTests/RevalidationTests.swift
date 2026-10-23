import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsRevalidationTests {
  enum Dependency: CaseIterable {
    case path, network, permission
  }

  enum Lifetime: CaseIterable {
    case pending, answered, executing, completed
  }

  @Test(
    arguments: Dependency.allCases,
    Lifetime.allCases.flatMap { lifetime in
      [false, true].map { (lifetime, $0) }
    })
  func changesRetireCompleteInvocationEvidence(
    dependency: Dependency, state: (Lifetime, Bool)
  ) throws {
    let (lifetime, restored) = state
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let call = invocation(project: nil)
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    let root = path("/people/me/Downloads/repo")
    let pending: PermissionRequest
    switch dependency {
    case .path:
      try ledger.setPermission(
        .granted(.read), for: .project("project"), principal: client,
        expectedRevision: ledger.revision)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      pending = try request(
        from: ledger.authorize(
          invocation: call,
          actions: [action(.project("project"), .read, scope: .path(root)), action()],
          now: instant))
    case .network:
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.setSandboxSettings(
        SandboxSettings(network: .full),
        for: key, expectedRevision: ledger.revision)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          [], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      pending = try request(
        from: ledger.authorizeNetwork(
          invocation: call,
          host: "local",
          sourceProjectID: "project",
          isLocalNetwork: true,
          now: instant))
    case .permission:
      pending = try request(
        from: ledger.authorize(
          invocation: call, actions: [action(.skills), action()], now: instant))
    }
    if lifetime != .pending {
      try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    }
    var allowed: InvocationAuthorization?
    var running: AuthorizedExecution?
    var completed: AuthorizedExecution?
    if lifetime == .executing || lifetime == .completed {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      allowed = try authorization(
        from: ledger.authorize(
          invocation: call,
          requirements: pending.requirements,
          retryIDs: [pending.id],
          now: instant))
      let id = try #require(allowed?.id)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      running = try ledger.startExecution(
        owner: client,
        authorizationIDs: [id])
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      if lifetime == .completed {
        completed = running
        running = nil
        try ledger.finishExecution(
          try #require(completed?.id), retainUntil: instant.addingTimeInterval(60))
      }
    }
    if restored { ledger = try roundTrip(ledger) }
    let result: RevocationResult
    switch dependency {
    case .path:
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      result = try ledger.setSandboxSettings(
        SandboxSettings(deniedReadLocations: [root]),
        for: key, expectedRevision: ledger.revision)
    case .network:
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      result = try ledger.setSandboxSettings(
        SandboxSettings(),
        for: key, expectedRevision: ledger.revision)
    case .permission:
      result = try ledger.setPermission(
        .notGranted, for: .skills, principal: client, expectedRevision: ledger.revision)
    }
    #expect(ledger.requests[pending.id]?.status == .revoked)
    #expect(result.executionsToTerminate == Set([running?.id].compactMap { $0 }))
    for execution in [running, completed].compactMap({ $0 }) {
      #expect(ledger.executions[execution.id]?.revoked == true)
    }
    // Persist the revocation before widening, without any intervening access check.
    if restored { ledger = try roundTrip(ledger) }
    switch dependency {
    case .path:
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.setSandboxSettings(
        SandboxSettings(),
        for: key, expectedRevision: ledger.revision)
    case .network:
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.setSandboxSettings(
        SandboxSettings(network: .full),
        for: key, expectedRevision: ledger.revision)
    case .permission:
      try ledger.setPermission(
        .granted(.access), for: .skills, principal: client, expectedRevision: ledger.revision)
    }
    if restored { ledger = try roundTrip(ledger) }
    #expect(ledger.requests[pending.id]?.status == .revoked)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.authorize(
        invocation: call,
        requirements: pending.requirements,
        retryIDs: [pending.id],
        now: instant)
    }
    if let allowed {
      #expect(throws: PermissionModelError.invalidAuthorization) {
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
    }
    for execution in [running, completed].compactMap({ $0 }) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      #expect(
        ledger.executionAccess(
          execution.id,
          principal: client,
          operation: .readResult,
          now: instant) == .denied(.authorizationRevoked))
    }
    if let running {
      ledger.acknowledgeExecutionTerminations([running.id])
      #expect(
        try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (resolver).environment.snapshot(
            preserving: updatedEnvironment.paths)
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }().executionsToTerminate.isEmpty)
      #expect(ledger.executions[running.id]?.revoked == true)
    }
  }

  @Test func settingsCommitRetiresInheritedPathsAtomically() async throws {
    let store = InMemoryPermissionStore()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let executionID = try await store.transaction { ledger in
      try ledger.setPermission(
        .granted(.read), for: .project("project"), principal: client,
        expectedRevision: ledger.revision)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      let pending = try request(
        from: ledger.authorize(
          invocation: invocation(project: nil),
          actions: [
            action(.project("project"), .read, scope: .path(path("/people/me/Downloads/repo"))),
            action(),
          ],
          now: instant))
      try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      let allowed = try authorization(
        from: ledger.authorize(
          invocation: invocation(project: nil),
          requirements: pending.requirements,
          retryIDs: [pending.id],
          now: instant))
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      return try ledger.startExecution(
        owner: client,
        authorizationIDs: [allowed.id]
      ).id
    }
    let result = try await store.transaction { ledger in
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      return try ledger.setSandboxSettings(
        SandboxSettings(deniedReadLocations: [path("/people/me/Downloads/repo")]),
        for: SandboxSettingsKey(principal: client, projectID: "project"),
        expectedRevision: ledger.revision)
    }
    let committed = try roundTrip(await store.read())
    #expect(result.executionsToTerminate == [executionID])
    #expect(committed.pendingExecutionTerminations == [executionID])
    #expect(committed.executions[executionID]?.revoked == true)
    #expect(committed.requests.values.allSatisfy { $0.status == .revoked })
  }

  @Test func unrelatedSettingsPreserveInheritedPaths() throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(project: nil),
        actions: [
          action(.project("project"), .read, scope: .path(path("/people/me/Downloads/repo"))),
          action(),
        ],
        now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(project: nil),
        requirements: pending.requirements,
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
    ledger = try roundTrip(ledger)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.setSandboxSettings(
        SandboxSettings(deniedReadLocations: [path("/people/me/Downloads/repo")]),
        for: SandboxSettingsKey(principal: client, projectID: "another"),
        expectedRevision: ledger.revision
      )
      .executionsToTerminate.isEmpty)
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
  }

  @Test(arguments: [false, true], [false, true])
  func implicitSandboxEvidenceSurvivesRetries(managed: Bool, executing: Bool) throws {
    var ledger = PermissionLedger()
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
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(project: nil),
        actions: [action(.project("project"), .read, scope: .project("project")), action()],
        now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    var running: AuthorizedExecution?
    if executing {
      let allowed = try authorization(
        from: ledger.authorize(
          invocation: invocation(project: nil), requirements: pending.requirements,
          retryIDs: [pending.id],
          now: instant))
      running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    }
    ledger = try roundTrip(ledger)
    let result: RevocationResult
    if managed {
      result = try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits = [
          client: ManagedLimits(owner: .available(ManagedPolicy(network: .none)))
        ]
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }()
    } else {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      result = try ledger.setSandboxSettings(
        SandboxSettings(),
        for: key, expectedRevision: ledger.revision)
    }
    #expect(result.executionsToTerminate == Set([running?.id].compactMap { $0 }))
    #expect(ledger.requests[pending.id]?.status == .revoked)
    ledger = try roundTrip(ledger)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .full),
      for: key, expectedRevision: ledger.revision)
    _ = try ledger.reconcile(
      environment: PermissionEnvironment(), expectedRevision: ledger.revision)
    #expect(ledger.requests[pending.id]?.status == .revoked)
  }

  @Test(arguments: ["host", "denied", "project", "sandbox"])
  func registrationRequestsRevalidateTheirPath(change: String) throws {
    var ledger = PermissionLedger()
    var environment = TestPathEnvironment()
    let root = path("/people/me/new-project")
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = environment.snapshot(preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.requestProjectRegistration(
        ProjectRegistrationRequest(
          principal: client, projectID: "new", path: root, access: .read),
        invocation: invocation(),
        now: instant))
    ledger = try roundTrip(ledger)
    switch change {
    case "host": environment.hostDataLocations.insert(root)
    case "denied": environment.deniedLocations.insert(root)
    case "project":
      environment.projects = try ProjectCatalog(
        environment.projects.projects + [RegisteredProject(id: "different", root: root)])
    default:
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.setSandboxSettings(
        SandboxSettings(deniedReadLocations: [root]),
        for: SandboxSettingsKey(principal: client, projectID: "new"),
        expectedRevision: ledger.revision)
    }
    _ = try { () throws -> RevocationResult in
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = PathEnvironmentSnapshot(
        (PathPermissions(environment: environment)).environment)
      return try ledger.reconcile(
        environment: updatedEnvironment, expectedRevision: ledger.revision)
    }()
    #expect(ledger.requests[pending.id]?.status == .revoked)
    ledger = try roundTrip(ledger)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(),
      for: SandboxSettingsKey(principal: client, projectID: "new"),
      expectedRevision: ledger.revision)
    _ = try { () throws -> RevocationResult in
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = PathEnvironmentSnapshot(
        (PathPermissions(environment: TestPathEnvironment())).environment)
      return try ledger.reconcile(
        environment: updatedEnvironment, expectedRevision: ledger.revision)
    }()
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.answerProjectRegistration(
        pending.id,
        registeredProject: RegisteredProject(id: "new", root: root), now: instant)
    }
  }

  @Test func endedConnectionCannotAdmitFreshCalls() throws {
    var ledger = PermissionLedger()
    _ = try { () throws -> RevocationResult in
      var updatedEnvironment = ledger.environment
      updatedEnvironment.endedConnections.insert("ended")
      return try ledger.reconcile(
        environment: updatedEnvironment, expectedRevision: ledger.revision)
    }()
    ledger = try roundTrip(ledger)
    let mode = ExecutionMode.fullAccess(.connection("ended"))
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
    #expect(
      try ledger.authorize(
        invocation: invocation(),
        actions: [action(.skills)],
        now: instant) == .denied(.authorizationRevoked))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
      updatedEnvironment = ledger.environment
      if updatedEnvironment.modes[(invocation()).principal]?.mode != mode {
        updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
          for: (invocation()).principal, mode: mode)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
    }
    #expect(
      try ledger.authorizeNetwork(
        invocation: invocation(),
        host: "example",
        sourceProjectID: "project",
        isLocalNetwork: false,
        now: instant) == .denied(.authorizationRevoked))
    #expect(ledger.authorizations.isEmpty)
  }

  @Test func unrelatedAdmissionPreservesTrustedNetworkSnapshot() throws {
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
    let allowed = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "registry",
        sourceProjectID: "project",
        isLocalNetwork: false,
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let running = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    _ = try ledger.authorize(
      invocation: invocation(tool: "screen"), actions: [action()], now: instant)
    let independent = try authorization(
      from: ledger.authorize(
        invocation: invocation(tool: "skills"), actions: [action(.skills)], now: instant))
    let other = try ledger.startExecution(owner: client, authorizationIDs: [independent.id])
    #expect(
      ledger.executionAccess(
        other.id, principal: client, operation: .readResult,
        now: instant) == .allowed)
    #expect(ledger.pendingExecutionTerminations.isEmpty)
    do {
      var updatedEnvironment = ledger.environment
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
  }

  @Test(arguments: [false, true])
  func executionChecksRevalidateAllLiveAuthority(starting: Bool) throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.access), for: .screen, principal: client, expectedRevision: ledger.revision)
    let screen = try authorization(
      from: ledger.authorize(
        invocation: invocation(tool: "screen"), actions: [action()], now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [screen.id])
    let skills = try authorization(
      from: ledger.authorize(
        invocation: invocation(tool: "skills"), actions: [action(.skills)], now: instant))
    let other = try ledger.startExecution(owner: client, authorizationIDs: [skills.id])
    let next = try authorization(
      from: ledger.authorize(
        invocation: invocation(tool: "skills", digest: "next"), actions: [action(.skills)],
        now: instant))
    var ceilings = Permissions()
    try ceilings.set(.denied, for: .screen)
    let limits = [
      client: ManagedLimits(owner: .available(ManagedPolicy(permissionCeilings: ceilings)))
    ]
    if starting {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits = limits
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.startExecution(
        owner: client,
        authorizationIDs: [next.id])
    } else {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits = limits
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      #expect(
        ledger.executionAccess(
          other.id,
          principal: client,
          operation: .readResult,
          now: instant) == .allowed)
    }
    #expect(ledger.pendingExecutionTerminations == [running.id])
    #expect(ledger.executions[running.id]?.revoked == true)
    #expect(ledger.executions[other.id]?.revoked == false)
  }

  private func roundTrip(_ ledger: PermissionLedger) throws -> PermissionLedger {
    try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
  }
}
