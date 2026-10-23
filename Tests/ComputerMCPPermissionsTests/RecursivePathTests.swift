import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsRecursivePathTests {
  @Test(arguments: [false, true], [ExecutionMode.sandbox, .fullAccess(.standing)])
  func recursiveProjectRangeCannotShrink(restored: Bool, mode: ExecutionMode) throws {
    for change in [
      "environment", "hostData", "owner", "machine", "nested", "projectRemoval",
      "sandbox", "permission", "ceiling", "unreadable", "projectReplacement",
    ] {
      if change == "sandbox" && mode != .sandbox { continue }
      var environment = TestPathEnvironment()
      let root = path("/people/me/tasks/job")
      let child = path("/people/me/tasks/job/private")
      let original = PathPermissions(environment: environment)
      var ledger = PermissionLedger()
      try ledger.setPermission(
        .granted(.read), for: .project("project"), principal: client,
        expectedRevision: ledger.revision)
      try ledger.setPermission(
        .denied, for: .project("nested"), principal: client, expectedRevision: ledger.revision)
      let read = action(.project("project"), .read, scope: .path(root))
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (original).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
        updatedEnvironment = ledger.environment
        if updatedEnvironment.modes[(invocation(project: "derived")).principal]?.mode != mode {
          updatedEnvironment.modes[(invocation(project: "derived")).principal] = ledger.consent(
            for: (invocation(project: "derived")).principal, mode: mode)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
      }
      let allowed = try authorization(
        from: ledger.authorize(
          invocation: invocation(project: "derived"),
          actions: [read],
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
      var limits = ManagedLimits()
      var terminated: Set<UUID> = []
      switch change {
      case "environment": environment.deniedLocations.insert(child)
      case "hostData": environment.hostDataLocations.insert(child)
      case "owner":
        limits = ManagedLimits(owner: .available(ManagedPolicy(deniedReadLocations: [child])))
      case "machine":
        limits = ManagedLimits(machine: .available(ManagedPolicy(deniedReadLocations: [child])))
      case "nested":
        // Source nesting also changes the corresponding region of its worktree.
        environment.projects = try ProjectCatalog(
          environment.projects.projects + [
            RegisteredProject(id: "nested", root: path("/people/me/Downloads/repo/private"))
          ])
      case "projectRemoval": environment.projects = try ProjectCatalog()
      case "projectReplacement":
        environment.projects = try ProjectCatalog([RegisteredProject(id: "replacement", root: root)]
        )
        try ledger.setPermission(
          .granted(.read), for: .project("replacement"), principal: client,
          expectedRevision: ledger.revision)
      case "sandbox":
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            [], preserving: ledger.environment.trustedHosts)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        terminated =
          try ledger.setSandboxSettings(
            SandboxSettings(deniedReadLocations: [child]),
            for: SandboxSettingsKey(principal: client, projectID: "project"),
            expectedRevision: ledger.revision
          )
          .executionsToTerminate
      case "permission":
        terminated = try ledger.setPermission(
          .notGranted, for: .project("project"), principal: client,
          expectedRevision: ledger.revision
        )
        .executionsToTerminate
      case "ceiling":
        var ceilings = Permissions()
        try ceilings.set(.denied, for: .project("project"))
        limits = ManagedLimits(owner: .available(ManagedPolicy(permissionCeilings: ceilings)))
      default: limits = ManagedLimits(machine: .unreadable)
      }
      let changed = PathPermissions(environment: environment)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits = [client: limits]
        updatedEnvironment.paths = (changed).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      #expect(
        ledger.executionAccess(
          running.id,
          principal: client,
          operation: .readResult,
          now: instant)
          == .denied(.authorizationRevoked))
      terminated.formUnion(
        try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [client: limits]
          updatedEnvironment.paths = (changed).environment.snapshot(
            preserving: updatedEnvironment.paths)
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }().executionsToTerminate)
      #expect(terminated == [running.id])
      if restored { ledger = try roundTrip(ledger) }
      #expect(
        try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (original).environment.snapshot(
            preserving: updatedEnvironment.paths)
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }().executionsToTerminate == [running.id])
      ledger.acknowledgeExecutionTerminations([running.id])
      #expect(
        try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (original).environment.snapshot(
            preserving: updatedEnvironment.paths)
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }().executionsToTerminate.isEmpty)
      #expect(throws: PermissionModelError.invalidAuthorization) {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (original).environment.snapshot(
            preserving: updatedEnvironment.paths)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        _ = try ledger.startExecution(
          owner: client,
          authorizationIDs: [allowed.id])
      }
    }
  }

  @Test(arguments: [false, true], [ExecutionMode.sandbox, .fullAccess(.standing)])
  func environmentClassificationChangesInvalidateRecordedRanges(restored: Bool, mode: ExecutionMode)
    throws
  {
    for change in ["category", "developer", "system", "userData", "nestedRegistration"] {
      var environment = TestPathEnvironment()
      let root = path("/outside/range")
      let child = path("/outside/range/private")
      switch change {
      case "category": environment.folders = [.documents: [root]]
      case "developer": environment.developerLocations = [root]
      case "system": environment.systemLocations = [root]
      default: break
      }
      let original = PathPermissions(environment: environment)
      var ledger = PermissionLedger()
      try ledger.setPermission(
        .granted(.read), for: .filesAndFolders(.documents), principal: client,
        expectedRevision: ledger.revision)
      let read = action(
        change == "category" ? .filesAndFolders(.documents) : .skills,
        change == "category" ? .read : .access, scope: .path(root))
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (original).environment.snapshot(
          preserving: updatedEnvironment.paths)
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
          actions: [read],
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
      switch change {
      case "category": environment.folders[.downloads] = [child]
      case "developer": environment.developerLocations = [child]
      case "system": environment.systemLocations = [child]
      case "nestedRegistration":
        environment.projects = try ProjectCatalog([RegisteredProject(id: "nested", root: child)])
      default: environment.userDataLocations.insert(child)
      }
      let changed = PathPermissions(environment: environment)
      #expect(
        try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (changed).environment.snapshot(
            preserving: updatedEnvironment.paths)
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }().executionsToTerminate == [running.id])
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
  }

  @Test(arguments: [ExecutionMode.sandbox, .fullAccess(.standing)])
  func exclusionsAndDirectoryTraversalRetainTheirOriginalExtent(mode: ExecutionMode) throws {
    for operation in [PathOperation.read, .openDirectory, .listDirectory] {
      var environment = TestPathEnvironment()
      let root = path("/people/me/Downloads/repo")
      let excluded = path("/people/me/Downloads/repo/private")
      environment.hostDataLocations.insert(excluded)
      let original = PathPermissions(environment: environment)
      var ledger = PermissionLedger()
      try ledger.setPermission(
        .granted(.read), for: .project("project"), principal: client,
        expectedRevision: ledger.revision)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (original).environment.snapshot(
          preserving: updatedEnvironment.paths)
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
          actions: [
            PermissionAction(
              requirement: requirement(.project("project"), .read), scope: .path(root),
              pathOperation: operation)
          ],
          now: instant))
      let rootBasis = try #require(
        allowed.basis.compactMap { element -> PathAccessBasis? in
          if case .path(let basis) = element, basis.path == root { return basis }
          return nil
        }.first)
      #expect(rootBasis.excludedSubtrees == (operation == .read ? [excluded] : nil))
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (original).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      let running = try ledger.startExecution(
        owner: client,
        authorizationIDs: [allowed.id])
      ledger = try roundTrip(ledger)
      environment.deniedLocations.insert(
        operation == .read
          ? path("/people/me/Downloads/repo/private/child")
          : path("/people/me/Downloads/repo/other"))
      environment.projects = try ProjectCatalog(
        environment.projects.projects + [
          RegisteredProject(id: "nested", root: excluded)
        ])
      let changed = PathPermissions(environment: environment)
      #expect(
        try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (changed).environment.snapshot(
            preserving: updatedEnvironment.paths)
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }().executionsToTerminate == (mode == .sandbox ? [] : [running.id]))
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (changed).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      #expect(
        ledger.executionAccess(
          running.id,
          principal: client,
          operation: .readResult,
          now: instant) == (mode == .sandbox ? .allowed : .denied(.authorizationRevoked)))
    }
  }

  @Test(arguments: [ExecutionMode.sandbox, .fullAccess(.standing)])
  func shrinkingRangeBeforeLaunchPermanentlyInvalidatesAuthorization(mode: ExecutionMode) throws {
    var environment = TestPathEnvironment()
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let original = PathPermissions(environment: environment)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (original).environment.snapshot(
        preserving: updatedEnvironment.paths)
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
        actions: [
          action(.project("project"), .read, scope: .path(path("/people/me/Downloads/repo")))
        ],
        now: instant))
    ledger = try roundTrip(ledger)
    environment.deniedLocations.insert(path("/people/me/Downloads/repo/private"))
    #expect(throws: PermissionModelError.invalidAuthorization) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = PathEnvironmentSnapshot(
          (PathPermissions(environment: environment)).environment)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.startExecution(
        owner: client,
        authorizationIDs: [allowed.id])
    }
    ledger = try roundTrip(ledger)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (original).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.startExecution(
        owner: client,
        authorizationIDs: [allowed.id])
    }
  }

  private func roundTrip(_ ledger: PermissionLedger) throws -> PermissionLedger {
    try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
  }
}
