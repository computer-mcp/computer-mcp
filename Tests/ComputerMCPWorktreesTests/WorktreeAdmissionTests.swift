import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeAdmissionTests {
  @Test func closureSurvivesReopenAndRequiresEveryOwnersAcknowledgement() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "writers")
      let admission = try service.admission(projectID: created.projectID)
      let a = try admission.reserve(ownerID: UUID(), executionID: UUID())
      let b = try admission.reserve(ownerID: UUID(), executionID: UUID())
      let operation = UUID()
      #expect(
        Set(try admission.close(operationID: operation).map(\.executionID)) == [
          a.executionID, b.executionID,
        ])
      let recovered = try f.service().admission(projectID: created.projectID)
      #expect(recovered == admission)
      #expect(throws: WorktreeError.self) { try recovered.requireOpen(a) }
      #expect(throws: WorktreeError.self) {
        try recovered.reserve(ownerID: UUID(), executionID: UUID())
      }
      #expect(throws: WorktreeError.self) { try recovered.close(operationID: UUID()) }
      try recovered.acknowledge(a)
      try recovered.acknowledge(a)
      #expect(throws: WorktreeError.self) { try recovered.requireDrained(operationID: operation) }
      #expect(throws: WorktreeError.self) { try recovered.reopen(operationID: operation) }
      try recovered.acknowledge(b)
      try recovered.requireDrained(operationID: operation)
      try recovered.reopen(operationID: operation)
      let next = try recovered.reserve(ownerID: UUID(), executionID: UUID())
      try recovered.requireOpen(next)
      try recovered.acknowledge(next)
    }
  }

  @Test func anotherWorktreeCannotAcknowledgeAndLostStateFailsClosed() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let a = try service.admission(projectID: service.create(name: "first").projectID)
      let b = try service.admission(projectID: service.create(name: "second").projectID)
      let use = try a.reserve(ownerID: UUID(), executionID: UUID())
      #expect(throws: WorktreeError.self) { try b.acknowledge(use) }
      let state = f.repository.appendingPathComponent(
        ".git/computer-mcp/admission/\(a.generation.uuidString.lowercased())/state.json")
      try FileManager.default.removeItem(at: state)
      #expect(throws: WorktreeError.self) { try a.close(operationID: UUID()) }
      #expect(throws: WorktreeError.self) { try service.admission(projectID: a.projectID) }
    }
  }
}
