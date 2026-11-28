import ComputerMCPPermissions
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore

@Suite struct ProfileGrantConfigTests {
  @Test func callerAdmissionAndPermissionDefaultsAreExplicit() throws {
    let config = ProfileGrantConfig(id: .chatGPTOperate)
    #expect(config.grant.allowedCallers.isEmpty)
    #expect(config.grant.permissions.entries.isEmpty)
    #expect(!config.grant.fullAccess)
    let decoded = try JSONDecoder().decode(
      ProfileGrantConfig.self,
      from: Data(#"{"id":"chatgpt-operate","allowed_callers":[]}"#.utf8))
    #expect(decoded == config)
    let unknown = try #require(GatewayProfileID(rawValue: "unknown"))
    #expect(GatewayConfiguration().profileGrant(for: unknown).allowedCallers.isEmpty)
  }

  @Test func wrapperUsesThePublicManifestCodec() throws {
    var grant = ProfileGrant.newPrincipal(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    try grant.permissions.set(.granted(.write), for: .project("one"))
    try grant.permissions.set(.denied, for: .screen)
    grant.projectNetworks["one"] = .custom(hosts: ["example.com"], includesTrusted: true)
    let config = ProfileGrantConfig(grant: grant)
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(ProfileGrantConfig.self, from: data) == config)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["permissions"] != nil)
    #expect(object["projects"] is [String: Any])
    #expect(object["authorization_revision"] == nil)
  }

  @Test func newPrincipalDefaultsAreSeparateFromEmptyProfiles() {
    let grant = ProfileGrant.newPrincipal(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    #expect(grant.permissions.state(for: .machineInformation) == .granted(.access))
    #expect(grant.permissions.state(for: .skills) == .granted(.access))
    #expect(grant.permissions.state(for: .project("future")) == .notGranted)
    #expect(grant.permissions.state(for: .screen) == .notGranted)
    #expect(!grant.fullAccess)
  }

  @Test(arguments: [
    ("capabilities = []", "permissions"), ("workspaces = []", "projects"),
    ("mode = ''", "full_access"), ("full_shell_enabled = false", "full_access"),
    ("confirmation_policy = ''", "permission grants"), ("projects = []", "access and network"),
    ("mcp_servers = []", "read, all or deny"), ("authorization_revision = 0", "host-owned"),
  ]) func publicConfigurationNamesOldFieldReplacement(_ fixture: (String, String)) {
    let text = """
      schema_version = 1
      [[profiles]]
      id = "fixture"
      allowed_callers = []
      \(fixture.0)
      """
    do {
      _ = try GatewayConfiguration.load(text: text)
      Issue.record("Accepted an obsolete profile field")
    } catch { #expect(String(describing: error).contains(fixture.1)) }
  }

  @Test func ownedManifestUpgradeRetiresLegacyProcessTeardownSetting() throws {
    let text = """
      schema_version = 1
      [policy]
      shell_termination_grace_ms = 1000
      [[profiles]]
      id = "chatgpt-operate"
      capabilities = ["skills.read"]
      """
    let source = try PermissionManifestUpgrade.source(manifest: text)
    #expect(source.profiles[0].capabilityIDs == ["skills.read"])
    let exported = try source.configuration.exportedTOML()
    #expect(!exported.contains("shell_termination_grace_ms"))
    #expect(throws: (any Error).self) {
      try PermissionManifestUpgrade.source(
        manifest: text.replacingOccurrences(
          of: "shell_termination_grace_ms", with: "unrecognized_policy"))
    }
    #expect(throws: (any Error).self) {
      try GatewayConfiguration.load(
        text: "schema_version = 1\n[policy]\nshell_termination_grace_ms = 1000\n")
    }
  }

  @Test func publicConfigurationRoundTripsPermissionTables() throws {
    let text = """
      schema_version = 1
      [[profiles]]
      id = "fixture"
      allowed_callers = ["secure-tunnel"]
      [profiles.permissions]
      screen = "deny"
      [profiles.projects]
      "*" = { access = "write", network = "none" }
      [profiles.mcp_servers]
      "*" = "read"
      """
    let config = try GatewayConfiguration.load(text: text)
    let exported = try config.exportedTOML()
    #expect(try GatewayConfiguration.load(text: exported).profiles == config.profiles)
    #expect(config.profiles[0].grant.permissions.state(for: .screen) == .denied)
  }

  @Test(arguments: [
    "capabilities = []", "full_shell_enabled = false", "projects = []", "mcp_servers = []",
  ])
  func ownedManifestUpgradeUsesStructuralPresence(_ field: String) throws {
    let text = "schema_version = 1\n[[profiles]]\nid = 'chatgpt-operate'\n\(field)\n"
    #expect(try PermissionManifestUpgrade.isRequired(manifest: text))
    let source = try PermissionManifestUpgrade.source(manifest: text)
    #expect(source.profiles.count == 1)
    let profile = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    let upgraded = try PermissionManifestUpgrade.upgraded(manifest: text, profiles: [profile])
    let exported = try upgraded.exportedTOML()
    #expect(try !PermissionManifestUpgrade.isRequired(manifest: exported))
    #expect(try GatewayConfiguration.load(text: exported).profiles[0].grant == profile)
    #expect(upgraded.profiles[0].grant.permissions.entries.isEmpty)
  }
}
