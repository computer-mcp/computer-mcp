import Testing

@testable import ComputerMCPValidation

@Suite("Codex Thread Archive Cleanup")
struct CodexThreadArchiveCleanupTests {
  @Test(arguments: [
    "no rollout found for thread id thread-1234",
    "no rollout found for thread id thread-12",
    "no rollout found for thread id thread-123 extra-details",
    "unrelated no rollout found for thread id thread-123",
    "no rollout found for thread id ",
    "",
  ])
  func ambiguousMissingRolloutIsNotSuccess(detail: String) {
    #expect(
      CodexThreadArchiveCleanupDisposition.classify(
        status: "failed", detail: detail, threadID: "thread-123") == .failed)
  }

  @Test(arguments: ["", " ", "thread-123\n"])
  func malformedTargetIsNotSuccess(threadID: String) {
    for status in ["passed", "failed"] {
      #expect(
        CodexThreadArchiveCleanupDisposition.classify(
          status: status, detail: "no rollout found for thread id \(threadID)",
          threadID: threadID) == .failed)
    }
  }

  @Test
  func missingOrUnconfirmedErrorIsNotSuccess() {
    #expect(
      CodexThreadArchiveCleanupDisposition.classify(
        status: "failed", detail: nil, threadID: "thread-123") == .failed)
    #expect(
      CodexThreadArchiveCleanupDisposition.classify(
        status: "unknown", detail: "no rollout found for thread id thread-123",
        threadID: "thread-123") == .failed)
    #expect(
      CodexThreadArchiveCleanupDisposition.classify(
        status: "failed", detail: "no rollout found for thread id thread-123",
        threadID: "thread-123") == .alreadyAbsent)
  }

  @Test("successful archive is complete")
  func successfulArchive() {
    #expect(
      CodexThreadArchiveCleanupDisposition.classify(
        status: "passed",
        detail: nil,
        threadID: "thread-123"
      ) == .archived
    )
  }

  @Test("missing rollout is already clean")
  func missingRollout() {
    #expect(
      CodexThreadArchiveCleanupDisposition.classify(
        status: "failed",
        detail:
          "codex.app.request_failed: App Server JSON-RPC error -32600: no rollout found for thread id thread-123",
        threadID: "thread-123"
      ) == .alreadyAbsent
    )
  }

  @Test("different missing rollout remains a failure")
  func differentMissingRollout() {
    #expect(
      CodexThreadArchiveCleanupDisposition.classify(
        status: "failed",
        detail:
          "codex.app.request_failed: App Server JSON-RPC error -32600: no rollout found for thread id thread-456",
        threadID: "thread-123"
      ) == .failed
    )
  }

  @Test("other provider errors remain failures")
  func otherProviderError() {
    #expect(
      CodexThreadArchiveCleanupDisposition.classify(
        status: "failed",
        detail: "codex.app.request_failed: permission denied",
        threadID: "thread-123"
      ) == .failed
    )
  }
}
