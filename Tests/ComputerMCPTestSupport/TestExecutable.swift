import Foundation

/// The standard utility path. Test helpers resolve from it so that installations earlier on
/// the caller's PATH, which have not been validated with the fixtures, are not selected.
package let systemUtilityPath = "/usr/bin:/bin"

package func testExecutable(_ name: String) throws -> String {
  for directory in systemUtilityPath.split(separator: ":") {
    let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
    if FileManager.default.isExecutableFile(atPath: path) { return path }
  }
  throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
}
