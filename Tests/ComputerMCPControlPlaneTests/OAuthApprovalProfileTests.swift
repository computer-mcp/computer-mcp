import ComputerMCPCore
import ComputerMCPPermissions
import Foundation
import Testing

@testable import ComputerMCPControlPlane

struct OAuthApprovalProfileTests {
  @Test func digestIgnoresOrderIdentityAndPersistenceRevision() throws {
    var first = ProfileGrant(
      id: .cloudflareObserve, allowedCallers: [.cloudflareTunnel, .localCLI])
    try first.permissions.set(.granted(.read), for: .project("a"))
    try first.permissions.set(.granted(.write), for: .project("z"))
    first.projectNetworks["a"] = .custom(
      hosts: ["example.com", "swift.org"], includesTrusted: false)
    var second = ProfileGrant(
      id: .cloudflareOperate, allowedCallers: [.localCLI, .cloudflareTunnel],
      authorizationRevision: 42)
    try second.permissions.set(.granted(.write), for: .project("z"))
    try second.permissions.set(.granted(.read), for: .project("a"))
    second.projectNetworks["a"] = .custom(
      hosts: ["swift.org", "example.com"], includesTrusted: false)
    #expect(
      try OAuthApprovalProfile(grant: first).authorizationDigest
        == OAuthApprovalProfile(grant: second).authorizationDigest)
  }

  @Test func everyAuthorizationFieldContributesToTheDigest() throws {
    let original = ProfileGrant.cloudflareObserve
    let digest = try OAuthApprovalProfile(grant: original).authorizationDigest
    var variants: [ProfileGrant] = []
    var changed = original
    try changed.permissions.set(.granted(.read), for: .project("project"))
    variants.append(changed)
    changed = original
    changed.projectNetworks["project"] = .trusted
    variants.append(changed)
    changed = original
    changed.allowedCallers.insert(.localCLI)
    variants.append(changed)
    changed = original
    changed.fullAccess = true
    variants.append(changed)
    for variant in variants {
      #expect(try OAuthApprovalProfile(grant: variant).authorizationDigest != digest)
    }
  }
}
