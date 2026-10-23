import ComputerMCPCore
import Foundation
import Testing

@testable import ComputerMCPControlPlane

struct OAuthApprovalProfileTests {
  @Test func digestHasACanonicalCrossPlatformEncoding() throws {
    var grant = ProfileGrant(
      id: .cloudflareObserve, capabilityIDs: ["file.write", "file.read"],
      projectIDs: ["z", "a"], allowedCallers: [.localCLI, .cloudflareTunnel],
      mcpServerIDs: ["two", "one"], mode: .projectOperations,
      confirmationPolicy: .allWrites)
    let digest = try OAuthApprovalProfile(grant: grant).authorizationDigest
    #expect(digest == "e8306ba71960006b18d3f20d849982ff45e7de46eef91d56c476c261d7881d0d")
    grant.capabilityIDs = Set(["file.read", "file.write"])
    grant.projectIDs = Set(["a", "z"])
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
    changed.mode = .projectOperations
    variants.append(changed)
    changed = original
    changed.capabilityIDs.insert("file.read")
    variants.append(changed)
    changed = original
    changed.projectIDs.insert("project")
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
