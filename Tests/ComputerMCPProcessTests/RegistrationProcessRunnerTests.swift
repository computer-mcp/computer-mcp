import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RegistrationProcessRunnerTests {
  @Test
  func usesExactlyTheSuppliedEnvironment() throws {
    let temporary = try ScopedTemporaryDirectory()
    let environment = [
      "HOME": temporary.url.path, "USER": "fixture", "LOGNAME": "fixture",
      "TMPDIR": temporary.url.path, "LANG": "C", "PATH": "/bin",
      "CODEX_HOME": temporary.url.appendingPathComponent("codex").path,
    ]
    let result = try RegistrationProcessRunner().run(
      executable: "/usr/bin/env", arguments: [], environment: environment,
      timeoutMilliseconds: 1_000, maxOutputBytes: 16_384)
    #expect(result.exitCode == 0)
    let observed = Dictionary(
      uniqueKeysWithValues: result.stdout.split(separator: "\n").map { line in
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]), String(parts[1]))
      })
    #expect(observed == environment)
  }

  @Test
  func killsTheProcessGroupAndConfirmsExitBeforeReturning() throws {
    let temporary = try ScopedTemporaryDirectory()
    let marker = temporary.url.appendingPathComponent("late-write")
    let result = try RegistrationProcessRunner().run(
      executable: "/bin/sh",
      arguments: ["-c", "(sleep 1; echo escaped > \"$1\") & wait", "fixture", marker.path],
      environment: ["PATH": "/bin"], timeoutMilliseconds: 100, maxOutputBytes: 1_024)
    #expect(result.timedOut && result.exitCode != nil && result.exitCode != 0)
    // Waiting here tests the descendant's side effect, after the runner has returned.
    Thread.sleep(forTimeInterval: 1.1)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test
  func boundsBothStreamsWhileStillEnforcingTheDeadline() throws {
    let result = try RegistrationProcessRunner().run(
      executable: "/bin/sh",
      arguments: ["-c", "while :; do echo '0123456789'; echo '0123456789' >&2; done"],
      environment: [:], timeoutMilliseconds: 100, maxOutputBytes: 128)
    #expect(result.timedOut && result.exitCode != nil)
    #expect(result.stdout.utf8.count == 128 && result.stderr.utf8.count == 128)
    #expect(result.stdoutTruncated && result.stderrTruncated)
  }

  @Test
  func launchFailuresContainNoPrivateArguments() {
    do {
      _ = try RegistrationProcessRunner().run(
        executable: "/nonexistent/registration-client", arguments: ["PRIVATE_SENTINEL"],
        environment: [:], timeoutMilliseconds: 100, maxOutputBytes: 100)
      Issue.record("A missing executable launched")
    } catch { #expect(!error.localizedDescription.contains("PRIVATE_SENTINEL")) }
  }
}
