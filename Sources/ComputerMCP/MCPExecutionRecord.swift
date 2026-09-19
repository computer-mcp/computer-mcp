import CryptoKit
import Foundation

/// A receipt is observation of one dispatch, never authority to replay it.
struct MCPExecutionRecord: Codable, Sendable {
  enum State: String, Codable, Sendable {
    case dispatching, running, succeeded, failed
    case outcomeUnknown = "outcome_unknown"
  }

  static let maximumOutputBytes = 262_144
  static let outputRetention: TimeInterval = 86_400
  let scope: String
  let serverID: String
  let requestID: String
  let instanceID: String
  let tool: String
  let inputDigest: String
  let createdAt: Date
  var state: State = .dispatching
  var downstreamRequestID: String?
  var completedAt: Date?
  var cancellation = "not_requested"
  var cleanup = "not_observed"
  var outputJSON: String?
  var outputByteCount = 0
  var retainedByteCount = 0
  var outputExpiresAt: Date?

  var key: String { Self.digest(.array([.string(scope), .string(serverID), .string(requestID)])) }
  var isTerminal: Bool { state == .succeeded || state == .failed || state == .outcomeUnknown }

  static func digest(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // JSONValue contains only JSON primitives; nonfinite values are rejected before dispatch.
    guard let data = try? encoder.encode(value) else { return "invalid-json" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  mutating func finish(result: JSONValue, failed: Bool, now: Date = Date()) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(result)
    outputByteCount = bytes.count
    outputJSON = Self.utf8Prefix(bytes, limit: Self.maximumOutputBytes)
    retainedByteCount = outputJSON?.utf8.count ?? 0
    outputExpiresAt = now.addingTimeInterval(Self.outputRetention)
    completedAt = now
    state = failed ? .failed : .succeeded
  }

  func snapshot(instance: String, offset: Int = 0, maxBytes: Int = 32_768, now: Date = Date())
    throws
    -> JSONValue
  {
    guard offset >= 0, (4...65_536).contains(maxBytes) else {
      throw GatewayToolError.invalidArguments(
        "offset must be nonnegative; max_bytes must be 4...65536.")
    }
    let observedState = !isTerminal && instance != instanceID ? State.outcomeUnknown : state
    let expired = outputExpiresAt.map { $0 <= now } ?? false
    let output = expired ? nil : outputJSON
    let bytes = output.map { Data($0.utf8) } ?? Data()
    guard offset <= bytes.count else {
      throw GatewayToolError.invalidArguments(
        "[cursor.invalid] Output cursor is unavailable or exceeds retained output.")
    }
    // A caller may only continue on UTF-8 boundaries returned by this receipt.
    guard offset == bytes.count || offset == 0 || bytes[offset] & 0xC0 != 0x80 else {
      throw GatewayToolError.invalidArguments(
        "[cursor.invalid] Output cursor is not a UTF-8 boundary.")
    }
    let fragment = Self.utf8Prefix(Data(bytes.dropFirst(offset)), limit: maxBytes)
    let next = offset + fragment.utf8.count
    let truncated = retainedByteCount < outputByteCount
    let availability: String
    if expired {
      availability = "expired"
    } else if output != nil {
      availability = truncated ? "truncated" : "available"
    } else if observedState == .running || observedState == .dispatching {
      availability = "pending"
    } else {
      availability = "unavailable"
    }
    var value: [String: JSONValue] = [
      "server": .string(serverID), "tool": .string(tool), "request_id": .string(requestID),
      "state": .string(observedState.rawValue),
      "downstream_request_id": downstreamRequestID.map(JSONValue.string) ?? .null,
      "started_at": .number(createdAt.timeIntervalSince1970),
      "completed_at": completedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
      "cancellation": .string(cancellation), "cleanup": .string(cleanup),
      "output_state": .string(availability), "output_bytes": .number(Double(outputByteCount)),
      "retained_bytes": .number(Double(bytes.count)), "offset": .number(Double(offset)),
      "next_offset": .number(Double(next)), "has_more": .bool(next < bytes.count),
      "truncated": .bool(truncated), "replayed": .bool(false),
    ]
    if output != nil, !truncated, offset == 0, next == bytes.count {
      value["result"] = try JSONDecoder().decode(JSONValue.self, from: bytes)
    } else {
      value["output_json_fragment"] = output == nil ? .null : .string(fragment)
    }
    return .object(value)
  }

  private static func utf8Prefix(_ data: Data, limit: Int) -> String {
    var end = min(data.count, limit)
    if let value = String(data: data.prefix(end), encoding: .utf8) {
      return value
    }
    // At most three continuation bytes can fall across a valid UTF-8 boundary.
    while end > 0 {
      end -= 1
      if let value = String(data: data.prefix(end), encoding: .utf8) { return value }
    }
    return ""
  }
}

/// Scope comes exclusively from the host's verified context, not tool arguments.
final class MCPExecutionJournal: @unchecked Sendable {
  let instanceID = UUID().uuidString
  let scope: String
  private let database: Result<GatewayDatabase, any Error>

  init(database: GatewayDatabase?, scope: String) {
    self.scope = scope
    self.database = Result { try database ?? GatewayDatabase(inMemory: ()) }
  }

  func reserve(server: MCPServerConfig, tool: String, arguments: JSONValue, requestID: String)
    throws
    -> (record: MCPExecutionRecord, inserted: Bool)
  {
    guard requestID.utf8.count <= 256 else {
      throw GatewayToolError.invalidArguments("request_id must not exceed 256 UTF-8 bytes.")
    }
    let intent = JSONValue.object([
      "server": try .encoded(server), "tool": .string(tool), "arguments": arguments,
    ])
    let encoder = JSONEncoder()
    _ = try encoder.encode(intent)
    let record = MCPExecutionRecord(
      scope: scope, serverID: server.id, requestID: requestID, instanceID: instanceID,
      tool: tool, inputDigest: MCPExecutionRecord.digest(intent), createdAt: Date())
    return try database.get().reserveMCPExecution(record)
  }

  func read(serverID: String, requestID: String) throws -> MCPExecutionRecord {
    guard
      let record = try database.get().mcpExecution(
        scope: scope, serverID: serverID, requestID: requestID)
    else {
      throw GatewayToolError.invalidArguments("Unknown downstream MCP request id.")
    }
    return record
  }

  func update(
    serverID: String, requestID: String, change: (inout MCPExecutionRecord) throws -> Void
  ) throws {
    try database.get().updateMCPExecution(
      scope: scope, serverID: serverID, requestID: requestID, instanceID: instanceID, change: change
    )
  }
}
