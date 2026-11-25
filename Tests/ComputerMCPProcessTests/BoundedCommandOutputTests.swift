import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct BoundedCommandOutputTests {
  @Test func parentRejectsOversizedPipeChunkBeforeWriting() throws {
    try withCommandAdministration {
      let temporary = try ScopedTemporaryDirectory()
      let output = temporary.url.appendingPathComponent("pack")
      let fd = open(output.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      try #require(fd >= 0)
      defer { close(fd) }
      let runner = ManagedCommandRunner(launcher: testExecutionLauncher())
      let invocation = CLIInvocation(arguments: ["-c", "printf 1234"], standardInput: Data())
      #expect(throws: (any Error).self) {
        try runner.runBounded(
          executable: testExecutable("sh"), invocation: invocation,
          workingDirectory: temporary.url, environment: [:], timeoutMilliseconds: 10_000,
          maxOutputBytes: 1024, fileOutput: (fd, 3), fileSizeLimit: nil)
      }
      #expect(try Data(contentsOf: output).count <= 3)
      #expect(ftruncate(fd, 0) == 0)
      #expect(lseek(fd, 0, SEEK_SET) == 0)
      let result = try runner.runBounded(
        executable: testExecutable("sh"), invocation: invocation,
        workingDirectory: temporary.url, environment: [:], timeoutMilliseconds: 10_000,
        maxOutputBytes: 1024, fileOutput: (fd, 4), fileSizeLimit: nil)
      #expect(result.exitCode == 0)
      #expect(try Data(contentsOf: output) == Data("1234".utf8))
    }
  }

  @Test func childFileLimitDoesNotChangeParentLimit() throws {
    try withCommandAdministration {
      let temporary = try ScopedTemporaryDirectory()
      let child = temporary.url.appendingPathComponent("child")
      let parent = temporary.url.appendingPathComponent("parent")
      let runner = ManagedCommandRunner(launcher: testExecutionLauncher())
      let result = try runner.runBounded(
        executable: testExecutable("sh"),
        invocation: .init(
          arguments: ["-c", "printf 0123456789abcdef > \"$1\"", "sh", child.path],
          standardInput: Data()),
        workingDirectory: temporary.url, environment: [:], timeoutMilliseconds: 10_000,
        maxOutputBytes: 1024, fileOutput: nil, fileSizeLimit: try .init(bytes: 8))
      #expect(result.exitCode != 0)
      #expect(try Data(contentsOf: child).count <= 8)
      try Data(repeating: 0, count: 16).write(to: parent)
      #expect(try Data(contentsOf: parent).count == 16)
    }
  }
}
