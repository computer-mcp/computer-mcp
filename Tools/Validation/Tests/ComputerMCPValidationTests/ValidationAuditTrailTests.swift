import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite struct ValidationAuditTrailTests {
  @Test func selectsTheTerminalAfterAdmission() throws {
    let terminal = audit()
    let admission = fixtureAdmissionAudit(terminal)
    let trail = try ValidationAuditTrail(
      events: [terminal, admission], requestID: terminal.requestID)
    #expect(trail.terminal == terminal)
    #expect(trail.admission == admission)
  }

  @Test func rejectsMissingCompletionDuplicateRowsAndMismatchedAdmissions() throws {
    let terminal = audit()
    let admission = fixtureAdmissionAudit(terminal)
    var wrongInput = admission
    wrongInput.inputDigest = "other-input"
    var wrongConnection = admission
    wrongConnection.socketConnectionID = "other-connection"
    for rows in [
      [terminal], [admission], [terminal, terminal], [terminal, admission, admission],
      [terminal, wrongInput], [terminal, wrongConnection],
    ] {
      #expect(throws: ValidationObservationCollectorError.self) {
        try ValidationAuditTrail(events: rows, requestID: terminal.requestID)
      }
    }
  }

  @Test func preAdmissionFailuresHaveOnlyATerminalAndPostAdmissionFailureIsNotSuccess() throws {
    var failed = audit()
    failed.decision = .failed
    failed.errorCode = "provider.failed"
    #expect(
      try ValidationAuditTrail(events: [failed], requestID: failed.requestID).admission == nil)
    let dispatched = try ValidationAuditTrail(
      events: [fixtureAdmissionAudit(failed), failed], requestID: failed.requestID)
    #expect(dispatched.terminal.decision == .failed)
    var denied = failed
    denied.decision = .denied
    #expect(
      try ValidationAuditTrail(events: [denied], requestID: denied.requestID).terminal.decision
        == .denied)
  }

  @Test func ownerControlRecorderUsesOneTerminal() throws {
    var terminal = audit()
    terminal.transport = "control_socket"
    #expect(
      try ValidationAuditTrail(events: [terminal], requestID: terminal.requestID).terminal
        == terminal)
  }

  @Test func auditClientNeverReturnsAdmissionAsTheOutcome() throws {
    let database = try GatewayDatabase(inMemory: ())
    let terminal = audit()
    try database.recordAudit(fixtureAdmissionAudit(terminal))
    #expect(throws: ValidationObservationCollectorError.self) {
      try database.auditEvent(requestID: terminal.requestID)
    }
    try database.recordAudit(terminal)
    #expect(try database.auditEvent(requestID: terminal.requestID) == terminal)
  }

  private func audit() -> AuditEvent {
    AuditEvent(
      requestID: "request", caller: .localMCP, transport: "gateway_socket",
      socketConnectionID: "connection", profileID: .chatGPTOperate, capabilityID: "system.time",
      decision: .allowed, inputDigest: "input", outputDigest: "output", outputByteCount: 10,
      outputTruncated: false)
  }
}

func fixtureAdmissionAudit(_ terminal: AuditEvent) -> AuditEvent {
  var admission = terminal
  admission.id += "-admission"
  admission.occurredAt = Date(
    timeIntervalSince1970: (terminal.occurredAt.timeIntervalSince1970 * 1_000).rounded() / 1_000 - 1
  )
  admission.decision = .allowed
  admission.errorCode = "permission.admitted"
  admission.durationMilliseconds = 0
  admission.outputDigest = nil
  admission.outputByteCount = nil
  admission.outputTruncated = nil
  return admission
}
