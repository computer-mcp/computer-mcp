import Foundation
import Testing

@testable import ComputerMCP

struct PluginApplicationLocatorTests {
  @Test
  func installedSystemApplicationIsResolvedByTheProductionLookupWithoutLaunchingIt() throws {
    let fixture = try ApplicationLocatorFixture()
    defer { fixture.cleanup() }
    let manifestURL = fixture.plugin.root.appendingPathComponent(PluginManifest.filename)
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
      .replacingOccurrences(of: "com.example.Fixture", with: "com.apple.finder")
      .replacingOccurrences(of: "Contents/MacOS/vendor", with: "Contents/MacOS/Finder")
      .replacingOccurrences(of: "commands = ['fixture-vendor']\n", with: "")
    try Data(manifest.utf8).write(to: manifestURL)
    let plugin = try PluginPackage.load(at: fixture.plugin.root)
    #expect(plugin.manifest.dependencies.first?.commands.isEmpty == true)
    let bindings = PluginStore.dependencyBindings(
      for: plugin, settings: fixture.settings, searchDirectories: [])
    let executable = try #require(bindings["vendor"])
    let application = executable.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    #expect(Bundle(url: application)?.bundleIdentifier == "com.apple.finder")
    let report = try PluginDoctorReport.inspect(
      pluginID: plugin.manifest.id,
      state: .init(settings: [plugin.manifest.id: fixture.settings]),
      bundled: .init(packages: [plugin], issues: []), hostVersion: PluginVersion("1.0.0"),
      architecture: "arm64", environment: [:])
    #expect(report.dependencies.first?.resolutionSource == "application_bundle")
    #expect(report.dependencies.first?.executable == executable.path)
    #expect(report.status == .passed)
  }

  @Test(arguments: [0, 2, 33])
  func applicationOnlyDependencyRequiresBoundedDistinctLocators(count: Int) throws {
    let locator = [
      "bundle_identifier": "com.example.Fixture", "executable": "Contents/MacOS/vendor",
    ]
    let data = try JSONSerialization.data(
      withJSONObject: [
        "id": "vendor", "instructions": "Configure the vendor.",
        "applications": Array(repeating: locator, count: count),
      ] as [String: Any])
    #expect(throws: PluginManifestError.self) {
      try JSONDecoder().decode(PluginDependency.self, from: data)
    }
  }

  @Test
  func applicationLookupFeedsTheSameDoctorAndActivationWithoutExecution() throws {
    let fixture = try ApplicationLocatorFixture()
    defer { fixture.cleanup() }
    let bindings = fixture.resolve()
    #expect(bindings["vendor"]?.executable == fixture.executable)
    #expect(bindings["vendor"]?.source == "application_bundle")
    let resolved = try fixture.activate(bindings)
    #expect(resolved.mcpServers.first?.command == fixture.executable.path)
    #expect(resolved.diagnostics.isEmpty)
    let report = try fixture.doctor()
    #expect(report.status == .passed)
    #expect(report.dependencies.first?.resolutionSource == "application_bundle")
    #expect(report.dependencies.first?.executable == resolved.mcpServers.first?.command)
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("ran").path))
    let dependency = try #require(fixture.plugin.manifest.dependencies.first)
    #expect(dependency.commands == ["fixture-vendor"])
    #expect(dependency.applications.first?.bundleIdentifier == "com.example.Fixture")
    #expect(
      try JSONDecoder().decode(PluginDependency.self, from: JSONEncoder().encode(dependency))
        == dependency)
  }

  @Test(arguments: ["override", "setting", "path"])
  func explicitAndPathBindingsPrecedeApplicationLookup(source: String) throws {
    let fixture = try ApplicationLocatorFixture()
    defer { fixture.cleanup() }
    let missing = fixture.root.appendingPathComponent("explicit-missing")
    var settings = fixture.settings
    if source != "path" { settings.dependencyExecutables["vendor"] = missing.path }
    let pathExecutable = fixture.root.appendingPathComponent("fixture-vendor")
    try FileManager.default.copyItem(at: fixture.executable, to: pathExecutable)
    let overrides = source == "override" ? ["vendor": fixture.executable] : [:]
    let bindings = PluginDependencyResolver.resolve(
      for: fixture.plugin, settings: settings, overrides: overrides,
      searchDirectories: [fixture.root],
      applicationURL: { _ in
        Issue.record("A selected explicit or PATH binding must not fall through.")
        return fixture.application
      })
    #expect(bindings["vendor"]?.source == (source == "path" ? "path" : "host_override"))
    #expect(
      bindings["vendor"]?.executable
        == (source == "override"
          ? fixture.executable : source == "setting" ? missing : pathExecutable))
  }

  @Test(arguments: ["missing", "non-executable", "interpreter"])
  func selectedApplicationFailureIsReportedWithoutChoosingAnotherProgram(failure: String) throws {
    let fixture = try ApplicationLocatorFixture()
    defer { fixture.cleanup() }
    switch failure {
    case "missing": try FileManager.default.removeItem(at: fixture.executable)
    case "non-executable":
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: fixture.executable.path)
    default:
      try Data("#!/fixture/missing-interpreter\n".utf8).write(to: fixture.executable)
    }
    let bindings = fixture.resolve()
    #expect(bindings["vendor"]?.executable == fixture.executable)
    let report = try fixture.doctor()
    #expect(report.status == .failed)
    #expect(report.dependencies.first?.resolutionSource == "application_bundle")
    #expect(report.dependencies.first?.executable == fixture.executable.path)
    let resolved = try fixture.activate(bindings)
    #expect(resolved.mcpServers.isEmpty)
    #expect(resolved.diagnostics.first?.code == .dependencyUnavailable)
  }

  @Test(arguments: ["absent", "wrong-identity", "network-url", "escape"])
  func unavailableOrUncontainedApplicationsCannotSupplyExecutables(failure: String) throws {
    let fixture = try ApplicationLocatorFixture()
    defer { fixture.cleanup() }
    if failure == "escape" {
      try FileManager.default.removeItem(at: fixture.executable)
      try FileManager.default.createSymbolicLink(
        at: fixture.executable, withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
    }
    if failure == "wrong-identity" { try fixture.writeInfo(identifier: "com.example.Other") }
    let application: URL? =
      failure == "absent"
      ? nil
      : failure == "network-url" ? URL(string: "https://example.test/App.app") : fixture.application
    let bindings = PluginDependencyResolver.resolve(
      for: fixture.plugin, settings: fixture.settings, searchDirectories: [],
      applicationURL: { _ in application })
    #expect(bindings.isEmpty)
    #expect(try fixture.activate(bindings).mcpServers.isEmpty)
  }

  @Test
  func containedExecutableSymlinkRetainsItsInvocationPath() throws {
    let fixture = try ApplicationLocatorFixture()
    defer { fixture.cleanup() }
    let target = fixture.application.appendingPathComponent("Contents/MacOS/implementation")
    try FileManager.default.moveItem(at: fixture.executable, to: target)
    try FileManager.default.createSymbolicLink(at: fixture.executable, withDestinationURL: target)
    #expect(fixture.resolve()["vendor"]?.executable == fixture.executable)
    #expect(try fixture.doctor().status == .passed)
  }

  @Test
  func commandOnlyDependencyEncodingPreservesExistingManifestIdentity() throws {
    let json =
      #"{"id":"vendor","commands":["fixture-vendor"],"instructions":"Configure the vendor."}"#
    let dependency = try JSONDecoder().decode(PluginDependency.self, from: Data(json.utf8))
    #expect(dependency.applications.isEmpty)
    let original = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(dependency))
    #expect(original == encoded)
  }

  @Test(arguments: ["/bin/echo", "../escape", "Contents/../outside", "", "~/App", "a//b"])
  func applicationExecutableMustBeRelativeAndNormalized(path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "bundle_identifier": "com.example.Fixture", "executable": path,
    ])
    #expect(throws: PluginManifestError.self) {
      try JSONDecoder().decode(PluginApplicationLocator.self, from: data)
    }
  }

  @Test(arguments: ["", "com..example", ".com.example", "com.example.", "../../app", "com example"])
  func applicationIdentityIsNotAnArbitraryPath(identifier: String) throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "bundle_identifier": identifier, "executable": "Contents/MacOS/vendor",
    ])
    #expect(throws: PluginManifestError.self) {
      try JSONDecoder().decode(PluginApplicationLocator.self, from: data)
    }
  }
}

