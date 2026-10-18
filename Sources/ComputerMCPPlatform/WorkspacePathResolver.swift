import Foundation

package enum WorkspacePathResolutionError: Error, Equatable, Sendable {
  case escapesWorkspace
  case cannotInspectExistingAncestor(path: String, code: Int32)
}

/// Resolves workspace paths using native filesystem observations.
/// Callers must revalidate opened objects when performing race-sensitive mutations.
package enum WorkspacePathResolver {}
