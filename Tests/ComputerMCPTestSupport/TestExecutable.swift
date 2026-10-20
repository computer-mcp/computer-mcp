import Foundation

package func testExecutable(_ name: String) throws -> String {
  for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
    let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
    if FileManager.default.isExecutableFile(atPath: path) { return path }
  }
  throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
}
