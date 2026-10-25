import Foundation

/// Facts resolved and attributed by the host, never an authority assertion from
/// tool arguments. A path includes the operation that the sandbox refused.
package enum DiscoveredRequirement: Hashable, Sendable, Codable {
  case path(PathRequirement)
  case network(NetworkRequirement)
}

package enum DiscoveredRequirementDecision: Equatable, Sendable {
  case satisfied
  case requests([PermissionRequest])
  case denied(DenialReason)
}

struct RuntimeRetryChain: Equatable, Sendable, Codable {
  let invocation: InvocationIdentity
  let originalRequirements: InvocationRequirements
  let requirements: InvocationRequirements
  let carriedIDs: Set<UUID>
}
