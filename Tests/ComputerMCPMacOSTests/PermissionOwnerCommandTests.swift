import ArgumentParser
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPGateway
import Foundation
import Testing

@testable import computer_mcp

@Suite struct PermissionOwnerCommandTests {
  @Test(arguments: ProjectAccess.allCases)
  func projectAccessRequiresAnExplicitChoiceAndBothReviewedRevisions(access: ProjectAccess) throws {
    let arguments = [
      "project", "--profile", "chatgpt-operate", "--access", access.rawValue,
      "--expected-profile-revision", "7", "--expected-permission-revision", "11",
    ]
    let command = try ProjectAccessCommand.parse(arguments)
    #expect(command.access == access.rawValue)
    #expect(command.expectedProfileRevision == 7 && command.expectedPermissionRevision == 11)
    for missing in ["--access", "--expected-profile-revision", "--expected-permission-revision"] {
      var incomplete = arguments
      let index = try #require(incomplete.firstIndex(of: missing))
      incomplete.removeSubrange(index...index + 1)
      #expect(throws: (any Error).self) { try ProjectAccessCommand.parse(incomplete) }
    }
    #expect(throws: (any Error).self) {
      try ProjectAccessCommand.parse([
        "project", "--profile", "chatgpt-operate", "--access", "enable",
        "--expected-profile-revision", "7", "--expected-permission-revision", "11",
      ])
    }
  }

  @Test func oauthApprovalRequiresAnExplicitProfile() throws {
    #expect(throws: (any Error).self) { try Clients.Authorize.parse(["PAIRING"]) }
    let explicit = try Clients.Authorize.parse(["PAIRING", "--profile", "cloudflare-observe"])
    #expect(explicit.profile == "cloudflare-observe")
  }

  @Test func recoveryRequiresAnEpochRevisionAndCompleteReviewedProfilesFile() throws {
    let epoch = UUID().uuidString
    #expect(throws: (any Error).self) {
      try PermissionConfirmAuthority.parse([
        "--epoch", epoch, "--expected-permission-revision", "9",
      ])
    }
    #expect(throws: (any Error).self) {
      try PermissionConfirmAuthority.parse([
        "--epoch", "invalid", "--expected-permission-revision", "9", "--profiles-file",
        "reviewed.json",
      ])
    }
    let command = try PermissionConfirmAuthority.parse([
      "--epoch", epoch, "--expected-permission-revision", "9", "--profiles-file", "reviewed.json",
    ])
    #expect(command.epoch == epoch)
    #expect(command.expectedPermissionRevision == 9)
    #expect(command.profilesFile == "reviewed.json")
  }

  @Test func localEntrypointsBindStableHostIdentityWithoutChangingSelectedPolicy() throws {
    let original = ExecutionContext(
      caller: .secureTunnel, profileID: .chatGPTObserve,
      projectID: "reviewed-project",
      transportTrace: .init(transport: "stdio", socketConnectionID: "connection"),
      trustedPrincipalID: "caller-supplied")
    let first = LocalCLIExecutionIdentity.bind(original, surface: .stdio)
    let reconnect = LocalCLIExecutionIdentity.bind(original, surface: .stdio)
    let owner = LocalCLIExecutionIdentity.bind(original, surface: .ownerTools)
    #expect(
      first.trustedPrincipalID != nil && first.trustedPrincipalID != original.trustedPrincipalID)
    #expect(first.trustedPrincipalID == reconnect.trustedPrincipalID)
    #expect(first.trustedPrincipalID != owner.trustedPrincipalID)
    #expect(first.caller == original.caller && first.profileID == original.profileID)
    #expect(first.projectID == original.projectID && first.requestID == original.requestID)
    #expect(first.transportTrace == original.transportTrace)
    #expect(
      try GatewayPermissionSubject(context: first) == GatewayPermissionSubject(context: reconnect))
    #expect(
      try GatewayPermissionSubject(context: first) != GatewayPermissionSubject(context: owner))
  }

  @Test func standaloneAuthorityNamespaceSurvivesReplacementAtTheSameLogicalLocation() throws {
    let location = URL(fileURLWithPath: "/tmp/standalone-authority/gateway.sqlite")
    let equivalent = URL(fileURLWithPath: "/tmp/standalone-authority/sub/../gateway.sqlite")
    #expect(
      StandalonePermissionAuthority.namespace(for: location)
        == StandalonePermissionAuthority.namespace(for: equivalent))
    #expect(
      StandalonePermissionAuthority.namespace(for: location)
        != StandalonePermissionAuthority.namespace(
          for: location.deletingLastPathComponent().appendingPathComponent("other.sqlite")))
  }
}
