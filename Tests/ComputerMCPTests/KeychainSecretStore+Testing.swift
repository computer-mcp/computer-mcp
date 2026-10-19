import Foundation
import Testing

@testable import ComputerMCP
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin

extension KeychainSecretStore {
  init(service: String = "com.showxu.computer-mcp.tests", adapter: any KeychainAdapter) throws {
    try self.init(
      service: service,
      accessGroup: "TESTTEAMID.com.showxu.computer-mcp.tests",
      adapter: adapter
    )
  }
}
