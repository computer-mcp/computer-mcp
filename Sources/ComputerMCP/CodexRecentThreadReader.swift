import CryptoKit
import Foundation
import GRDB

struct CodexPersistedThreadMetadata: Equatable, Sendable {
  let id: String
  let rolloutURL: URL
  let cwd: String
  let title: String
  let createdAtSeconds: Int64
  let updatedAtSeconds: Int64
  let tokensUsed: Int64
  let archived: Bool
  let firstUserMessage: String
  let preview: String
}

struct CodexRecentThreadLimits: Equatable, Sendable {
  static let maximumReadBytes = 1_048_576
  static let maximumGoalScanBytes = 4 * 1_048_576
  static let maximumOutputBytes = 1_048_576
  static let maximumElapsedMilliseconds = 5_000

  let maxTurns: Int
  let maxMessages: Int
  let maxItems: Int
  let maxReadBytes: Int
  let maxOutputBytes: Int
  let maxElapsedMilliseconds: Int

  init(
    maxTurns: Int = 10,
    maxMessages: Int = 50,
    maxItems: Int = 100,
    maxReadBytes: Int = 262_144,
    maxOutputBytes: Int = 524_288,
    maxElapsedMilliseconds: Int = 2_000
  ) {
    self.maxTurns = max(1, min(maxTurns, 50))
    self.maxMessages = max(1, min(maxMessages, 200))
    self.maxItems = max(1, min(maxItems, 500))
    self.maxReadBytes = max(4_096, min(maxReadBytes, Self.maximumReadBytes))
    self.maxOutputBytes = max(4_096, min(maxOutputBytes, Self.maximumOutputBytes))
    self.maxElapsedMilliseconds = max(
      50,
      min(maxElapsedMilliseconds, Self.maximumElapsedMilliseconds)
    )
  }
}

enum CodexRecentThreadReaderError: Error, LocalizedError, Equatable {
  case stateDatabaseUnavailable(String)
  case unknownThread(String)
  case outsideWorkspace
  case rolloutOutsideCodexHome
  case rolloutUnavailable
  case invalidCursor

  var errorDescription: String? {
    switch self {
    case .stateDatabaseUnavailable(let path):
      return "Codex state database is unavailable at '\(path)'."
    case .unknownThread(let id):
      return "Unknown persisted Codex thread '\(id)'."
    case .outsideWorkspace:
      return "The persisted thread belongs to a different canonical workspace."
    case .rolloutOutsideCodexHome:
      return "The persisted rollout path is outside the configured Codex home."
    case .rolloutUnavailable:
      return "The persisted rollout is not a readable regular file."
    case .invalidCursor:
      return "The recent-thread cursor is invalid or belongs to another rollout snapshot."
    }
  }
}

struct CodexRecentThreadReader: Sendable {
  private let workspaceURL: URL
  private let stateDatabaseURL: URL?
  private let allowedRolloutRoot: URL
  private let fixedMetadata: CodexPersistedThreadMetadata?

  init(
    workspaceURL: URL,
    stateDatabaseURL: URL,
    allowedRolloutRoot: URL
  ) {
    self.workspaceURL = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    self.stateDatabaseURL = stateDatabaseURL.standardizedFileURL
    self.allowedRolloutRoot = allowedRolloutRoot.standardizedFileURL.resolvingSymlinksInPath()
    fixedMetadata = nil
  }

  init(
    workspaceURL: URL,
    metadata: CodexPersistedThreadMetadata,
    allowedRolloutRoot: URL
  ) {
    self.workspaceURL = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    stateDatabaseURL = nil
    self.allowedRolloutRoot = allowedRolloutRoot.standardizedFileURL.resolvingSymlinksInPath()
    fixedMetadata = metadata
  }

