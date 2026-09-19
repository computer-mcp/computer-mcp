import ComputerMCPValidation
import Foundation
import Testing

@testable import ComputerMCPValidationCLI

@Suite(.timeLimit(.minutes(1)))
struct ValidationOperationApprovalTests {
  @Test
  func pendingApprovalWithoutResolverCannotProceed() async {
    do {
      try await ValidationOperationApproval.resolve(ticket("pending_approval"), using: nil)
      Issue.record("A pending ticket proceeded without local approval.")
    } catch {
      #expect(error.localizedDescription.contains("requires local approval"))
      #expect(error.localizedDescription.contains("not executed"))
    }
  }

  @Test(arguments: ["prepared", "approved"])
  func eligibleTicketDoesNotRequestAnotherApproval(state: String) async throws {
    try await ValidationOperationApproval.resolve(ticket(state)) { _ in
      Issue.record("An eligible ticket must not ask for another approval.")
      return .null
    }
  }

  @Test
  func resolverMustReturnTheExactApprovedTicket() async throws {
    try await ValidationOperationApproval.resolve(ticket("pending_approval")) { id in
      #expect(id == "fixture-ticket")
      return .object(["id": .string(id), "state": .string("approved")])
    }
  }

  @Test(arguments: ["denied", "expired", "pending_approval", "succeeded", "wrong-id"])
  func unapprovedOrUnrelatedResolutionCannotProceed(resolution: String) async {
    await #expect(throws: (any Error).self) {
      try await ValidationOperationApproval.resolve(ticket("pending_approval")) { _ in
        .object([
          "id": .string(resolution == "wrong-id" ? "other-ticket" : "fixture-ticket"),
          "state": .string(resolution == "wrong-id" ? "approved" : resolution),
        ])
      }
    }
  }

  @Test(arguments: ["denied", "expired", "executing", "succeeded", "failed"])
  func ineligibleTicketCannotReachResolver(state: String) async {
    await #expect(throws: (any Error).self) {
      try await ValidationOperationApproval.resolve(ticket(state)) { _ in
        Issue.record("An ineligible ticket reached the local resolver.")
        return .null
      }
    }
  }

  @Test
  func missingIdentityOrStateCannotProceed() async {
    for value in [JSONValue.null, .object([:]), .object(["ticket_id": .string("fixture-ticket")])] {
      await #expect(throws: (any Error).self) {
        try await ValidationOperationApproval.resolve(value, using: nil)
      }
    }
  }

  private func ticket(_ state: String) -> JSONValue {
    .object(["ticket_id": .string("fixture-ticket"), "state": .string(state)])
  }
}
