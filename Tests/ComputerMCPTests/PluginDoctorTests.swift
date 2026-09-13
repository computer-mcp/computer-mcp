import Foundation
import Testing

@testable import ComputerMCP

struct PluginDoctorTests {
  @Test
  func disabledPackagesAndHelpersAreCheckedWithoutActivationOrExecution() throws {
    let fixture = try PluginDoctorFixture()
    defer { fixture.cleanup() }
    let state = fixture.state(enabled: false, executable: "/bin/echo")
    let report = try fixture.inspect(state)
    #expect(!report.enabled && report.revision == 7 && report.status == .passed)
    #expect(report.scope == "configuration_and_files")
    #expect(
      report.notChecked == [
        "runtime_version", "binary_compatibility", "connection", "system_permissions",
      ])
    #expect(
      report.checks.map(\.id) == [
        "source", "compatibility", "mcp:native:executable", "cli:command:executable",
        "cli:command:helper", "skills:guidance",
      ])
    #expect(report.checks.compactMap(\.enabled).allSatisfy { !$0 })
    #expect(report.dependencies[0].resolutionSource == "host_override")
    #expect(report.dependencies[0].executable == "/bin/echo")
    let resolution = try PluginStore.resolve(
      snapshot: state, bundled: [fixture.plugin], hostVersion: PluginVersion("1.0.0"),
      architecture: "arm64")
    #expect(resolution.plugins.isEmpty)
    #expect(state == fixture.state(enabled: false, executable: "/bin/echo"))
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("executed").path))
    let encoded = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(PluginDoctorReport.self, from: encoded)
    #expect(decoded.checks.map(\.id) == report.checks.map(\.id))
    #expect(!String(decoding: encoded, as: UTF8.self).contains("host-secret-value"))
  }

  @Test
  func brokenExplicitBindingsAreRetainedAndIndependentSkillsPass() throws {
    let fixture = try PluginDoctorFixture()
    defer { fixture.cleanup() }
    let broken = fixture.root.appendingPathComponent("missing")
    let state = fixture.state(enabled: true, executable: broken.path)
    let report = try fixture.inspect(state)
    #expect(report.status == .failed)
    #expect(report.dependencies.first?.executable == broken.path)
    #expect(report.dependencies.first?.resolutionSource == "host_override")
    let dependent = report.checks.filter { $0.dependencyID == "vendor" }
    #expect(dependent.count == 2 && dependent.allSatisfy { $0.status == .failed })
    #expect(dependent.allSatisfy { $0.inspection?.status == .missing })
    #expect(
      report.dependencies.first?.declaration.instructions
        == "Configure the vendor runtime separately.")
    #expect(report.checks.first { $0.id == "skills:guidance" }?.status == .passed)
  }

  @Test
  func sharedDependencyInstructionsAreSerializedOnce() throws {
    let fixture = try PluginDoctorFixture()
    defer { fixture.cleanup() }
    let path = fixture.root.appendingPathComponent(PluginManifest.filename)
    let instructions = String(repeating: "Vendor setup guidance. ", count: 3_000)
    var manifest = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(
      of: "Configure the vendor runtime separately.", with: instructions)
    for index in 0..<64 {
      manifest += """

        [[mcp]]
        id = 'native-\(index)'
        transport = 'stdio'
        executable = { dependency = 'vendor' }

        """
    }
    try manifest.write(to: path, atomically: true, encoding: .utf8)
    let report = try PluginDoctorReport.inspect(
      pluginID: "sample", state: fixture.state(enabled: false, executable: "/bin/echo"),
      bundled: .init(packages: [try PluginPackage.load(at: fixture.root)], issues: []),
      hostVersion: PluginVersion("1.0.0"), architecture: "arm64", environment: [:])
    let encoded = try JSONEncoder().encode(report)
    #expect(report.status == .passed && report.checks.count == 70)
    #expect(report.dependencies.first?.declaration.instructions == instructions)
    #expect(encoded.count < 200_000)
  }

  @Test
  func inconclusiveInterpreterRemainsUnverifiedWithoutExposingItsArguments() throws {
    let fixture = try PluginDoctorFixture()
    defer { fixture.cleanup() }
    try "#!/usr/bin/env VALUE=header-secret fixture-runtime\n".write(
      to: fixture.root.appendingPathComponent("helper"), atomically: false, encoding: .utf8)
    let report = try fixture.inspect(fixture.state(enabled: false, executable: "/bin/echo"))
    #expect(report.status == .unverified)
    #expect(report.checks.first { $0.id == "cli:command:executable" }?.status == .unverified)
    #expect(report.checks.first { $0.id == "mcp:native:executable" }?.status == .passed)
    #expect(
      !String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("header-secret"))
  }

  @Test
  func contributionWorkingDirectoryMatchesActivationInspection() throws {
    let fixture = try PluginDoctorFixture(cwd: "work")
    defer { fixture.cleanup() }
    let script = fixture.root.appendingPathComponent("vendor")
    try "#!/usr/bin/env fixture-runtime\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appendingPathComponent("work/fixture-runtime"),
      withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
    let state = fixture.state(enabled: true, executable: script.path)
    let report = try fixture.inspect(state, environment: ["PATH": "."])
    #expect(report.status == .passed)
    let dependent = report.checks.filter { $0.dependencyID == "vendor" }
    #expect(dependent.count == 2)
    #expect(
      dependent.allSatisfy {
        $0.workingDirectory == fixture.plugin.root.appendingPathComponent("work").path
      })
    let resolution = try PluginStore.resolve(
      snapshot: state, bundled: [fixture.plugin], hostVersion: PluginVersion("1.0.0"),
      architecture: "arm64", environment: ["PATH": "."])
    #expect(resolution.plugins.first?.diagnostics.isEmpty == true)
  }

  @Test
  func missingSelectedSourceCannotActivateOrInspectTheBundledFallback() throws {
    let fixture = try PluginDoctorFixture()
    defer { fixture.cleanup() }
    var state = fixture.state(enabled: false, executable: "/bin/echo")
    let source = PluginSource(
      kind: .development, root: fixture.root.appendingPathComponent("missing"))
    state.installations = [
      .init(
        id: "selected", pluginID: "sample", version: fixture.plugin.manifest.version,
        source: source,
        manifestDigest: try PluginStore.manifestDigest(fixture.plugin.manifest),
        registeredAt: Date())
    ]
    state.selectedInstallations = ["sample": "selected"]
    let report = try fixture.inspect(state)
    #expect(report.status == .failed && report.checks.count == 1)
    #expect(report.source == source)
    #expect(report.dependencies.isEmpty)
    #expect(state.selectedInstallations["sample"] == "selected")
  }

  @Test
  func compatibilityFailuresDoNotHideOtherDiagnostics() throws {
    let fixture = try PluginDoctorFixture(
      compatibility: "[compatibility]\nminimum_host = '2.0.0'\n")
    defer { fixture.cleanup() }
    let report = try fixture.inspect(fixture.state(enabled: false))
    #expect(report.checks.first { $0.id == "compatibility" }?.status == .failed)
    #expect(report.dependencies.first?.resolutionSource == "unresolved")
    #expect(report.checks.first { $0.id == "mcp:native:executable" }?.status == .failed)
    #expect(report.checks.first { $0.id == "skills:guidance" }?.status == .passed)
  }

  @Test
  func unusedDeclaredDependenciesAreInspectedAndUnknownPackagesFailExplicitly() throws {
    let fixture = try PluginDoctorFixture(spareDependency: true)
    defer { fixture.cleanup() }
    let report = try fixture.inspect(fixture.state(enabled: false, executable: "/bin/echo"))
    #expect(report.checks.first { $0.id == "dependency:spare" }?.status == .failed)
    #expect(report.dependencies.count == 2)
    #expect(throws: GatewayToolError.self) {
      try PluginDoctorReport.inspect(
        pluginID: "unknown", state: .init(), bundled: fixture.bundled,
        hostVersion: PluginVersion("1.0.0"), architecture: "arm64")
    }
  }

  @Test
  func bundledChangesAreReportedInsteadOfAcceptingDifferentDeclarations() throws {
    let fixture = try PluginDoctorFixture()
    defer { fixture.cleanup() }
    let path = fixture.root.appendingPathComponent(PluginManifest.filename)
    let text = try String(contentsOf: path, encoding: .utf8)
    try text.replacingOccurrences(of: "version = '1.0.0'", with: "version = '2.0.0'")
      .write(to: path, atomically: true, encoding: .utf8)
    let report = try fixture.inspect(fixture.state(enabled: false))
    #expect(report.status == .failed && report.checks.count == 1)
    #expect(report.checks.first?.message.contains("Bundled declaration") == true)
  }
}

