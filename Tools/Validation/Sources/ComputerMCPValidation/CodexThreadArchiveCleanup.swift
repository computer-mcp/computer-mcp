public enum CodexThreadArchiveCleanupDisposition: Equatable, Sendable {
  case archived
  case alreadyAbsent
  case failed

  public static func classify(
    status: String,
    detail: String?,
    threadID: String
  ) -> Self {
    guard !threadID.isEmpty, !threadID.contains(where: { $0.isWhitespace }) else {
      return .failed
    }
    if status == "passed" {
      return .archived
    }
    guard status == "failed", let detail else { return .failed }
    let missingRollout = "no rollout found for thread id \(threadID)"
    if detail == missingRollout || detail.hasSuffix(": \(missingRollout)") {
      return .alreadyAbsent
    }
    return .failed
  }
}