  static func live(workspaceURL: URL) -> CodexRecentThreadReader {
    let environment = ProcessInfo.processInfo.environment
    let codexHome =
      environment["CODEX_HOME"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".codex",
        isDirectory: true
      )
    return CodexRecentThreadReader(
      workspaceURL: workspaceURL,
      stateDatabaseURL: newestStateDatabase(in: codexHome),
      allowedRolloutRoot: codexHome
    )
  }

  private static func newestStateDatabase(in codexHome: URL) -> URL {
    let candidates =
      (try? FileManager.default.contentsOfDirectory(
        at: codexHome,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )) ?? []
    return candidates.compactMap { url -> (version: Int, url: URL)? in
      let name = url.lastPathComponent
      guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
      let versionText = name.dropFirst("state_".count).dropLast(".sqlite".count)
      guard let version = Int(versionText) else { return nil }
      return (version, url)
    }.max { $0.version < $1.version }?.url
      ?? codexHome.appendingPathComponent("state_5.sqlite")
  }

  func read(
    threadID: String,
    beforeCursor: String?,
    limits: CodexRecentThreadLimits
  ) throws -> JSONValue {
    let clock = ContinuousClock()
    let started = clock.now
    let deadline = started.advanced(by: .milliseconds(limits.maxElapsedMilliseconds))
    let metadata = try resolveMetadata(threadID: threadID)
    let rolloutURL = try validatedRolloutURL(metadata: metadata)
    let rollout = try rolloutFile(at: rolloutURL)
    let cursorIdentity = cursorIdentityFor(metadata: metadata, rollout: rollout)
    let cursor = try decodeCursor(
      beforeCursor,
      identity: cursorIdentity,
      currentFileSize: rollout.size
    )
    let page = try readPage(
      url: rollout.url,
      snapshotSize: cursor.snapshotSize,
      endOffset: cursor.endOffset,
      maxBytes: limits.maxReadBytes,
      maxRecords: min(2_000, max(200, (limits.maxMessages + limits.maxItems) * 4))
    )
    let decoded = page.lines.compactMap(Self.decodeRecord)
    let summaries = Self.summarize(decoded, limits: limits)
    let goalScan = try latestGoal(
      in: rollout.url,
      snapshotSize: cursor.snapshotSize,
      preferredRecords: decoded,
      maximumBytes: CodexRecentThreadLimits.maximumGoalScanBytes,
      deadline: deadline
    )
    let elapsed = started.duration(to: clock.now)
    let elapsedMilliseconds = Self.milliseconds(elapsed)
    let nextCursor = page.nextEndOffset.map {
      encodeCursor(identity: cursorIdentity, snapshotSize: cursor.snapshotSize, endOffset: $0)
    }
    let metadataObject: JSONValue = .object([
      "id": .string(metadata.id),
      "cwd": .string(metadata.cwd),
      "title": .string(Self.bounded(metadata.title, maximumCharacters: 2_048)),
      "created_at_seconds": .number(Double(metadata.createdAtSeconds)),
      "updated_at_seconds": .number(Double(metadata.updatedAtSeconds)),
      "tokens_used": .number(Double(metadata.tokensUsed)),
      "archived": .bool(metadata.archived),
      "first_user_message": .string(
        Self.bounded(
          CodexApprovalRedactor.redactString(
            metadata.firstUserMessage,
            maximumCharacters: 8_192
          ),
          maximumCharacters: 8_192
        )
      ),
      "preview": .string(
        Self.bounded(
          CodexApprovalRedactor.redactString(metadata.preview, maximumCharacters: 8_192),
          maximumCharacters: 8_192
        )
      ),
      "rollout_size_bytes": .number(Double(rollout.size)),
    ])
    let result: JSONValue = .object([
      "schema_version": .number(1),
      "thread": metadataObject,
      "goal": goalScan.goal ?? .null,
      "active_turn": summaries.activeTurn ?? .null,
      "recent_turns": .array(summaries.turns),
      "recent_messages": .array(summaries.messages),
      "recent_items": .array(summaries.items),
      "latest_assistant_progress": summaries.latestAssistantProgress ?? .null,
      "latest_user_request": summaries.latestUserRequest ?? .null,
      "before_cursor": beforeCursor.map(JSONValue.string) ?? .null,
      "next_before_cursor": nextCursor.map(JSONValue.string) ?? .null,
      "has_more": .bool(nextCursor != nil),
      "bounds": .object([
        "page_bytes_read": .number(Double(page.bytesRead)),
        "goal_scan_bytes_read": .number(Double(goalScan.bytesRead)),
        "total_io_bytes_read": .number(Double(page.bytesRead + goalScan.bytesRead)),
        "records_decoded": .number(Double(decoded.count)),
        "max_turns": .number(Double(limits.maxTurns)),
        "max_messages": .number(Double(limits.maxMessages)),
        "max_items": .number(Double(limits.maxItems)),
        "max_page_bytes": .number(Double(limits.maxReadBytes)),
        "max_goal_scan_bytes": .number(Double(CodexRecentThreadLimits.maximumGoalScanBytes)),
        "max_output_bytes": .number(Double(limits.maxOutputBytes)),
        "max_elapsed_milliseconds": .number(Double(limits.maxElapsedMilliseconds)),
        "latency_budget_exhausted": .bool(goalScan.latencyBudgetExhausted),
        "elapsed_milliseconds": .number(elapsedMilliseconds),
      ]),
      "source": .string("read-only-persisted-rollout-tail"),
      "full_history_loaded": .bool(false),
      "state_database_mutated": .bool(false),
    ])
    return CodexOutputBounds(maxOutputBytes: limits.maxOutputBytes).json(
      CodexApprovalRedactor.redact(result),
      maxBytes: limits.maxOutputBytes
    )
  }