private struct ApplicationLocatorFixture {
  let root: URL
  let application: URL
  let executable: URL
  let plugin: PluginPackage
  var settings: PluginSettings { .init(enabled: true) }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    application = root.appendingPathComponent("Installed App.app")
    executable = application.appendingPathComponent("Contents/MacOS/vendor")
    let package = root.appendingPathComponent("package")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data("#!/bin/sh\ntouch '\(root.path)/ran'\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try Data(
      """
      id = 'application-fixture'
      name = 'Application Fixture'
      version = '1.0.0'
      [[dependencies]]
      id = 'vendor'
      commands = ['fixture-vendor']
      instructions = 'Configure the vendor.'
      applications = [{ bundle_identifier = 'com.example.Fixture', executable = 'Contents/MacOS/vendor' }]
      [[mcp]]
      id = 'native'
      transport = 'stdio'
      executable = { dependency = 'vendor' }
      """.utf8
    ).write(to: package.appendingPathComponent(PluginManifest.filename))
    plugin = try PluginPackage.load(at: package)
    try writeInfo(identifier: "com.example.Fixture")
  }

  func writeInfo(identifier: String) throws {
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "vendor",
        "CFBundlePackageType": "APPL",
      ], format: .xml, options: 0
    ).write(to: application.appendingPathComponent("Contents/Info.plist"))
  }

  func resolve() -> [String: PluginDependencyResolver.Binding] {
    PluginDependencyResolver.resolve(
      for: plugin, settings: settings, searchDirectories: [], applicationURL: { _ in application })
  }

  func activate(_ bindings: [String: PluginDependencyResolver.Binding]) throws -> ResolvedPlugin {
    try PluginResolver.resolve(
      package: plugin, source: .init(kind: .development, root: plugin.root), settings: settings,
      dependencyExecutables: bindings.mapValues(\.executable), hostVersion: PluginVersion("1.0.0"),
      architecture: "arm64", environment: [:])
  }

  func doctor() throws -> PluginDoctorReport {
    try PluginDoctorReport.inspect(
      pluginID: plugin.manifest.id, state: .init(settings: [plugin.manifest.id: settings]),
      bundled: .init(packages: [plugin], issues: []), hostVersion: PluginVersion("1.0.0"),
      architecture: "arm64", environment: [:], applicationURL: { _ in application })
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
