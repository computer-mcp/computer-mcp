import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPToolKit
import Foundation

internal enum DeliveryState: String, Codable, Sendable {
  case aborted, merged, committed
  case cleanupPending = "cleanup_pending"
}

internal enum DeliveryReason: String, Codable, Sendable {
  case scopeUnknown = "scope_unknown"
  case pathOutsideScope = "path_outside_scope"
  case pathInvalid = "path_invalid"
  case matchMissing = "match_missing"
  case matchAmbiguous = "match_ambiguous"
  case fileExists = "file_exists"
  case fileMissing = "file_missing"
  case notText = "not_text"
  case mainCheckoutDirty = "main_checkout_dirty"
  case mainCheckoutBranch = "main_checkout_branch"
  case worktreeRootNotIgnored = "worktree_root_not_ignored"
  case branchExists = "branch_exists"
  case messageInvalid = "message_invalid"
  case busy
  case gitFailed = "git_failed"
  case commitOnly = "commit_only"
  case notFastForward = "not_fast_forward"
  case rebaseConflict = "rebase_conflict"
  case rebaseScopeChanged = "rebase_scope_changed"
  case worktreeUnrecognized = "worktree_unrecognized"
  case journalFailed = "journal_failed"
  case interrupted
  case cleanupFailed = "cleanup_failed"
}

internal struct DeliveryFailure: Error, LocalizedError, Sendable {
  let reason: DeliveryReason
  var detail: String = ""
  var exitCode: Int32?
  var stderr: String?
  var code: String { "delivery.\(reason.rawValue)" }
  var errorDescription: String? { "[\(code)] \(detail)" }
}

internal struct DeliveryFile: Codable, Sendable {
  var path: String
  var snippets: [String]
}

internal struct DeliveryResult: Codable, Sendable {
  var state: DeliveryState
  var commit: String?
  var branch: String?
  var reason: DeliveryReason?
  var files: [DeliveryFile] = []

  func envelope(failure: DeliveryFailure? = nil) throws -> JSONValue {
    var value = try JSONValue.encoded(self).objectValue ?? [:]
    if let failure {
      value["code"] = .string(failure.code)
      value["message"] = .string(failure.detail)
      if let exitCode = failure.exitCode { value["exit_code"] = .integer(Int64(exitCode)) }
      if let stderr = failure.stderr { value["stderr"] = .string(stderr) }
    }
    var result = try textResult(.object(value)).objectValue ?? [:]
    result["isError"] = .bool(state == .aborted)
    return .object(result)
  }
}

internal struct DeliveryRequest: Sendable {
  struct Edit: Sendable {
    enum Change: Sendable {
      case replace(old: String, new: String)
      case create(String)
    }
    var path: String
    var change: Change
  }
  var scope: String
  var message: String
  var branch: String
  var edits: [Edit]

  init(arguments: JSONValue?) throws {
    guard let object = arguments?.objectValue,
      Set(object.keys).isSubset(of: ["scope", "message", "slug", "edits"]),
      let scope = object["scope"]?.stringValue, !scope.isEmpty
    else {
      throw DeliveryFailure(reason: .scopeUnknown, detail: "A delivery scope is required.")
    }
    guard let message = object["message"]?.stringValue, !message.contains("\0"),
      let first = message.components(separatedBy: .newlines).first,
      let type = first.split(separator: "(").first?.split(separator: ":").first?.split(
        separator: "!"
      ).first,
      first.range(
        of:
          "^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\\([^()\\r\\n]+\\))?!?: \\S[^\\r\\n]*$",
        options: .regularExpression) != nil,
      let slug = object["slug"]?.stringValue, slug.utf8.count <= 48,
      slug.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
    else {
      throw DeliveryFailure(
        reason: .messageInvalid,
        detail:
          "Use a Conventional Commit message and a lowercase hyphenated slug of at most 48 characters."
      )
    }
    guard let items = object["edits"]?.arrayValue, (1...64).contains(items.count) else {
      throw DeliveryFailure(reason: .pathInvalid, detail: "edits must contain 1 to 64 entries.")
    }
    self.scope = scope
    self.message = message.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
      of: "\r", with: "\n")
    self.branch = "\(type)/\(slug)"
    self.edits = try items.map { item in
      guard let fields = item.objectValue,
        Set(fields.keys).isSubset(of: ["path", "replace", "create"]),
        let path = fields["path"]?.stringValue, let normalized = DeliveryScope.normalizedPath(path),
        (fields["replace"] != nil) != (fields["create"] != nil)
      else {
        throw DeliveryFailure(
          reason: .pathInvalid,
          detail: "Each edit needs a relative path and exactly one of replace or create.")
      }
      if let replacement = fields["replace"]?.objectValue,
        Set(replacement.keys) == ["old", "new"], let old = replacement["old"]?.stringValue,
        !old.isEmpty, let new = replacement["new"]?.stringValue,
        old.utf8.count + new.utf8.count <= 1_048_576
      {
        return Edit(path: normalized, change: .replace(old: old, new: new))
      }
      if let creation = fields["create"]?.objectValue, Set(creation.keys) == ["content"],
        let content = creation["content"]?.stringValue, content.utf8.count <= 1_048_576
      {
        return Edit(path: normalized, change: .create(content))
      }
      throw DeliveryFailure(
        reason: .pathInvalid, detail: "Invalid edit or text content larger than 1 MiB.")
    }
  }

  var paths: [String] { Array(Set(edits.map(\.path))).sorted() }
}

internal func boundedDeliveryText(_ text: String, bytes: Int = 4096) -> String {
  var data = Data(text.utf8.prefix(bytes))
  while !data.isEmpty {
    if let text = String(data: data, encoding: .utf8) { return text }
    data.removeLast()
  }
  return ""
}
