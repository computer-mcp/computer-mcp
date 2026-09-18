import Foundation
import Testing

@testable import ComputerMCP

struct MCPExecutionRecordTests {
  private let server = MCPServerConfig(id: "fixture", transport: .stdio, command: "/usr/bin/false")

  @Test func stableIdentityBindsInputAndSurvivesAHostInstanceChange() throws {
    let database = try GatewayDatabase(inMemory: ())
    let first = MCPExecutionJournal(database: database, scope: "credential-a/workspace")
    let input = JSONValue.object(["body": .string("hello")])
    let reservation = try first.reserve(
      server: server, tool: "write", arguments: input, requestID: "one")
    #expect(reservation.inserted)
    #expect(
      try !first.reserve(server: server, tool: "write", arguments: input, requestID: "one").inserted
    )
    #expect(throws: (any Error).self) {
      try first.reserve(server: server, tool: "write", arguments: .object([:]), requestID: "one")
    }
    let next = MCPExecutionJournal(database: database, scope: "credential-a/workspace")
    let recovered = try next.reserve(
      server: server, tool: "write", arguments: input, requestID: "one")
    #expect(!recovered.inserted)
    #expect(
      try recovered.record.snapshot(instance: next.instanceID).objectValue?["state"]
        == .string("outcome_unknown"))
    #expect(throws: (any Error).self) {
      try next.update(serverID: server.id, requestID: "one") { $0.state = .running }
    }
    let stranger = MCPExecutionJournal(database: database, scope: "credential-b/workspace")
    #expect(throws: (any Error).self) { try stranger.read(serverID: server.id, requestID: "one") }
  }

  @Test func successfulEmptyResultIsRetainedAndExpiryIsNotEmptySuccess() throws {
    let database = try GatewayDatabase(inMemory: ())
    let journal = MCPExecutionJournal(database: database, scope: "owner")
    _ = try journal.reserve(
      server: server, tool: "empty", arguments: .object([:]), requestID: "empty")
    let result = JSONValue.object(["content": .array([]), "isError": .bool(false)])
    try journal.update(serverID: server.id, requestID: "empty") {
      try $0.finish(result: result, failed: false)
    }
    let record = try journal.read(serverID: server.id, requestID: "empty")
    let read = try record.snapshot(instance: journal.instanceID)
    #expect(read.objectValue?["state"] == .string("succeeded"))
    #expect(read.objectValue?["output_state"] == .string("available"))
    #expect(read.objectValue?["result"] == result)
    #expect(try record.snapshot(instance: journal.instanceID) == read)
    let expired = try record.snapshot(
      instance: journal.instanceID, now: Date().addingTimeInterval(86_401))
    #expect(expired.objectValue?["state"] == .string("succeeded"))
    #expect(expired.objectValue?["output_state"] == .string("expired"))
    #expect(expired.objectValue?["result"] == nil)
  }

  @Test func boundedUnicodeOutputHasRepeatableValidCursorsAndExplicitTruncation() throws {
    var record = MCPExecutionRecord(
      scope: "owner", serverID: "fixture", requestID: "large", instanceID: "instance",
      tool: "large", inputDigest: "digest", createdAt: Date())
    try record.finish(result: .string(String(repeating: "完整", count: 70_000)), failed: false)
    #expect(record.retainedByteCount <= MCPExecutionRecord.maximumOutputBytes)
    let first = try record.snapshot(instance: "instance", maxBytes: 17)
    #expect(first.objectValue?["truncated"] == .bool(true))
    #expect(first.objectValue?["output_state"] == .string("truncated"))
    let cursor = try #require(first.objectValue?["next_offset"]?.intValue)
    #expect(cursor <= 17)
    let next = try record.snapshot(instance: "instance", offset: cursor, maxBytes: 17)
    #expect(next.objectValue?["next_offset"]?.intValue ?? 0 > cursor)
    #expect(try record.snapshot(instance: "instance", offset: cursor, maxBytes: 17) == next)
    #expect(throws: (any Error).self) { try record.snapshot(instance: "instance", offset: 2) }
    #expect(throws: (any Error).self) {
      try record.snapshot(instance: "instance", offset: record.retainedByteCount + 1)
    }
  }

  @Test func independentDatabaseConnectionsAtomicallyReserveOneExecution() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("receipts.sqlite").path
    let first = MCPExecutionJournal(database: try GatewayDatabase(path: path), scope: "shared")
    let second = MCPExecutionJournal(database: try GatewayDatabase(path: path), scope: "shared")
    let results = try await withThrowingTaskGroup(of: Bool.self) { group in
      for journal in [first, second] {
        group.addTask {
          try journal.reserve(
            server: server, tool: "write", arguments: .object([:]), requestID: "same"
          ).inserted
        }
      }
      var values: [Bool] = []
      for try await value in group { values.append(value) }
      return values
    }
    #expect(results.filter { $0 }.count == 1)
  }
}
