import Foundation
import Testing

@testable import ComputerMCPPlatform

struct PluginPlatformCompatibilityTests {
  @Test
  func targetsMatchOnlyDeclaredPlatformsAndArchitectures() throws {
    let universalMac = try PluginPlatformCompatibility(platforms: ["macos"], architectures: [])
    let windowsIntel = try PluginPlatformCompatibility(
      platforms: ["windows"], architectures: ["x86_64"])
    #expect(universalMac.permits(platform: "macos", architecture: "arm64"))
    #expect(universalMac.permits(platform: "macos", architecture: "x86_64"))
    #expect(!universalMac.permits(platform: "windows", architecture: "arm64"))
    #expect(!universalMac.permits(platform: "macos", architecture: "unknown"))
    #expect(windowsIntel.permits(platform: "windows", architecture: "x86_64"))
    #expect(!windowsIntel.permits(platform: "windows", architecture: "arm64"))
    let combined = try PluginPlatformCompatibility(
      platforms: ["windows", "macos"], architectures: [])
    #expect(universalMac.isSubset(of: combined))
    #expect(windowsIntel.isSubset(of: combined))
    #expect(!combined.isSubset(of: universalMac))
    #expect(!combined.isSubset(of: windowsIntel))
    #expect(
      try JSONDecoder().decode(
        PluginPlatformCompatibility.self, from: JSONEncoder().encode(combined)) == combined)
    #expect(
      try combined
        == PluginPlatformCompatibility(platforms: ["macos", "windows"], architectures: []))
  }

  @Test(arguments: [
    #"{"platforms":[],"architectures":[]}"#,
    #"{"platforms":["macos","macos"],"architectures":[]}"#,
    #"{"platforms":["linux"],"architectures":[]}"#,
    #"{"platforms":["windows"],"architectures":["ARM64"]}"#,
    #"{"platforms":["windows"],"architectures":["arm64","arm64"]}"#,
    #"{"platforms":["windows"],"architectures":[],"extra":true}"#,
    #"{"platforms":["windows"]}"#,
  ])
  func invalidOrAmbiguousTargetsFailClosed(json: String) {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(PluginPlatformCompatibility.self, from: Data(json.utf8))
    }
  }

  @Test
  func unrestrictedArchitectureCannotExpandAnExplicitParent() throws {
    let parent = try PluginPlatformCompatibility(platforms: ["windows"], architectures: ["arm64"])
    let unrestricted = try PluginPlatformCompatibility(platforms: ["windows"], architectures: [])
    #expect(!unrestricted.isSubset(of: parent))
    #expect(parent.isSubset(of: unrestricted))
  }
}
