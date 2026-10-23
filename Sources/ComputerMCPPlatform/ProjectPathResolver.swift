import Foundation

package enum ProjectPathResolutionError: Error, Equatable, Sendable {
  case escapesProject
  case cannotInspectExistingAncestor(path: String, code: Int32)
}

/// Resolves project paths using native filesystem observations.
/// Callers must revalidate opened objects when performing race-sensitive mutations.
package enum ProjectPathResolver {}
