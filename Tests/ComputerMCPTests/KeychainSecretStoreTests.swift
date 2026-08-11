import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class KeychainSecretStoreTests {
  @Test
  func testSetGetAndDeleteUseOpaqueReference() throws {
    let adapter = MemoryKeychainAdapter()
    let store = try KeychainSecretStore(service: "test.service", adapter: adapter)
    let reference = try SecretReference(account: "tunnel.primary.api-key")

    try store.set("sk-secret-value", for: reference)

    #expect((try store.value(for: reference)) == ("sk-secret-value"))
    #expect((adapter.accounts) == (["test.service:tunnel.primary.api-key"]))
    #expect(!(String(describing: reference).contains("sk-secret-value")))

    try store.delete(reference)
    #expect((try store.value(for: reference)) == nil)
  }

  @Test
  func testMissingSecretReturnsNilAndDeleteIsIdempotent() throws {
    let store = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let reference = try SecretReference(account: "missing")

    #expect((try store.value(for: reference)) == nil)
    #expect(try !store.contains(reference))
    expectNoThrow(try store.delete(reference))
  }

  @Test
  func testContainsUsesMetadataCheckWithoutReadingSecret() throws {
    let adapter = MetadataKeychainAdapter()
    let store = try KeychainSecretStore(adapter: adapter)
    let reference = try SecretReference(account: "present")

    #expect(try store.contains(reference))
    #expect(adapter.getCount == 0)
    #expect(adapter.containsCount == 1)
    #expect(adapter.authenticationUI == .fail)
  }

  @Test
  func testBackgroundValueReadDisablesAuthenticationUI() throws {
    let adapter = MetadataKeychainAdapter()
    let store = try KeychainSecretStore(adapter: adapter)
    let reference = try SecretReference(account: "present")

    #expect(
      (try store.value(for: reference, authenticationUI: .fail)) == "secret"
    )
    #expect(adapter.authenticationUI == .fail)
  }

  @Test
  func testRejectsInvalidReferencesAndSecrets() throws {
    expectThrows(try SecretReference(account: " "))
    let store = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let reference = try SecretReference(account: "valid")
    expectThrows(try store.set("", for: reference))
    expectThrows(try store.set("secret\0value", for: reference))
  }

  @Test
  func testInvalidStoredUTF8FailsClosed() throws {
    let adapter = MemoryKeychainAdapter()
    let store = try KeychainSecretStore(adapter: adapter)
    let reference = try SecretReference(account: "binary")
    try adapter.set(
      service: store.service,
      account: reference.account,
      data: Data([0xFF])
    )

    expectThrows(try store.value(for: reference)) { error in
      #expect((error as? KeychainSecretStoreError) == (.invalidStoredSecret))
    }
  }
}

final class MemoryKeychainAdapter: KeychainAdapter, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]

  var accounts: [String] {
    lock.lock()
    defer { lock.unlock() }
    return values.keys.sorted()
  }

  func set(service: String, account: String, data: Data) throws {
    lock.lock()
    values["\(service):\(account)"] = data
    lock.unlock()
  }

  func get(service: String, account: String) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return values["\(service):\(account)"]
  }

  func delete(service: String, account: String) throws {
    lock.lock()
    values.removeValue(forKey: "\(service):\(account)")
    lock.unlock()
  }
}

private final class MetadataKeychainAdapter: KeychainAdapter, @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0
  private var metadataChecks = 0
  private var lastAuthenticationUI: KeychainAuthenticationUI?

  var getCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reads
  }

  var containsCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return metadataChecks
  }

  var authenticationUI: KeychainAuthenticationUI? {
    lock.lock()
    defer { lock.unlock() }
    return lastAuthenticationUI
  }

  func set(service: String, account: String, data: Data) throws {}

  func get(service: String, account: String) throws -> Data? {
    lock.lock()
    reads += 1
    lock.unlock()
    return Data("secret".utf8)
  }

  func get(
    service: String,
    account: String,
    authenticationUI: KeychainAuthenticationUI
  ) throws -> Data? {
    lock.lock()
    reads += 1
    lastAuthenticationUI = authenticationUI
    lock.unlock()
    return Data("secret".utf8)
  }

  func contains(service: String, account: String) throws -> Bool {
    lock.lock()
    metadataChecks += 1
    lock.unlock()
    return true
  }

  func contains(
    service: String,
    account: String,
    authenticationUI: KeychainAuthenticationUI
  ) throws -> Bool {
    lock.lock()
    metadataChecks += 1
    lastAuthenticationUI = authenticationUI
    lock.unlock()
    return true
  }

  func delete(service: String, account: String) throws {}
}
