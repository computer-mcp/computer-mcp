import ComputerMCPCore
import Foundation
import Testing

@testable import ComputerMCPControlPlane

struct OAuthApprovalProfileTests {
  @Test func digestHasACanonicalCrossPlatformEncoding() throws {
    var grant = ProfileGrant(
      id: .cloudflareObserve, capabilityIDs: ["file.write", "file.read"],
      workspaceIDs: ["z", "a"], allowedCallers: [.localCLI, .cloudflareTunnel],
      mcpServerIDs: ["two", "one"], mode: .workspaceOperations,
      confirmationPolicy: .allWrites)
    let digest = try OAuthApprovalProfile(grant: grant).authorizationDigest
    #expect(digest == "b1edbbfd51125b84cdf116dc9cd019127e726a90cd7d6a3263c103d5ba3837c0")
    grant.capabilityIDs = Set(["file.read", "file.write"])
    grant.workspaceIDs = Set(["a", "z"])
    grant.allowedCallers = Set([.cloudflareTunnel, .localCLI])
    grant.mcpServerIDs = Set(["one", "two"])
    grant.authorizationRevision += 42
    grant.id = .cloudflareOperate
    #expect(try OAuthApprovalProfile(grant: grant).authorizationDigest == digest)
  }

  @Test func everyAuthorizationFieldContributesToTheDigest() throws {
    let original = ProfileGrant.cloudflareObserve
    let digest = try OAuthApprovalProfile(grant: original).authorizationDigest
    var variants: [ProfileGrant] = []
    var changed = original
    changed.mode = .workspaceOperations
    variants.append(changed)
    changed = original
    changed.capabilityIDs.insert("file.read")
    variants.append(changed)
    changed = original
    changed.workspaceIDs.insert("workspace")
    variants.append(changed)
    changed = original
    changed.allowedCallers.insert(.localCLI)
    variants.append(changed)
    changed = original
    changed.fullShellEnabled = true
    variants.append(changed)
    changed = original
    changed.mcpServerIDs.insert("integration")
    variants.append(changed)
    changed = original
    changed.confirmationPolicy = .allWrites
    variants.append(changed)
    for variant in variants {
      #expect(try OAuthApprovalProfile(grant: variant).authorizationDigest != digest)
    }
  }
}
