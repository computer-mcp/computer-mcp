import Testing

@testable import ComputerMCPComputerUse
@testable import ComputerMCPGateway

struct ComputerUseControlErrorTests {
  @Test(arguments: [
    ComputerUseGatewayProviderError.invalidArguments("Invalid pointer button."),
    .service(.permissionRequired(.accessibility)),
  ])
  func computerUseErrorsUseControlDefaults(error: ComputerUseGatewayProviderError) {
    let disposition = ControlToolResponse.auditDisposition(for: error)
    #expect(disposition.decision == .failed)
    #expect(disposition.code == "control.operation_failed")
  }
}