  private func resolveMetadata(threadID: String) throws -> CodexPersistedThreadMetadata {
    if let fixedMetadata {
      guard fixedMetadata.id == threadID else {
        throw CodexRecentThreadReaderError.unknownThread(threadID)
      }
      return fixedMetadata
    }
    guard let stateDatabaseURL,
      FileManager.default.fileExists(atPath: stateDatabaseURL.path)
    else {
      throw CodexRecentThreadReaderError.stateDatabaseUnavailable(
        stateDatabaseURL?.path ?? "unknown"
      )
    }
    var configuration = Configuration()
    configuration.readonly = true
    let queue = try DatabaseQueue(path: stateDatabaseURL.path, configuration: configuration)
    return try queue.read { database in
      guard
        let row = try Row.fetchOne(
          database,
          sql: """
            SELECT id, rollout_path, cwd, title, created_at, updated_at,
                   tokens_used, archived, first_user_message, preview
            FROM threads WHERE id = ? LIMIT 1
            """,
          arguments: [threadID]
        )
      else {
        throw CodexRecentThreadReaderError.unknownThread(threadID)
      }
      return CodexPersistedThreadMetadata(
        id: row["id"],
        rolloutURL: URL(fileURLWithPath: row["rollout_path"]),
        cwd: row["cwd"],
        title: row["title"],
        createdAtSeconds: row["created_at"],
        updatedAtSeconds: row["updated_at"],
        tokensUsed: row["tokens_used"],
        archived: (row["archived"] as Int64) != 0,
        firstUserMessage: row["first_user_message"],
        preview: row["preview"]
      )
    }
  }

