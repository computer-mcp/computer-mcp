import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsRequestInvalidationTests {
  @Test(arguments: [false, true], [ExecutionMode.sandbox, .fullAccess(.standing)])
  func permissionEditsPermanentlyInvalidateUnconsumedRequests(restored: Bool, mode: ExecutionMode)
    throws
  {
    for (permission, value) in [
      (Permission.screen, PermissionValue.access), (.project("project"), .write),
      (.plugin("plugin"), .use), (.mcpServer("server"), .all), (.localNetwork, .access),
    ] {
      for change in ["deny", "revoke", "clear", "lower", "fallback"] {
        if change == "lower" && value != .write && value != .all { continue }
        if change == "fallback" && permission == .screen
          || change == "fallback" && permission == .localNetwork
        {
          continue
        }
        for answered in [false, true] {
          var ledger = PermissionLedger()
          let required = action(permission, value)
          do {
            var updatedEnvironment = ledger.environment
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
            updatedEnvironment = ledger.environment
            if updatedEnvironment.modes[(invocation()).principal]?.mode != mode {
              updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
                for: (invocation()).principal, mode: mode)
              try ledger.reconcile(
                environment: updatedEnvironment, expectedRevision: ledger.revision)

            }
          }
          let pending = try request(
            from: ledger.authorize(
              invocation: invocation(),
              actions: [required],
              now: instant))
          if answered { try ledger.answer(pending.id, with: .onlyThisTime, now: instant) }
          if change == "clear" || change == "lower" {
            try ledger.setPermission(
              .granted(value), for: permission, principal: client, expectedRevision: ledger.revision
            )
          }
          if restored { ledger = try roundTrip(ledger) }
          switch change {
          case "clear":
            try ledger.setPermission(
              .notGranted, for: permission, principal: client, expectedRevision: ledger.revision)
          case "lower":
            try ledger.setPermission(
              .granted(.read), for: permission, principal: client, expectedRevision: ledger.revision
            )
          case "revoke":
            _ = try ledger.revoke(
              principal: client, permission: permission, expectedRevision: ledger.revision)
          case "fallback":
            let fallback: Permission
            switch permission {
            case .project: fallback = .project("*")
            case .plugin: fallback = .plugin("*")
            default: fallback = .mcpServer("*")
            }
            try ledger.setPermission(
              .denied, for: fallback, principal: client, expectedRevision: ledger.revision)
            try ledger.setPermission(
              .notGranted, for: fallback, principal: client, expectedRevision: ledger.revision)
          default:
            try ledger.setPermission(
              .denied, for: permission, principal: client, expectedRevision: ledger.revision)
          }
          #expect(ledger.requests[pending.id]?.status == .revoked)
          try ledger.setPermission(
            .notGranted, for: permission, principal: client, expectedRevision: ledger.revision)
          if restored { ledger = try roundTrip(ledger) }
          #expect(throws: PermissionModelError.invalidAuthorization) {
            try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
          }
          #expect(throws: PermissionModelError.invalidAuthorization) {
            do {
              var updatedEnvironment = ledger.environment
              try ledger.reconcile(
                environment: updatedEnvironment, expectedRevision: ledger.revision)
              updatedEnvironment = ledger.environment
              if updatedEnvironment.modes[(invocation()).principal]?.mode != mode {
                updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
                  for: (invocation()).principal, mode: mode)
                try ledger.reconcile(
                  environment: updatedEnvironment, expectedRevision: ledger.revision)

              }
            }
            _ = try ledger.authorize(
              invocation: invocation(),
              actions: [required],
              retryIDs: [pending.id],
              now: instant)
          }
          do {
            var updatedEnvironment = ledger.environment
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
            updatedEnvironment = ledger.environment
            do {
              updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
                for: (invocation()).principal, mode: mode)
              try ledger.reconcile(
                environment: updatedEnvironment, expectedRevision: ledger.revision)

            }
          }
          let fresh = try request(
            from: ledger.authorize(
              invocation: invocation(),
              actions: [required],
              now: instant))
          #expect(fresh.id != pending.id)
        }
      }
    }
  }

  @Test(arguments: [false, true], [ExecutionMode.sandbox, .fullAccess(.standing)])
  func pathAndPolicyChangesInvalidateOneTimeRequests(restored: Bool, mode: ExecutionMode) throws {
    for change in [
      "hostData", "environment", "nested", "owner", "machine", "ceiling", "sandbox", "unreadable",
    ] {
      if change == "sandbox" && mode != .sandbox { continue }
      var ledger = PermissionLedger()
      var environment = TestPathEnvironment()
      let original = PathPermissions(environment: environment)
      let root = path("/people/me/Downloads/repo")
      let child = path("/people/me/Downloads/repo/private")
      let read = action(.project("project"), .read, scope: .path(root))
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
      let pending = try request(
        from: ledger.authorize(
          invocation: invocation(),
          actions: [read],
          now: instant))
      try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
      if restored { ledger = try roundTrip(ledger) }
      var limits = ManagedLimits()
      switch change {
      case "hostData": environment.hostDataLocations.insert(child)
      case "environment": environment.deniedLocations.insert(child)
      case "nested":
        environment.projects = try ProjectCatalog(
          environment.projects.projects + [RegisteredProject(id: "nested", root: child)])
      case "owner":
        limits = ManagedLimits(owner: .available(ManagedPolicy(deniedReadLocations: [child])))
      case "machine":
        limits = ManagedLimits(machine: .available(ManagedPolicy(deniedReadLocations: [child])))
      case "ceiling":
        var ceilings = Permissions()
        try ceilings.set(.denied, for: .project("project"))
        limits = ManagedLimits(owner: .available(ManagedPolicy(permissionCeilings: ceilings)))
      case "sandbox":
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            [], preserving: ledger.environment.trustedHosts)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        _ = try ledger.setSandboxSettings(
          SandboxSettings(deniedReadLocations: [child]),
          for: SandboxSettingsKey(principal: client, projectID: "project"),
          expectedRevision: ledger.revision)
      default: limits = ManagedLimits(machine: .unreadable)
      }
      #expect(
        try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [client: limits]
          updatedEnvironment.paths = PathEnvironmentSnapshot(
            (PathPermissions(environment: environment)).environment)
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
        .executionsToTerminate.isEmpty)
      #expect(ledger.requests[pending.id]?.status == .revoked)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.setSandboxSettings(
        SandboxSettings(),
        for: SandboxSettingsKey(principal: client, projectID: "project"),
        expectedRevision: ledger.revision)
      if restored { ledger = try roundTrip(ledger) }
      _ = try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (original).environment.snapshot(
          preserving: updatedEnvironment.paths)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }()
      #expect(throws: PermissionModelError.invalidAuthorization) {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [:]
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
        _ = try ledger.authorize(
          invocation: invocation(),
          actions: [read],
          retryIDs: [pending.id],
          now: instant)
      }
    }
  }

  @Test(arguments: [false, true])
  func networkAndConnectionRequestsCannotRevive(restored: Bool) throws {
    for change in ["settings", "policy", "connection"] {
      var ledger = PermissionLedger()
      let mode: ExecutionMode =
        change == "connection" ? .fullAccess(.connection("connection")) : .sandbox
      let key = SandboxSettingsKey(principal: client, projectID: "project")
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          ["registry"], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.setSandboxSettings(
        SandboxSettings(network: .trusted),
        for: key, expectedRevision: ledger.revision)
      let pending: PermissionRequest
      if change == "connection" {
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
        pending = try request(
          from: ledger.authorize(
            invocation: invocation(),
            actions: [action()],
            now: instant))
      } else {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            ["registry"], preserving: ledger.environment.trustedHosts)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        pending = try request(
          from: ledger.authorizeNetwork(
            invocation: invocation(),
            host: "example",
            sourceProjectID: "project",
            isLocalNetwork: false,
            now: instant))
      }
      try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
      if restored { ledger = try roundTrip(ledger) }
      switch change {
      case "settings":
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            ["registry"], preserving: ledger.environment.trustedHosts)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        _ = try ledger.setSandboxSettings(
          SandboxSettings(),
          for: key, expectedRevision: ledger.revision)
      case "policy":
        _ = try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [
            client: ManagedLimits(owner: .available(ManagedPolicy(network: .none)))
          ]
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      default:
        _ = try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.endedConnections.insert("connection")
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      }
      #expect(ledger.requests[pending.id]?.status == .revoked)
      if restored { ledger = try roundTrip(ledger) }
      _ = try ledger.reconcile(
        environment: PermissionEnvironment(), expectedRevision: ledger.revision)
      if change == "connection" {
        #expect(throws: PermissionModelError.invalidAuthorization) {
          do {
            var updatedEnvironment = ledger.environment
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
            updatedEnvironment = ledger.environment
            if updatedEnvironment.modes[(invocation()).principal]?.mode != mode {
              updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
                for: (invocation()).principal, mode: mode)
              try ledger.reconcile(
                environment: updatedEnvironment, expectedRevision: ledger.revision)

            }
          }
          _ = try ledger.authorize(
            invocation: invocation(),
            actions: [action()],
            retryIDs: [pending.id],
            now: instant)
        }
      } else {
        #expect(throws: PermissionModelError.invalidAuthorization) {
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.trustedHosts = hostRules(
              [], preserving: ledger.environment.trustedHosts)
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

          }
          _ = try ledger.authorizeNetwork(
            invocation: invocation(),
            host: "example",
            sourceProjectID: "project",
            isLocalNetwork: false,
            retryIDs: [pending.id],
            now: instant)
        }
      }
    }
  }

  @Test func fallbackEditsPreserveExplicitAndOtherPrincipalsRequests() throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.project("project"), .write)], now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    try ledger.setPermission(
      .denied, for: .project("*"), principal: client, expectedRevision: ledger.revision)
    try ledger.setPermission(
      .denied, for: .project("project"), principal: otherClient, expectedRevision: ledger.revision)
    _ = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.project("project"), .write)], retryIDs: [pending.id], now: instant))
  }

  @Test(arguments: [false, true], [ExecutionMode.sandbox, .fullAccess(.standing)])
  func unconsumedRequestsRetainIndependentPathGrants(restored: Bool, mode: ExecutionMode) throws {
    for change in ["deny", "clear", "ceiling"] {
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
        updatedEnvironment = ledger.environment
        if updatedEnvironment.modes[(invocation()).principal]?.mode != mode {
          updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
            for: (invocation()).principal, mode: mode)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
      }
      let pending = try request(
        from: ledger.authorize(
          invocation: invocation(),
          actions: [traversal],
          now: instant))
      try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
      if restored { ledger = try roundTrip(ledger) }
      if change == "ceiling" {
        var ceilings = Permissions()
        try ceilings.set(.denied, for: .project("project"))
        _ = try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [
            client: ManagedLimits(
              owner: .available(
                ManagedPolicy(permissionCeilings: ceilings)))
          ]
          updatedEnvironment.paths = (resolver).environment.snapshot(
            preserving: updatedEnvironment.paths)
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      } else {
        try ledger.setPermission(
          change == "deny" ? .denied : .notGranted,
          for: .project("project"), principal: client, expectedRevision: ledger.revision)
      }
      #expect(ledger.requests[pending.id]?.status == .revoked)
      try ledger.setPermission(
        .granted(.read), for: .project("project"), principal: client,
        expectedRevision: ledger.revision)
      if restored { ledger = try roundTrip(ledger) }
      _ = try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }()
      #expect(throws: PermissionModelError.invalidAuthorization) {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [:]
          updatedEnvironment.paths = (resolver).environment.snapshot(
            preserving: updatedEnvironment.paths)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
          updatedEnvironment = ledger.environment
          if updatedEnvironment.modes[(invocation()).principal]?.mode != mode {
            updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
              for: (invocation()).principal, mode: mode)
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

          }
        }
        _ = try ledger.authorize(
          invocation: invocation(),
          actions: [traversal],
          retryIDs: [pending.id],
          now: instant)
      }
    }
  }

  @Test(arguments: [false, true], [false, true])
  func localNetworkRequestsRetainNetworkPolicyAndPermission(restored: Bool, hostRequest: Bool)
    throws
  {
    for change in ["network", "permission", "ceiling"] {
      var ledger = PermissionLedger()
      let key = SandboxSettingsKey(principal: client, projectID: "project")
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.setSandboxSettings(
        SandboxSettings(network: hostRequest ? .none : .full),
        for: key, expectedRevision: ledger.revision)
      if hostRequest {
        try ledger.setPermission(
          .granted(.access), for: .localNetwork, principal: client,
          expectedRevision: ledger.revision)
      }
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          [], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      let pending = try request(
        from: ledger.authorizeNetwork(
          invocation: invocation(),
          host: "local",
          sourceProjectID: "project",
          isLocalNetwork: true,
          now: instant))
      try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
      if restored { ledger = try roundTrip(ledger) }
      switch change {
      case "permission":
        try ledger.setPermission(
          .denied, for: .localNetwork, principal: client, expectedRevision: ledger.revision)
        try ledger.setPermission(
          .notGranted, for: .localNetwork, principal: client, expectedRevision: ledger.revision)
      case "ceiling":
        var ceilings = Permissions()
        try ceilings.set(.denied, for: .localNetwork)
        _ = try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [
            client: ManagedLimits(
              machine: .available(
                ManagedPolicy(permissionCeilings: ceilings)))
          ]
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      default:
        _ = try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.limits = [
            client: ManagedLimits(owner: .available(ManagedPolicy(network: .none)))
          ]
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
      }
      #expect(ledger.requests[pending.id]?.status == .revoked)
      try ledger.setPermission(
        .granted(.access), for: .localNetwork, principal: client, expectedRevision: ledger.revision)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.setSandboxSettings(
        SandboxSettings(network: .full),
        for: key, expectedRevision: ledger.revision)
      if restored { ledger = try roundTrip(ledger) }
      _ = try ledger.reconcile(
        environment: PermissionEnvironment(), expectedRevision: ledger.revision)
      #expect(throws: PermissionModelError.invalidAuthorization) {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            [], preserving: ledger.environment.trustedHosts)
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
  }

  private func roundTrip(_ ledger: PermissionLedger) throws -> PermissionLedger {
    try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
  }

  @Test(arguments: [false, true], [ExecutionMode.sandbox, .fullAccess(.standing)])
  func partialAnswersRetainOneTimePathDependencies(restored: Bool, mode: ExecutionMode) throws {
    for change in ["deny", "lower", "consume", "expire", "none"] {
      var ledger = PermissionLedger()
      let resolver = PathPermissions(environment: TestPathEnvironment())
      let project = action(.project("project"), .read, scope: .path(path("/people/me/tasks/job")))
      let actions = [project, action()]
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
        updatedEnvironment = ledger.environment
        if updatedEnvironment.modes[(invocation()).principal]?.mode != mode {
          updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
            for: (invocation()).principal, mode: mode)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
      }
      guard
        case .requests(let pending) = try ledger.authorize(
          invocation: invocation(),
          actions: actions,
          now: instant)
      else {
        Issue.record("Expected project and screen requests")
        return
      }
      let first = pending[0]
      let second = pending[1]
      try ledger.answer(first.id, with: .onlyThisTime, now: instant)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.paths = (resolver).environment.snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
        updatedEnvironment = ledger.environment
        if updatedEnvironment.modes[(invocation()).principal]?.mode != mode {
          updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
            for: (invocation()).principal, mode: mode)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
      }
      _ = try ledger.authorize(
        invocation: invocation(),
        actions: actions,
        retryIDs: [first.id],
        now: instant.addingTimeInterval(1))
      try ledger.answer(second.id, with: .onlyThisTime, now: instant.addingTimeInterval(1))
      if restored { ledger = try roundTrip(ledger) }
      if change == "none" || change == "consume" {
        _ = try { () throws -> RevocationResult in
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (resolver).environment.snapshot(
            preserving: updatedEnvironment.paths)
          return try ledger.reconcile(
            environment: updatedEnvironment, expectedRevision: ledger.revision)
        }()
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.paths = (resolver).environment.snapshot(
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
            actions: actions,
            retryIDs: [first.id, second.id],
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
          if restored { ledger = try roundTrip(ledger) }
          #expect(
            throws: mode == .sandbox ? PermissionModelError.requestConsumed : .invalidAuthorization
          ) {
            do {
              var updatedEnvironment = ledger.environment
              updatedEnvironment.paths = (resolver).environment.snapshot(
                preserving: updatedEnvironment.paths)
              try ledger.reconcile(
                environment: updatedEnvironment, expectedRevision: ledger.revision)
              updatedEnvironment = ledger.environment
              if updatedEnvironment.modes[(invocation()).principal]?.mode != mode {
                updatedEnvironment.modes[(invocation()).principal] = ledger.consent(
                  for: (invocation()).principal, mode: mode)
                try ledger.reconcile(
                  environment: updatedEnvironment, expectedRevision: ledger.revision)

              }
            }
            _ = try ledger.authorize(
              invocation: invocation(),
              actions: actions,
              retryIDs: [second.id],
              now: instant)
          }
          #expect(try ledger.revokeAuthorization(allowed.id).executionsToTerminate == [running.id])
          #expect(ledger.requests[first.id]?.status == .revoked)
          #expect(ledger.requests[second.id]?.status == .revoked)
        }
        #expect(
          throws: change == "consume" ? PermissionModelError.invalidAuthorization : .requestConsumed
        ) {
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.paths = (resolver).environment.snapshot(
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
          _ = try ledger.authorize(
            invocation: invocation(),
            actions: actions,
            retryIDs: [first.id, second.id],
            now: instant.addingTimeInterval(1))
        }
        continue
      }
      switch change {
      case "deny":
        try ledger.setPermission(
          .denied, for: .project("project"), principal: client, expectedRevision: ledger.revision)
      case "lower":
        try ledger.setPermission(
          .granted(.read), for: .project("project"), principal: client,
          expectedRevision: ledger.revision)
        try ledger.setPermission(
          .notGranted, for: .project("project"), principal: client,
          expectedRevision: ledger.revision)
      default: break
      }
      try ledger.setPermission(
        .granted(.read), for: .project("project"), principal: client,
        expectedRevision: ledger.revision)
      if restored { ledger = try roundTrip(ledger) }
      if change == "expire" {
        #expect(throws: PermissionModelError.expiredRequest) {
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.paths = (resolver).environment.snapshot(
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
          _ = try ledger.authorize(
            invocation: invocation(),
            actions: actions,
            retryIDs: [second.id],
            now: first.expiresAt)
        }
      } else {
        #expect(throws: PermissionModelError.invalidAuthorization) {
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.paths = (resolver).environment.snapshot(
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
          _ = try ledger.authorize(
            invocation: invocation(),
            actions: actions,
            retryIDs: [second.id],
            now: instant.addingTimeInterval(1))
        }
      }
      #expect(ledger.requests[second.id]?.status == .revoked)
    }
  }

  @Test(arguments: [false, true])
  func networkRequestsConsumeTheirDependenciesTogether(restored: Bool) throws {
    for consumeTogether in [false, true] {
      var ledger = PermissionLedger()
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          [], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      let first = try request(
        from: ledger.authorizeNetwork(
          invocation: invocation(),
          host: "local",
          sourceProjectID: "project",
          isLocalNetwork: true,
          now: instant))
      try ledger.answer(first.id, with: .onlyThisTime, now: instant)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          [], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      let second = try request(
        from: ledger.authorizeNetwork(
          invocation: invocation(),
          host: "local",
          sourceProjectID: "project",
          isLocalNetwork: true,
          retryIDs: [first.id],
          now: instant))
      try ledger.answer(second.id, with: .onlyThisTime, now: instant)
      if restored { ledger = try roundTrip(ledger) }
      if consumeTogether {
        do {
          var updatedEnvironment = ledger.environment
          updatedEnvironment.trustedHosts = hostRules(
            [], preserving: ledger.environment.trustedHosts)
          try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

        }
        let allowed = try authorization(
          from: ledger.authorizeNetwork(
            invocation: invocation(),
            host: "local",
            sourceProjectID: "project",
            isLocalNetwork: true,
            retryIDs: [first.id, second.id],
            now: instant))
        #expect(ledger.requests[first.id]?.status == .consumed(allowed.id))
        #expect(ledger.requests[second.id]?.status == .consumed(allowed.id))
        let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
        #expect(
          ledger.executionAccess(
            running.id, principal: client, operation: .readResult, now: instant) == .allowed)
      } else {
        let unrelated = try request(
          from: ledger.authorize(
            invocation: invocation(),
            actions: [action(.localNetwork, .access, scope: .host("local", project: "project"))],
            retryIDs: [first.id], now: instant))
        #expect(unrelated.id != first.id)
        #expect(ledger.requests[first.id]?.status == .onlyThisTime)
        #expect(ledger.requests[second.id]?.status == .onlyThisTime)
        try ledger.setPermission(
          .granted(.access), for: .localNetwork, principal: client,
          expectedRevision: ledger.revision)
        #expect(throws: PermissionModelError.invalidAuthorization) {
          do {
            var updatedEnvironment = ledger.environment
            updatedEnvironment.trustedHosts = hostRules(
              [], preserving: ledger.environment.trustedHosts)
            try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

          }
          _ = try ledger.authorizeNetwork(
            invocation: invocation(),
            host: "local",
            sourceProjectID: "project",
            isLocalNetwork: true,
            retryIDs: [second.id],
            now: instant)
        }
      }
    }
  }

  @Test func expiredDependencyCannotBeAnsweredWithAStandingGrant() throws {
    var ledger = PermissionLedger()
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let first = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "local",
        sourceProjectID: "project",
        isLocalNetwork: true,
        now: instant))
    try ledger.answer(first.id, with: .onlyThisTime, now: instant)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let second = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "local",
        sourceProjectID: "project",
        isLocalNetwork: true,
        retryIDs: [first.id],
        now: instant.addingTimeInterval(1)))
    ledger = try roundTrip(ledger)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.answer(second.id, with: .always, now: first.expiresAt)
    }
    #expect(ledger.requests[second.id]?.status == .revoked)
    #expect(
      ledger.sandboxSettings.entries[SandboxSettingsKey(principal: client, projectID: "project")]
        == nil)
  }

}
