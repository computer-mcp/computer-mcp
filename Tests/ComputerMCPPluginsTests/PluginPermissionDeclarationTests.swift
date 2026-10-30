import ComputerMCPCore
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPPlugins

struct PluginPermissionDeclarationTests {
  private static let skill = "\n[[skills]]\nid = 'guide'\npath = 'skills'\n"
  private static let remote = """

    [[mcp]]
    id = 'remote'
    transport = 'http'
    url = 'https://example.test/mcp'
    """

  private func manifest(_ declaration: String) throws -> PluginManifest {
    try PluginManifest.parse(PluginManifestFixture.header + declaration + Self.skill)
  }

  @Test(arguments: [
    "id = 'project'\naccess = 'all'\npurpose = 'Edit'",
    "id = 'screen'\naccess = 'read'\npurpose = 'Observe'",
    "id = 'screen'\naccess = 'allow'",
    "id = 'screen'\naccess = 'allow'\npurpose = '   '",
    "id = 'screen'\naccess = 'allow'\npurpose = 'Observe'\ncategory = 'desktop'",
    "id = 'files-and-folders'\naccess = 'read'\npurpose = 'Read'",
    "id = 'files-and-folders'\naccess = 'read'\npurpose = 'Read'\ncategory = 'icloud'",
    "id = 'plugin'\naccess = 'use'\npurpose = 'Delegate'\nobjects = ['*']",
    "id = 'unknown'\naccess = 'allow'\npurpose = 'Unknown'",
    "id = 'project'\naccess = 'deny'\npurpose = 'Deny'",
  ])
  func malformedPermissionsAreRejected(fields: String) {
    #expect(throws: (any Error).self) { try manifest("\n[[permissions]]\n" + fields) }
  }

