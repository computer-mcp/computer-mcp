import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import CryptoKit
import Foundation

/// A host-owned namespace shared by all writers, independent of the selected
/// database path. Keep its lock directory stable across database replacement.
/// Keychain interaction fails without prompting while the SQLite lock is held.
package struct KeychainAuthorizationEpochCounter: AuthorizationEpochCounter {
  private let keychain: any KeychainAdapter
  private let service: String
  private let account: String
  private let lockURL: URL
  private let lockTimeout: Duration

  package init(
    keychain: any KeychainAdapter, lockDirectory: URL,
    service: String, account: String, lockTimeout: Duration = .seconds(5)
  ) throws {
    self.keychain = keychain
    self.service = service
    self.account = account
    self.lockTimeout = lockTimeout
    let namespace = try JSONEncoder().encode([service, account])
    let digest = SHA256.hash(data: namespace).map { String(format: "%02x", $0) }.joined()
    try FileManager.default.createDirectory(
      at: lockDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    lockURL = lockDirectory.appendingPathComponent("authorization-epoch-\(digest).lock")
  }

  package func withExclusiveAccess<Result>(
    _ body: (any AuthorizationEpochCounterAccess) throws -> Result
  ) throws -> Result {
    let deadline = ContinuousClock.now.advanced(by: lockTimeout)
    let lock: FileLock
    while true {
      do {
        lock = try FileLock(path: lockURL.path, mode: .exclusive)
        break
      } catch FileLockError.held where ContinuousClock.now < deadline {
        Thread.sleep(forTimeInterval: 0.005)
      }
    }
    defer { lock.release() }
    return try body(Access(keychain: keychain, service: service, account: account))
  }

  private struct Access: AuthorizationEpochCounterAccess {
    let keychain: any KeychainAdapter
    let service: String
    let account: String

    func read() throws -> AuthorizationEpochWatermark? {
      guard let data = try keychain.get(service: service, account: account, authenticationUI: .fail)
      else { return nil }
      guard let watermark = try? JSONDecoder().decode(AuthorizationEpochWatermark.self, from: data),
        watermark.revision > 0, watermark.revision <= UInt64(Int64.max)
      else {
        throw AuthorizationEpochCounterError.invalidRecord
      }
      return watermark
    }

    func advance(to watermark: AuthorizationEpochWatermark) throws {
      guard watermark.revision > 0, watermark.revision <= UInt64(Int64.max) else {
        throw AuthorizationEpochCounterError.revisionExhausted
      }
      guard watermark.revision > (try read()?.revision ?? 0) else {
        throw AuthorizationEpochCounterError.nonMonotonicWrite
      }
      try keychain.set(
        service: service, account: account,
        data: JSONEncoder().encode(watermark), authenticationUI: .fail)
    }
  }
}
