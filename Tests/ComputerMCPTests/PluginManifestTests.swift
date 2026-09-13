import Foundation
import Testing

@testable import ComputerMCP

struct PluginManifestTests {
  @Test
  func referenceExampleUsesTheActualManifestContract() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let reference = try String(
      contentsOf: root.appendingPathComponent("Documentation/Reference/PluginPackages.md"),
      encoding: .utf8)
    let sections = reference.components(separatedBy: "```toml\n")
    #expect(sections.count > 1)
    for section in sections.dropFirst() {
      let example = try #require(section.components(separatedBy: "```").first)
      let manifest = try PluginManifest.parse(example)
      #expect(!manifest.mcp.isEmpty && !manifest.cli.isEmpty && !manifest.skills.isEmpty)
    }
  }

  @Test
  func declarativePackageCombinesAllThreeContributionsWithoutCodeOrGrants() throws {
    let manifest = try PluginManifest.parse(Self.combined)
    #expect(manifest.id == "test-package")
    #expect(manifest.mcp.map(\.id) == ["native"])
    #expect(manifest.cli.map(\.id) == ["commands"])
    #expect(manifest.skills.map(\.id) == ["guidance"])
    #expect(manifest.mcp[0].executable?.dependency == "vendor")
    #expect(manifest.cli[0].tree?.kind == .introspection)
    #expect(manifest.cli[0].tree?.args == ["schema", "--json"])
    let encoded = try JSONEncoder().encode(manifest)
    #expect(try JSONDecoder().decode(PluginManifest.self, from: encoded) == manifest)
  }

  @Test(arguments: [
    "official = true", "allow_any_tool = true", "env = { TOKEN = 'value' }",
    "tool_risks = { write = 'read-only' }", "hooks = []", "runtime = 'plugin'",
  ])
  func packageCannotDeclareHostAuthorityOrAnotherRuntime(field: String) {
    #expect(throws: (any Error).self) {
      try PluginManifest.parse(field + "\n" + Self.combined)
    }
  }

  @Test(arguments: [
    "allow_any_tool = true", "allowed_tools = ['anything']", "tool_schema = {}", "env = {}",
  ])
  func mcpContributionRejectsHostSelectionSecretsAndCopiedSchemas(field: String) {
    #expect(throws: (any Error).self) {
      try PluginManifest.parse(
        Self.header
          + "\n[[mcp]]\nid = 'remote'\ntransport = 'http'\nurl = 'https://example.test/mcp'\n"
          + field)
    }
  }

  @Test(arguments: [
    "/etc", "../escape", "folder/../escape", "./folder", "a//b", "a/", "~/skills", "a\\b", "a\0b",
  ])
  func packagePathsMustBeNormalizedRelativePaths(path: String) {
    #expect(throws: PluginManifestError.self) { try validatePluginRelativePath(path) }
  }

  @Test(arguments: [
    "[[skills]]\nid = 'guidance'\npath = 'other'",
    "[[cli]]\nid = 'guidance'\nexecutable = { dependency = 'vendor' }",
    "[[dependencies]]\nid = 'vendor'\ncommands = ['vendor']\ninstructions = 'Install it.'",
  ])
  func duplicateIdentityIsRejectedAcrossContributionKinds(extra: String) {
    #expect(throws: PluginManifestError.self) {
      try PluginManifest.parse(Self.combined + "\n" + extra)
    }
  }

  @Test
  func missingDependenciesEmptyPackagesAndUnknownNestedFieldsAreRejected() {
    #expect(throws: PluginManifestError.self) { try PluginManifest.parse(Self.header) }
    #expect(throws: PluginManifestError.self) {
      try PluginManifest.parse(
        Self.combined.replacingOccurrences(
          of: "dependency = 'vendor'", with: "dependency = 'missing'"))
    }
    #expect(throws: PluginManifestError.self) {
      try PluginManifest.parse(
        Self.combined.replacingOccurrences(
          of: "dependency = 'vendor'", with: "dependency = 'vendor', grant = 'admin'"))
    }
    #expect(throws: PluginManifestError.self) {
      try PluginManifest.parse(
        Self.combined.replacingOccurrences(
          of: "dependency = 'vendor'", with: "dependency = 'vendor', path = 'bin/helper'"))
    }
  }

  @Test(arguments: [
    "url = 'file:///tmp/mcp'", "url = 'https://user:secret@example.test/mcp'",
    "url = 'https://example.test/mcp#token'", "url = 'https://example.test/mcp'\nargs = ['run']",
  ])
  func invalidHTTPProcessMixesAndCredentialURLsAreRejected(fields: String) {
    #expect(throws: PluginManifestError.self) {
      try PluginManifest.parse(
        Self.header + "\n[[mcp]]\nid = 'remote'\ntransport = 'http'\n" + fields)
    }
  }

  @Test
  func compatibilityUsesReleasePrecedenceAndExclusiveUpperBound() throws {
    let manifest = try PluginManifest.parse(
      Self.header + """

        [compatibility]
        minimum_host = '1.2.0'
        maximum_host = '2.0.0'
        architectures = ['arm64']
        [[skills]]
        id = 'guidance'
        path = 'skills'
        """)
    let compatibility = try #require(manifest.compatibility)
    #expect(try compatibility.permits(host: PluginVersion("1.2.0+build.2"), architecture: "arm64"))
    #expect(try !compatibility.permits(host: PluginVersion("1.2.0-alpha"), architecture: "arm64"))
    #expect(try !compatibility.permits(host: PluginVersion("2.0.0"), architecture: "arm64"))
    #expect(try !compatibility.permits(host: PluginVersion("1.3.0"), architecture: "x86_64"))
  }

  @Test(arguments: [
    "", "1", "1.2", "v1.2.3", "01.2.3", "1.2.3-", "1.2.3-01", "1.2.3+", "1.2.3+a+b",
    "1.2.3-alpha..1",
  ])
  func malformedReleaseVersionsAreRejected(version: String) {
    #expect(throws: PluginManifestError.self) { try PluginVersion(version) }
  }

  @Test
  func semanticVersionsSortNumericIdentifiersWithoutIntegerOverflow() throws {
    let ordered = try [
      "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
      "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "999999999999999999999999999999.0.0",
    ].map(PluginVersion.init)
    for (before, after) in zip(ordered, ordered.dropFirst()) {
      #expect(before.precedes(after))
      #expect(!after.precedes(before))
    }
    #expect(try !PluginVersion("1.0.0+a").precedes(PluginVersion("1.0.0+b")))
    #expect(try !PluginVersion("1.0.0+b").precedes(PluginVersion("1.0.0+a")))
  }

  static let header = "id = 'test-package'\nname = 'Test package'\nversion = '1.2.3'\n"
  static let combined =
    header + """
      [[dependencies]]
      id = 'vendor'
      commands = ['vendor-cli']
      instructions = 'Install the vendor CLI separately.'
      [[mcp]]
      id = 'native'
      transport = 'stdio'
      executable = { dependency = 'vendor' }
      args = ['mcp']
      [[cli]]
      id = 'commands'
      executable = { dependency = 'vendor' }
      tree = { kind = 'introspection', args = ['schema', '--json'] }
      [[skills]]
      id = 'guidance'
      path = 'skills'
      """
}

