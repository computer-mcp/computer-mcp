import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsProjectRegistrationTests {
  @Test(arguments: ["project", "derived"])
  func registeredProjectsDoNotCreateRequests(projectID: String) throws {
    var ledger = PermissionLedger()
    let environment = TestPathEnvironment()
    let project = try #require(environment.projects.projects.first { $0.id == projectID })
    try ledger.setPermission(
      .granted(.write), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action(.project("project"), .write)], now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = environment.snapshot(preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.requestProjectRegistration(
        ProjectRegistrationRequest(
          principal: client, projectID: "candidate", path: project.root, access: .read),
        invocation: invocation(),
        now: instant) == .registered("project"))
    #expect(ledger.requests.isEmpty)
    #expect(ledger.permissions(for: client).state(for: .project("project")) == .granted(.write))
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .readResult, now: instant)
        == .allowed)
    #expect(
      try ledger.reconcile(environment: PermissionEnvironment(), expectedRevision: ledger.revision)
        .executionsToTerminate.isEmpty)
  }

  @Test(arguments: [Permission.project("new"), .project("*")])
  func registrationAnswerPreservesHigherGrants(permission: Permission) throws {
    var ledger = PermissionLedger()
    let content = try ProjectRegistrationRequest(
      principal: client, projectID: "new", path: path("/people/me/new"), access: .read)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = TestPathEnvironment().snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.requestProjectRegistration(
        content,
        invocation: invocation(),
        now: instant))
    try ledger.setPermission(
      .granted(.write), for: permission, principal: client, expectedRevision: ledger.revision)
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(project: "new"), actions: [action(.project("new"), .write)],
        now: instant))
    let running = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    let result = try ledger.answerProjectRegistration(
      pending.id, registeredProject: RegisteredProject(id: "new", root: content.path), now: instant)
    #expect(result.executionsToTerminate.isEmpty)
    #expect(ledger.permissions(for: client).state(for: .project("new")) == .granted(.write))
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .readResult, now: instant)
        == .allowed)
    #expect(
      try ledger.reconcile(environment: PermissionEnvironment(), expectedRevision: ledger.revision)
        .executionsToTerminate.isEmpty)
    let narrowed = try ledger.setPermission(
      .granted(.read), for: permission, principal: client, expectedRevision: ledger.revision)
    #expect(narrowed.executionsToTerminate == [running.id])
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
  }

  @Test(arguments: [Permission.project("new"), .project("*")])
  func deniedRegistrationProducesNoRequest(permission: Permission) throws {
    let content = try ProjectRegistrationRequest(
      principal: client, projectID: "new", path: path("/people/me/new"), access: .read)
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .denied, for: permission, principal: client, expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = TestPathEnvironment().snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    #expect(
      try ledger.requestProjectRegistration(
        content,
        invocation: invocation(),
        now: instant)
        == .denied(.permissionDenied(.project("new"))))
    #expect(ledger.requests.isEmpty)

    var ceilings = Permissions()
    try ceilings.set(.denied, for: permission)
    ledger = PermissionLedger()
    for source in PolicySource.allCases {
      let policy = PolicyAvailability.available(ManagedPolicy(permissionCeilings: ceilings))
      let limits = ManagedLimits(
        owner: source == .owner ? policy : .absent,
        machine: source == .machine ? policy : .absent)
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits[(invocation()).principal] = limits
        updatedEnvironment.paths = TestPathEnvironment().snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      #expect(
        try ledger.requestProjectRegistration(
          content,
          invocation: invocation(),
          now: instant)
          == .denied(.managedLimit([source])))
      #expect(ledger.requests.isEmpty)
    }
  }

  @Test func registrationChecksIdentityAndCurrentLimits() throws {
    var ledger = PermissionLedger()
    let content = try ProjectRegistrationRequest(
      principal: client, projectID: "new", path: path("/people/me/new"), access: .write)
    let readOnly = ManagedLimits(
      machine: .available(
        ManagedPolicy(
          permissionCeilings: try granted([(.project("*"), .read)]))))
    for limits in [readOnly, ManagedLimits(machine: .unreadable)] {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits[(invocation()).principal] = limits
        updatedEnvironment.paths = TestPathEnvironment().snapshot(
          preserving: updatedEnvironment.paths)
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      #expect(
        try ledger.requestProjectRegistration(
          content,
          invocation: invocation(),
          now: instant)
          == .denied(.managedLimit([.machine])))
      #expect(ledger.requests.isEmpty)
    }
    var unrestricted = ledger.environment
    unrestricted.limits = [:]
    try ledger.reconcile(environment: unrestricted, expectedRevision: ledger.revision)
    unrestricted = ledger.environment
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.paths = TestPathEnvironment().snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.requestProjectRegistration(
        content,
        invocation: invocation(),
        now: instant))
    #expect(throws: PermissionModelError.invalidRegistrationAnswer) {
      try ledger.answerProjectRegistration(
        pending.id,
        registeredProject: RegisteredProject(id: "other", root: content.path), now: instant)
    }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      do {
        var updatedEnvironment = ledger.environment
        updatedEnvironment.limits[ledger.requests[pending.id]!.invocation.principal] = readOnly
        try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

      }
      try ledger.answerProjectRegistration(
        pending.id,
        registeredProject: RegisteredProject(id: "new", root: content.path),
        now: instant)
    }
    try ledger.setPermission(
      .denied, for: .project("*"), principal: client, expectedRevision: ledger.revision)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.answerProjectRegistration(
        pending.id,
        registeredProject: RegisteredProject(id: "new", root: content.path), now: instant)
    }
    #expect(ledger.requests[pending.id]?.status == .revoked)
    #expect(ledger.permissions(for: client).state(for: .project("new")) == .denied)
  }

  @Test func explicitProjectRulesOverrideWildcardDuringRegistration() throws {
    var ledger = PermissionLedger()
    let content = try ProjectRegistrationRequest(
      principal: client, projectID: "new", path: path("/people/me/new"), access: .read)
    var ceilings = Permissions()
    try ceilings.set(.denied, for: .project("*"))
    try ceilings.set(.granted(.read), for: .project("new"))
    try ledger.setPermission(
      .denied, for: .project("*"), principal: client, expectedRevision: ledger.revision)
    try ledger.setPermission(
      .notGranted, for: .project("new"), principal: client, expectedRevision: ledger.revision)
    do {
      var updatedEnvironment = ledger.environment
      updatedEnvironment.limits[(invocation()).principal] = ManagedLimits(
        machine: .available(ManagedPolicy(permissionCeilings: ceilings)))
      updatedEnvironment.paths = TestPathEnvironment().snapshot(
        preserving: updatedEnvironment.paths)
      try ledger.reconcile(environment: updatedEnvironment, expectedRevision: ledger.revision)

    }
    let pending = try request(
      from: ledger.requestProjectRegistration(
        content,
        invocation: invocation(),
        now: instant))
    #expect(pending.content == .projectRegistration(content))
  }
}
