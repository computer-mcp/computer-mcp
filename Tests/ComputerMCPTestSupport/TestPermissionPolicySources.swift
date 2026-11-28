import ComputerMCPPlatform
import Foundation

package final class TestAuthorizationEpochCounter: AuthorizationEpochCounter, @unchecked Sendable {
  private let lock = NSLock()
  private let access = Access()
  package init() {}
  private final class Registry: @unchecked Sendable {
    let lock = NSLock()
    var counters: [String: TestAuthorizationEpochCounter] = [:]
  }
  private static let registry = Registry()
  package static func shared(forDatabasePath path: String) -> TestAuthorizationEpochCounter {
    let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return registry.lock.withLock {
      if let counter = registry.counters[key] { return counter }
      let counter = TestAuthorizationEpochCounter()
      registry.counters[key] = counter
      return counter
    }
  }
  package func withExclusiveAccess<Result>(
    _ body: (any AuthorizationEpochCounterAccess) throws -> Result
  ) throws -> Result {
    try lock.withLock { try body(access) }
  }
  package func forget() { lock.withLock { access.watermark = nil } }
  private final class Access: AuthorizationEpochCounterAccess {
    var watermark: AuthorizationEpochWatermark?
    func read() throws -> AuthorizationEpochWatermark? { watermark }
    func advance(to watermark: AuthorizationEpochWatermark) throws { self.watermark = watermark }
  }
}

package final class TestManagedPolicyReader: ManagedPolicyReading, @unchecked Sendable {
  private let lock = NSLock()
  private var statuses: [ManagedPolicySourceID: ManagedPolicyReadStatus] = [:]
  package init() {}
  package func set(_ source: ManagedPolicySourceID, _ value: ManagedPolicyReadStatus) {
    lock.withLock { statuses[source] = value }
  }
  package func canonicalPolicyPath(_ path: String) throws -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }
  package func readSources() -> [ManagedPolicySourceSnapshot] {
    lock.withLock {
      ManagedPolicySourceID.allCases.map {
        .init(source: $0, location: "fixture/" + $0.rawValue, status: statuses[$0] ?? .absent)
      }
    }
  }
}
