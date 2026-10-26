import Foundation

package enum HostPathOperation: Sendable {
  case read, write, openDirectory, listDirectory
}

/// Invoked with host-resolved paths at use time. Mutators additionally retain and
/// revalidate descriptor identity; this check never replaces those guards.
package protocol HostPathAccessChecking: Sendable {
  func check(_ path: URL, operation: HostPathOperation) throws
}

package enum HostPathAccess {
  @TaskLocal package static var current: (any HostPathAccessChecking)?
}
