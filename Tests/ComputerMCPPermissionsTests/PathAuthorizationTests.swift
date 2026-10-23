import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsPathAuthorizationTests {
  @Test(arguments: [PathOperation.openDirectory, .listDirectory])
  func readableProjectAllowsAncestorTraversal(operation: PathOperation) throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let traversal = PermissionAction(
      requirement: requirement(.filesAndFolders(.downloads), .read),
      scope: .path(path("/people/me/Downloads")), pathOperation: operation)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [traversal],
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
    let unrelated = try ledger.setPermission(
      .granted(.access), for: .screen, principal: client, expectedRevision: ledger.revision)
    #expect(unrelated.executionsToTerminate.isEmpty)
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
    #expect(ledger.requests.isEmpty)
    for target in ["/people/me/Downloads", "/people/me/Downloads/other.txt"] {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try request(
        from: ledger.authorize(
          invocation: invocation(),
          actions: [action(.filesAndFolders(.downloads), .read, scope: .path(path(target)))],
          now: instant))
    }
    var restored = try JSONDecoder().decode(
      PermissionLedger.self, from: JSONEncoder().encode(ledger))
    let revoked = try restored.setPermission(
      .notGranted, for: .project("project"), principal: client, expectedRevision: restored.revision)
    #expect(revoked.executionsToTerminate == [running.id])
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = restored.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        return try restored.reconcile(
          environment: updatedEnvironment, expectedRevision: restored.revision)
      }().executionsToTerminate == [running.id])
    restored.acknowledgeExecutionTerminations([running.id])
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = restored.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        return try restored.reconcile(
          environment: updatedEnvironment, expectedRevision: restored.revision)
      }().executionsToTerminate.isEmpty)
    do {
      var updatedEnvironment = restored.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try restored.reconcile(environment: updatedEnvironment, expectedRevision: restored.revision)

    }
    #expect(
      restored.executionAccess(
        running.id,
        principal: client,
        operation: .readResult,
        now: instant) == .denied(.authorizationRevoked))
  }

  @Test func systemTraversalDoesNotGrantUnrelatedPermissions() throws {
    var ledger = PermissionLedger()
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = PathEnvironmentSnapshot(
        (PathPermissions(environment: TestPathEnvironment())).environment)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [
          PermissionAction(
            requirement: requirement(.screen, .access),
            scope: .path(path("/system")), pathOperation: .listDirectory)
        ],
        now: instant))
    guard case .permission(let content) = pending.content else {
      Issue.record("Expected a Screen permission request")
      return
    }
    #expect(content.requirement.permission == .screen)
  }

  @Test(arguments: [PathOperation.openDirectory, .listDirectory])
  func ancestorTraversalHonorsExplicitAndManagedDenials(operation: PathOperation) throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let traversal = PermissionAction(
      requirement: requirement(.filesAndFolders(.downloads), .read),
      scope: .path(path("/people/me/Downloads")), pathOperation: operation)
    let resolver = PathPermissions(environment: TestPathEnvironment())
    var ceilings = Permissions()
    try ceilings.set(.denied, for: .filesAndFolders(.downloads))
    let limits = ManagedLimits(machine: .available(ManagedPolicy(permissionCeilings: ceilings)))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits[(invocation()).principal] = limits
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.authorize(
        invocation: invocation(),
        actions: [traversal],
        now: instant) == .denied(.managedLimit([.machine])))
    try ledger.setPermission(
      .denied, for: .filesAndFolders(.downloads), principal: client,
      expectedRevision: ledger.revision)
    var unrestricted = ledger.environment
    unrestricted.limits = [:]
    try ledger.reconcile(environment: unrestricted, expectedRevision: ledger.revision)
    unrestricted = ledger.environment
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.authorize(
        invocation: invocation(),
        actions: [traversal],
        now: instant)
        == .denied(.permissionDenied(.filesAndFolders(.downloads))))
    #expect(ledger.requests.isEmpty)
  }

  @Test func pathAuthorizationRequiresResolverAndCannotRequestHostData() throws {
    var ledger = PermissionLedger()
    let target = path("/people/me/Downloads/repo/host/secret")
    let read = action(.project("project"), .read, scope: .path(target))
    #expect(
      try ledger.authorize(invocation: invocation(), actions: [read], now: instant)
        == .denied(.pathResolutionRequired))
    var environment = TestPathEnvironment()
    environment.hostDataLocations = [path("/people/me/Downloads/repo/host")]
    let resolver = PathPermissions(environment: environment)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.authorize(
        invocation: invocation(),
        actions: [read],
        now: instant)
        == .denied(.hostData))
    #expect(ledger.requests.isEmpty)
    try ledger.setPermission(
      .granted(.write), for: .project("*"), principal: client, expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
      updatedEnvironment = ledger.environment
      if updatedEnvironment.modes[(invocation()).principal]?.mode != .fullAccess(.standing) {
        updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
          for: (invocation()).principal, mode: .fullAccess(.standing))
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
    }
    #expect(
      try ledger.authorize(
        invocation: invocation(),
        actions: [read],
        now: instant) == .denied(.hostData))
  }

  @Test func oneTimeRetryCannotBypassAChangedPathDecision() throws {
    var ledger = PermissionLedger()
    let target = path("/people/me/Downloads/repo/file")
    let read = action(.project("project"), .read, scope: .path(target))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = PathEnvironmentSnapshot(
        (PathPermissions(environment: TestPathEnvironment())).environment)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [read],
        now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    var environment = TestPathEnvironment()
    environment.hostDataLocations.insert(target)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = PathEnvironmentSnapshot(
        (PathPermissions(environment: environment)).environment)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.authorize(
        invocation: invocation(),
        actions: [read],
        retryIDs: [pending.id],
        now: instant) == .denied(.hostData)
    )
    #expect(ledger.requests[pending.id]?.status == .revoked)
    #expect(ledger.authorizations.isEmpty)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = PathEnvironmentSnapshot(
          (PathPermissions(environment: TestPathEnvironment())).environment)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.authorize(
        invocation: invocation(),
        actions: [read],
        retryIDs: [pending.id],
        now: instant)
    }
  }

  @Test(arguments: [ExecutionMode.sandbox, .fullAccess(.standing)])
  func sandboxPathDenialsAffectLaterCallsAndRunningExecutions(mode: ExecutionMode) throws {
    var ledger = PermissionLedger()
    let target = path("/people/me/Downloads/repo/private")
    let read = action(.project("project"), .read, scope: .path(target))
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    var environment = PermissionEnvironment()
    environment.paths = TestPathEnvironment().snapshot(preserving: ledger.environment.paths)
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    environment.modes[client] = ledger.consent(for: client, mode: mode)
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    let allowed = try authorization(
      from: ledger.authorize(invocation: invocation(), actions: [read], now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    let effect = try ledger.setSandboxSettings(
      SandboxSettings(deniedReadLocations: [target]),
      for: SandboxSettingsKey(principal: client, projectID: "project"),
      expectedRevision: ledger.revision)
    #expect(effect.executionsToTerminate == [running.id])
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
    if mode == .sandbox {
      #expect(
        try ledger.authorize(invocation: invocation(), actions: [read], now: instant)
          == .denied(.deniedLocation))
    } else {
      #expect(
        try ledger.authorize(invocation: invocation(), actions: [read], now: instant)
          == .denied(.authorizationRevoked))
      environment.modes[client] = ledger.consent(for: client, mode: mode)
      try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      environment = ledger.environment
      let fresh = try authorization(
        from: ledger.authorize(invocation: invocation(), actions: [read], now: instant))
      let unconfined = try ledger.startExecution(owner: client, authorizationIDs: [fresh.id])
      #expect(
        ledger.executionAccess(
          unconfined.id, principal: client, operation: .readResult, now: instant) == .allowed)
    }
  }

  @Test func invocationProjectSettingsControlReadsOfOtherProjects() throws {
    var ledger = PermissionLedger()
    var environment = TestPathEnvironment()
    environment.projects = try ProjectCatalog(
      environment.projects.projects + [
        RegisteredProject(id: "other", root: path("/people/me/other"))
      ])
    let target = path("/people/me/other/private")
    let read = action(.project("other"), .read, scope: .path(target))
    try ledger.setPermission(
      .granted(.read), for: .project("other"), principal: client, expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(deniedReadLocations: [target]),
      for: SandboxSettingsKey(principal: client, projectID: "project"),
      expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = PathEnvironmentSnapshot(
        (PathPermissions(environment: environment)).environment)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.authorize(
        invocation: invocation(project: "derived"),
        actions: [read],
        now: instant)
        == .denied(.deniedLocation))
  }

  @Test func changingOneSettingsKeyPreservesOtherPrincipalsNetworkExecutions() throws {
    var ledger = PermissionLedger()
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .trusted),
      for: SandboxSettingsKey(principal: otherClient, projectID: "project"),
      expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(principal: otherClient),
        host: "registry",
        sourceProjectID: "project",
        isLocalNetwork: false,
        now: instant)
    )
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let running = try ledger.startExecution(
      owner: otherClient,
      authorizationIDs: [allowed.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = ledger.environment.trustedHosts
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.setSandboxSettings(
        SandboxSettings(deniedReadLocations: [path("/secret")]),
        for: SandboxSettingsKey(principal: client, projectID: "project"),
        expectedRevision: ledger.revision
      ).executionsToTerminate.isEmpty)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        running.id,
        principal: otherClient,
        operation: .readResult,
        now: instant) == .allowed)
  }

  @Test func pluginPathRequestRetainsPurposeAndMainWriteNeverRequests() throws {
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let target = path("/people/me/Downloads/repo/file")
    let decision = resolver.evaluate(
      target, operation: .read, principal: .plugin(.package("builder")), permissions: .init(),
      pluginPurpose: "Read source files to build the project")
    guard case .request(let content) = decision else {
      Issue.record("Expected request")
      return
    }
    #expect(content.pluginPurpose == "Read source files to build the project")
    #expect(
      resolver.evaluate(target, operation: .write, principal: client, permissions: .init())
        == .denied(.mainProjectWrite))
  }
  @Test func pathAuthorityCannotBeAttributedToAnotherPermission() throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let target = path("/people/me/Downloads/repo/file")
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.authorize(
        invocation: invocation(),
        actions: [action(.skills, .access, scope: .path(target))],
        now: instant) == .denied(.invalidPathRequirement))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.project("project"), .read, scope: .path(target))],
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
  }

  @Test func derivedExecutionKeepsItsSourceSettingsForLaterRevocation() throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let target = path("/people/me/tasks/job/private")
    let read = action(.project("project"), .read, scope: .path(target))
    let call = invocation(project: "derived")
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: call,
        actions: [read],
        now: instant))
    #expect(allowed.sandboxProjectID == "project")
    #expect(allowed.invocation.projectID == "derived")
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let running = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let effect = try ledger.setSandboxSettings(
      SandboxSettings(deniedReadLocations: [target]),
      for: SandboxSettingsKey(principal: client, projectID: "project"),
      expectedRevision: ledger.revision)
    #expect(effect.executionsToTerminate == [running.id])
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
        now: instant) == .denied(.authorizationRevoked))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.authorize(
        invocation: call,
        actions: [read],
        now: instant)
        == .denied(.deniedLocation))
  }

}
