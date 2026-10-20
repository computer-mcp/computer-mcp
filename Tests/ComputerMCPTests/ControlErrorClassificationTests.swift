import Testing

@testable import ComputerMCP
@testable import ComputerMCPCore

struct ControlErrorClassificationTests {
  @Test
  func fullShellRejectionRetainsMessagesAndAuditDefaults() {
    let original = AppControlPlaneServiceError.fullShellManifestDisabled
    let error = GatewayControlError.fullShellManifestDisabled
    #expect(ControlToolResponse.errorMessage(error) == ControlToolResponse.errorMessage(original))
    let disposition = ControlToolResponse.auditDisposition(for: error)
    let originalDisposition = ControlToolResponse.auditDisposition(for: original)
    #expect(disposition.decision == originalDisposition.decision)
    #expect(disposition.code == originalDisposition.code)
    #expect(disposition.decision == .failed)
    #expect(disposition.code == "control.operation_failed")
    #expect(GatewayRuntime.auditDecision(for: error) == GatewayRuntime.auditDecision(for: original))
    #expect(
      GatewayRuntime.auditErrorCode(for: error) == GatewayRuntime.auditErrorCode(for: original))
    #expect(GatewayRuntime.auditErrorCode(for: error) == nil)
  }

  @Test
  func localAdminRejectionRetainsControlAuditClassification() {
    let error = AppControlPlaneServiceError.localAdminCannotBeSocketProfile
    let disposition = ControlToolResponse.auditDisposition(for: error)
    #expect(disposition.decision == .denied)
    #expect(disposition.code == "policy.local_admin_remote")
    #expect(AppControlPlaneServiceError.fullShellManifestDisabled.auditClassification == nil)
    #expect(AppControlPlaneServiceError.unknownWorkspace("missing").auditClassification == nil)
  }
}
