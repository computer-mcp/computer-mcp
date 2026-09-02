import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)
final class CodexRecentThreadReaderTests {
  @Test
  func testLargePersistedThreadReadIsBoundedAndPaginatesWithoutOverlap() throws {
    let fixture = try RecentThreadFixture(recordCount: 30_000)
    defer { fixture.remove() }
    let limits = CodexRecentThreadLimits(
      maxTurns: 3,
      maxMessages: 5,
      maxItems: 5,
      maxReadBytes: 65_536,
      maxOutputBytes: 131_072,
      maxElapsedMilliseconds: 1_000
    )

    let first = try fixture.reader.read(
      threadID: fixture.threadID,
      beforeCursor: nil,
      limits: limits
    )
    let firstObject = try #require(first.objectValue)
    let firstBounds = try #require(firstObject["bounds"]?.objectValue)
    let firstMessages = try #require(firstObject["recent_messages"]?.arrayValue)
    let cursor = try #require(firstObject["next_before_cursor"]?.stringValue)

    #expect(fixture.rolloutSize > 8 * 1_048_576)
    #expect(firstObject["full_history_loaded"] == .bool(false))
    #expect(firstObject["state_database_mutated"] == .bool(false))
    #expect((firstBounds["page_bytes_read"]?.intValue ?? .max) <= 65_536)
    #expect(
      (firstBounds["total_io_bytes_read"]?.intValue ?? .max)
        <= 65_536 + CodexRecentThreadLimits.maximumGoalScanBytes
    )
    #expect((firstBounds["elapsed_milliseconds"]?.numberValue ?? .infinity) < 1_000)
    #expect(firstBounds["max_elapsed_milliseconds"] == .number(1_000))
    #expect(firstBounds["latency_budget_exhausted"] == .bool(false))
    #expect(firstMessages.count <= 5)
    #expect(firstObject["recent_items"]?.arrayValue?.count ?? .max <= 5)
    #expect(firstObject["recent_turns"]?.arrayValue?.count ?? .max <= 3)
    #expect(
      firstObject["goal"]?.objectValue?["objective"]
        == .string("Complete bounded supervision.")
    )
    #expect(try JSONEncoder().encode(first).count <= 131_072)

    let second = try fixture.reader.read(
      threadID: fixture.threadID,
      beforeCursor: cursor,
      limits: limits
    )
    let secondMessages = try #require(
      second.objectValue?["recent_messages"]?.arrayValue
    )
    let firstOrdinals = Set(
      firstMessages.compactMap {
        $0.objectValue?["ordinal"]?.intValue
      })
    let secondOrdinals = Set(
      secondMessages.compactMap {
        $0.objectValue?["ordinal"]?.intValue
      })
    #expect(firstOrdinals.isDisjoint(with: secondOrdinals))
    if let newestOlder = secondOrdinals.max(), let oldestNewer = firstOrdinals.min() {
      #expect(newestOlder < oldestNewer)
    }
  }

  @Test
  func testGoalAndCompactStatusReadDoNotRequireFullHistory() throws {
    let fixture = try RecentThreadFixture(recordCount: 12_000)
    defer { fixture.remove() }
    let result = try fixture.reader.read(
      threadID: fixture.threadID,
      beforeCursor: nil,
      limits: CodexRecentThreadLimits(maxReadBytes: 32_768, maxOutputBytes: 98_304)
    )
    let object = try #require(result.objectValue)

    #expect(object["goal"]?.objectValue?["status"] == .string("active"))
    #expect(object["latest_user_request"] != nil)
    #expect(object["latest_assistant_progress"] != nil)
    #expect(object["active_turn"]?.objectValue?["status"] == .string("in_progress"))
    #expect(object["full_history_loaded"] == .bool(false))
    #expect(
      (object["bounds"]?.objectValue?["total_io_bytes_read"]?.intValue ?? .max)
        < fixture.rolloutSize
    )
  }

  @Test
  func testRecentThreadReaderRejectsForeignCursorAndWorkspace() throws {
    let fixture = try RecentThreadFixture(recordCount: 1_000)
    defer { fixture.remove() }
    expectThrows(
      try fixture.reader.read(
        threadID: fixture.threadID,
        beforeCursor: "v1:foreign:1:1",
        limits: CodexRecentThreadLimits()
      )
    ) { error in
      #expect(error as? CodexRecentThreadReaderError == .invalidCursor)
    }

    let foreignReader = CodexRecentThreadReader(
      workspaceURL: fixture.root.appendingPathComponent("Foreign Workspace"),
      metadata: fixture.metadata,
      allowedRolloutRoot: fixture.root
    )
    expectThrows(
      try foreignReader.read(
        threadID: fixture.threadID,
        beforeCursor: nil,
        limits: CodexRecentThreadLimits()
      )
    ) { error in
      guard case CodexRecentThreadReaderError.outsideWorkspace = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
  }

  @Test
  func testRecentThreadReaderRejectsCursorAfterRolloutReplacement() throws {
    let fixture = try RecentThreadFixture(recordCount: 1_000)
    defer { fixture.remove() }
    let first = try fixture.reader.read(
      threadID: fixture.threadID,
      beforeCursor: nil,
      limits: CodexRecentThreadLimits(maxReadBytes: 16_384)
    )
    let cursor = try #require(first.objectValue?["next_before_cursor"]?.stringValue)
    var replacement = try Data(contentsOf: fixture.rollout)
    replacement.append(Data("{\"replacement\":true}\n".utf8))
    try FileManager.default.removeItem(at: fixture.rollout)
    try replacement.write(to: fixture.rollout)

    expectThrows(
      try fixture.reader.read(
        threadID: fixture.threadID,
        beforeCursor: cursor,
        limits: CodexRecentThreadLimits(maxReadBytes: 16_384)
      )
    ) { error in
      #expect(error as? CodexRecentThreadReaderError == .invalidCursor)
    }
  }
}

