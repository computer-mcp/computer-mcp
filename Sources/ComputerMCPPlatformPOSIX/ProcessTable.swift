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

  /// The processes with an open descriptor for the file at `path`, including this process.
  /// Only processes this user may inspect are visible.
  package static func processesHoldingOpen(path: String) throws -> [Int32] {
    #if canImport(Darwin)
      let capacity = Int(max(proc_listallpids(nil, 0), 0)) + 64
      var processIDs = [Int32](repeating: 0, count: capacity)
      let bytes = processIDs.withUnsafeMutableBytes { buffer in
        proc_listpidspath(
          UInt32(PROC_ALL_PIDS), 0, path, UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY),
          buffer.baseAddress, Int32(buffer.count))
      }
      guard bytes >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      return Array(processIDs.prefix(Int(bytes) / MemoryLayout<Int32>.stride)).sorted()
    #else
      // Descriptor links name the file by its real path.
      guard let real = realpath(path, nil) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      let resolved = String(cString: real)
      free(real)
      let fileManager = FileManager.default
      var holders: [Int32] = []
      for entry in try fileManager.contentsOfDirectory(atPath: "/proc") {
        guard let processID = Int32(entry),
          let descriptors = try? fileManager.contentsOfDirectory(atPath: "/proc/\(entry)/fd")
        else { continue }
        if descriptors.contains(where: {
          (try? fileManager.destinationOfSymbolicLink(atPath: "/proc/\(entry)/fd/\($0)"))
            == resolved
        }) {
          holders.append(processID)
        }
      }
      return holders.sorted()
    #endif
  }
}
