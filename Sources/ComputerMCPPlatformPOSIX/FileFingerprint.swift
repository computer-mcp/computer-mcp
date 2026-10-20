import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

package struct FileFingerprint: Equatable, Sendable {
  package let device: Int64
  package let inode: UInt64
  package let size: Int64
  package let modifiedSeconds: Int64
  package let modifiedNanoseconds: Int64
  package let changedSeconds: Int64
  package let changedNanoseconds: Int64

  package static func current(of url: URL) -> FileFingerprint? {
    var value = stat()
    guard stat(url.path, &value) == 0 else { return nil }
    #if canImport(Darwin)
      let modified = value.st_mtimespec
      let changed = value.st_ctimespec
    #else
      let modified = value.st_mtim
      let changed = value.st_ctim
    #endif
    return FileFingerprint(
      device: Int64(value.st_dev), inode: UInt64(value.st_ino), size: Int64(value.st_size),
      modifiedSeconds: Int64(modified.tv_sec), modifiedNanoseconds: Int64(modified.tv_nsec),
      changedSeconds: Int64(changed.tv_sec), changedNanoseconds: Int64(changed.tv_nsec))
  }
}
