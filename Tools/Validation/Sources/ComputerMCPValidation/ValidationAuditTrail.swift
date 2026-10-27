import Foundation

public struct ValidationAuditTrail: Sendable {
  public let terminal: AuditEvent
  public let admission: AuditEvent?

  public init(events: [AuditEvent], requestID: String) throws {
    let terminals = events.filter { $0.errorCode != "permission.admitted" }
    let admissions = events.filter { $0.errorCode == "permission.admitted" }
    guard terminals.count == 1, let terminal = terminals.first else {
      throw ValidationObservationCollectorError.auditCardinality(
        requestID: requestID, count: terminals.count)
    }
    guard terminal.requestID == requestID, admissions.count <= 1 else {
      throw ValidationObservationCollectorError.auditMismatch(
        requestID: requestID, detail: "the request identity or admission cardinality differs")
    }
    // Owner control commands have a separate recorder and do not dispatch a gateway invocation.
    if terminal.decision == .allowed, terminal.transport != "control_socket", admissions.isEmpty {
      throw ValidationObservationCollectorError.auditMismatch(
        requestID: requestID, detail: "a dispatched call requires its pre-dispatch admission record"
      )
    }
    if let admission = admissions.first {
      guard admission.id != terminal.id, admission.requestID == terminal.requestID,
        admission.mcpRequestID == terminal.mcpRequestID,
        admission.invocationID == terminal.invocationID,
        admission.parentRequestID == terminal.parentRequestID,
        admission.caller == terminal.caller, admission.transport == terminal.transport,
        admission.socketConnectionID == terminal.socketConnectionID,
        admission.tunnelInstanceID == terminal.tunnelInstanceID,
        admission.tunnelProfileID == terminal.tunnelProfileID,
        admission.profileID == terminal.profileID, admission.projectID == terminal.projectID,
        admission.capabilityID == terminal.capabilityID,
        admission.inputDigest == terminal.inputDigest,
        admission.decision == .allowed, admission.outputDigest == nil,
        admission.outputByteCount == nil, admission.outputTruncated == nil,
        admission.occurredAt.timeIntervalSince1970 <= terminal.occurredAt.timeIntervalSince1970
          + 0.001
      else {
        throw ValidationObservationCollectorError.auditMismatch(
          requestID: requestID,
          detail: "the admission does not match the terminal identity, input, or ordering")
      }
    }
    self.terminal = terminal
    self.admission = admissions.first
  }
}
