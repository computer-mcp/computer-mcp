import ComputerMCPPlatformDarwin
import ComputerMCPProcess
import ComputerMCPTestSupport
import Foundation

package func testExecutionLauncher(observations: ExecutionObservations? = nil) -> ExecutionLauncher
{
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let roots = [
    Bundle.main.bundleURL, URL(fileURLWithPath: CommandLine.arguments[0]),
    root.appendingPathComponent(".build/debug"),
    root.appendingPathComponent(".build/out/Products/Debug"),
  ]
  let bootstrap = roots.flatMap { root in
    Array(sequence(first: root) { $0.deletingLastPathComponent() }.prefix(7))
  }.map { $0.appendingPathComponent("computer-mcp-execution-bootstrap") }
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  let base = DarwinExecutionPlatform(bootstrapExecutable: bootstrap)
  if let observations {
    return ExecutionLauncher(
      platform: ObservedExecutionPlatform(base: base, observations: observations))
  }
  return ExecutionLauncher(platform: base)
}
