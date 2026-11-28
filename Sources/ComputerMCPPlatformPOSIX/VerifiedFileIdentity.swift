import ComputerMCPPlatform
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

package enum FileIdentityError: Error {
  case unavailable, changed, unsupportedType
}

/// Stable across content edits, but not replacement or a change of canonical target.
package struct VerifiedFileIdentity: Codable, Hashable, Sendable {
  package let path: String
  package let isDirectory: Bool
  private let device: UInt64
  private let inode: UInt64
  private let token: Data

  package static func capture(_ input: URL) throws -> Self {
    let canonical = try ProjectPathResolver.canonicalProject(input)
    let descriptor = open(canonical.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw FileIdentityError.unavailable }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw FileIdentityError.unavailable }
    let kind = status.st_mode & S_IFMT
    guard kind == S_IFDIR || kind == S_IFREG else { throw FileIdentityError.unsupportedType }
    let token: Data
    #if canImport(Darwin)
      var attributes = attrlist()
      attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
      attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
      var bytes = [UInt8](repeating: 0, count: 4 + MemoryLayout<uuid_t>.size)
      let result = bytes.withUnsafeMutableBytes {
        fgetattrlist(descriptor, &attributes, $0.baseAddress, $0.count, 0)
      }
      guard result == 0,
        bytes.withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }) == bytes.count,
        bytes.dropFirst(4).contains(where: { $0 != 0 })
      else { throw FileIdentityError.unavailable }
      let volume = bytes.withUnsafeBytes {
        UUID(uuid: $0.loadUnaligned(fromByteOffset: 4, as: uuid_t.self))
      }
      token = Data(
        "\(volume.uuidString):\(status.st_birthtimespec.tv_sec):\(status.st_birthtimespec.tv_nsec):\(status.st_gen)"
          .utf8)
    #elseif canImport(Glibc)
      guard let handle = try LinuxSystemCalls.fileHandle(descriptor) else {
        throw FileIdentityError.unavailable
      }
      token = Data(handle)
    #else
      throw FileIdentityError.unavailable
    #endif
    var current = stat()
    guard try ProjectPathResolver.canonicalProject(input) == canonical,
      lstat(canonical.path, &current) == 0,
      current.st_dev == status.st_dev, current.st_ino == status.st_ino,
      current.st_mode & S_IFMT == kind
    else { throw FileIdentityError.changed }
    return Self(
      path: canonical.path, isDirectory: kind == S_IFDIR,
      device: UInt64(truncatingIfNeeded: status.st_dev), inode: UInt64(status.st_ino), token: token)
  }

  package var evidence: Data {
    get throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(self)
    }
  }

  package func verify(_ input: URL) throws {
    guard try Self.capture(input) == self else { throw FileIdentityError.changed }
  }
}
