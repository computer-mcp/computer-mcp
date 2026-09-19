import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite(.timeLimit(.minutes(1)))
struct ValidationProcessTests {
  @Test
  func outputIsDrainedAndBoundedDuringExecution() throws {
    let result = try run("printf 123456789; printf error >&2", maxOutputBytes: 4)
    #expect(result.exitCode == 0)
    #expect(!result.timedOut)
    #expect(result.cleanupError == nil)
    #expect(result.stdout == "1234")
    #expect(result.stderr == "erro")
    #expect(result.stdoutTruncated && result.stderrTruncated)
  }

  @Test
  func timeoutEscalatesOwnedProcessIgnoringTermination() throws {
    let started = ContinuousClock.now
    let result = try run("trap '' TERM; printf ready; exec /bin/sleep 60", timeout: 100)
    #expect(started.duration(to: .now) < .seconds(5))
    #expect(result.timedOut)
    #expect(result.exitCode != nil)
    #expect(result.stdout == "ready")
    #expect(result.cleanupError == nil)
  }

  @Test
  func descendantHoldingOutputDoesNotBlockFinalDrain() throws {
    let started = ContinuousClock.now
    let result = try run("/bin/sleep 2 & printf complete", timeout: 1_000)
    #expect(started.duration(to: .now) < .seconds(2))
    #expect(result.exitCode == 0)
    #expect(result.stdout == "complete")
    #expect(!result.timedOut)
    #expect(result.cleanupError?.contains("EOF") == true)
  }

  @Test
  func launchFailureClosesPipes() {
    #expect(throws: ValidationProcessError.self) {
      try ProcessCommandRunner().run(
        executable: "/nonexistent-validation-fixture", arguments: [], workingDirectory: nil,
        environment: [:], timeoutMilliseconds: 100, maxOutputBytes: 128)
    }
  }

  private func run(_ script: String, timeout: Int = 2_000, maxOutputBytes: Int = 128) throws
    -> CommandResult
  {
    try ProcessCommandRunner().run(
      executable: "/bin/sh", arguments: ["-c", script], workingDirectory: nil,
      environment: [:], timeoutMilliseconds: timeout, maxOutputBytes: maxOutputBytes)
  }
}
