import Foundation
import Testing

@testable import ComputerMCPPlatform

struct PluginPlatformCompatibilityTests {
  @Test
  func targetsMatchOnlyDeclaredPlatformsAndArchitectures() throws {
    let universalMac = try PluginPlatformCompatibility(platforms: ["macos"], architectures: [])
    let intelMac = try PluginPlatformCompatibility(platforms: ["macos"], architectures: ["x86_64"])
    #expect(universalMac.permits(platform: "macos", architecture: "arm64"))
    #expect(universalMac.permits(platform: "macos", architecture: "x86_64"))
    #expect(!universalMac.permits(platform: "windows", architecture: "arm64"))
    #expect(!universalMac.permits(platform: "macos", architecture: "unknown"))
    #expect(intelMac.permits(platform: "macos", architecture: "x86_64"))
    #expect(!intelMac.permits(platform: "macos", architecture: "arm64"))
    #expect(intelMac.isSubset(of: universalMac))
    #expect(!universalMac.isSubset(of: intelMac))
    #expect(
      try JSONDecoder().decode(
        PluginPlatformCompatibility.self,
        from: JSONEncoder().encode(universalMac)) == universalMac)
  }

  @Test(arguments: [
    #"{"platforms":[],"architectures":[]}"#,
    #"{"platforms":["macos","macos"],"architectures":[]}"#,
    #"{"platforms":["linux"],"architectures":[]}"#,
    #"{"platforms":["windows"],"architectures":[]}"#,
    #"{"platforms":["macos"],"architectures":["ARM64"]}"#,
    #"{"platforms":["macos"],"architectures":["arm64","arm64"]}"#,
    #"{"platforms":["macos"],"architectures":[],"extra":true}"#,
    #"{"platforms":["macos"]}"#,
  ])
  func invalidOrAmbiguousTargetsFailClosed(json: String) {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(PluginPlatformCompatibility.self, from: Data(json.utf8))
    }
  }

  @Test
  func unrestrictedArchitectureCannotExpandAnExplicitParent() throws {
    let parent = try PluginPlatformCompatibility(platforms: ["macos"], architectures: ["arm64"])
    let unrestricted = try PluginPlatformCompatibility(platforms: ["macos"], architectures: [])
    #expect(!unrestricted.isSubset(of: parent))
    #expect(parent.isSubset(of: unrestricted))
  }
}