private struct PluginDoctorFixture {
  let root: URL
  let plugin: PluginPackage
  var bundled: BundledPlugins { .init(packages: [plugin], issues: []) }

  init(cwd: String? = nil, compatibility: String = "", spareDependency: Bool = false) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-doctor-\(UUID())")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("skills"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("helper")
    try "#!/bin/sh\ntouch '\(root.path)/executed'\n".write(
      to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let cwdLine = cwd.map { "cwd = '\($0)'" } ?? ""
    let spare =
      spareDependency
      ? "[[dependencies]]\nid='spare'\ncommands=['missing-spare-runtime']\ninstructions='Configure spare.'\n"
      : ""
    let text = """
      id = 'sample'
      name = 'Sample'
      version = '1.0.0'
      \(compatibility)
      [[dependencies]]
      id = 'vendor'
      commands = ['echo']
      instructions = 'Configure the vendor runtime separately.'
      \(spare)
      [[mcp]]
      id = 'native'
      transport = 'stdio'
      executable = { dependency = 'vendor' }
      \(cwdLine)
      [[cli]]
      id = 'command'
      executable = { path = 'helper' }
      tree = { kind = 'helper', helper = { dependency = 'vendor' } }
      \(cwdLine)
      [[skills]]
      id = 'guidance'
      path = 'skills'
      """
    try text.write(
      to: root.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8)
    plugin = try PluginPackage.load(at: root)
  }
  func state(enabled: Bool, executable: String? = nil) -> PluginStoreSnapshot {
    .init(
      revision: 7,
      settings: [
        "sample": .init(
          enabled: enabled, dependencyExecutables: executable.map { ["vendor": $0] } ?? [:])
      ])
  }
  func inspect(_ state: PluginStoreSnapshot, environment: [String: String]? = nil) throws
    -> PluginDoctorReport
  {
    try PluginDoctorReport.inspect(
      pluginID: "sample", state: state, bundled: bundled, hostVersion: PluginVersion("1.0.0"),
      architecture: "arm64",
      environment: environment ?? ["PATH": root.path, "TOKEN": "host-secret-value"],
      workingDirectory: root)
  }
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
