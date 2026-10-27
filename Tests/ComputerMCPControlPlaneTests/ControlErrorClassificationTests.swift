import Testing

@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

struct ControlErrorClassificationTests {
  @Test
  func unavailablePermissionServiceUsesDiagnosticFailure() {
    let error = AppControlPlaneServiceError.permissionServiceUnavailable
    let disposition = ControlToolResponse.auditDisposition(for: error)
    #expect(disposition.decision == .failed)
    #expect(disposition.code == "control.operation_failed")
    #expect(GatewayRuntime.auditDecision(for: error) == .failed)
    #expect(GatewayRuntime.auditErrorCode(for: error) == nil)
  }

  @Test
  func localAdminRejectionRetainsControlAuditClassification() {
    let error = AppControlPlaneServiceError.localAdminCannotBeSocketProfile
    let disposition = ControlToolResponse.auditDisposition(for: error)
    #expect(disposition.decision == .denied)
    #expect(disposition.code == "policy.local_admin_remote")
    #expect(GatewayRuntime.auditDecision(for: error) == .failed)
    #expect(GatewayRuntime.auditErrorCode(for: error) == nil)
    #expect(
      AppControlPlaneServiceError.permissionServiceUnavailable.controlAuditClassification == nil)
    #expect(
      AppControlPlaneServiceError.unknownProject("missing").controlAuditClassification == nil)
  }
}
