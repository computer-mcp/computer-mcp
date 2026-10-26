import Foundation

package enum ManagedPolicySourceID: String, CaseIterable, Sendable, Codable {
  case machineFile, managedPreferences
}

package enum ManagedPolicyReadStatus: Equatable, Sendable {
  case absent
  case available(Data)
  /// Diagnostics describe the source, never include policy contents.
  case unreadable(String)
}

package struct ManagedPolicySourceSnapshot: Equatable, Sendable {
  package let source: ManagedPolicySourceID
  package let location: String
  package let status: ManagedPolicyReadStatus

  package init(source: ManagedPolicySourceID, location: String, status: ManagedPolicyReadStatus) {
    self.source = source
    self.location = location
    self.status = status
  }
}

/// Bounded local reads and path acquisition before admission and owner transactions.
/// Implementations return both sources even when absent or unreadable.
package protocol ManagedPolicyReading: Sendable {
  func readSources() -> [ManagedPolicySourceSnapshot]
  func canonicalPolicyPath(_ path: String) throws -> String
}
