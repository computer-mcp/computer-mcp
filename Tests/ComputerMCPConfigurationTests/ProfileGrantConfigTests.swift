import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore

@Suite
struct ProfileGrantConfigTests {
  @Test
  func newProfilesHaveNoImplicitTransportOrWriteAuthority() {
    let config = ProfileGrantConfig(id: .chatGPTOperate, capabilities: ["file.write"])
    #expect(config.allowedCallers.isEmpty)
    #expect(config.mode == .readOnly)
    #expect(config.confirmationPolicy == .riskBased)
    #expect(!config.grant.permitsRisk(.projectWrite))
  }

  @Test
  func explicitModeDoesNotInferTransportFromProfileName() throws {
    let config = try decode(
      #"{"id":"chatgpt-operate","mode":"project-operations","capabilities":["file.write"]}"#)
    #expect(config.allowedCallers.isEmpty)
    #expect(config.mode == .projectOperations)
  }

  @Test
  func legacyProfilesPreserveRiskAndCallerRestrictions() throws {
    let observe = try decode(#"{"id":"cloudflare-observe","capabilities":["*"]}"#)
    #expect(observe.mode == .readOnly)
    #expect(observe.allowedCallers == [.cloudflareTunnel])
    #expect(!observe.grant.permitsRisk(.projectWrite))

    let operate = try decode(
      #"{"id":"chatgpt-operate","capabilities":["file.write"],"projects":["project"]}"#)
    #expect(operate.mode == .projectOperations)
    #expect(operate.allowedCallers == [.secureTunnel])
    #expect(!operate.fullShellEnabled)
    #expect(operate.capabilities == ["file.write"])
    #expect(operate.projects == ["project"])

    let fullAccess = try decode(
      #"{"id":"chatgpt-operate","full_shell_enabled":true,"capabilities":["shell.run"]}"#)
    #expect(fullAccess.mode == .localFullAccess)
    #expect(fullAccess.fullShellEnabled)
    #expect(fullAccess.capabilities == ["shell.run"])
    #expect(fullAccess.confirmationPolicy == .riskBased)

    let custom = try decode(
      #"{"id":"custom","capabilities":["file.write"],"allowed_callers":["local-mcp"]}"#)
    #expect(custom.mode == .projectOperations)
    #expect(custom.allowedCallers == [.localMCP])
  }

  @Test
  func legacyInvalidExecutionGrantCannotBecomeAuthorized() throws {
    for id in ["chatgpt-observe", "cloudflare-operate", "custom"] {
      let config = try decode("{\"id\":\"\(id)\",\"full_shell_enabled\":true}")
      #expect(throws: GatewayPolicyConfigurationError.fullShellRequiresFullAccess) {
        try config.grant.validate()
      }
    }
  }

  @Test
  func currentPolicyRoundTripsExplicitly() throws {
    let config = ProfileGrantConfig(
      id: GatewayProfileID(rawValue: "external-client")!, capabilities: ["file.write"],
      projects: ["one"], allowedCallers: [.cloudflareTunnel],
      mode: .projectOperations, confirmationPolicy: .allWrites)
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(ProfileGrantConfig.self, from: data) == config)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["mode"] as? String == "project-operations")
    #expect(object["confirmation_policy"] as? String == "all-writes")
  }

  @Test
  func storedLegacyGrantMigratesWithoutAddingCapabilities() throws {
    let json =
      #"{"id":"chatgpt-operate","capabilityIDs":["file.write"],"projectIDs":["one"],"allowedCallers":["secure-tunnel"],"fullShellEnabled":false}"#
    let grant = try JSONDecoder().decode(ProfileGrant.self, from: Data(json.utf8))
    #expect(grant.mode == .projectOperations)
    #expect(grant.capabilityIDs == ["file.write"])
    #expect(grant.projectIDs == ["one"])
    #expect(!grant.supportsFullShell)
    #expect(grant.confirmationPolicy == .riskBased)
    #expect(try JSONDecoder().decode(ProfileGrant.self, from: JSONEncoder().encode(grant)) == grant)
  }

  @Test
  func unknownModesAndConfirmationPoliciesFailClosed() {
    #expect(throws: DecodingError.self) {
      try decode(#"{"id":"client","mode":"unrestricted"}"#)
    }
    #expect(throws: DecodingError.self) {
      try decode(#"{"id":"client","confirmation_policy":"sometimes"}"#)
    }
  }

  private func decode(_ json: String) throws -> ProfileGrantConfig {
    try JSONDecoder().decode(ProfileGrantConfig.self, from: Data(json.utf8))
  }
}
