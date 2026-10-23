import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// Owns an empty, mode-0700 home for a host subprocess and removes it after the last use.
package final class PrivateProcessHome: Sendable {
  package let url: URL

  package init() throws {
    var template = Array(
      FileManager.default.temporaryDirectory.appendingPathComponent("computer-mcp-home-XXXXXX")
        .path.utf8CString)
    guard let path = mkdtemp(&template) else { throw POSIXError(.EACCES) }
    url = URL(fileURLWithPath: String(cString: path), isDirectory: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }
}
