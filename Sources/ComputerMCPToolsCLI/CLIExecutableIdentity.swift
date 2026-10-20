import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// Detects observed path/content/permission changes around compatibility probes.
/// This is not a kernel-pinned executable or a snapshot of its dynamic dependencies.
struct CLIExecutableIdentity: Equatable, Sendable {
  let executable: String
  let arguments: [String]
  private let files: [File]

  private struct File: Equatable, Sendable {
    let lookupPath: String
    let targetPath: String
    let device: Int64
    let inode: UInt64
    let size: Int64
    let mode: UInt32
    let owner: UInt32
    let group: UInt32
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
  }

  static func capture(
    executable: String, cwd: URL, environment: [String: String],
    interpreterBindings: [String: String] = [:]
  ) throws -> Self {
    let invocation = ExecutableInspection.invocation(
      executable, workingDirectory: cwd, environment: environment,
      interpreterBindings: interpreterBindings)
    let inspection = invocation.inspection
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
      #if canImport(Darwin)
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
      #else
        let modified = info.st_mtim
        let changed = info.st_ctim
      #endif
      files.append(
        File(
          lookupPath: path, targetPath: target, device: Int64(info.st_dev),
          inode: UInt64(info.st_ino),
          size: Int64(info.st_size), mode: UInt32(info.st_mode), owner: info.st_uid,
          group: info.st_gid,
          modifiedSeconds: modified.tv_sec, modifiedNanoseconds: modified.tv_nsec,
          changedSeconds: changed.tv_sec, changedNanoseconds: changed.tv_nsec))
      for interpreter in item.interpreters { try append(interpreter) }
    }
    try append(inspection)
    return Self(
      executable: invocation.executable ?? files[0].lookupPath, arguments: invocation.arguments,
      files: files)
  }
}
