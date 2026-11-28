import ComputerMCPCore
import Foundation

/// Correlates TRAE's native ACP requests within one owned workload.
struct TraeVendorProtocol {
  private enum PeerID: Hashable {
    case integer(Int64)
    case text(Data)

    init?(_ value: JSONValue?) {
      if case .integer(let number) = value {
        self = .integer(number)
      } else if let id = TraeVendorProtocol.identifier(value) {
        self = .text(Data(id.utf8))
      } else {
        return nil
      }
    }
  }

  private enum Request {
    case initialize, session, prompt, close
  }

  private struct Permission {
    let id: PeerID
    let options: Set<Data>
  }

  private let directory: String
  private let operation: String
  private let requestedSession: String?
  private var capabilities: [String: JSONValue]?
  private var nativeSession: String?
  private var lastRequestID: Int64 = 0
  private var pendingRequest: Request?
  private var unboundPermissions: [Permission] = []
  private var permissions: [String: Permission] = [:]
  private var unsupportedRequests: Set<PeerID> = []
  private(set) var closeDispatched = false

  var sessionReady: Bool { nativeSession != nil }
  var promptInFlight: Bool { pendingRequest == .prompt }
  private var restoringSession: Bool { operation == "load" || operation == "resume" }

  init(open: [String: JSONValue], directory: String) throws {
    let operation = open["operation"] ?? .string("new")
    let session = Self.identifier(open["native_session_id"])
    guard let name = operation.stringValue, ["new", "load", "resume", "fork"].contains(name),
      open["sandbox"].map({ $0 == .string("read-only") }) ?? true,
      name == "new" ? open["native_session_id"] == nil : session != nil
    else { throw VendorExecutionFailure.denied }
    self.directory = directory
    self.operation = name
    requestedSession = session
  }

