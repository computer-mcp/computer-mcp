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
        executable: "git", arguments: [], exitCode: 128,
        timedOut: false, stdout: "", stderr: stderr, stdoutTruncated: false, stderrTruncated: false)
      #expect(ProjectGitLayout.isNonRepository(result) == expected)
    }
  }

  @Test func mountedNonRepositoryDiagnosisRequiresTheCompleteDiagnostic() {
    let fatal = "fatal: not a git repository (or any parent up to mount point /mnt/runner temp)\n"
    let boundary = "Stopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n"
    for (stderr, truncated, expected) in [
      (fatal + boundary, false, true),
      ("git: warning: using /tmp instead\n" + fatal + boundary, false, true),
      (fatal, false, false),
      (fatal + boundary, true, false),
      ("fatal: bad config line 1 in file /project/.git/config\n", false, false),
    ] {
      let result = CommandResult(
        executable: "git", arguments: [], exitCode: 128,
        timedOut: false, stdout: "", stderr: stderr, stdoutTruncated: false,
        stderrTruncated: truncated)
      #expect(ProjectGitLayout.isNonRepository(result) == expected)
    }
  }
}
