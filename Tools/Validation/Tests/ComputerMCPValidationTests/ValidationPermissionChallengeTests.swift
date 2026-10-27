import ComputerMCPValidation
import Foundation
import Testing

struct ValidationPermissionChallengeTests {
  @Test func exactRetryPreservesEveryToolArgument() throws {
    let first = UUID()
    let second = UUID()
    let result = challenge(ids: [first.uuidString, second.uuidString])
    let parsed = try #require(try ValidationPermissionChallenge(result: result))
    let arguments: [String: JSONValue] = [
      "path": .string("Sources/value.swift"), "content": .string("value"),
    ]
    let retry = try parsed.retryArguments(arguments)
    #expect(retry["path"] == arguments["path"])
    #expect(retry["content"] == arguments["content"])
    #expect(
      retry[ValidationPermissionChallenge.retryField]
        == .array([.string(first.uuidString), .string(second.uuidString)]))
    #expect(throws: ValidationPermissionChallengeError.retryAlreadyPresent) {
      try parsed.retryArguments(retry)
    }
  }

  @Test func malformedOrDuplicateRequestIDsCannotCreateARetry() throws {
    for ids in [["invalid"], [], [UUID().uuidString, "invalid"]] {
      #expect(throws: ValidationPermissionChallengeError.invalidChallenge) {
        try ValidationPermissionChallenge(result: challenge(ids: ids))
      }
    }
    let id = UUID().uuidString
    #expect(throws: ValidationPermissionChallengeError.invalidChallenge) {
      try ValidationPermissionChallenge(result: challenge(ids: [id, id]))
    }
    #expect(try ValidationPermissionChallenge(result: .object([:])) == nil)
  }

  private func challenge(ids: [String]) -> JSONValue {
    .object([
      "isError": .bool(true),
      "structuredContent": .object([
        "error": .object([
          "code": .string("permission.required"), "request_ids": .array(ids.map(JSONValue.string)),
          "request_group_id": .string("invocation-digest"),
          "retry": .object([
            "field": .string(ValidationPermissionChallenge.retryField),
            "instructions": .string(
              "After the local owner answers, retry the same tool with unchanged arguments and all request IDs."
            ),
          ]),
        ])
      ]),
    ])
  }
}
