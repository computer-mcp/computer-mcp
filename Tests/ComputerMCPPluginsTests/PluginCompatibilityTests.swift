import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPPlugins

struct PluginCompatibilityTests {
  @Test(arguments: ["", "0", "-1", "true", "'1'", "1.0", "[1]"])
  func pluginAPIIsARequiredPositiveInteger(value: String) {
    let text = PluginManifestFixture.combined.replacingOccurrences(
      of: "plugin_api = 1\n", with: value.isEmpty ? "" : "plugin_api = \(value)\n")
    #expect(throws: PluginManifestError.invalid("plugin_api must be a positive integer.")) {
      try PluginManifest.parse(text)
    }
  }

  @Test
  func newerSchemaIsRefusedBeforeAnyUnknownOrRequiredFieldsAreDecoded() throws {
    let text = "id = 'future'\nversion = '2.0.0'\nplugin_api = 2\nfuture = { runtime = 'new' }\n"
    let expected = try #require(
      PluginAPIVersions.supported.refusal(
        pluginID: "future", version: PluginVersion("2.0.0"), declared: 2))
    #expect(throws: expected) { try PluginManifest.parse(text) }
    let json = Data(#"{"id":"future","version":"2.0.0","plugin_api":2,"future":true}"#.utf8)
    #expect(throws: expected) { try JSONDecoder().decode(PluginManifest.self, from: json) }
    #expect(expected.code == "plugin.host_update_required")
    #expect(expected.message.contains("Update Computer MCP."))
    #expect(throws: PluginManifestError.self) {
      try PluginManifest.parse(PluginManifestFixture.combined + "\n[future]\nvalue = true")
    }
  }

  @Test(arguments: [false, true])
  func hostRefusesATestPluginOutsideItsSupportedAPIRange(olderPlugin: Bool) throws {
    let manifest = try PluginManifest.parse(PluginManifestFixture.combined)
    // A positive older API first exists when a host's minimum advances beyond API 1.
    let supported = olderPlugin ? PluginAPIVersions(2...2) : .supported
    let declared = olderPlugin ? manifest.pluginAPI : 2
    let refusal = try #require(
      PluginCompatibilityRefusal.evaluate(
        pluginID: manifest.id, version: manifest.version, pluginAPI: declared,
        target: .macOS, artifacts: [.macOS], minimumHost: nil, maximumHost: nil,
        host: PluginVersion("1.0.0"), architecture: "arm64", platform: "macos",
        supportedAPIs: supported))
    #expect(refusal.pluginID == manifest.id && refusal.version == manifest.version)
    #expect(refusal.reason == (olderPlugin ? .pluginUpdateRequired : .hostUpdateRequired))
    #expect(refusal.requirement == .pluginAPI(declared: declared, supported: supported))
    #expect(refusal.message.contains(olderPlugin ? "Update the plugin." : "Update Computer MCP."))
    #expect(
      try JSONDecoder().decode(
        PluginCompatibilityRefusal.self, from: JSONEncoder().encode(refusal)) == refusal)
  }

  @Test(arguments: [
    "api", "platform", "architecture", "artifact", "minimum", "maximum", "permitted",
  ])
  func evaluatesTheFirstFailureAndRetainsDeclaredAndSupportedValues(fault: String) throws {
    let version = try PluginVersion("1.2.3")
    let host = try PluginVersion("2.0.0+build.1")
    let target = try PluginPlatformCompatibility(platforms: ["macos"], architectures: ["arm64"])
    let minimum = try PluginVersion(fault == "maximum" || fault == "permitted" ? "1.0.0" : "3.0.0")
    let maximum = try PluginVersion(fault == "maximum" ? "2.0.0" : "4.0.0")
    let platform = fault == "platform" || fault == "api" ? "linux" : "macos"
    let architecture = fault == "architecture" ? "x86_64" : "arm64"
    let artifacts: [PluginPlatformCompatibility] = fault == "artifact" ? [] : [target]
    let refusal = PluginCompatibilityRefusal.evaluate(
      pluginID: "fixture", version: version, pluginAPI: fault == "api" ? 2 : 1,
      target: target, artifacts: artifacts, minimumHost: minimum, maximumHost: maximum,
      host: host, architecture: architecture, platform: platform)
    if fault == "permitted" {
      #expect(refusal == nil)
      return
    }
    let result = try #require(refusal)
    switch fault {
    case "api":
      #expect(result.requirement == .pluginAPI(declared: 2, supported: .supported))
      #expect(result.reason == .hostUpdateRequired)
    case "minimum", "maximum":
      #expect(result.requirement == .hostVersion(minimum: minimum, maximum: maximum, current: host))
      #expect(result.reason == (fault == "minimum" ? .hostUpdateRequired : .pluginUpdateRequired))
    default:
      #expect(result.reason == .platformUnsupported)
      #expect(
        result.requirement
          == .platform(
            declared: target, artifacts: artifacts, platform: platform, architecture: architecture))
      #expect(result.message.contains("Use a package built for this Mac."))
    }
  }

  @Test
  func canonicalSnapshotsRetainSchemaKeysAndHostConstraints() throws {
    let text = PluginManifestFixture.platformExecutables.replacingOccurrences(
      of: "[compatibility]", with: "[compatibility]\nminimum_host = '1.0.0'\nmaximum_host = '2.0.0'"
    )
    let manifest = try PluginManifest.parse(text)
    let decoded = try CanonicalJSONCoding.decoder().decode(
      PluginManifest.self, from: CanonicalJSONCoding.encoder().encode(manifest))
    #expect(decoded == manifest)
    #expect(decoded.pluginAPI == 1)
    #expect(try decoded.compatibility?.minimumHost == PluginVersion("1.0.0"))
    #expect(try decoded.compatibility?.maximumHost == PluginVersion("2.0.0"))
    #expect(throws: PluginManifestError.self) {
      try PluginManifest.parse(text.replacingOccurrences(of: "plugin_api", with: "pluginAPI"))
    }
  }

  @Test
  func packageLoadingCarriesTheHeaderRefusalWithoutInspectingFuturePaths() throws {
    let root = try pluginPackageFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let text = "id = 'future'\nversion = '1.0.0'\nplugin_api = 2\nnew_runtime = 'unavailable'\n"
    try text.write(
      to: root.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8)
    let refusal = try #require(
      PluginAPIVersions.supported.refusal(
        pluginID: "future", version: PluginVersion("1.0.0"), declared: 2))
    #expect(throws: refusal) { try PluginPackage.load(at: root) }
  }
}
