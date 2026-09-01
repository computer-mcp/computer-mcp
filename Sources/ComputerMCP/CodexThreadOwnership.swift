import Foundation

enum CodexThreadOwnershipState: String, Codable, Equatable, Sendable {
  case loaded
  case released
  case archived
}

struct CodexThreadOwnershipRecord: Codable, Equatable, Sendable, Identifiable {
  var id: String { threadID }

  let threadID: String
  let workspaceID: String?
  let workspacePath: String
  var runtimeID: String
  var state: CodexThreadOwnershipState
  let createdAt: Date
  var updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case threadID = "thread_id"
    case workspaceID = "workspace_id"
    case workspacePath = "workspace_path"
    case runtimeID = "runtime_id"
    case state
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}
