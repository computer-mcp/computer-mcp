import ComputerMCPPlatform
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

private final class EpochKeychainDouble: KeychainAdapter, @unchecked Sendable {
  private struct State {
    var data: Data?
    var unavailable = false
    var readUI: [KeychainAuthenticationUI] = []
    var writeUI: [KeychainAuthenticationUI] = []
  }
  private let lock = NSLock()
  private var state = State()
  func replace(_ data: Data?) { lock.withLock { state.data = data } }
  func fail() { lock.withLock { state.unavailable = true } }
  var promptsDisabled: Bool {
    lock.withLock {
      !state.readUI.isEmpty && !state.writeUI.isEmpty
        && state.readUI.allSatisfy { $0 == .fail } && state.writeUI.allSatisfy { $0 == .fail }
    }
  }
  func get(service: String, account: String) throws -> Data? {
    try get(service: service, account: account, authenticationUI: .allow)
  }
  func get(service: String, account: String, authenticationUI: KeychainAuthenticationUI) throws
    -> Data?
  {
    try lock.withLock {
      state.readUI.append(authenticationUI)
      if state.unavailable { throw AuthorizationEpochCounterError.unavailable }
      return state.data
    }
  }
  func set(service: String, account: String, data: Data) throws {
    try set(service: service, account: account, data: data, authenticationUI: .allow)
  }
  func set(service: String, account: String, data: Data, authenticationUI: KeychainAuthenticationUI)
    throws
  {
    try lock.withLock {
      state.writeUI.append(authenticationUI)
      if state.unavailable { throw AuthorizationEpochCounterError.unavailable }
      state.data = data
    }
  }
  func delete(service: String, account: String) throws { replace(nil) }
}

struct KeychainAuthorizationEpochCounterTests {
  @Test func namespaceSerializesInstancesAndCounterNeverPromptsOrMovesBackward() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keychain = EpochKeychainDouble()
    let first = try KeychainAuthorizationEpochCounter(
      keychain: keychain, lockDirectory: directory, service: "test.epoch", account: "fixture",
      lockTimeout: .milliseconds(25))
    let second = try KeychainAuthorizationEpochCounter(
      keychain: keychain, lockDirectory: directory, service: "test.epoch", account: "fixture",
      lockTimeout: .milliseconds(25))
    let one = AuthorizationEpochWatermark(databaseID: UUID(), revision: 1)
    try first.withExclusiveAccess { access in
      #expect(try access.read() == nil)
      try access.advance(to: one)
      #expect(try access.read() == one)
      #expect(throws: (any Error).self) { try second.withExclusiveAccess { _ in () } }
      #expect(throws: AuthorizationEpochCounterError.nonMonotonicWrite) {
        try access.advance(to: one)
      }
    }
    try second.withExclusiveAccess { access in
      #expect(try access.read() == one)
      try access.advance(to: .init(databaseID: UUID(), revision: 2))
    }
    #expect(keychain.promptsDisabled)
    keychain.replace(Data("invalid".utf8))
    #expect(throws: AuthorizationEpochCounterError.invalidRecord) {
      try second.withExclusiveAccess { try $0.read() }
    }
    keychain.fail()
    #expect(throws: AuthorizationEpochCounterError.unavailable) {
      try second.withExclusiveAccess { try $0.read() }
    }
  }

  @Test func invalidCountersDoNotBecomeMissingItems() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keychain = EpochKeychainDouble()
    let counter = try KeychainAuthorizationEpochCounter(
      keychain: keychain, lockDirectory: directory, service: "test.epoch", account: "fixture",
      lockTimeout: .milliseconds(25))
    for revision in [UInt64(0), UInt64.max] {
      keychain.replace(
        try JSONEncoder().encode(
          AuthorizationEpochWatermark(databaseID: UUID(), revision: revision)))
      #expect(throws: AuthorizationEpochCounterError.invalidRecord) {
        try counter.withExclusiveAccess { try $0.read() }
      }
    }
  }
}

private struct LegacyEpochKeychainDouble: KeychainAdapter {
  func set(service: String, account: String, data: Data) throws {
    Issue.record("Noninteractive write invoked the legacy setter")
  }
  func get(service: String, account: String) throws -> Data? { nil }
  func delete(service: String, account: String) throws {}
}

extension KeychainAuthorizationEpochCounterTests {
  @Test func legacyAdapterCannotSilentlyPromptOnNoninteractiveWrite() throws {
    let adapter: any KeychainAdapter = LegacyEpochKeychainDouble()
    #expect(throws: KeychainSecretStoreError.noninteractiveOperationUnavailable) {
      try adapter.set(service: "test", account: "counter", data: Data(), authenticationUI: .fail)
    }
  }

  @Test func competingNamespaceWriterWaitsUntilFirstWriterReleases() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keychain = EpochKeychainDouble()
    let first = try KeychainAuthorizationEpochCounter(
      keychain: keychain, lockDirectory: directory,
      service: "test.epoch", account: "fixture")
    let second = try KeychainAuthorizationEpochCounter(
      keychain: keychain, lockDirectory: directory,
      service: "test.epoch", account: "fixture")
    let held = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let attempted = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let writer = Task.detached {
      try first.withExclusiveAccess { access in
        try access.advance(to: .init(databaseID: UUID(), revision: 1))
        held.signal()
        #expect(release.wait(timeout: .now() + 5) == .success)
      }
    }
    while !pollSignal(held) { try await Task.sleep(for: .milliseconds(5)) }
    let waiter = Task.detached {
      attempted.signal()
      return try second.withExclusiveAccess { access in
        completed.signal()
        return try access.read()?.revision
      }
    }
    while !pollSignal(attempted) { try await Task.sleep(for: .milliseconds(5)) }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!pollSignal(completed))
    release.signal()
    try await writer.value
    #expect(try await waiter.value == 1)
  }
}

private func pollSignal(_ semaphore: DispatchSemaphore) -> Bool {
  semaphore.wait(timeout: .now()) == .success
}
