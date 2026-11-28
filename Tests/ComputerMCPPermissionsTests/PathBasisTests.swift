import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsPathBasisTests {
  @Test(arguments: [false, true], [ExecutionMode.sandbox, .fullAccess(.standing)])
  func traversalRetainsItsReadableDescendant(restored: Bool, mode: ExecutionMode) throws {
    for source in ["project", "category", "developer"] {
      for denial in ["owner", "machine", "environment", "hostData", "sandbox"] {
        if denial == "sandbox" && mode != .sandbox { continue }
        for operation in [PathOperation.openDirectory, .listDirectory] {
          var environment = TestPathEnvironment()
          let ancestor = path("/people/me/routes")
          let first = path("/people/me/routes/A")
          let second = path("/people/me/routes/B")
          environment.projects = try ProjectCatalog(
            source == "project"
              ? [
                RegisteredProject(id: "project", root: first),
                RegisteredProject(id: "derived", root: second, sourceID: "project"),
              ] : [])
          environment.folders = source == "category" ? [.documents: [first, second]] : [:]
          environment.developerLocations = source == "developer" ? [first, second] : []
          var ledger = PermissionLedger()
          try ledger.setPermission(
            .granted(.read), for: .project("project"), principal: client,
            expectedRevision: ledger.revision)
          try ledger.setPermission(
            .granted(.read), for: .filesAndFolders(.documents), principal: client,
            expectedRevision: ledger.revision)
          let traversal = PermissionAction(
            requirement: requirement(.skills, .access), scope: .path(ancestor),
            pathOperation: operation)
          let initialResolver = PathPermissions(environment: environment)
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.paths = (initialResolver).environment.snapshot(
              preserving: updatedEnvironment.paths)
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
            updatedEnvironment = ledger.environment
            if updatedEnvironment.modes[(invocation()).principal]?.mode != mode {
              updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
                for: (invocation()).principal, mode: mode)
              try ledger.reconcile(
                environment: updatedEnvironment, expectedRevision: ledger.revision)

            }
          }
          let allowed = try authorization(
            from: ledger.authorize(
              invocation: invocation(),
              actions: [traversal],
              now: instant))
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.paths = (initialResolver).environment.snapshot(
              preserving: updatedEnvironment.paths)
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

          }
          let running = try ledger.startExecution(
            owner: client,
            authorizationIDs: [allowed.id])
          if restored { ledger = try roundTrip(ledger) }
          var limits = ManagedLimits()
          var terminated: Set<UUID> = []
          switch denial {
          case "owner":
            limits = ManagedLimits(owner: .available(ManagedPolicy(deniedReadLocations: [first])))
          case "machine":
            limits = ManagedLimits(machine: .available(ManagedPolicy(deniedReadLocations: [first])))
          case "environment": environment.deniedLocations.insert(first)
          case "hostData": environment.hostDataLocations.insert(first)
          default:
            do {
              var updatedEnvironment = ledger.environment
              updatedEnvironment.trustedHosts = hostRules(
                [], preserving: ledger.environment.trustedHosts)
              try ledger.reconcile(
                environment: updatedEnvironment, expectedRevision: ledger.revision)

            }
            terminated =
              try ledger.setSandboxSettings(
                SandboxSettings(deniedReadLocations: [first]),
                for: SandboxSettingsKey(principal: client, projectID: "project"),
                expectedRevision: ledger.revision
              ).executionsToTerminate
          }
          let resolver = PathPermissions(environment: environment)
          // B still permits a fresh invocation, but cannot replace A in this execution.
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.limits[(invocation(digest: "fresh")).principal] = limits
            updatedEnvironment.paths = (resolver).environment.snapshot(
              preserving: updatedEnvironment.paths)
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
            updatedEnvironment = ledger.environment
            do {
              updatedEnvironment.modes[(invocation(digest: "fresh")).principal] = ledger.consent(
                for: (invocation(digest: "fresh")).principal, mode: mode)
              try ledger.reconcile(
                environment: updatedEnvironment, expectedRevision: ledger.revision)

            }
          }
          _ = try authorization(
            from: ledger.authorize(
              invocation: invocation(digest: "fresh"),
              actions: [traversal],
              now: instant))
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.limits = [client: limits]
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
          terminated.formUnion(
            try { () throws -> RevocationResult in
              var updatedEnvironment = ledger.environment
              updatedEnvironment.limits = [client: limits]
              updatedEnvironment.paths = (resolver).environment.snapshot(
                preserving: updatedEnvironment.paths)
              return try ledger.reconcile(
                environment: updatedEnvironment, expectedRevision: ledger.revision)
            }().executionsToTerminate
          )
          #expect(terminated == [running.id])
          if restored { ledger = try roundTrip(ledger) }
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.trustedHosts = hostRules(
              [], preserving: ledger.environment.trustedHosts)
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

          }
          _ = try ledger.setSandboxSettings(
            SandboxSettings(),
            for: SandboxSettingsKey(principal: client, projectID: "project"),
            expectedRevision: ledger.revision)
          #expect(
            try { () throws -> RevocationResult in
              var updatedEnvironment = ledger.environment
              updatedEnvironment.paths = (initialResolver).environment.snapshot(
                preserving: updatedEnvironment.paths)
              return try ledger.reconcile(
                environment: updatedEnvironment, expectedRevision: ledger.revision)
            }().executionsToTerminate == [running.id])
          ledger.acknowledgeExecutionTerminations([running.id])
          #expect(
            try { () throws -> RevocationResult in
              var updatedEnvironment = ledger.environment
              updatedEnvironment.paths = (initialResolver).environment.snapshot(
                preserving: updatedEnvironment.paths)
              return try ledger.reconcile(
                environment: updatedEnvironment, expectedRevision: ledger.revision)
            }().executionsToTerminate.isEmpty)
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.paths = (initialResolver).environment.snapshot(
              preserving: updatedEnvironment.paths)
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

          }
          #expect(
            ledger.executionAccess(
              running.id,
              principal: client,
              operation: .readResult,
              now: instant) == .denied(.authorizationRevoked))
          #expect(throws: PermissionModelError.invalidAuthorization) {
            do {
              var updatedEnvironment = ledger.environment
              updatedEnvironment.paths = (initialResolver).environment.snapshot(
                preserving: updatedEnvironment.paths)
              try ledger.reconcile(
                environment: updatedEnvironment, expectedRevision: ledger.revision)

            }
            _ = try ledger.startExecution(
              owner: client,
              authorizationIDs: [allowed.id])
          }
        }
      }
    }
  }

  @Test(arguments: [false, true], [ExecutionMode.sandbox, .fullAccess(.standing)])
  func pathClassificationCannotReplaceRecordedAuthority(restored: Bool, mode: ExecutionMode) throws
  {
    for change in ["project", "category", "developer"] {
      var environment = TestPathEnvironment()
      let target = path("/people/me/routes/A")
      let ancestor = path("/people/me/routes")
      environment.projects = try ProjectCatalog(
        change == "project" ? [RegisteredProject(id: "project", root: target)] : [])
      environment.folders = change == "category" ? [.documents: [target]] : [:]
      environment.developerLocations = change == "developer" ? [target] : []
      let original = PathPermissions(environment: environment)
      var ledger = PermissionLedger()
      try ledger.setPermission(
        .granted(.read), for: .project("*"), principal: client, expectedRevision: ledger.revision)
      try ledger.setPermission(
        .granted(.read), for: .filesAndFolders(.documents), principal: client,
        expectedRevision: ledger.revision)
      try ledger.setPermission(
        .granted(.read), for: .filesAndFolders(.downloads), principal: client,
        expectedRevision: ledger.revision)
      let traversal = PermissionAction(
        requirement: requirement(.skills, .access), scope: .path(ancestor),
        pathOperation: .listDirectory)
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
          actions: [traversal],
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
      case "project":
        environment.projects = try ProjectCatalog([
          RegisteredProject(id: "replacement", root: target)
        ])
      case "category": environment.folders = [.downloads: [target]]
      default:
        environment.developerLocations = []
        environment.systemLocations.insert(target)
        environment.folders = [.downloads: [path("/people/me/routes/B")]]
      }
      let changed = PathPermissions(environment: environment)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (changed).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
        updatedEnvironment = ledger.environment
        do {
          updatedEnvironment.modes[(invocation(digest: "fresh")).principal] = ledger.consent(
            for: (invocation(digest: "fresh")).principal, mode: mode)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
      }
      _ = try authorization(
        from: ledger.authorize(
          invocation: invocation(digest: "fresh"),
          actions: [traversal],
          now: instant))
      #expect(
        try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (changed).environment.snapshot(
            preserving: updatedEnvironment.paths)
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }().executionsToTerminate == [running.id])
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

  @Test(arguments: [false, true], [ExecutionMode.sandbox, .fullAccess(.standing)])
  func failedRevalidationPermanentlyRevokesAuthority(restored: Bool, mode: ExecutionMode) throws {
    for checkStart in [false, true] {
      var environment = TestPathEnvironment()
      environment.developerLocations = [path("/people/me/routes/A"), path("/people/me/routes/B")]
      let original = PathPermissions(environment: environment)
      var ledger = PermissionLedger()
      let traversal = PermissionAction(
        requirement: requirement(.skills, .access), scope: .path(path("/people/me/routes")),
        pathOperation: .listDirectory)
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
          actions: [traversal],
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
      environment.deniedLocations.insert(path("/people/me/routes/A"))
      let denied = PathPermissions(environment: environment)
      if checkStart {
        #expect(throws: PermissionModelError.invalidAuthorization) {
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.paths = (denied).environment.snapshot(
              preserving: updatedEnvironment.paths)
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

          }
          _ = try ledger.startExecution(
            owner: client,
            authorizationIDs: [allowed.id])
        }
      } else {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (denied).environment.snapshot(
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
      #expect(
        try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (original).environment.snapshot(
            preserving: updatedEnvironment.paths)
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }().executionsToTerminate == [running.id])
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

  @Test func storeCommitsFailedValidationAndReportsTermination() async throws {
    let store = InMemoryPermissionStore()
    var environment = TestPathEnvironment()
    environment.developerLocations = [path("/people/me/routes/A"), path("/people/me/routes/B")]
    let original = PathPermissions(environment: environment)
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
          actions: [
            PermissionAction(
              requirement: requirement(.skills, .access), scope: .path(path("/people/me/routes")),
              pathOperation: .listDirectory)
          ],
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
    environment.deniedLocations.insert(path("/people/me/routes/A"))
    let denied = PathPermissions(environment: environment)
    let result = try await store.transaction { ledger in
      Result {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (denied).environment.snapshot(
            preserving: updatedEnvironment.paths)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        _ = try ledger.startExecution(
          owner: client,
          authorizationIDs: [authorizationID])
      }
    }
    #expect(throws: PermissionModelError.invalidAuthorization) { try result.get() }
    var restored = try roundTrip(await store.read())
    do {
      var updatedEnvironment = restored.environment
      updatedEnvironment.paths = (original).environment.snapshot(
        preserving: updatedEnvironment.paths)
      try restored.reconcile(environment: updatedEnvironment, expectedRevision: restored.revision)

    }
    #expect(
      restored.executionAccess(
        executionID,
        principal: client,
        operation: .readResult,
        now: instant) == .denied(.authorizationRevoked))
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = restored.environment
        updatedEnvironment.paths = (original).environment.snapshot(
          preserving: updatedEnvironment.paths)
        return try restored.reconcile(
          environment: updatedEnvironment, expectedRevision: restored.revision)
      }().executionsToTerminate == [executionID])
  }

  private func roundTrip(_ ledger: PermissionLedger) throws -> PermissionLedger {
    try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
  }
}