  @Test
  func duplicatesAreByPermissionAndFolderCategory() throws {
    let project = "\n[[permissions]]\nid = 'project'\naccess = 'write'\npurpose = 'Edit'\n"
    #expect(throws: (any Error).self) { try manifest(project + project) }
    let folder =
      "\n[[permissions]]\nid = 'files-and-folders'\naccess = 'read'\npurpose = 'Read'\ncategory = 'desktop'\n"
    #expect(throws: (any Error).self) { try manifest(folder + folder) }
    #expect(
      try manifest(folder + folder.replacingOccurrences(of: "desktop", with: "downloads"))
        .permissions?.count == 2)
  }

  @Test(arguments: [
    "network = 'none'", "purpose = 'Unused'", "network = 'unknown'\npurpose = 'Network'",
    "full_access = true", "full_access = 'true'\npurpose = 'Native'",
    "full_access = true\nnetwork = 'none'\npurpose = 'Native'",
    "full_access = true\nread_exceptions = []\npurpose = 'Native'",
    "network = { level = 'custom', hosts = ['example.test'] }\npurpose = 'Network'",
    "network = { level = 'custom', hosts = ['Example.test', 'example.test.'], include_trusted = false }\npurpose = 'Network'",
    "network = { level = 'custom', hosts = ['https://example.test'], include_trusted = false }\npurpose = 'Network'",
    "network = { level = 'custom', hosts = ['*'], include_trusted = false }\npurpose = 'Network'",
    "network = { level = 'custom', hosts = ['example.test'], include_trusted = false, other = true }\npurpose = 'Network'",
    "read_exceptions = [{path = '~/.config'}]", "unknown = true",
  ])
  func malformedSandboxIsRejected(fields: String) {
    #expect(throws: (any Error).self) { try manifest("\n[sandbox]\n" + fields) }
  }

  @Test func duplicateReadExceptionPathsAreRejected() {
    #expect(throws: PluginManifestError.self) {
      try manifest(
        """

        [sandbox]
        read_exceptions = [
          {path = '~/.config', purpose = 'Read configuration'},
          {path = '~/.config', purpose = 'Read the same configuration'}
        ]
        """)
    }
  }

  @Test(arguments: [
    "~", "~/", "~other/config", "/tmp/config", ".config", "$HOME/config", "~/../config",
    "~/a//b", "~/./b", "~/a/", "~/a/*", "~/a/?", "~/a/[bc]", "~/${CONFIG}",
  ])
  func readPathsMustBeHomeRelativeAndNormalized(path: String) {
    #expect(throws: (any Error).self) {
      try manifest("\n[sandbox]\nread_exceptions = [{ path = '\(path)', purpose = 'Config' }]")
    }
  }

  @Test(arguments: [
    "requirements = {}", "requirements = 'read'", "requirements = { project = 'projectWrite' }",
    "requirements = { project = 'none', full_access = false }",
    "requirements = { project = 'none', permissions = ['screen', 'screen'] }",
    "requirements = { project = 'none', permissions = ['plugin'] }",
    "requirements = { project = 'none', files_and_folders = ['downloads', 'downloads'] }",
    "requirements = { project = 'none', files_and_folders = ['unknown'] }",
    "tool_requirements = { '' = { project = 'none' } }",
    "tool_requirements = { status = { project = 'read' }, status = { project = 'write' } }",
    "host_service_contract = 'projects-v1'",
  ])
  func malformedMCPRequirementsAreRejected(fields: String) {
    #expect(throws: (any Error).self) {
      try manifest(Self.remote + "\n" + fields)
    }
  }

  @Test
  func requirementOverridesReplaceDefaultsAndAbsenceIsDistinct() throws {
    let value = try manifest(
      Self.remote + """

        requirements = { project = 'write', permissions = ['screen'] }
        tool_requirements = { status = { project = 'read' }, empty = { project = 'none' } }
        """)
    let mcp = try #require(value.mcp.first)
    #expect(mcp.requirements?.project == .write)
    #expect(mcp.toolRequirements?["status"]?.permissions == [])
    #expect(mcp.toolRequirements?["empty"]?.project == PluginToolRequirements.Project.none)
    #expect(try manifest(Self.remote).mcp[0].requirements == nil)
    let encoded = try CanonicalJSONCoding.encoder().encode(value)
    #expect(try CanonicalJSONCoding.decoder().decode(PluginManifest.self, from: encoded) == value)
  }

  @Test
  func declarationDigestIncludesOnlyReviewedDeclarationFields() throws {
    let text = "\n[[permissions]]\nid = 'project'\naccess = 'read'\npurpose = 'Read'\n"
    let original = try manifest(text + Self.remote + "\nrequirements = { project = 'read' }")
    let digest = try PluginPermissionDeclarations(original).digest()
    let renamed = try PluginManifest.parse(
      PluginManifestFixture.header.replacingOccurrences(of: "Test package", with: "Renamed")
        + text + Self.remote + "\nrequirements = { project = 'read' }" + Self.skill)
    #expect(try PluginPermissionDeclarations(renamed).digest() == digest)
    for replacement in [
      text.replacingOccurrences(of: "access = 'read'", with: "access = 'write'")
        + Self.remote + "\nrequirements = { project = 'read' }",
      text + Self.remote + "\nrequirements = { project = 'write' }",
      text.replacingOccurrences(of: "purpose = 'Read'", with: "purpose = 'Read config'")
        + Self.remote + "\nrequirements = { project = 'read' }",
      text + "\n[sandbox]\nnetwork = 'none'\npurpose = 'Offline'\n"
        + Self.remote + "\nrequirements = { project = 'read' }",
    ] {
      let changed = try manifest(replacement)
      #expect(try PluginPermissionDeclarations(changed).digest() != digest)
      #expect(try PluginStore.manifestDigest(changed) != PluginStore.manifestDigest(original))
    }
    let stdio = PluginManifestFixture.combined
    let marked = stdio.replacingOccurrences(
      of: "transport = 'stdio'", with: "transport = 'stdio'\nhost_service_contract = 'projects-v1'")
    #expect(
      try PluginPermissionDeclarations(PluginManifest.parse(stdio)).digest()
        == PluginPermissionDeclarations(PluginManifest.parse(marked)).digest())
  }

  @Test
  func canonicalNetworkAndSetOrderingStabilizeReviewIdentity() throws {
    let a = try manifest(
      """

      [sandbox]
      network = { level = 'custom', hosts = ['B.example.', 'a.example'], include_trusted = false }
      purpose = 'Network'
      """ + Self.remote
        + "\nrequirements = { project = 'none', permissions = ['skills', 'screen'] }")
    let b = try manifest(
      """

      [sandbox]
      network = { level = 'custom', hosts = ['a.example', 'b.example'], include_trusted = false }
      purpose = 'Network'
      """ + Self.remote
        + "\nrequirements = { project = 'none', permissions = ['screen', 'skills'] }")
    #expect(
      try PluginPermissionDeclarations(a).digest() == PluginPermissionDeclarations(b).digest())
  }

  @Test
  func declarationsRetainReviewedProvenanceAndLegacyEncoding() throws {
    let root = try pluginPackageFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try manifest("")
    let data = try JSONEncoder().encode(legacy)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["permissions"] == nil && object["sandbox"] == nil)
    let text =
      PluginManifestFixture.header
      + "\n[sandbox]\nfull_access = true\npurpose = 'Native'\n" + Self.skill
    try text.write(
      to: root.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8)
    let package = try PluginPackage.load(at: root)
    let source = PluginSource(kind: .development, root: root)
    let enabled = try PluginResolver.resolve(
      package: package, source: source, settings: .init(enabled: true),
      hostVersion: PluginVersion("1.0.0"), architecture: PluginHost.architecture)
    if PluginHost.platform == "macos" {
      #expect(enabled.skillRoots.count == 1 && enabled.diagnostics.isEmpty)
      #expect(
        enabled.origins.values.first?.reviewedRequirements?.sourceDigest
          == (try PluginStore.manifestDigest(package.manifest)))
    } else {
      #expect(enabled.skillRoots.isEmpty)
      #expect(enabled.diagnostics.first?.code == .platformUnsupported)
    }
    let disabled = try PluginResolver.resolve(
      package: package, source: source, settings: .init(),
      hostVersion: PluginVersion("1.0.0"), architecture: "arm64")
    #expect(
      disabled.mcpServers.isEmpty && disabled.cliCommands.isEmpty && disabled.skillRoots.isEmpty)
  }
}
