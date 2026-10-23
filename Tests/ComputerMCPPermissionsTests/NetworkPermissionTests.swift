import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsNetworkTests {
  @Test func networkRequestsRespectDenialsAndManagedCeilings() throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .denied, for: .localNetwork, principal: client, expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.authorizeNetwork(
        invocation: invocation(),
        host: "device.example",
        sourceProjectID: "project",
        isLocalNetwork: true,
        now: instant)
        == .denied(.permissionDenied(.localNetwork)))
    #expect(ledger.requests.isEmpty)
    ledger = PermissionLedger()
    var ceilings = Permissions()
    try ceilings.set(.denied, for: .localNetwork)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits[(invocation()).principal] = ManagedLimits(
        owner: .available(ManagedPolicy(permissionCeilings: ceilings)))
      updatedEnvironment.trustedHosts = hostRules([], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.authorizeNetwork(
        invocation: invocation(),
        host: "device.example",
        sourceProjectID: "project",
        isLocalNetwork: true,
        now: instant) == .denied(.managedLimit([.owner])))
    for isLocal in [true, false] {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits[(invocation()).principal] = ManagedLimits(
          machine: .available(ManagedPolicy(network: .none)))
        updatedEnvironment.trustedHosts = hostRules(
          [], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      #expect(
        try ledger.authorizeNetwork(
          invocation: invocation(),
          host: "device.example",
          sourceProjectID: "project",
          isLocalNetwork: isLocal,
          now: instant) == .denied(.managedLimit([.machine])))
    }
    #expect(ledger.requests.isEmpty)
  }

  @Test func allNetworkLevelsAndCustomTrustedInclusion() {
    let trusted: Set<String> = ["registry.example"]
    #expect(!NetworkAccess.none.allows("registry.example", trustedHosts: trusted))
    #expect(NetworkAccess.trusted.allows("registry.example", trustedHosts: trusted))
    #expect(!NetworkAccess.trusted.allows("other.example", trustedHosts: trusted))
    #expect(NetworkAccess.full.allows("other.example", trustedHosts: trusted))
    #expect(
      NetworkAccess.custom(hosts: ["custom.example"], includesTrusted: true).allows(
        "registry.example", trustedHosts: trusted))
    #expect(
      !NetworkAccess.custom(hosts: ["custom.example"], includesTrusted: false).allows(
        "registry.example", trustedHosts: trusted))
    #expect(
      NetworkAccess.none.adding("host").configuration
        == .custom(hosts: ["host"], includesTrusted: false))
    #expect(
      NetworkAccess.trusted.adding("host").configuration
        == .custom(hosts: ["host"], includesTrusted: true))
  }

  @Test func localNetworkPermissionIsIndependentOfHostAdmission() throws {
    let content = NetworkRequestContent(
      principal: client, host: "device.example", projectID: "project")
    let request = NetworkEvaluation.evaluate(
      host: content.host, projectID: content.projectID,
      principal: client, isLocalNetwork: true, permissions: .newPrincipal,
      settings: SandboxSettings(network: .full), trustedHosts: [])
    guard case .permissionRequest(let localRequest) = request else {
      Issue.record("Missing Local network")
      return
    }
    #expect(localRequest.requirement.permission == .localNetwork)
    var rules = try granted([(.localNetwork, .access)])
    #expect(
      NetworkEvaluation.evaluate(
        host: content.host, projectID: content.projectID, principal: client,
        isLocalNetwork: true, permissions: rules, settings: .init(), trustedHosts: [])
        == .hostRequest(content))
    try rules.set(.denied, for: .localNetwork)
    #expect(
      NetworkEvaluation.evaluate(
        host: content.host, projectID: content.projectID, principal: client,
        isLocalNetwork: true, permissions: rules, settings: .init(), trustedHosts: [])
        == .denied(.permissionDenied(.localNetwork)))
    let cap = ManagedLimits(machine: .available(ManagedPolicy(network: .none)))
    #expect(
      NetworkEvaluation.evaluate(
        host: content.host, projectID: content.projectID, principal: client,
        isLocalNetwork: false, permissions: rules, settings: .init(), limits: cap, trustedHosts: [])
        == .denied(.managedLimit([.machine])))
  }

  @Test func networkAlwaysKeepsTrustedAndOneTimeIsExecutionBound() throws {
    var ledger = PermissionLedger()
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
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "custom",
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
      with: .always,
      now: instant)
    #expect(
      ledger.sandboxSettings.entries[key]?.network.configuration
        == .custom(hosts: ["custom"], includesTrusted: true))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let second = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "once",
        sourceProjectID: "project",
        isLocalNetwork: false,
        now: instant))
    try ledger.answer(second.id, with: .onlyThisTime, now: instant)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let once = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(),
        host: "once",
        sourceProjectID: "project",
        isLocalNetwork: false,
        retryIDs: [second.id],
        now: instant))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let execution = try ledger.startExecution(
      owner: client,
      authorizationIDs: [once.id])
    #expect(throws: PermissionModelError.requestConsumed) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.trustedHosts = hostRules(
          ["registry"], preserving: ledger.environment.trustedHosts)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      _ = try ledger.authorizeNetwork(
        invocation: invocation(),
        host: "once",
        sourceProjectID: "project",
        isLocalNetwork: false,
        retryIDs: [second.id],
        now: instant)
    }
    try ledger.finishExecution(execution.id, retainUntil: instant.addingTimeInterval(100_000))
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        execution.id,
        principal: client,
        operation: .readResult,
        now: instant.addingTimeInterval(90_000)) == .allowed)
    _ = try ledger.revokeAuthorization(once.id)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        execution.id,
        principal: client,
        operation: .readResult,
        now: instant) == .denied(.authorizationRevoked))
  }

  @Test func trustedNetworkSurvivesUnrelatedPermissionChangesButNotPolicyTightening() throws {
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
    let execution = try ledger.startExecution(
      owner: client,
      authorizationIDs: [allowed.id])
    try ledger.setPermission(
      .granted(.access), for: .screen, principal: client, expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.trustedHosts = hostRules(
        ["registry"], preserving: ledger.environment.trustedHosts)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      ledger.executionAccess(
        execution.id,
        principal: client,
        operation: .readResult,
        now: instant) == .allowed)
    let limits = ManagedLimits(owner: .available(ManagedPolicy(network: .none)))
    #expect(
      try { () throws -> RevocationResult in
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits = [client: limits]
        updatedEnvironment.trustedHosts = hostRules(
          ["registry"], preserving: ledger.environment.trustedHosts)
        return try ledger.reconcile(
          environment: updatedEnvironment, expectedRevision: ledger.revision)
      }().executionsToTerminate
        == [execution.id])
  }
}
