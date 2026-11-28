import ComputerMCPSandbox
import Darwin
import Foundation

/// Owns opaque MAC policy payloads until the asynchronous spawn has consumed them.
/// libquarantine supplies thread-local scratch; Darwin's attribute setter borrows its pointer.
final class DarwinSpawnPolicyStorage: @unchecked Sendable {
  typealias Getter =
    @convention(c) (
      UnsafePointer<posix_spawnattr_t?>, UnsafePointer<CChar>,
      UnsafeMutablePointer<UnsafeMutableRawPointer?>, UnsafeMutablePointer<Int>
    ) -> Int32
  typealias Setter =
    @convention(c) (
      UnsafeMutablePointer<posix_spawnattr_t?>, UnsafePointer<CChar>, UnsafeMutableRawPointer, Int
    ) -> Int32

  private let getter: Getter?
  private let setter: Setter?
  private let lock = NSLock()
  private var buffers: [UnsafeMutableRawPointer] = []

  init(
    getter: Getter? = resolve("posix_spawnattr_getmacpolicyinfo_np", as: Getter.self),
    setter: Setter? = resolve("posix_spawnattr_setmacpolicyinfo_np", as: Setter.self)
  ) {
    self.getter = getter
    self.setter = setter
  }

  func retain(_ name: String, in attributes: inout posix_spawnattr_t?) throws {
    guard let getter, let setter else {
      throw ExecutionEnvironmentError.unavailable("Cannot retain privacy responsibility policy")
    }
    var borrowed: UnsafeMutableRawPointer?
    var size = 0
    let status = name.withCString { getter(&attributes, $0, &borrowed, &size) }
    // Bound allocation without depending on the private policy's byte layout.
    guard status == 0, let borrowed, size > 0, size <= 65_536 else {
      throw ExecutionEnvironmentError.unavailable("Cannot read privacy responsibility policy")
    }
    let owned = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    owned.copyMemory(from: borrowed, byteCount: size)
    let rebound = name.withCString { setter(&attributes, $0, owned, size) }
    guard rebound == 0 else {
      owned.deallocate()
      throw ExecutionEnvironmentError.unavailable(
        "Cannot bind retained privacy responsibility policy")
    }
    lock.withLock { buffers.append(owned) }
  }

  deinit { for buffer in buffers { buffer.deallocate() } }

  private static func resolve<T>(_ name: String, as type: T.Type) -> T? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
    return unsafeBitCast(symbol, to: type)
  }
}
