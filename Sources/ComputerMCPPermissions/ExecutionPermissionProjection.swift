import Foundation

/// Openings selected by the same resolver as host file operations. Construction
/// belongs to the ledger so every opening is saved in the authorization's basis.
package struct ExecutionPermissionProjection: Sendable {
  package let authorization: InvocationAuthorization
  package let readablePaths: [PathAccessBasis]
  package let directoryPaths: [PathAccessBasis]
  package let forbiddenPaths: Set<CanonicalPath>
  package let boundaries: Set<CanonicalPath>
  package let network: NetworkAccess.Configuration
  package let screenCapture: Bool
  package let accessibility: Bool
  package let localNetwork: Bool
  package let localNetworkHosts: Set<String>
  package let limits: EffectiveExecutionLimits
}
