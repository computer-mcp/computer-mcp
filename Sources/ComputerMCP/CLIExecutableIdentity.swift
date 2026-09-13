import Darwin
import Foundation

/// Detects observed path/content/permission changes around compatibility probes.
/// This is not a kernel-pinned executable or a snapshot of its dynamic dependencies.
struct CLIExecutableIdentity: Equatable, Sendable {
  let executable: String
  private let files: [File]

  private struct File: Equatable, Sendable {
    let lookupPath: String
    let targetPath: String
    let device: Int32
    let inode: UInt64
    let size: Int64
    let mode: UInt16
    let owner: UInt32
    let group: UInt32
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
  }

  static func capture(executable: String, cwd: URL, environment: [String: String]) throws -> Self {
    let inspection = ExecutableInspection.inspect(
      executable, workingDirectory: cwd, environment: environment)
    var files: [File] = []
    func append(_ item: ExecutableInspection) throws {
      guard item.status == .passed, let path = item.path else {
        throw CLITreeError.invalid(
          "Compatibility requires a verified executable and interpreter path.")
      }
      let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
      var info = stat()
      guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0 else {
        throw CLITreeError.invalid("Executable identity could not be checked.")
      }
      files.append(
        File(
          lookupPath: path, targetPath: target, device: info.st_dev, inode: info.st_ino,
          size: info.st_size, mode: info.st_mode, owner: info.st_uid, group: info.st_gid,
          modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
          changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec))
      for interpreter in item.interpreters { try append(interpreter) }
    }
    try append(inspection)
    return Self(executable: files[0].lookupPath, files: files)
  }
}
