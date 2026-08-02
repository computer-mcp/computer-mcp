import Foundation

struct CodexBoundedText: Sendable {
  let value: String
  let originalBytes: Int
  let truncated: Bool
}

struct CodexOutputBounds: Sendable {
  let maxOutputBytes: Int
  let maxStructuredBytes: Int
  let maxFieldBytes: Int
  let maxEventPayloadBytes: Int

  init(maxOutputBytes: Int) {
    self.maxOutputBytes = max(maxOutputBytes, 1)
    maxStructuredBytes = max(maxOutputBytes / 3, 512)
    maxFieldBytes = min(max(maxStructuredBytes / 4, 256), 65_536)
    maxEventPayloadBytes = maxFieldBytes
  }

  func text(_ value: String, maxBytes: Int? = nil) -> CodexBoundedText {
    let limit = max(maxBytes ?? maxFieldBytes, 0)
    let originalBytes = value.utf8.count
    guard originalBytes > limit else {
      return CodexBoundedText(
        value: value,
        originalBytes: originalBytes,
        truncated: false
      )
    }

    var index = value.startIndex
    var byteCount = 0
    while index < value.endIndex {
      let next = value.index(after: index)
      let characterBytes = value[index..<next].utf8.count
      guard byteCount + characterBytes <= limit else {
        break
      }
      byteCount += characterBytes
      index = next
    }
    return CodexBoundedText(
      value: String(value[..<index]),
      originalBytes: originalBytes,
      truncated: true
    )
  }

  func json(_ value: JSONValue, maxBytes: Int? = nil) -> JSONValue {
    let limit = max(maxBytes ?? maxStructuredBytes, 1)
    guard let data = try? Self.encoded(value), data.count > limit else {
      return value
    }
    let preview = text(
      String(decoding: data, as: UTF8.self),
      maxBytes: max(limit - 192, 0)
    )
    return .object([
      "encoding": .string("json"),
      "original_bytes": .number(Double(data.count)),
      "preview": .string(preview.value),
      "truncated": .bool(true),
    ])
  }

  func encodedByteCount(_ value: JSONValue) -> Int {
    (try? Self.encoded(value).count) ?? 0
  }

  private static func encoded(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
}

struct CodexBufferedEvent: Sendable {
  let cursor: Int
  let timestamp: Date
  let kind: String
  let payload: JSONValue

  var json: JSONValue {
    .object([
      "cursor": .number(Double(cursor)),
      "timestamp": .string(timestamp.formatted(Self.timestampFormat)),
      "kind": .string(kind),
      "payload": payload,
    ])
  }

  private static let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

actor CodexEventBuffer {
  private let capacity: Int
  private let bounds: CodexOutputBounds
  private var events: [CodexBufferedEvent] = []
  private var nextCursor = 1

  init(capacity: Int, maxOutputBytes: Int = 1_048_576) {
    self.capacity = max(capacity, 1)
    self.bounds = CodexOutputBounds(maxOutputBytes: maxOutputBytes)
  }

  @discardableResult
  func append(kind: String, payload: JSONValue) -> Int {
    let cursor = nextCursor
    nextCursor += 1
    events.append(
      CodexBufferedEvent(
        cursor: cursor,
        timestamp: Date(),
        kind: kind,
        payload: bounds.json(payload, maxBytes: bounds.maxEventPayloadBytes)
      )
    )
    if events.count > capacity {
      events.removeFirst(events.count - capacity)
    }
    return cursor
  }

  func read(afterCursor: Int, maxResults: Int) -> JSONValue {
    let limit = min(max(maxResults, 1), 1_000)
    let firstRetainedCursor = events.first?.cursor ?? nextCursor
    let missed = max(firstRetainedCursor - max(afterCursor + 1, 1), 0)
    let available =
      events
      .filter { $0.cursor > afterCursor }
    var rows: [JSONValue] = []
    var encodedEventBytes = 0
    for event in available.prefix(limit) {
      let row = event.json
      let rowBytes = bounds.encodedByteCount(row)
      if !rows.isEmpty, encodedEventBytes + rowBytes > bounds.maxStructuredBytes {
        break
      }
      rows.append(row)
      encodedEventBytes += rowBytes
    }
    let resultCursor =
      rows.last?.objectValue?["cursor"]?.intValue
      ?? max(afterCursor, firstRetainedCursor - 1)
    let remaining = max(available.count - rows.count, 0)
    return .object([
      "after_cursor": .number(Double(afterCursor)),
      "next_cursor": .number(Double(resultCursor)),
      "events": .array(rows),
      "missed_events": .number(Double(missed)),
      "returned_events": .number(Double(rows.count)),
      "remaining_events": .number(Double(remaining)),
      "result_truncated": .bool(remaining > 0),
      "encoded_event_bytes": .number(Double(encodedEventBytes)),
      "max_output_bytes": .number(Double(bounds.maxOutputBytes)),
    ])
  }
}
