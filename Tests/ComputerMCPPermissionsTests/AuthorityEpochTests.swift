import Foundation
import Testing

@testable import ComputerMCPPermissions

struct AuthorityEpochTests {
  @Test func recoverySuspendsAuthorityAndKeepsTerminationHandoffUntilAcknowledged() throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .granted(.access), for: .screen, principal: client,
      expectedRevision: ledger.revision)
    let originalGrant = ledger.permissions(for: client).grantIDs[.screen]
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action()], now: instant))
    let execution = try ledger.startExecution(
      owner: client, authorizationIDs: [proof.id], now: instant)
    _ = try ledger.revokeAuthorization(proof.id)
    let epoch = UUID()
    ledger.beginAuthorizationEpoch(epoch)
    #expect(ledger.pendingEpochRecovery?.executionsToTerminate == [execution.id])
    #expect(ledger.pendingExecutionTerminations.isEmpty && ledger.executions.isEmpty)
    let suspendedRevision = ledger.revision
    var environment = ledger.environment
    environment.limits = [:]
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    #expect(throws: PermissionModelError.revisionConflict) {
      try ledger.confirmSuspendedAuthority(epochID: epoch, expectedRevision: suspendedRevision)
    }
    let consent = ledger.consent(for: client, mode: .fullAccess(.connection("new")))
    environment = ledger.environment
    environment.connections["new"] = PermissionConnection(principal: client, consent: consent)
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision, now: instant)
    try ledger.confirmSuspendedAuthority(epochID: epoch, expectedRevision: ledger.revision)
    #expect(ledger.environment.connections.isEmpty && ledger.environment.modes.isEmpty)
    #expect(ledger.permissions(for: client).grantIDs[.screen] != originalGrant)
    #expect(
      try ledger.authorize(invocation: invocation(), actions: [], now: instant)
        == .denied(.authoritySuspended))
    try ledger.acknowledgeEpochRecovery(epoch)
    #expect(
      try ledger.authorize(invocation: invocation(), actions: [action()], now: instant)
        != .denied(.authoritySuspended))
    #expect(
      ledger.executionAccess(execution.id, principal: client, operation: .readResult, now: instant)
        == .denied(.executionOwner))
    try ledger.validatePersistedState()
  }

  @Test func repeatedRecoveryPreservesReviewSnapshotAndInvalidatesOldConfirmation() throws {
    var ledger = PermissionLedger()
    try ledger.setPermission(
      .denied, for: .screen, principal: client, expectedRevision: ledger.revision)
    let first = UUID()
    ledger.beginAuthorizationEpoch(first)
    let displayed = ledger.revision
    let second = UUID()
    ledger.beginAuthorizationEpoch(second)
    #expect(throws: PermissionModelError.revisionConflict) {
      try ledger.confirmSuspendedAuthority(epochID: first, expectedRevision: displayed)
    }
    #expect(throws: PermissionModelError.revisionConflict) {
      try ledger.acknowledgeEpochRecovery(first)
    }
    try ledger.acknowledgeEpochRecovery(second)
    try ledger.confirmSuspendedAuthority(epochID: second, expectedRevision: ledger.revision)
    #expect(ledger.permissions(for: client).state(for: .screen) == .denied)
  }

  @Test func suspendedAuthorityCannotAccumulateUnreviewedSandboxGrants() throws {
    var ledger = PermissionLedger()
    ledger.beginAuthorizationEpoch(UUID())
    #expect(throws: PermissionModelError.authoritySuspended) {
      try ledger.setSandboxSettings(
        .init(network: .full),
        for: .init(principal: client, projectID: "project"), expectedRevision: ledger.revision)
    }
    let registration = try ProjectRegistrationRequest(
      principal: client, projectID: "new",
      path: path("/projects/new"), access: .write)
    #expect(
      try ledger.requestProjectRegistration(registration, invocation: invocation(), now: instant)
        == .denied(.authoritySuspended))
  }
}
