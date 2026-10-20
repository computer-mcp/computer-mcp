import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPProcess

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct ShellLaunchFailureTests {
  /// A launch that fails after its output pipes exist stops both readers and reports the
  /// failure instead of waiting on them.
  @Test func failedLaunchReportsPromptly() throws {
    let root = try ScopedTemporaryDirectory()
    let runtime = SubprocessShellRuntime()
    let started = ContinuousClock.now
    #expect(throws: ShellRuntimeError.self) {
      try runtime.run(
        request: .init(
          mode: .argv, executable: "/bin/sh", argv: ["-c", "exit 0"],
          workingDirectory: root.url.appendingPathComponent("missing").path,
          inheritsEnvironment: false),
        defaultShell: "/bin/sh", defaultWorkingDirectory: root.url, timeoutMilliseconds: 5_000,
        maxOutputBytes: 1_024, maxSessions: 1, terminationGraceMilliseconds: 250)
    }
    #expect(started.duration(to: .now) < .seconds(5))
  }
}
