import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsExecutionLimitTests {
  @Test func managedReadRestrictionsInvalidateAProjectExecution() throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.write), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.project("project"), .write, scope: .project("project"))], now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    var limits = ManagedLimits(
      machine: .available(
        ManagedPolicy(deniedReadLocations: [path("/people/me/Downloads/repo/private")])))
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits = [client: limits]
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate == [running.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits[(invocation()).principal] = limits
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)
      updatedEnvironment = ledger.environment
      limits = ledger.environment.limits[client]!
    }
    let fresh = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.project("project"), .write, scope: .project("project"))],
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits = [client: limits]
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    _ = try ledger.startExecution(
      owner: client,
      authorizationIDs: [fresh.id])
  }

  @Test func sandboxReadRestrictionsInvalidateAProjectExecutionWithoutPathActions() throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.write), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = PathEnvironmentSnapshot(
        (PathPermissions(environment: TestPathEnvironment())).environment)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(project: "derived"),
        actions: [action(.project("project"), .write, scope: .project("project"))],
        now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.setSandboxSettings(
        SandboxSettings(deniedReadLocations: [path("/people/me/Downloads/repo/private")]),
        for: SandboxSettingsKey(principal: client, projectID: "project"),
        expectedRevision: ledger.revision
      ).executionsToTerminate == [running.id])
  }

  @Test func managedNetworkTighteningInvalidatesAProjectExecution() throws {
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
    let allowed = try authorization(
      from: ledger.authorize(invocation: invocation(), actions: [action(.skills)], now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    let limits = ManagedLimits(owner: .available(ManagedPolicy(network: .trusted)))
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits = [client: limits]
        updatedEnvironment.trustedHosts = hostRules(
          ["registry"], preserving: ledger.environment.trustedHosts)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate
        == [running.id])
  }
}
