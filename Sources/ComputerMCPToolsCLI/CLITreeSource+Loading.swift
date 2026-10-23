import ComputerMCPConfiguration
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import Foundation

extension CLITreeSource {
  func load(command: CLICommandConfig, project: URL, execution: CLIProcessExecution) throws
    -> CLITree
  {
    try validate()
    let cwd = command.resolvedWorkingDirectory(base: project) ?? project
    let data: Data
    switch kind {
    case .file:
      let url =
        path!.hasPrefix("/") ? URL(fileURLWithPath: path!) : cwd.appendingPathComponent(path!)
      // The common no-follow reader bounds regular-file reads and rejects FIFO/device sources.
      if let packageRoot {
        guard url.path.hasPrefix(packageRoot.path + "/") else {
          throw CLITreeError.invalid("Tree source is outside its owning package.")
        }
        data = try PackageFiles(root: packageRoot)
          .read(String(url.path.dropFirst(packageRoot.path.count + 1)), maximumBytes: 4_194_304)
      } else {
        data = try PackageFiles(root: url.deletingLastPathComponent())
          .read(url.lastPathComponent, maximumBytes: 4_194_304)
      }
    case .introspection, .helper:
      let result = try execution.run(
        executable: kind == .helper ? helper! : command.executable,
        invocation: .init(arguments: args, standardInput: Data()),
        cwd: cwd, environment: command.env, timeoutMilliseconds: 5_000, maxOutputBytes: 4_194_304,
        interpreterBindings: command.interpreterBindings)
      guard result.exitCode == 0, !result.timedOut, !result.cancelled,
        !result.stdout.truncated, !result.stdout.missedBytes, result.streamErrors.isEmpty,
        let encoded = result.stdout.base64, let output = Data(base64Encoded: encoded)
      else {
        throw CLITreeError.invalid("Interface exporter failed or returned incomplete output.")
      }
      data = output
    }
    return try CLITree.parse(data)
  }
}
