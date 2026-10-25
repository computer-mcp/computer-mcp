import Foundation
import Testing

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

/// Resolves the interpreter before isolating HOME/TMPDIR, avoiding Apple's Python
/// launcher and its Xcode discovery and environment injection in each child.
package func writePythonTestExecutable(_ script: String, to executable: URL) throws {
  let lookup = Process()
  let output = Pipe()
  lookup.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  #if os(macOS)
    lookup.arguments = ["xcrun", "--find", "python3"]
  #else
    lookup.arguments = ["python3", "-c", "import sys; print(sys.executable)"]
  #endif
  lookup.standardOutput = output
  lookup.standardError = FileHandle.nullDevice
  try lookup.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  lookup.waitUntilExit()
  try #require(lookup.terminationStatus == 0)
  let interpreter = String(decoding: data, as: UTF8.self).trimmingCharacters(
    in: .whitespacesAndNewlines)
  try #require(interpreter.hasPrefix("/") && !interpreter.contains("\n"))
  try Data(("#!\(interpreter)\n" + script + "\n").utf8).write(to: executable)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
}
