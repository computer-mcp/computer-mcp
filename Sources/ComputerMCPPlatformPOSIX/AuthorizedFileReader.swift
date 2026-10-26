import ComputerMCPCore
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Pins the opened object and rechecks its actual location on every data read.
package final class AuthorizedFileReader {
  private let handle: FileHandle
  private let access: (any HostPathAccessChecking)?

  package init(url: URL, access: (any HostPathAccessChecking)? = HostPathAccess.current) throws {
    self.access = access
    try access?.check(url, operation: .read)
    handle = try FileHandle(forReadingFrom: url)
    do { try check() } catch {
      try? handle.close()
      throw error
    }
  }

  deinit { try? handle.close() }
  package func close() throws { try handle.close() }
  package func seek(toOffset offset: UInt64) throws {
    try check()
    try handle.seek(toOffset: offset)
  }
  package func seekToEnd() throws -> UInt64 {
    try check()
    return try handle.seekToEnd()
  }
  package func readToEnd() throws -> Data {
    var result = Data()
    while let chunk = try read(upToCount: 65_536), !chunk.isEmpty { result.append(chunk) }
    return result
  }
  package func read(upToCount count: Int) throws -> Data? {
    try check()
    let data = try handle.read(upToCount: count)
    try check()
    return data
  }
  package func check() throws {
    if let access {
      try access.check(authorizedDescriptorURL(handle.fileDescriptor), operation: .read)
    }
  }
}

package func authorizedDescriptorURL(_ fd: Int32) throws -> URL {
  #if canImport(Darwin)
    var path = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fcntl(fd, F_GETPATH, &path) == 0 else { throw POSIXError(.EACCES) }
    return URL(
      fileURLWithPath: String(
        decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
  #elseif canImport(Glibc)
    var path = [UInt8](repeating: 0, count: Int(PATH_MAX))
    let count = readlink("/proc/self/fd/\(fd)", &path, path.count)
    guard count > 0, count < path.count else { throw POSIXError(.EACCES) }
    let value = String(decoding: path.prefix(count), as: UTF8.self)
    guard !value.hasSuffix(" (deleted)") else { throw POSIXError(.EACCES) }
    return URL(fileURLWithPath: value)
  #else
    throw POSIXError(.ENOTSUP)
  #endif
}
