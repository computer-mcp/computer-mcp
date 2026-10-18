import CryptoKit
import Darwin
import Foundation

/// Binds verification and decoding to one private copy, even if the original
/// file changes during the copy. The borrowed descriptor is never closed here.
struct PluginArchiveSnapshot {
  struct Contents {
    let url: URL
    let sha256: String
    let bytes: Int
  }

  static func validateDigest(_ digest: String) throws {
    guard digest.utf8.count == 64,
      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw PluginArchiveError.invalidInput }
  }

  static func withVerifiedCopy<Result>(
    from input: Int32, inNewDirectory root: URL, expectedSHA256: String,
    limits: PluginArchiveLimits = PluginArchiveLimits(),
    checkCancellation: () throws -> Void = { try Task.checkCancellation() },
    body: (Contents) throws -> Result
  ) throws -> Result {
    try validateDigest(expectedSHA256)
    try limits.validate()
    try checkCancellation()
    var status = stat()
    guard fstat(input, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_size > 0, fcntl(input, F_GETFL) & O_ACCMODE == O_RDONLY
    else { throw PluginArchiveError.invalidInput }
    guard status.st_size <= limits.archiveBytes else { throw PluginArchiveError.limitExceeded }
    guard lseek(input, 0, SEEK_SET) == 0 else { throw PluginArchiveError.invalidInput }

    let directory = try PluginArchiveDirectory(at: root)
    let result: Result
    do {
      var hasher = SHA256()
      var total = 0
      var buffer = [UInt8](repeating: 0, count: 65_536)
      try directory.createFile(["archive"], executable: false, readOnly: true) { output in
        while true {
          try checkCancellation()
          let count = buffer.withUnsafeMutableBytes {
            Darwin.read(input, $0.baseAddress, min($0.count, limits.archiveBytes - total + 1))
          }
          if count < 0, errno == EINTR { continue }
          guard count >= 0 else { throw PluginArchiveError.fileSystemFailure }
          if count == 0 { break }
          guard count <= limits.archiveBytes - total else { throw PluginArchiveError.limitExceeded }
          try buffer.withUnsafeBytes { bytes in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
            var offset = 0
            while offset < count {
              let written = Darwin.write(
                output, bytes.baseAddress?.advanced(by: offset), count - offset)
              if written < 0, errno == EINTR { continue }
              guard written > 0 else { throw PluginArchiveError.fileSystemFailure }
              offset += written
            }
          }
          total += count
        }
      }
      guard total > 0 else { throw PluginArchiveError.invalidInput }
      let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      guard digest == expectedSHA256 else { throw PluginArchiveError.checksumMismatch }
      try directory.finish()
      try checkCancellation()
      result = try body(
        Contents(
          url: directory.url.appendingPathComponent("archive"), sha256: digest, bytes: total))
    } catch {
      try directory.discard()
      throw error
    }
    try directory.discard()
    return result
  }
}
