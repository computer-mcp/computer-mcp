import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPPlugins

struct PluginPlatformCompatibilityTests {
  @Test
  func namedArtifactsConstrainTheReleaseWidePlatformRange() throws {
    let manifest = try PluginManifest.parse(PluginManifestFixture.platformArtifacts)
    let compatibility = try #require(manifest.compatibility)
    #expect(compatibility.artifactTarget(named: "mac.zip")?.platforms == ["macos"])
    #expect(compatibility.artifactTarget(named: "intel.zip")?.architectures == ["x86_64"])
    #expect(compatibility.artifactTarget(named: "renamed.zip") == nil)
    #expect(compatibility.artifactTarget(named: nil) == nil)
    let root = URL(fileURLWithPath: "/fixture")
    let mac = PluginSource(kind: .artifact, root: root, artifactName: "mac.zip")
    let intel = PluginSource(kind: .artifact, root: root, artifactName: "intel.zip")
    #expect(
      try mac.refusal(manifest: manifest, host: PluginVersion("1.2.3"), architecture: "arm64")
        == nil)
    #expect(
      try mac.refusal(manifest: manifest, host: PluginVersion("1.2.3"), architecture: "x86_64")
        != nil)
    #expect(
      try intel.refusal(manifest: manifest, host: PluginVersion("1.2.3"), architecture: "x86_64")
        == nil
    )
    #expect(
      try PluginSource(kind: .artifact, root: root).refusal(
        manifest: manifest, host: PluginVersion("1.2.3"), architecture: "arm64") != nil)
    #expect(try JSONDecoder().decode(PluginSource.self, from: JSONEncoder().encode(mac)) == mac)
  }

  @Test
  func packageLoadingAndInspectionUseTheSamePlatformEntryPoint() throws {
    let root = try pluginPackageFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = root.appendingPathComponent("helper")
    try "#!/bin/sh\ntouch executed\n".write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    try PluginManifestFixture.platformExecutables.write(
      to: root.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8)
    let package = try PluginPackage.load(at: root)
    let executables =
      package.manifest.mcp.compactMap(\.executable)
      + package.manifest.cli.map(\.executable) + package.manifest.cli.compactMap { $0.tree?.helper }
    #expect(executables.count == 3)
    for executable in executables {
      let inspected = try #require(
        try PluginResolver.inspectExecutable(
          executable, package: package,
          dependencyExecutables: [:], workingDirectory: root, environment: [:]))
      #expect(inspected.path == helper.path)
      #expect(inspected.status == .passed)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("helper.exe").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path))
    try FileManager.default.moveItem(at: helper, to: root.appendingPathComponent("helper.exe"))
    #expect(throws: (any Error).self) { try PluginPackage.load(at: root) }
  }
}
