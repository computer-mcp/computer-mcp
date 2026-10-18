import ServiceManagement
import Testing

@testable import ComputerMCP

@Suite
struct AppControlPlaneLaunchAtLoginTests {
  @Test
  func missingMainAppRegistrationIsDisabledAndRegisterable() {
    #expect(SMAppServiceLaunchAtLoginController.state(for: .notFound) == .disabled)
  }
}
