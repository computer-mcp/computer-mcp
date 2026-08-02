import Foundation
import Testing

@testable import ComputerMCPApp

@Suite

final class ComputerMCPAppModelTests {
  @MainActor
  @Test
  func testProfileActivationRefreshesProfileDependentSections() {
    let refresh = ComputerMCPAppModel.profileActivationRefresh
    #expect((refresh) == ([.profiles, .workspaces, .status, .providers, .tunnels]))
  }
}
