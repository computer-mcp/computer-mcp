import Foundation
import Testing

@testable import ComputerMCP

@Suite
final class AppDistributionEnvironmentTests {
  @Test
  func testDevelopmentAndProductionNamespacesAreDisjoint() throws {
    let development = try AppDistributionIdentity(
      environment: .development,
      bundleIdentifier: "com.showxu.computer-mcp.development",
      teamIdentifier: "A7JC3DY3PU"
    )
    let production = try AppDistributionIdentity(
      environment: .production,
      bundleIdentifier: "com.showxu.computer-mcp",
      teamIdentifier: "A7JC3DY3PU"
    )

    #expect(development.bundleIdentifier != production.bundleIdentifier)
    #expect(development.keychainAccessGroup != production.keychainAccessGroup)
    #expect(
      AppDistributionEnvironment.development.applicationSupportDirectoryName
        != AppDistributionEnvironment.production.applicationSupportDirectoryName
    )
    #expect(
      AppDistributionEnvironment.development.keychainService
        != AppDistributionEnvironment.production.keychainService
    )
  }

  @Test
  func testBundledIdentityRequiresMatchingSignedEnvironmentMetadata() throws {
    let identity = try AppDistributionIdentity.bundled(
      infoDictionary: [
        AppDistributionEnvironment.infoPlistKey: "production",
        kCFBundleIdentifierKey as String: "com.showxu.computer-mcp",
        AppDistributionIdentity.teamIdentifierInfoPlistKey: "A7JC3DY3PU",
      ]
    )

    #expect(identity.environment == .production)
    #expect(identity.keychainAccessGroup == "A7JC3DY3PU.com.showxu.computer-mcp")
    #expect(identity.environment.keychainService == "com.showxu.computer-mcp.secrets")
  }

  @Test
  func testBundledIdentityRejectsEnvironmentAndBundleMismatch() {
    expectThrows(
      try AppDistributionIdentity.bundled(
        infoDictionary: [
          AppDistributionEnvironment.infoPlistKey: "development",
          kCFBundleIdentifierKey as String: "com.showxu.computer-mcp",
          AppDistributionIdentity.teamIdentifierInfoPlistKey: "A7JC3DY3PU",
        ]
      )
    ) { error in
      #expect(
        (error as? AppDistributionIdentityError)
          == .bundleIdentifierMismatch(
            expected: "com.showxu.computer-mcp.development",
            actual: "com.showxu.computer-mcp"
          )
      )
    }
  }

  @Test
  func testBundledIdentityRejectsAdHocSigning() {
    expectThrows(
      try AppDistributionIdentity.bundled(
        infoDictionary: [
          AppDistributionEnvironment.infoPlistKey: "production",
          kCFBundleIdentifierKey as String: "com.showxu.computer-mcp",
          AppDistributionIdentity.teamIdentifierInfoPlistKey: "adhoc",
        ]
      )
    ) { error in
      #expect((error as? AppDistributionIdentityError) == .invalidTeamIdentifier)
    }
  }
}
