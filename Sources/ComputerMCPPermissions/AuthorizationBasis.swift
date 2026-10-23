import Foundation

/// A concrete requirement pinned to the identity and generation of its grant.
package struct PermissionGrant: Hashable, Sendable, Codable {
  package enum Source: Hashable, Sendable, Codable {
    case standing(entry: Permission, id: BasisIdentity)
    case onlyThisTime(request: BasisIdentity, permit: BasisIdentity)

    var requestID: UUID? {
      if case .onlyThisTime(let request, _) = self { return request.id }
      return nil
    }
  }

  package let principal: Principal
  package let requirement: PermissionRequirement
  package let scope: RequestScope
  package let pluginPurpose: String?
  package let source: Source
}

/// The path and classification used to construct access rules. Ancestor access
/// names the readable descendant; that descendant has its own basis in the set.
/// Read/write rules cover a subtree minus exclusions. A different classification
/// needs its own basis, even when it is also readable. Directory traversal covers
/// only the named directory.
package struct PathAccessBasis: Hashable, Sendable, Codable {
  package enum Location: Hashable, Sendable, Codable {
    case project(ProjectLocation)
    case folder(FolderCategory, root: CanonicalPath)
    case developer(CanonicalPath)
    case systemOrApplication(CanonicalPath)
    case outsideUserData, userData
  }

  package let path: CanonicalPath
  package let operation: PathOperation
  package let location: Location
  package let readableDescendant: CanonicalPath?
  package let sandboxProjectID: String?
  package let excludedSubtrees: Set<CanonicalPath>?
  let ruleIdentities: Set<BasisIdentity>

  var requirement: PermissionRequirement? {
    switch location {
    case .project(let project):
      try! PermissionRequirement(.project(project.projectID), operation == .write ? .write : .read)
    case .folder(let category, _): try! PermissionRequirement(.filesAndFolders(category), .read)
    default: nil
    }
  }
}

/// The resolver emits this same immutable evidence that the ledger persists and
/// validates. Every element must remain valid for the lifetime of the invocation.
/// Every identity and modification generation survives serialization.
package enum AuthorizationBasis: Hashable, Sendable, Codable {
  case mode(ExecutionMode)
  case managed(source: PolicySource, identity: BasisIdentity)
  case consent(BasisIdentity)
  case managedPermission(source: PolicySource, grant: PermissionGrant)
  case permission(PermissionGrant)
  case path(PathAccessBasis)
  /// Traversal may replace a missing grant, but still obeys its denials and ceilings.
  case traversal(PermissionRequirement)
  /// A requested condition, shared by all requests for the originating call.
  case request(BasisIdentity)
  case permit(request: BasisIdentity, identity: BasisIdentity)
  case network(NetworkAccessBasis)
  /// The sandbox profile used by the entire invocation, including implicit access.
  case sandbox(SandboxAccessBasis)

  var requestID: UUID? {
    switch self {
    case .permission(let grant):
      return grant.source.requestID
    case .request(let identity), .permit(let identity, _): return identity.id
    case .mode, .consent, .managed, .managedPermission, .path, .traversal, .network, .sandbox:
      return nil
    }
  }
}

struct PermissionResolution {
  let decision: PermissionDecision
  var basis: Set<AuthorizationBasis> = []
}

/// The network rule that admitted a host, independent of Local network permission.
package struct NetworkAccessBasis: Hashable, Sendable, Codable {
  package enum Source: Hashable, Sendable, Codable {
    case full, custom, trusted
  }

  package let host: String
  package let projectID: String
  package let source: Source
  package let policySource: PolicySource?
  package let ruleIdentity: BasisIdentity
  package let trustedHostIdentity: BasisIdentity?

  func isValid(access: NetworkAccess, trustedHosts: Set<HostRule>) -> Bool {
    guard access.identity(for: source, host: host) == ruleIdentity else { return false }
    if source == .trusted {
      return trustedHosts.contains { $0.host == host && $0.identity == trustedHostIdentity }
    }
    return true
  }

}

/// The complete sandbox profile admitted for one source project. Effective network
/// access includes the trusted-host snapshot and managed ceilings at admission.
package struct SandboxAccessBasis: Hashable, Sendable, Codable {
  let projectID: String?
  let settings: SandboxSettings
  let managedDeniedReadLocations: Set<CanonicalPath>
  let network: NetworkAccess.Configuration
}

extension Set where Element == AuthorizationBasis {
  func networkRule(for content: NetworkRequestContent, policySource: PolicySource? = nil)
    -> NetworkAccessBasis?
  {
    for element in self {
      if case .network(let basis) = element, basis.host == content.host,
        basis.projectID == content.projectID, basis.policySource == policySource
      {
        return basis
      }
    }
    return nil
  }

  func permissionGrant(
    for requirement: PermissionRequirement, scope: RequestScope, pluginPurpose: String?,
    oneTimeRequests: [PermissionRequest]
  ) -> PermissionGrant? {
    first { element in
      guard case .permission(let grant) = element,
        grant.requirement == requirement, grant.scope == scope, grant.pluginPurpose == pluginPurpose
      else { return false }
      if let id = grant.source.requestID {
        return oneTimeRequests.contains { $0.id == id && $0.status == .onlyThisTime }
      }
      return true
    }.flatMap {
      if case .permission(let grant) = $0 { return grant }
      return nil
    }
  }
}
