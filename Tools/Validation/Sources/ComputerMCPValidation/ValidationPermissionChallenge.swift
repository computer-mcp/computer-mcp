import Foundation

/// A refused invocation's durable permission requests. An owner answers them
/// separately before the original caller explicitly retries unchanged arguments.
public struct ValidationPermissionChallenge: Equatable, Sendable {
  public let requestIDs: [UUID]
  public let groupID: String
  public let instructions: String
  public static let retryField = "_permission_request_ids"

  public init?(result: JSONValue) throws {
    guard let error = result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue,
      error["code"]?.stringValue == "permission.required"
    else { return nil }
    guard let ids = error["request_ids"]?.arrayValue, !ids.isEmpty, ids.count <= 64,
      let group = error["request_group_id"]?.stringValue, !group.isEmpty,
      let retry = error["retry"]?.objectValue,
      retry["field"]?.stringValue == Self.retryField,
      let instructions = retry["instructions"]?.stringValue, !instructions.isEmpty
    else { throw ValidationPermissionChallengeError.invalidChallenge }
    let decoded = ids.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
    guard decoded.count == ids.count, Set(decoded).count == decoded.count else {
      throw ValidationPermissionChallengeError.invalidChallenge
    }
    self.requestIDs = decoded
    self.groupID = group
    self.instructions = instructions
  }

  public func retryArguments(_ original: [String: JSONValue]) throws -> [String: JSONValue] {
    guard original[Self.retryField] == nil else {
      throw ValidationPermissionChallengeError.retryAlreadyPresent
    }
    return original.merging([Self.retryField: .array(requestIDs.map { .string($0.uuidString) })]) {
      _, new in new
    }
  }
}

public enum ValidationPermissionChallengeError: Error, Equatable {
  case invalidChallenge, retryAlreadyPresent
}
