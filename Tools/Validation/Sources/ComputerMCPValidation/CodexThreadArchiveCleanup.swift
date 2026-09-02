public enum CodexThreadArchiveCleanupDisposition: Equatable, Sendable {
  case archived
  case alreadyAbsent
  case failed

  public static func classify(
    status: String,
    detail: String?,
    threadID: String
  ) -> Self {
    if status == "passed" {
      return .archived
    }
    if let detail,
      detail.contains("no rollout found for thread id \(threadID)")
    {
      return .alreadyAbsent
    }
    return .failed
  }
}
