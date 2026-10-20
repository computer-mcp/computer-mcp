import Testing

@testable import ComputerMCP
@testable import ComputerMCPCore

struct ControlErrorClassificationTests {
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
