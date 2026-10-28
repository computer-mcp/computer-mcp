import ComputerMCPPlatform
import Testing

@testable import ComputerMCPToolKit

struct ProjectGitLayoutTests {
  @Test func nonRepositoryDiagnosisAllowsWarningsButRejectsOtherFatalErrors() {
    let absent = "fatal: not a git repository (or any of the parent directories): .git\n"
    for (stderr, expected) in [
      (absent, true),
      ("xcodebuild: Failed to start fs event stream.\n" + absent, true),
      ("fatal: bad config line 1 in file /project/forged\n" + absent, false),
      ("fatal: detected dubious ownership in repository at /project\n", false),
    ] {
      let result = CommandResult(
        executable: "/usr/bin/git", arguments: [], exitCode: 128,
        timedOut: false, stdout: "", stderr: stderr, stdoutTruncated: false, stderrTruncated: false)
      #expect(ProjectGitLayout.isNonRepository(result) == expected)
    }
  }
}