  private func validatedRolloutURL(metadata: CodexPersistedThreadMetadata) throws -> URL {
    let recordedWorkspace = URL(fileURLWithPath: metadata.cwd, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    guard recordedWorkspace == workspaceURL else {
      throw CodexRecentThreadReaderError.outsideWorkspace
    }
    let rollout = metadata.rolloutURL.standardizedFileURL.resolvingSymlinksInPath()
    let rootPath =
      allowedRolloutRoot.path.hasSuffix("/")
      ? allowedRolloutRoot.path : allowedRolloutRoot.path + "/"
    guard rollout.path == allowedRolloutRoot.path || rollout.path.hasPrefix(rootPath) else {
      throw CodexRecentThreadReaderError.rolloutOutsideCodexHome
    }
    return rollout
  }

  private struct RolloutFile {
    let url: URL
    let size: UInt64
    let systemNumber: UInt64
    let fileNumber: UInt64
  }

  private func rolloutFile(at url: URL) throws -> RolloutFile {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber,
      let systemNumber = attributes[.systemNumber] as? NSNumber,
      let fileNumber = attributes[.systemFileNumber] as? NSNumber
    else {
      throw CodexRecentThreadReaderError.rolloutUnavailable
    }
    return RolloutFile(
      url: url,
      size: size.uint64Value,
      systemNumber: systemNumber.uint64Value,
      fileNumber: fileNumber.uint64Value
    )
  }

  private struct Cursor {
    let snapshotSize: UInt64
    let endOffset: UInt64
  }

  private func decodeCursor(
    _ value: String?,
    identity: String,
    currentFileSize: UInt64
  ) throws -> Cursor {
    guard let value else {
      return Cursor(snapshotSize: currentFileSize, endOffset: currentFileSize)
    }
    let components = value.split(separator: ":", omittingEmptySubsequences: false)
    guard components.count == 4, components[0] == "v1", components[1] == identity,
      let snapshotSize = UInt64(components[2]),
      let endOffset = UInt64(components[3]),
      snapshotSize <= currentFileSize,
      endOffset <= snapshotSize
    else {
      throw CodexRecentThreadReaderError.invalidCursor
    }
    return Cursor(snapshotSize: snapshotSize, endOffset: endOffset)
  }

  private func encodeCursor(
    identity: String,
    snapshotSize: UInt64,
    endOffset: UInt64
  ) -> String {
    "v1:\(identity):\(snapshotSize):\(endOffset)"
  }

  private func cursorIdentityFor(
    metadata: CodexPersistedThreadMetadata,
    rollout: RolloutFile
  ) -> String {
    let input = Data(
      "\(metadata.id)\u{0}\(rollout.url.path)\u{0}\(rollout.systemNumber)\u{0}\(rollout.fileNumber)"
        .utf8
    )
    return SHA256.hash(data: input).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  private struct LocatedLine {
    let offset: UInt64
    let data: Data
  }

  private struct Page {
    let lines: [LocatedLine]
    let nextEndOffset: UInt64?
    let bytesRead: Int
  }

  private func readPage(
    url: URL,
    snapshotSize: UInt64,
    endOffset: UInt64,
    maxBytes: Int,
    maxRecords: Int
  ) throws -> Page {
    let boundedEnd = min(endOffset, snapshotSize)
    let rawStart = boundedEnd > UInt64(maxBytes) ? boundedEnd - UInt64(maxBytes) : 0
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: rawStart)
    let data = try handle.read(upToCount: Int(boundedEnd - rawStart)) ?? Data()
    let bytes = [UInt8](data)
    var lineStart = 0
    if rawStart > 0 {
      guard let newline = bytes.firstIndex(of: 0x0A) else {
        return Page(lines: [], nextEndOffset: rawStart > 0 ? rawStart : nil, bytesRead: data.count)
      }
      lineStart = newline + 1
    }
    var located: [LocatedLine] = []
    var current = lineStart
    for index in lineStart..<bytes.count where bytes[index] == 0x0A {
      if index > current {
        located.append(
          LocatedLine(
            offset: rawStart + UInt64(current),
            data: data.subdata(in: current..<index)
          )
        )
      }
      current = index + 1
    }
    if current < bytes.count {
      located.append(
        LocatedLine(
          offset: rawStart + UInt64(current),
          data: data.subdata(in: current..<bytes.count)
        )
      )
    }
    let selected = Array(located.suffix(maxRecords))
    let nextOffset: UInt64?
    if let first = selected.first, first.offset > 0 {
      nextOffset = first.offset
    } else if rawStart > 0 {
      nextOffset = rawStart
    } else {
      nextOffset = nil
    }
    return Page(lines: selected, nextEndOffset: nextOffset, bytesRead: data.count)
  }

  private struct DecodedRecord {
    let timestamp: String?
    let ordinal: Int?
    let type: String
    let payload: [String: JSONValue]
  }

  private static func decodeRecord(_ line: LocatedLine) -> DecodedRecord? {
    guard line.data.count <= CodexRecentThreadLimits.maximumReadBytes,
      let value = try? JSONDecoder().decode(JSONValue.self, from: line.data),
      let object = value.objectValue,
      let type = object["type"]?.stringValue,
      let payload = object["payload"]?.objectValue
    else { return nil }
    return DecodedRecord(
      timestamp: object["timestamp"]?.stringValue,
      ordinal: object["ordinal"]?.intValue,
      type: type,
      payload: payload
    )
  }

  private struct Summaries {
    let turns: [JSONValue]
    let messages: [JSONValue]
    let items: [JSONValue]
    let activeTurn: JSONValue?
    let latestAssistantProgress: JSONValue?
    let latestUserRequest: JSONValue?
  }

  private static func summarize(
    _ records: [DecodedRecord],
    limits: CodexRecentThreadLimits
  ) -> Summaries {
    var turnOrder: [String] = []
    var turnStatus: [String: String] = [:]
    var turnTimestamps: [String: String] = [:]
    var messages: [JSONValue] = []
    var items: [JSONValue] = []
    var activeTurnID: String?
    var latestAssistantProgress: JSONValue?
    var latestUserRequest: JSONValue?

    for record in records {
      let payloadType = record.payload["type"]?.stringValue ?? record.type
      if let turnID = record.payload["turn_id"]?.stringValue
        ?? record.payload["turnId"]?.stringValue
        ?? record.payload["turn"]?.objectValue?["id"]?.stringValue
      {
        if !turnOrder.contains(turnID) { turnOrder.append(turnID) }
        if let timestamp = record.timestamp { turnTimestamps[turnID] = timestamp }
        if payloadType.contains("turn_started") || payloadType.contains("turn/started") {
          turnStatus[turnID] = "in_progress"
          activeTurnID = turnID
        } else if payloadType.contains("turn_completed")
          || payloadType.contains("turn/completed")
          || payloadType.contains("turn_aborted")
        {
          turnStatus[turnID] = "completed"
          if activeTurnID == turnID { activeTurnID = nil }
        }
      }

      if record.type == "response_item",
        record.payload["type"]?.stringValue == "message",
        let role = record.payload["role"]?.stringValue
      {
        let text = messageText(record.payload)
        guard !text.isEmpty else { continue }
        let message: JSONValue = .object([
          "role": .string(role),
          "text": .string(
            bounded(
              CodexApprovalRedactor.redactString(text, maximumCharacters: 8_192),
              maximumCharacters: 8_192
            )
          ),
          "timestamp": record.timestamp.map(JSONValue.string) ?? .null,
          "ordinal": record.ordinal.map { .number(Double($0)) } ?? .null,
        ])
        messages.append(message)
        if role == "assistant" { latestAssistantProgress = message }
        if role == "user" { latestUserRequest = message }
      }

      if record.type == "event_msg",
        ["item_started", "item_completed", "item_updated"].contains(payloadType),
        let item = record.payload["item"]?.objectValue
      {
        let itemType = item["type"]?.stringValue ?? "unknown"
        let summary = itemSummary(item)
        items.append(
          .object([
            "id": item["id"] ?? .null,
            "type": .string(itemType),
            "status": item["status"] ?? .string(payloadType),
            "summary": summary.map {
              .string(
                bounded(
                  CodexApprovalRedactor.redactString($0, maximumCharacters: 4_096),
                  maximumCharacters: 4_096
                )
              )
            } ?? .null,
            "timestamp": record.timestamp.map(JSONValue.string) ?? .null,
            "ordinal": record.ordinal.map { .number(Double($0)) } ?? .null,
          ])
        )
      }
    }

    let recentTurnIDs = Array(turnOrder.suffix(limits.maxTurns))
    let turns = recentTurnIDs.map { turnID in
      JSONValue.object([
        "turn_id": .string(turnID),
        "status": .string(turnStatus[turnID] ?? "observed"),
        "latest_timestamp": turnTimestamps[turnID].map(JSONValue.string) ?? .null,
      ])
    }
    let activeTurn = activeTurnID.map { turnID in
      JSONValue.object([
        "turn_id": .string(turnID),
        "status": .string(turnStatus[turnID] ?? "in_progress"),
      ])
    }
    return Summaries(
      turns: turns,
      messages: Array(messages.suffix(limits.maxMessages)),
      items: Array(items.suffix(limits.maxItems)),
      activeTurn: activeTurn,
      latestAssistantProgress: latestAssistantProgress,
      latestUserRequest: latestUserRequest
    )
  }

  private struct GoalScan {
    let goal: JSONValue?
    let bytesRead: Int
    let latencyBudgetExhausted: Bool
  }

  private func latestGoal(
    in url: URL,
    snapshotSize: UInt64,
    preferredRecords: [DecodedRecord],
    maximumBytes: Int,
    deadline: ContinuousClock.Instant
  ) throws -> GoalScan {
    if let goal = Self.latestGoal(in: preferredRecords) {
      return GoalScan(goal: goal, bytesRead: 0, latencyBudgetExhausted: false)
    }
    let clock = ContinuousClock()
    var end = snapshotSize
    var totalBytes = 0
    while end > 0, totalBytes < maximumBytes {
      guard clock.now < deadline else {
        return GoalScan(goal: nil, bytesRead: totalBytes, latencyBudgetExhausted: true)
      }
      let allowance = min(262_144, maximumBytes - totalBytes)
      let page = try readPage(
        url: url,
        snapshotSize: snapshotSize,
        endOffset: end,
        maxBytes: allowance,
        maxRecords: 2_000
      )
      totalBytes += page.bytesRead
      let records = page.lines.compactMap(Self.decodeRecord)
      if let goal = Self.latestGoal(in: records) {
        return GoalScan(goal: goal, bytesRead: totalBytes, latencyBudgetExhausted: false)
      }
      guard let next = page.nextEndOffset, next < end else { break }
      end = next
    }
    return GoalScan(
      goal: nil,
      bytesRead: totalBytes,
      latencyBudgetExhausted: clock.now >= deadline
    )
  }

  private static func latestGoal(in records: [DecodedRecord]) -> JSONValue? {
    for record in records.reversed() where record.type == "event_msg" {
      let type = record.payload["type"]?.stringValue
      if type == "thread_goal_cleared" { return .null }
      if type == "thread_goal_updated", let goal = record.payload["goal"] {
        return CodexApprovalRedactor.redact(goal)
      }
    }
    return nil
  }

  private static func messageText(_ payload: [String: JSONValue]) -> String {
    (payload["content"]?.arrayValue ?? []).compactMap { content in
      let object = content.objectValue
      return object?["text"]?.stringValue
        ?? object?["input_text"]?.stringValue
        ?? object?["output_text"]?.stringValue
    }.joined(separator: "\n")
  }

  private static func itemSummary(_ item: [String: JSONValue]) -> String? {
    if let text = item["text"]?.stringValue { return text }
    if let command = item["command"]?.arrayValue?.compactMap(\.stringValue) {
      return command.joined(separator: " ")
    }
    if let summaries = item["summary_text"]?.arrayValue?.compactMap(\.stringValue) {
      return summaries.joined(separator: " ")
    }
    return nil
  }

  private static func bounded(_ value: String, maximumCharacters: Int) -> String {
    String(value.prefix(maximumCharacters))
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }
}
