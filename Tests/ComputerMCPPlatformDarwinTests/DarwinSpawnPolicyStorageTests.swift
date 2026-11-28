import ComputerMCPSandbox
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite struct DarwinSpawnPolicyStorageTests {
  @Test(.timeLimit(.minutes(1)))
  func policySurvivesScratchMutationAndOriginatingThreadExit() throws {
    let attributes = try SpawnAttributes()
    let storage = DarwinSpawnPolicyStorage()
    defer { withExtendedLifetime(storage) {} }
    let result = PolicyResult()
    let work = PolicyThreadWork {
      result.set(
        Result {
          try DarwinPrivacyResponsibility().disclaim(&attributes.value.pointee)
          let getter = try Self.getter()
          var borrowed: UnsafeMutableRawPointer?
          var size = 0
          try #require(getter(attributes.value, "Quarantine", &borrowed, &size) == 0)
          let original = try #require(borrowed)
          let bytes = Data(bytes: original, count: size)
          try storage.retain("Quarantine", in: &attributes.value.pointee)
          var retained: UnsafeMutableRawPointer?
          var retainedSize = 0
          try #require(getter(attributes.value, "Quarantine", &retained, &retainedSize) == 0)
          let owned = try #require(retained)
          try #require(owned != original)
          try #require(retainedSize == size)
          // Deterministically invalidate the borrowed payload before another thread spawns.
          let first = original.load(as: UInt8.self)
          original.storeBytes(of: first ^ 0xff, as: UInt8.self)
          defer { original.storeBytes(of: first, as: UInt8.self) }
          try #require(Data(bytes: owned, count: retainedSize) == bytes)
        })
    }
    let context = Unmanaged.passRetained(work).toOpaque()
    var thread: pthread_t?
    let created = pthread_create(
      &thread, nil,
      { context in
        Unmanaged<PolicyThreadWork>.fromOpaque(context).takeRetainedValue().run()
        return nil
      }, context)
    if created != 0 { Unmanaged<PolicyThreadWork>.fromOpaque(context).release() }
    try #require(created == 0)
    try #require(pthread_join(try #require(thread), nil) == 0)
    try result.get().get()

    let arguments = [strdup("/usr/bin/true"), nil]
    defer { free(arguments[0]) }
    var pid: pid_t = 0
    try #require(posix_spawn(&pid, "/usr/bin/true", nil, attributes.value, arguments, [nil]) == 0)
    var status: Int32 = 0
    var reaped: pid_t
    repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
    #expect(reaped == pid)
    #expect(status == 0)
  }

  @Test
  func missingPolicyInterfacesFailClosed() throws {
    let attributes = try SpawnAttributes()
    for storage in [DarwinSpawnPolicyStorage(getter: nil), DarwinSpawnPolicyStorage(setter: nil)] {
      #expect(throws: ExecutionEnvironmentError.self) {
        try storage.retain("Quarantine", in: &attributes.value.pointee)
      }
    }
    #expect(throws: ExecutionEnvironmentError.self) {
      try DarwinSpawnPolicyStorage().retain("Quarantine", in: &attributes.value.pointee)
    }
  }

  private static func getter() throws -> DarwinSpawnPolicyStorage.Getter {
    let symbol = try #require(
      dlsym(UnsafeMutableRawPointer(bitPattern: -2), "posix_spawnattr_getmacpolicyinfo_np"))
    return unsafeBitCast(symbol, to: DarwinSpawnPolicyStorage.Getter.self)
  }
}

private final class SpawnAttributes: @unchecked Sendable {
  let value = UnsafeMutablePointer<posix_spawnattr_t?>.allocate(capacity: 1)

  init() throws {
    value.initialize(to: nil)
    try #require(posix_spawnattr_init(value) == 0)
  }

  deinit {
    posix_spawnattr_destroy(value)
    value.deinitialize(count: 1)
    value.deallocate()
  }
}

private final class PolicyResult: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<Void, Error>?
  func set(_ value: Result<Void, Error>) { lock.withLock { self.value = value } }
  func get() throws -> Result<Void, Error> { try lock.withLock { try #require(value) } }
}

private final class PolicyThreadWork: Sendable {
  private let operation: @Sendable () -> Void
  init(_ operation: @escaping @Sendable () -> Void) { self.operation = operation }
  func run() { operation() }
}