  static func canonicalLine(_ line: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    guard let message = try? JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8)),
      let bytes = try? encoder.encode(message)
    else { throw VendorExecutionFailure.denied }
    return String(decoding: bytes, as: UTF8.self)
  }

  mutating func bindPermission(_ token: String) throws {
    guard !unboundPermissions.isEmpty else { throw VendorExecutionFailure.denied }
    permissions[token] = unboundPermissions.removeFirst()
  }

  mutating func finishTurn() {
    unboundPermissions.removeAll()
    permissions.removeAll()
    unsupportedRequests.removeAll()
  }

  mutating func commitWrite(
    _ kind: String, line: String, token: String?, arguments: [String: JSONValue]
  ) throws {
    guard let message = Self.message(Data(line.utf8)) else { throw VendorExecutionFailure.denied }
    switch kind {
    case "setup", "prompt", "close":
      try request(kind, message: message, arguments: arguments)
    case "cancel":
      guard let nativeSession, message.count == 3, message["method"] == .string("session/cancel"),
        let params = message["params"]?.objectValue, params.count == 1,
        Self.matches(params["sessionId"], nativeSession)
      else { throw VendorExecutionFailure.denied }
    case "answer", "housekeeping":
      try response(kind, message: message, token: token, arguments: arguments)
    default: throw VendorExecutionFailure.denied
    }
  }

  private mutating func request(
    _ kind: String, message: [String: JSONValue], arguments: [String: JSONValue]
  ) throws {
    guard pendingRequest == nil, message.count == 4,
      case .integer(let id) = message["id"], id > lastRequestID,
      let method = message["method"]?.stringValue, let params = message["params"]?.objectValue
    else { throw VendorExecutionFailure.denied }
    let request: Request
    switch (kind, method) {
    case ("setup", "initialize"):
      guard lastRequestID == 0, params.count == 3, params["protocolVersion"] == .integer(1),
        params["clientCapabilities"] == .object([:]),
        let client = params["clientInfo"]?.objectValue, client.count == 2,
        client["name"] == .string("computer-mcp-plugin-trae"),
        Self.identifier(client["version"]) != nil
      else { throw VendorExecutionFailure.denied }
      request = .initialize
    case ("setup", "session/" + operation):
      let supportsOperation =
        operation == "new"
        || (operation == "load" && capabilities?["loadSession"] == .bool(true))
        || (["resume", "fork"].contains(operation)
          && capabilities?["sessionCapabilities"]?.objectValue?[operation]?.objectValue != nil)
      guard capabilities != nil, nativeSession == nil, supportsOperation,
        params.count == (requestedSession == nil ? 2 : 3),
        Self.matches(params["cwd"], directory), params["mcpServers"] == .array([]),
        requestedSession.map({ Self.matches(params["sessionId"], $0) }) ?? true
      else { throw VendorExecutionFailure.denied }
      request = .session
    case ("prompt", "session/prompt"):
      guard let nativeSession, !closeDispatched, params.count == 2,
        Self.matches(params["sessionId"], nativeSession),
        let prompt = arguments["prompt"]?.stringValue,
        let content = params["prompt"]?.arrayValue, content.count == 1,
        let item = content.first?.objectValue, item.count == 2, item["type"] == .string("text"),
        Self.matches(item["text"], prompt)
      else { throw VendorExecutionFailure.denied }
      request = .prompt
    case ("close", "session/close"):
      guard let nativeSession, !closeDispatched, params.count == 1,
        Self.matches(params["sessionId"], nativeSession),
        capabilities?["sessionCapabilities"]?.objectValue?["close"]?.objectValue != nil
      else { throw VendorExecutionFailure.denied }
      closeDispatched = true
      request = .close
    default: throw VendorExecutionFailure.denied
    }
    lastRequestID = id
    pendingRequest = request
  }

  private mutating func response(
    _ kind: String, message: [String: JSONValue], token: String?, arguments: [String: JSONValue]
  ) throws {
    guard message.count == 3, let id = PeerID(message["id"]) else {
      throw VendorExecutionFailure.denied
    }
    if let token {
      guard let permission = permissions[token], permission.id == id,
        let result = message["result"]?.objectValue, result.count == 1,
        let outcome = result["outcome"]?.objectValue
      else { throw VendorExecutionFailure.denied }
      if kind == "answer", let option = arguments["option_id"] {
        guard let choice = Self.identifier(option), permission.options.contains(Data(choice.utf8)),
          outcome.count == 2, outcome["outcome"] == .string("selected"),
          Self.matches(outcome["optionId"], choice)
        else { throw VendorExecutionFailure.denied }
      } else {
        guard outcome == ["outcome": .string("cancelled")] else {
          throw VendorExecutionFailure.denied
        }
      }
      permissions[token] = nil
    } else {
      guard kind == "housekeeping",
        message["error"]
          == .object([
            "code": .integer(-32601), "message": .string("Client method not supported"),
          ]), unsupportedRequests.remove(id) != nil
      else { throw VendorExecutionFailure.denied }
    }
  }

  mutating func observe(_ bytes: Data) {
    guard let message = Self.message(bytes) else { return }
    if let method = message["method"]?.stringValue, let id = PeerID(message["id"]) {
      observePeerRequest(method, id: id, params: message["params"]?.objectValue)
      return
    }
    guard message["id"] == .integer(lastRequestID), message["method"] == nil,
      (message["error"] == nil) != (message["result"] == nil),
      let request = pendingRequest
    else { return }
    pendingRequest = nil
    guard let result = message["result"]?.objectValue else { return }
    switch request {
    case .initialize:
      guard result["protocolVersion"] == .integer(1) else { return }
      capabilities = result["agentCapabilities"]?.objectValue
    case .session:
      if restoringSession, let requestedSession {
        guard result["sessionId"] == nil || Self.matches(result["sessionId"], requestedSession)
        else { return }
        nativeSession = requestedSession
      } else {
        nativeSession = Self.identifier(result["sessionId"])
      }
    case .prompt, .close:
      break
    }
  }

  private mutating func observePeerRequest(
    _ method: String, id: PeerID, params: [String: JSONValue]?
  ) {
    if method != "session/request_permission" {
      if unsupportedRequests.count < 16 { unsupportedRequests.insert(id) }
      return
    }
    let session =
      nativeSession ?? (pendingRequest == .session && restoringSession ? requestedSession : nil)
    guard let session, let params, Self.matches(params["sessionId"], session),
      params["toolCall"]?.objectValue != nil, let options = params["options"]?.arrayValue,
      (1...32).contains(options.count),
      unboundPermissions.count + permissions.count < 16,
      !unboundPermissions.contains(where: { $0.id == id }),
      !permissions.values.contains(where: { $0.id == id })
    else { return }
    let transient = Set(
      options.compactMap { option -> Data? in
        guard let option = option.objectValue, let kind = option["kind"]?.stringValue,
          ["allow_once", "reject_once"].contains(kind),
          let name = Self.identifier(option["optionId"])
        else { return nil }
        return Data(name.utf8)
      })
    unboundPermissions.append(Permission(id: id, options: transient))
  }

  private static func message(_ bytes: Data) -> [String: JSONValue]? {
    guard let message = try? JSONDecoder().decode([String: JSONValue].self, from: bytes),
      message["jsonrpc"] == .string("2.0")
    else { return nil }
    return message
  }

  private static func identifier(_ value: JSONValue?) -> String? {
    guard let text = value?.stringValue, (1...1024).contains(text.utf8.count),
      !text.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) })
    else { return nil }
    return text
  }

  private static func matches(_ value: JSONValue?, _ expected: String) -> Bool {
    value?.stringValue?.utf8.elementsEqual(expected.utf8) == true
  }
}
