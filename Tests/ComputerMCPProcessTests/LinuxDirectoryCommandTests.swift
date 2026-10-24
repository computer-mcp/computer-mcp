#if canImport(Glibc)
  import ComputerMCPProcess
  import ComputerMCPTestSupport
  import Foundation
  import Glibc
  import Testing

  @Suite(.nativeIntegration)
  struct LinuxDirectoryCommandTests {
    @Test
    func spawnUsesThePinnedDirectoryAfterItsPathIsReplaced() throws {
      let temporary = try ScopedTemporaryDirectory()
      let directory = temporary.url.appendingPathComponent("directory")
      let moved = temporary.url.appendingPathComponent("moved")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let pinned = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      let input = open("/dev/null", O_RDONLY | O_CLOEXEC)
      let outputURL = temporary.url.appendingPathComponent("output")
      let output = open(outputURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      try #require(pinned >= 0 && input >= 0 && output >= 0)
      defer {
        close(pinned)
        close(input)
        close(output)
      }
      try FileManager.default.moveItem(at: directory, to: moved)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      let result = try ProcessCommandRunner().runInDirectory(
        executable: testExecutable("pwd"), arguments: ["-P"], directoryDescriptor: pinned,
        inputDescriptor: input, outputDescriptor: output, environment: [:],
        timeoutMilliseconds: 10_000, maxOutputBytes: 4096)
      #expect(result.exitCode == 0)
      #expect(!result.timedOut)
      #expect(try String(contentsOf: outputURL, encoding: .utf8) == moved.path + "\n")
    }
  }
#endif
