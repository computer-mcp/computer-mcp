import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class CodexEventBufferTests {
  @Test
  func testLargeEventPayloadIsReplacedWithBoundedMechanicalPreview() async throws {
    let buffer = CodexEventBuffer(capacity: 64, maxOutputBytes: 4_096)
    await buffer.append(
      kind: "server_message",
      payload: .object(["html": .string(String(repeating: "x", count: 32_000))])
    )

    let result = await buffer.read(afterCursor: 0, maxResults: 100)
    let event = try #require(result.objectValue?["events"]?.arrayValue?.first?.objectValue)
    let payload = try #require(event["payload"]?.objectValue)

    #expect((payload["truncated"]) == (.bool(true)))
    #expect((payload["encoding"]) == (.string("json")))
    #expect((payload["original_bytes"]?.intValue ?? 0) > (32_000))
    #expect((payload["preview"]?.stringValue?.utf8.count ?? .max) < (4_096))
    #expect((result.objectValue?["result_truncated"]) == (.bool(false)))
  }

  @Test
  func testEventPageStopsAtByteBudgetAndCursorCanContinue() async throws {
    let buffer = CodexEventBuffer(capacity: 64, maxOutputBytes: 4_096)
    for sequence in 1...12 {
      await buffer.append(
        kind: "chunk",
        payload: .object([
          "sequence": .number(Double(sequence)),
          "text": .string(String(repeating: "a", count: 240)),
        ])
      )
    }

    let first = await buffer.read(afterCursor: 0, maxResults: 100)
    let firstCount = try #require(first.objectValue?["returned_events"]?.intValue)
    let firstCursor = try #require(first.objectValue?["next_cursor"]?.intValue)

    #expect((firstCount) > (0))
    #expect((firstCount) < (12))
    #expect((first.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((first.objectValue?["remaining_events"]) == (.number(Double(12 - firstCount))))

    let second = await buffer.read(afterCursor: firstCursor, maxResults: 100)
    #expect((second.objectValue?["returned_events"]?.intValue ?? 0) > (0))
    #expect((second.objectValue?["after_cursor"]) == (.number(Double(firstCursor))))
  }

  @Test
  func testEventPayloadIsRedactedBeforeRetention() async throws {
    let buffer = CodexEventBuffer(capacity: 8, maxOutputBytes: 4_096)
    await buffer.append(
      kind: "diagnostic",
      payload: .object([
        "message": .string("Authorization: Bearer event-secret"),
        "token": .string("event-secret"),
      ])
    )

    let result = await buffer.read(afterCursor: 0, maxResults: 10)
    let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    #expect(encoded.contains("[REDACTED]"))
    #expect(!encoded.contains("event-secret"))
  }
}