struct PluginPackageTests {
  @Test
  func loadingDeclarativePackageDoesNotRequireSwiftOrExecuteAnything() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try PluginManifestTests.combined.write(
      to: root.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8)
    let package = try PluginPackage.load(at: root)
    #expect(package.manifest.skills.count == 1)
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path))
  }

  @Test
  func ownedHelperIsInspectedButNeverExecuted() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = root.appendingPathComponent("helper")
    try "#!/bin/sh\ntouch executed\n".write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let text = PluginManifestTests.combined.replacingOccurrences(
      of: "dependency = 'vendor'", with: "path = 'helper'")
    try text.write(
      to: root.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8)
    _ = try PluginPackage.load(at: root)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: helper.path)
    #expect(throws: PluginManifestError.self) { try PluginPackage.load(at: root) }
  }

  @Test
  func externalAndDanglingSymlinksFailButContainedSymlinksRemainUsable() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let sibling = try fixture()
    defer { try? FileManager.default.removeItem(at: sibling) }
    try "inside".write(
      to: root.appendingPathComponent("content"), atomically: true, encoding: .utf8)
    try "outside".write(
      to: sibling.appendingPathComponent("content"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("link").path, withDestinationPath: "content")
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("escape").path, withDestinationPath: sibling.path)
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "missing")
    let files = try PluginPackageFiles(root: root)
    #expect(try files.read("link", maximumBytes: 6) == Data("inside".utf8))
    #expect(throws: (any Error).self) { try files.read("escape/content", maximumBytes: 100) }
    #expect(throws: (any Error).self) { try files.read("dangling", maximumBytes: 100) }
    #expect(throws: PluginManifestError.self) { try files.read("content", maximumBytes: 5) }
    #expect(throws: PluginManifestError.self) { try files.read("skills", maximumBytes: 100) }
  }

  @Test
  func invalidUTF8AndOversizedManifestsFailBeforeParsing() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = root.appendingPathComponent(PluginManifest.filename)
    try Data([0xff]).write(to: manifest)
    #expect(throws: PluginManifestError.self) { try PluginPackage.load(at: root) }
    try Data(repeating: 32, count: 1_048_577).write(to: manifest)
    #expect(throws: PluginManifestError.self) { try PluginPackage.load(at: root) }
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "plugin-package-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("skills"), withIntermediateDirectories: true)
    return root
  }
}
