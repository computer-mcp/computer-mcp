import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPTestSupport
import Foundation
import Testing

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct DescriptorCommandRunnerTests {
  private func runner(managed: Bool) -> any CommandRunning {
    let launcher = testExecutionLauncher()
    return managed
      ? ManagedCommandRunner(launcher: launcher)
      : ProcessCommandRunner(launcher: launcher, environment: ["HOST_ONLY": "private"])
  }

  @Test(arguments: [false, true], [false, true])
  func isolatedEnvironmentIsExact(managed: Bool, explicitDirectory: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let result = try runner(managed: managed).runIsolated(
      executable: testExecutable("env"), arguments: [],
      workingDirectory: explicitDirectory ? temporary.url : nil,
      environment: ["CHILD_ONLY": "selected"], timeoutMilliseconds: 10_000, maxOutputBytes: 4096)
    #expect(result.exitCode == 0)
    #expect(result.stdout == "CHILD_ONLY=selected\n")
  }

  #if os(macOS)
    @Test(arguments: [false, true], [false, true])
    func explicitEnvironmentsExcludeProcessAndRunnerSecrets(managed: Bool, readOnly: Bool) throws {
      let key = "PROCESS_SECRET_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      setenv(key, "private", 1)
      defer { unsetenv(key) }
      let temporary = try ScopedTemporaryDirectory()
      let policy: HostExecutionPolicy = readOnly ? .readOnly : .fullAccess
      let launcher = testExecutionLauncher()
      let runner: any CommandRunning =
        managed
        ? ManagedCommandRunner(
          launcher: launcher, policy: policy, hostVariables: ["BASE_SECRET": "private"])
        : ProcessCommandRunner(launcher: launcher, environment: ["BASE_SECRET": "private"])
      let directory = open(temporary.url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      let input = open("/dev/null", O_RDONLY | O_CLOEXEC)
      let outputURL = temporary.url.appendingPathComponent("output")
      let output = open(outputURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      try #require(directory >= 0 && input >= 0 && output >= 0)
      defer {
        close(directory)
        close(input)
        close(output)
      }
      try HostExecutionPolicy.$current.withValue(policy) {
        for entry in ["isolated", "file", "directory"] {
          let result: CommandResult
          let variables = ["SELECTED": "explicit", "LC_ALL": "C"]
          if entry == "isolated" {
            result = try runner.runIsolated(
              executable: testExecutable("env"), arguments: [], workingDirectory: temporary.url,
              environment: variables, timeoutMilliseconds: 10_000, maxOutputBytes: 4096)
          } else if entry == "file" {
            result = try runner.runToFile(
              executable: testExecutable("env"), arguments: [], workingDirectory: temporary.url,
              environment: variables, timeoutMilliseconds: 10_000, maxOutputBytes: 4096,
              outputDescriptor: output)
          } else {
            result = try runner.runInDirectory(
              executable: testExecutable("env"), arguments: [], directoryDescriptor: directory,
              inputDescriptor: input, outputDescriptor: output, environment: variables,
              timeoutMilliseconds: 10_000, maxOutputBytes: 4096)
          }
          #expect(result.exitCode == 0, "\(entry): \(result.stderr)")
          let text =
            entry == "isolated"
            ? result.stdout : String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
          // Report booleans so a regression cannot print inherited credentials into test logs.
          let validEncoding = !text.contains("\u{FFFD}")
          let selectedValuePresent = text.contains("SELECTED=explicit\n")
          let localePresent = text.contains("LC_ALL=C\n")
          let processSecretAbsent = !text.contains(key)
          let runnerSecretAbsent = !text.contains("BASE_SECRET")
          #expect(validEncoding, "\(entry)")
          #expect(selectedValuePresent)
          #expect(localePresent)
          #expect(processSecretAbsent)
          #expect(runnerSecretAbsent)
          if !readOnly {
            let exact = Set(text.split(separator: "\n")) == ["SELECTED=explicit", "LC_ALL=C"]
            #expect(exact)
          }
          ftruncate(output, 0)
          lseek(output, 0, SEEK_SET)
        }
      }
    }
  #endif

  @Test(arguments: [false, true])
  func streamsBeyondCaptureLimitAndReportsWriteErrors(managed: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let destination = temporary.url.appendingPathComponent("output")
    let descriptor = open(destination.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    let result = try runner(managed: managed).runToFile(
      executable: testExecutable("sh"),
      arguments: ["-c", "printf 0123456789 >&2; head -c 131072 /dev/zero"],
      workingDirectory: temporary.url, environment: ["PATH": systemUtilityPath],
      timeoutMilliseconds: 10_000, maxOutputBytes: 4, outputDescriptor: descriptor)
    #expect(result.exitCode == 0)
    #expect(result.stdout.isEmpty)
    #expect(!result.stdoutTruncated)
    #expect(result.stderr == "0123")
    #expect(result.stderrTruncated)
    #expect(try Data(contentsOf: destination) == Data(repeating: 0, count: 131072))
    let readOnly = open(destination.path, O_RDONLY | O_CLOEXEC)
    try #require(readOnly >= 0)
    defer { close(readOnly) }
    #expect(throws: (any Error).self) {
      try runner(managed: managed).runToFile(
        executable: testExecutable("echo"), arguments: ["bytes"],
        workingDirectory: temporary.url, environment: [:], timeoutMilliseconds: 10_000,
        maxOutputBytes: 4, outputDescriptor: readOnly)
    }
  }

  @Test(arguments: [false, true])
  func directoryAndInputStayPinned(managed: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let directory = temporary.url.appendingPathComponent("directory")
    let moved = temporary.url.appendingPathComponent("moved")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let pinned = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    let inputURL = temporary.url.appendingPathComponent("input")
    try Data("input bytes".utf8).write(to: inputURL)
    let input = open(inputURL.path, O_RDONLY | O_CLOEXEC)
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
    let result = try runner(managed: managed).runInDirectory(
      executable: testExecutable("sh"), arguments: ["-c", "pwd -P; cat"],
      directoryDescriptor: pinned, inputDescriptor: input, outputDescriptor: output,
      environment: ["PATH": systemUtilityPath], timeoutMilliseconds: 10_000, maxOutputBytes: 4096)
    #expect(result.exitCode == 0)
    let captured = try String(contentsOf: outputURL, encoding: .utf8)
    let physicalDirectory = try ProjectPathResolver.canonicalProject(moved).path
    #expect(captured == physicalDirectory + "\ninput bytes")
  }

  @Test(arguments: [false, true])
  func timeoutTerminatesTheProcessGroup(managed: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let directory = open(temporary.url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    let input = open("/dev/null", O_RDONLY | O_CLOEXEC)
    let outputURL = temporary.url.appendingPathComponent("output")
    let output = open(outputURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    try #require(directory >= 0 && input >= 0 && output >= 0)
    defer {
      close(directory)
      close(input)
      close(output)
    }
    let result = try runner(managed: managed).runInDirectory(
      executable: testExecutable("sh"),
      arguments: ["-c", "trap '' TERM; sleep 30 & echo $$ $!; wait"],
      directoryDescriptor: directory, inputDescriptor: input, outputDescriptor: output,
      environment: ["PATH": systemUtilityPath], timeoutMilliseconds: 250, maxOutputBytes: 4096)
    #expect(result.timedOut)
    let pids = try String(contentsOf: outputURL, encoding: .utf8).split(
      whereSeparator: \.isWhitespace)
    #expect(pids.count == 2)
    for text in pids {
      let pid = try #require(Int32(text))
      #expect(ProcessTable.hasExited(pid))
    }
  }
}
