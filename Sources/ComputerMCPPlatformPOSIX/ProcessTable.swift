import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Process table queries; the kernels expose process state differently.
package enum ProcessTable {
  /// Whether `processID` has exited: it no longer exists, or it is a zombie awaiting
  /// collection by its parent.
  package static func hasExited(_ processID: Int32) -> Bool {
    #if canImport(Darwin)
      var info = proc_bsdinfo()
      let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
      errno = 0
      let actualSize = proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, expectedSize)
      if actualSize == expectedSize {
        return info.pbi_status == SZOMB
      }
      return actualSize <= 0 && errno == ESRCH
    #else
      guard let status = FileManager.default.contents(atPath: "/proc/\(processID)/stat") else {
        return kill(processID, 0) == -1 && errno == ESRCH
      }
      // The state follows the parenthesized command name, which may contain any bytes.
      guard let nameEnd = status.lastIndex(of: UInt8(ascii: ")")) else { return false }
      return status[(nameEnd + 1)...].first(where: { $0 != UInt8(ascii: " ") })
        == UInt8(ascii: "Z")
    #endif
  }
}
