import Foundation

package enum HostPathOperation: Sendable {
  case read, write, openDirectory, listDirectory
}

/// Invoked with host-resolved paths at use time. Mutators additionally retain and
/// revalidate descriptor identity; this check never replaces those guards.
package protocol HostPathAccessChecking: Sendable {
  func check(_ path: URL, operation: HostPathOperation) throws
  /// Directory inventories omit inaccessible children without requesting new access.
  func isAccessible(_ path: URL, operation: HostPathOperation) -> Bool
}

extension HostPathAccessChecking {
  package func isAccessible(_ path: URL, operation: HostPathOperation) -> Bool {
    (try? check(path, operation: operation)) != nil
  }
}

package enum HostPathAccess {
  @TaskLocal package static var current: (any HostPathAccessChecking)?
}
