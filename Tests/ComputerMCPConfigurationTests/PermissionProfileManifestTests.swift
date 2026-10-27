import ComputerMCPCore
import ComputerMCPPermissions
import Testing

@testable import ComputerMCPConfiguration

@Suite struct PermissionProfileManifestTests {
  private let prefix = """
    [[profiles]]
    id = "fixture"
    allowed_callers = ["secure-tunnel"]
    """

  @Test func roundTripExplicitDenyWildcardsAndCustomNetwork() throws {
    let text =
      prefix + """

        full_access = false
        [profiles.permissions]
        screen = "allow"
        unified-logs = "deny"
        [profiles.projects]
        "*" = { access = "write", network = "none" }
        concrete = { access = "deny", network = { level = "custom", hosts = ["registry.npmjs.org"], include_trusted = true } }
        [profiles.files_and_folders]
        downloads = "read"
        [profiles.plugins]
        "*" = "use"
        disabled = "deny"
        [profiles.mcp_servers]
        "*" = "all"
        restricted = "read"
        [profiles.automation]
        "com.apple.Notes" = "allow"
        """
    let profile = try #require(PermissionProfileManifest.decode(text).first)
    #expect(profile.permissions.state(for: .project("future")) == .granted(.write))
    #expect(profile.permissions.state(for: .project("concrete")) == .denied)
    #expect(profile.permissions.state(for: .machineInformation) == .notGranted)
    #expect(profile.permissions.state(for: .unifiedLogs) == .denied)
    #expect(profile.authorizationRevision == 1)
    let encoded = try PermissionProfileManifest.encode([profile])
    #expect(!encoded.contains("authorization_revision"))
    #expect(try PermissionProfileManifest.decode(encoded) == [profile])
    #expect(
      try PermissionProfileManifest.encode(PermissionProfileManifest.decode(encoded)) == encoded)
  }

  @Test(arguments: [
    ("capabilities = []", "permissions"), ("workspaces = []", "projects"),
    ("mode = ''", "full_access"), ("full_shell_enabled = false", "full_access"),
    ("confirmation_policy = ''", "permission grants"), ("projects = []", "access and network"),
    ("mcp_servers = []", "read, all or deny"), ("authorization_revision = 0", "host-owned"),
  ]) func oldFieldsNameReplacement(_ fixture: (String, String)) throws {
    do {
      _ = try PermissionProfileManifest.decode(prefix + "\n" + fixture.0)
      Issue.record("Accepted an obsolete field")
    } catch { #expect(String(describing: error).contains(fixture.1)) }
  }

  @Test(arguments: [
    "[profiles.permissions]\nscreen = 'read'", "[profiles.permissions]\nunknown = 'allow'",
    "[profiles.automation]\n'*' = 'allow'",
    "[profiles.projects]\np = { access = 'read', network = { level = 'custom', hosts = ['https://example.com'], include_trusted = false } }",
    "[profiles.projects]\np = { access = 'read', network = { level = 'custom', hosts = [] } }",
  ]) func invalidValuesFail(_ suffix: String) {
    #expect(throws: (any Error).self) {
      try PermissionProfileManifest.decode(prefix + "\n" + suffix)
    }
  }

  @Test func unrepresentableOverrideCannotExpandWildcard() throws {
    var profile = ProfileGrant.newPrincipal(
      id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    try profile.permissions.set(.granted(.all), for: .mcpServer("*"))
    try profile.permissions.set(.notGranted, for: .mcpServer("limited"))
    #expect(throws: (any Error).self) { try PermissionProfileManifest.encode([profile]) }
  }

  @Test func accessOverrideDoesNotReplaceNetworkFallback() throws {
    let text =
      prefix + """

        [profiles.projects]
        "*" = { access = "write", network = "full" }
        concrete = { access = "read" }
        """
    let profile = try #require(PermissionProfileManifest.decode(text).first)
    #expect(profile.projectNetworks["concrete"] == nil)
    #expect(profile.projectNetworks["*"] == .full)
    #expect(
      try PermissionProfileManifest.decode(PermissionProfileManifest.encode([profile])) == [profile]
    )
  }

  @Test func networkOverrideDoesNotCreateAnAccessGrant() throws {
    let text =
      prefix + """

        [profiles.projects]
        "*" = { access = "write", network = "none" }
        concrete = { network = { level = "custom", hosts = [], include_trusted = false } }
        """
    let profile = try #require(PermissionProfileManifest.decode(text).first)
    #expect(profile.permissions.entries[.project("concrete")] == nil)
    #expect(profile.permissions.state(for: .project("concrete")) == .granted(.write))
    #expect(
      profile.projectNetworks["concrete"]?.configuration
        == .custom(hosts: [], includesTrusted: false))
    #expect(
      try PermissionProfileManifest.decode(PermissionProfileManifest.encode([profile])) == [profile]
    )
  }
}
