import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsDependencyTests {
  @Test(arguments: [false, true], [PathOperation.read, .openDirectory, .listDirectory])
  func projectAccessRetainsItsGrant(restored: Bool, operation: PathOperation) throws {
    for target in ["/people/me/Downloads/repo", "/people/me/tasks/job"] {
      for grant in [Permission.project("project"), .project("*")] {
        try verifyRevocation(
          action: PermissionAction(
            requirement: requirement(.project("project"), .read),
            scope: .path(path(target)), pathOperation: operation),
          grant: grant, restored: restored)
      }
    }
  }

  @Test(arguments: [false, true], [PathOperation.openDirectory, .listDirectory])
  func ancestorTraversalRetainsProjectGrant(restored: Bool, operation: PathOperation) throws {
    for grant in [Permission.project("project"), .project("*")] {
      try verifyRevocation(
        action: PermissionAction(
          requirement: requirement(.skills, .access),
          scope: .path(path("/people/me/tasks")), pathOperation: operation),
        grant: grant, restored: restored)
      try verifyRevocation(
        action: PermissionAction(
          requirement: requirement(.filesAndFolders(.downloads), .read),
          scope: .path(path("/people/me/Downloads")), pathOperation: operation),
        grant: grant, restored: restored)
    }
  }

  @Test(arguments: FolderCategory.allCases, [false, true])
  func categoryAndItsAncestorsRetainCategoryGrant(category: FolderCategory, restored: Bool)
    throws
  {
    var environment = TestPathEnvironment()
    environment.folders = [category: [path("/people/me/category/files")]]
    for operation in [PathOperation.read, .openDirectory, .listDirectory] {
      try verifyRevocation(
        action: PermissionAction(
          requirement: requirement(.filesAndFolders(category), .read),
          scope: .path(path("/people/me/category/files")), pathOperation: operation),
        grant: .filesAndFolders(category), environment: environment, restored: restored)
    }
    for operation in [PathOperation.openDirectory, .listDirectory] {
      try verifyRevocation(
        action: PermissionAction(
          requirement: requirement(.skills, .access),
          scope: .path(path("/people/me/category")), pathOperation: operation),
        grant: .filesAndFolders(category), environment: environment, restored: restored)
    }
  }

  @Test(arguments: [false, true])
  func projectWritesRetainWriteGrant(restored: Bool) throws {
    try verifyRevocation(
      action: action(.project("project"), .write, scope: .path(path("/people/me/tasks/job/file"))),
      grant: .project("project"), value: .write, restored: restored)
    try verifyRevocation(
      action: action(
        .project("project"), .write, scope: .path(path("/people/me/Downloads/repo/file"))),
      grant: .project("project"), value: .write, mode: .fullAccess(.standing), restored: restored)
  }

  @Test(arguments: [false, true])
  func baselinePathsDoNotDependOnUnrelatedGrants(restored: Bool) throws {
    var environment = TestPathEnvironment()
    // Baseline access does not depend on readable descendants.
    environment.projects = try ProjectCatalog(
      environment.projects.projects + [
        RegisteredProject(id: "tool", root: path("/people/me/toolchains/swift/project")),
        RegisteredProject(id: "system", root: path("/system/project")),
        RegisteredProject(id: "app", root: path("/apps/project")),
        RegisteredProject(id: "outside", root: path("/outside/project")),
      ])
    let resolver = PathPermissions(environment: environment)
    for target in [
      "/people/me/toolchains/swift", "/people/me/toolchains", "/system", "/apps", "/outside",
    ] {
      for operation in [PathOperation.read, .openDirectory, .listDirectory]
      where target != "/people/me/toolchains" || operation != .read {
        var ledger = PermissionLedger()
        for grant in [Permission.project("*"), .filesAndFolders(.downloads)] {
          try ledger.setPermission(
            .granted(.read), for: grant, principal: client, expectedRevision: ledger.revision)
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
            actions: [
              PermissionAction(
                requirement: requirement(.skills, .access), scope: .path(path(target)),
                pathOperation: operation)
            ],
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
        if restored {
          ledger = try JSONDecoder().decode(
            PermissionLedger.self, from: JSONEncoder().encode(ledger))
        }
        for grant in [Permission.project("*"), .filesAndFolders(.downloads)] {
          #expect(
            try ledger.revoke(
              principal: client, permission: grant, expectedRevision: ledger.revision
            ).executionsToTerminate.isEmpty)
        }
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
            now: instant) == .allowed)
        #expect(
          try ledger.revoke(
            principal: client, permission: .skills, expectedRevision: ledger.revision
          ).executionsToTerminate
            == [execution.id])
      }
    }
  }

  @Test(arguments: [false, true])
  func nestedProjectSuppliesAncestorAccess(restored: Bool) throws {
    var environment = TestPathEnvironment()
    environment.projects = try ProjectCatalog(
      environment.projects.projects + [
        RegisteredProject(id: "nested", root: path("/people/me/Downloads/repo/nested"))
      ])
    try verifyRevocation(
      action: PermissionAction(
        requirement: requirement(.project("project"), .read),
        scope: .path(path("/people/me/Downloads/repo")), pathOperation: .listDirectory),
      grant: .project("nested"), environment: environment, restored: restored)
  }

  @Test func directlyReadableDirectoryDoesNotDependOnItsReadableDescendants() throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    try ledger.setPermission(
      .granted(.read), for: .filesAndFolders(.downloads), principal: client,
      expectedRevision: ledger.revision)
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let traversal = PermissionAction(
      requirement: requirement(.filesAndFolders(.downloads), .read),
      scope: .path(path("/people/me/Downloads")), pathOperation: .listDirectory)
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
    let execution = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    ledger = try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
    #expect(
      try ledger.revoke(
        principal: client, permission: .project("project"), expectedRevision: ledger.revision
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
        execution.id,
        principal: client,
        operation: .readResult,
        now: instant) == .allowed)
    #expect(
      try ledger.revoke(
        principal: client, permission: .filesAndFolders(.downloads),
        expectedRevision: ledger.revision
      )
      .executionsToTerminate
        == [execution.id])
  }

  @Test func ancestorExecutionKeepsItsOriginalGrantWhenAnotherRouteBecomesReadable() throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let traversal = PermissionAction(
      requirement: requirement(.filesAndFolders(.downloads), .read),
      scope: .path(path("/people/me/Downloads")), pathOperation: .listDirectory)
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
    let execution = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    try ledger.setPermission(
      .granted(.read), for: .filesAndFolders(.downloads), principal: client,
      expectedRevision: ledger.revision)
    #expect(
      try ledger.revoke(
        principal: client, permission: .project("project"), expectedRevision: ledger.revision
      ).executionsToTerminate
        == [execution.id])
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
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [traversal],
        now: instant))
  }

  @Test(arguments: [false, true], [PathOperation.openDirectory, .listDirectory])
  func traversalRetainsTheActionsRequiredValue(restored: Bool, operation: PathOperation) throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    try ledger.setPermission(
      .granted(.write), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let write = PermissionAction(
      requirement: requirement(.project("project"), .write),
      scope: .path(path("/people/me/tasks")), pathOperation: operation)
    let read = PermissionAction(
      requirement: requirement(.project("project"), .read),
      scope: write.scope, pathOperation: operation)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [write],
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let writer = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let readable = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [read],
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let reader = try ledger.startExecution(
      owner: client,
      authorizationIDs: [readable.id])
    if restored { ledger = try roundTrip(ledger) }
    #expect(
      try ledger.setPermission(
        .granted(.read), for: .project("project"), principal: client,
        expectedRevision: ledger.revision
      )
      .executionsToTerminate == [writer.id, reader.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        reader.id,
        principal: client,
        operation: .readResult,
        now: instant) == .denied(.authorizationRevoked))
    if restored { ledger = try roundTrip(ledger) }
    try ledger.setPermission(
      .granted(.write), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    if restored { ledger = try roundTrip(ledger) }
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        writer.id,
        principal: client,
        operation: .readResult,
        now: instant) == .denied(.authorizationRevoked))
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate == [writer.id, reader.id])
    ledger.acknowledgeExecutionTerminations([writer.id, reader.id])
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate.isEmpty)
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

  @Test(arguments: [false, true], [false, true])
  func traversalChecksActionAndPathIndependently(restored: Bool, changeAction: Bool) throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    try ledger.setPermission(
      .granted(.all), for: .mcpServer("server"), principal: client,
      expectedRevision: ledger.revision)
    let traversal = PermissionAction(
      requirement: requirement(.mcpServer("server"), .all),
      scope: .path(path("/people/me/tasks")), pathOperation: .listDirectory)
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
    if restored { ledger = try roundTrip(ledger) }
    let changed: Permission = changeAction ? .mcpServer("server") : .project("project")
    #expect(
      try ledger.setPermission(
        changeAction ? .granted(.read) : .notGranted, for: changed, principal: client,
        expectedRevision: ledger.revision
      )
      .executionsToTerminate == [running.id])
    if restored { ledger = try roundTrip(ledger) }
    try ledger.setPermission(
      .granted(changeAction ? .all : .read), for: changed, principal: client,
      expectedRevision: ledger.revision)
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
        operation: .writeInput,
        now: instant) == .denied(.authorizationRevoked))
  }

  @Test(arguments: [false, true], [false, true])
  func pathWriteRetainsItsOriginalEntryAndRequiredValue(restored: Bool, shadowEntry: Bool) throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    try ledger.setPermission(
      .granted(.write), for: .project("*"), principal: client, expectedRevision: ledger.revision)
    let write = action(
      .project("project"), .write, scope: .path(path("/people/me/tasks/job/file")))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [write],
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
    if shadowEntry {
      #expect(
        try ledger.setPermission(
          .granted(.write), for: .project("project"), principal: client,
          expectedRevision: ledger.revision
        )
        .executionsToTerminate.isEmpty)
    }
    if restored { ledger = try roundTrip(ledger) }
    #expect(
      try ledger.setPermission(
        .granted(.read), for: .project("*"), principal: client, expectedRevision: ledger.revision
      )
      .executionsToTerminate == [running.id])
    if restored { ledger = try roundTrip(ledger) }
    try ledger.setPermission(
      .granted(.write), for: .project("*"), principal: client, expectedRevision: ledger.revision)
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
  }

  @Test(arguments: [false, true])
  func traversalSubstitutionRetainsDenialAndDescendantConditions(restored: Bool) throws {
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let traversal = PermissionAction(
      requirement: requirement(.filesAndFolders(.downloads), .read),
      scope: .path(path("/people/me/Downloads")), pathOperation: .listDirectory)
    var initial = PermissionLedger()
    try initial.setPermission(
      .granted(.write), for: .project("project"), principal: client,
      expectedRevision: initial.revision)
    do {
      var updatedEnvironment = initial.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try initial.reconcile(environment: updatedEnvironment, expectedRevision: initial.revision)

    }
    let allowed = try authorization(
      from: initial.authorize(
        invocation: invocation(),
        actions: [traversal],
        now: instant))
    do {
      var updatedEnvironment = initial.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try initial.reconcile(environment: updatedEnvironment, expectedRevision: initial.revision)

    }
    let running = try initial.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    var edited = initial
    #expect(
      try edited.setPermission(
        .granted(.read), for: .project("project"), principal: client,
        expectedRevision: edited.revision
      )
      .executionsToTerminate == [running.id])
    #expect(
      edited.executionAccess(running.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
    #expect(
      try initial.setPermission(
        .notGranted, for: .filesAndFolders(.downloads), principal: client,
        expectedRevision: initial.revision
      )
      .executionsToTerminate.isEmpty)
    for revoked in [Permission.project("project"), .filesAndFolders(.downloads)] {
      var ledger = restored ? try roundTrip(initial) : initial
      #expect(
        try ledger.revoke(principal: client, permission: revoked, expectedRevision: ledger.revision)
          .executionsToTerminate
          == [running.id])
      if restored { ledger = try roundTrip(ledger) }
      try ledger.setPermission(
        .granted(.read), for: revoked, principal: client, expectedRevision: ledger.revision)
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
          now: instant) == .denied(.authorizationRevoked))
    }
  }

  @Test(arguments: [false, true], [false, true])
  func oneTimeActionRetainsItsIndependentPathGrant(restored: Bool, revokePath: Bool) throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let traversal = PermissionAction(
      requirement: requirement(.mcpServer("server"), .all),
      scope: .path(path("/people/me/tasks")), pathOperation: .listDirectory)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [traversal],
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
        invocation: invocation(),
        actions: [traversal],
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
    if restored { ledger = try roundTrip(ledger) }
    #expect(
      try ledger.setPermission(
        .granted(.read), for: .mcpServer("server"), principal: client,
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
    let revoked: Permission = revokePath ? .project("project") : .mcpServer("server")
    #expect(
      try ledger.revoke(principal: client, permission: revoked, expectedRevision: ledger.revision)
        .executionsToTerminate == [
          running.id
        ])
    if restored { ledger = try roundTrip(ledger) }
    try ledger.setPermission(
      .granted(revokePath ? .read : .all), for: revoked, principal: client,
      expectedRevision: ledger.revision)
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
  }

  @Test(arguments: [false, true])
  func oneTimePathGrantCannotBeReplacedByAStandingGrant(restored: Bool) throws {
    var ledger = PermissionLedger()
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let read = action(
      .project("project"), .read, scope: .path(path("/people/me/tasks/job/file")))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [read],
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
        invocation: invocation(),
        actions: [read],
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
    for state in [PermissionState.granted(.read), .notGranted] {
      #expect(
        try ledger.setPermission(
          state, for: .project("project"), principal: client, expectedRevision: ledger.revision
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
    #expect(
      try ledger.revoke(
        principal: client, permission: .project("project"), expectedRevision: ledger.revision
      ).executionsToTerminate
        == [running.id])
    if restored { ledger = try roundTrip(ledger) }
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
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
  }

  private func roundTrip(_ ledger: PermissionLedger) throws -> PermissionLedger {
    try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
  }

  private func verifyRevocation(
    action: PermissionAction, grant: Permission, value: PermissionValue = .read,
    environment: TestPathEnvironment = TestPathEnvironment(), mode: ExecutionMode = .sandbox,
    restored: Bool
  ) throws {
    var initial = PermissionLedger()
    let resolver = PathPermissions(environment: environment)
    try initial.setPermission(
      .granted(value), for: grant, principal: client, expectedRevision: initial.revision)
    do {
      var updatedEnvironment = initial.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try initial.reconcile(environment: updatedEnvironment, expectedRevision: initial.revision)
      updatedEnvironment = initial.environment
      if updatedEnvironment.modes[(invocation()).principal]?.mode != mode {
        updatedEnvironment.modes[(invocation()).principal] = initial.consent(
          for: (invocation()).principal, mode: mode)
        try initial.reconcile(environment: updatedEnvironment, expectedRevision: initial.revision)

      }
    }
    let allowed = try authorization(
      from: initial.authorize(
        invocation: invocation(),
        actions: [action],
        now: instant))
    do {
      var updatedEnvironment = initial.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try initial.reconcile(environment: updatedEnvironment, expectedRevision: initial.revision)

    }
    let execution = try initial.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    do {
      var updatedEnvironment = initial.environment
      updatedEnvironment.paths = (resolver).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try initial.reconcile(environment: updatedEnvironment, expectedRevision: initial.revision)

    }
    #expect(
      initial.executionAccess(
        execution.id,
        principal: client,
        operation: .readResult,
        now: instant) == .allowed)
    for deny in [false, true] {
      var ledger = initial
      if restored {
        ledger = try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
      }
      let effect =
        try deny
        ? ledger.revoke(principal: client, permission: grant, expectedRevision: ledger.revision)
        : ledger.setPermission(
          .notGranted, for: grant, principal: client, expectedRevision: ledger.revision)
      #expect(effect.executionsToTerminate == [execution.id])
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
      try ledger.setPermission(
        .granted(value), for: grant, principal: client, expectedRevision: ledger.revision)
      if restored {
        ledger = try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
      }
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
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
        updatedEnvironment = ledger.environment
        do {
          updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
            for: (invocation()).principal, mode: mode)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
      }
      let fresh = try authorization(
        from: ledger.authorize(
          invocation: invocation(),
          actions: [action],
          now: instant))
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      let restarted = try ledger.startExecution(
        owner: client,
        authorizationIDs: [fresh.id])
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      #expect(
        ledger.executionAccess(
          restarted.id,
          principal: client,
          operation: .readResult,
          now: instant) == .allowed)
    }
  }
}
