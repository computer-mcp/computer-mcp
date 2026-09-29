import ComputerMCP
import Foundation
import Testing

@testable import ComputerMCPApp

struct OperationApprovalDetailsTests {
  @Test
  func nestedValuesRetainIntegerPrecisionArrayOrderAndDistinctPaths() throws {
    let value = OperationApprovalDetails(
      ticket: ticket(
        summary: """
          {"recipient":"fixture@example.invalid","items":[9007199254740993,9223372036854775807],
           "a/b":"literal key","a":{"b":"nested key"},"secret":"[REDACTED]"}
          """))
    #expect(value.title == "Send a message")
    let fields = try #require(value.fields)
    #expect(fields.first { $0.id == "/items/0" }?.value == "9007199254740993")
    #expect(fields.first { $0.id == "/items/1" }?.value == "9223372036854775807")
    #expect(fields.first { $0.id == "/a~1b" }?.value == "literal key")
    #expect(fields.first { $0.id == "/a/b" }?.value == "nested key")
    #expect(fields.first { $0.id == "/secret" }?.value == "[REDACTED]")
    #expect(Set(fields.map(\.id)).count == fields.count)
  }

  @Test(arguments: [nil, "invalid", "[]", "null"] as [String?])
  func unavailableOrMalformedDetailsCannotBePresentedAsAReviewedRequest(summary: String?) {
    #expect(OperationApprovalDetails(ticket: ticket(summary: summary)).fields == nil)
  }

  @Test
  func oldSerializedTicketsRemainReadableAndNewTitlesRoundTripThroughStorage() throws {
    let database = try GatewayDatabase(inMemory: ())
    let current = ticket(summary: "{}")
    try database.saveOperationTicket(current)
    #expect(try database.operationTicket(id: current.id)?.reviewTitle == "Send a message")
    var json = try JSONDecoder().decode(
      JSONValue.self, from: JSONEncoder().encode(current)
    ).objectValue!
    json.removeValue(forKey: "reviewTitle")
    let legacy = try JSONDecoder().decode(
      OperationTicket.self, from: JSONEncoder().encode(JSONValue.object(json)))
    #expect(legacy.reviewTitle == nil)
    #expect(OperationApprovalDetails(ticket: legacy).fields != nil)
  }

  private func ticket(summary: String?) -> OperationTicket {
    .init(
      capabilityID: "mail.send", caller: .secureTunnel, profileID: .chatGPTOperate,
      inputDigest: "fixture", expiresAt: Date().addingTimeInterval(60),
      reviewSummary: summary, reviewTitle: "Send a message")
  }
}