private struct RecentThreadFixture {
  let root: URL
  let workspace: URL
  let rollout: URL
  let threadID = "thread-large-fixture"
  let metadata: CodexPersistedThreadMetadata
  let reader: CodexRecentThreadReader
  let rolloutSize: Int

  init(recordCount: Int) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cm-recent-\(UUID().uuidString)",
      isDirectory: true
    )
    workspace = root.appendingPathComponent("Workspace", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    rollout = sessions.appendingPathComponent("rollout.jsonl")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    var data = Data()
    let padding = String(repeating: "x", count: 320)
    let goalOrdinal = max(0, recordCount - 1_200)
    for ordinal in 0..<recordCount {
      if ordinal == goalOrdinal {
        Self.append(
          .object([
            "timestamp": .string("2026-09-03T00:00:00Z"),
            "ordinal": .number(Double(ordinal)),
            "type": .string("event_msg"),
            "payload": .object([
              "type": .string("thread_goal_updated"),
              "threadId": .string(threadID),
              "goal": .object([
                "threadId": .string(threadID),
                "objective": .string("Complete bounded supervision."),
                "status": .string("active"),
                "tokensUsed": .number(1_000),
                "timeUsedSeconds": .number(60),
              ]),
            ]),
          ]),
          to: &data
        )
      } else if ordinal % 100 == 0 {
        let role = ordinal % 200 == 0 ? "user" : "assistant"
        Self.append(
          .object([
            "timestamp": .string("2026-09-03T00:00:00Z"),
            "ordinal": .number(Double(ordinal)),
            "type": .string("response_item"),
            "payload": .object([
              "type": .string("message"),
              "role": .string(role),
              "content": .array([
                .object([
                  "type": .string(role == "user" ? "input_text" : "output_text"),
                  "text": .string("\(role) progress \(ordinal)"),
                ])
              ]),
            ]),
          ]),
          to: &data
        )
      } else {
        Self.append(
          .object([
            "timestamp": .string("2026-09-03T00:00:00Z"),
            "ordinal": .number(Double(ordinal)),
            "type": .string("event_msg"),
            "payload": .object([
              "type": .string("token_count"),
              "turn_id": .string("turn-\(ordinal / 1_000)"),
              "padding": .string(padding),
            ]),
          ]),
          to: &data
        )
      }
    }
    Self.append(
      .object([
        "timestamp": .string("2026-09-03T00:00:01Z"),
        "ordinal": .number(Double(recordCount + 1)),
        "type": .string("event_msg"),
        "payload": .object([
          "type": .string("turn_started"),
          "thread_id": .string(threadID),
          "turn_id": .string("turn-active"),
        ]),
      ]),
      to: &data
    )
    Self.append(
      .object([
        "timestamp": .string("2026-09-03T00:00:02Z"),
        "ordinal": .number(Double(recordCount + 2)),
        "type": .string("event_msg"),
        "payload": .object([
          "type": .string("item_completed"),
          "thread_id": .string(threadID),
          "turn_id": .string("turn-active"),
          "item": .object([
            "id": .string("item-latest"),
            "type": .string("AgentMessage"),
            "status": .string("completed"),
            "text": .string("Latest bounded progress."),
          ]),
        ]),
      ]),
      to: &data
    )
    Self.append(
      .object([
        "timestamp": .string("2026-09-03T00:00:03Z"),
        "ordinal": .number(Double(recordCount + 3)),
        "type": .string("response_item"),
        "payload": .object([
          "type": .string("message"),
          "role": .string("user"),
          "content": .array([
            .object([
              "type": .string("input_text"),
              "text": .string("Latest user request."),
            ])
          ]),
        ]),
      ]),
      to: &data
    )
    Self.append(
      .object([
        "timestamp": .string("2026-09-03T00:00:04Z"),
        "ordinal": .number(Double(recordCount + 4)),
        "type": .string("response_item"),
        "payload": .object([
          "type": .string("message"),
          "role": .string("assistant"),
          "content": .array([
            .object([
              "type": .string("output_text"),
              "text": .string("Latest assistant progress."),
            ])
          ]),
        ]),
      ]),
      to: &data
    )
    try data.write(to: rollout, options: .atomic)
    rolloutSize = data.count
    metadata = CodexPersistedThreadMetadata(
      id: threadID,
      rolloutURL: rollout,
      cwd: workspace.path,
      title: "Large bounded thread",
      createdAtSeconds: 1,
      updatedAtSeconds: 2,
      tokensUsed: 3,
      archived: false,
      firstUserMessage: "Start the bounded test.",
      preview: "Bounded supervision fixture."
    )
    reader = CodexRecentThreadReader(
      workspaceURL: workspace,
      metadata: metadata,
      allowedRolloutRoot: root
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  private static func append(_ value: JSONValue, to data: inout Data) {
    let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
    if let encoded = try? encoder.encode(value) {
      data.append(encoded)
      data.append(0x0A)
    }
  }
}
