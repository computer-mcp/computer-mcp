import ComputerMCPPlatform
import Foundation

/// Stores Keychain items in memory, keyed by service and account.
package final class MemoryKeychainAdapter: KeychainAdapter, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]

  package init() {}

  package var accounts: [String] {
    lock.lock()
    defer { lock.unlock() }
    return values.keys.sorted()
  }

  package func set(service: String, account: String, data: Data) throws {
    lock.lock()
    values["\(service):\(account)"] = data
    lock.unlock()
  }

  package func get(service: String, account: String) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return values["\(service):\(account)"]
  }

  package func delete(service: String, account: String) throws {
    lock.lock()
    values.removeValue(forKey: "\(service):\(account)")
    lock.unlock()
  }
}
