import ServiceManagement
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite
struct AppControlPlaneLaunchAtLoginTests {
  @Test
  func missingMainAppRegistrationIsDisabledAndRegisterable() {
    #expect(SMAppServiceLaunchAtLoginController.state(for: .notFound) == .disabled)
  }
}
