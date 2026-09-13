import Foundation

/// Incremental UTF-8 SSE decoding with a bound on each event, including unterminated lines.
struct MCPSSEDecoder {
  struct Event: Equatable, Sendable {
    let data: Data?
    let id: String?
    let retryMilliseconds: Int?
  }

  private let maxEventBytes: Int
  private var line: [UInt8] = []
  private var dataLines: [String] = []
  private var eventID: String?
  private var retryMilliseconds: Int?
  private var eventBytes = 0
  private var afterCR = false
  private var firstLine = true

  init(maxEventBytes: Int = 32 * 1_024 * 1_024) {
    self.maxEventBytes = maxEventBytes
  }

  mutating func append(_ byte: UInt8) throws -> Event? {
    if afterCR {
      afterCR = false
      if byte == 10 { return nil }
    }
    eventBytes += 1
    guard eventBytes <= maxEventBytes else { throw MCPHTTPTransportError.messageTooLarge }
    if byte == 10 || byte == 13 {
      afterCR = byte == 13
      return try consumeLine()
    }
    line.append(byte)
    return nil
  }

  private mutating func consumeLine() throws -> Event? {
    guard var text = String(bytes: line, encoding: .utf8) else {
      throw MCPHTTPTransportError.invalidUTF8
    }
    line.removeAll(keepingCapacity: true)
    if firstLine {
      firstLine = false
      if text.first == "\u{FEFF}" { text.removeFirst() }
    }
    if text.isEmpty {
      let event = Event(
        data: dataLines.isEmpty ? nil : Data(dataLines.joined(separator: "\n").utf8),
        id: eventID,
        retryMilliseconds: retryMilliseconds)
      dataLines.removeAll(keepingCapacity: true)
      eventID = nil
      retryMilliseconds = nil
      eventBytes = 0
      return event
    }
    if text.first == ":" { return nil }
    let separator = text.firstIndex(of: ":") ?? text.endIndex
    let field = text[..<separator]
    var value = separator == text.endIndex ? "" : String(text[text.index(after: separator)...])
    if value.first == " " { value.removeFirst() }
    switch field {
    case "data": dataLines.append(value)
    case "id": if !value.contains("\0") { eventID = value }
    case "retry":
      if !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
        retryMilliseconds = Int(value)
      }
    default: break
    }
    return nil
  }
}

enum MCPHTTPTransportError: Error, Equatable, LocalizedError {
  case invalidResponse
  case invalidUTF8
  case messageTooLarge
  case receiveQueueFull
  case httpStatus(Int)
  case unsupportedContentType
  case incompleteResponse
  case sessionChanged

  var errorDescription: String? {
    switch self {
    case .invalidResponse: "The MCP HTTP server returned an invalid JSON-RPC response."
    case .invalidUTF8: "The MCP event stream contains invalid UTF-8."
    case .messageTooLarge: "The MCP HTTP message exceeds the 32 MiB transport limit."
    case .receiveQueueFull: "The MCP HTTP receive queue is full; reconnect and refresh the catalog."
    case .httpStatus(let status): "The MCP HTTP server returned status \(status)."
    case .unsupportedContentType: "The MCP HTTP response is neither JSON nor an event stream."
    case .incompleteResponse:
      "The MCP response stream ended without a response or resumable cursor; the request was not replayed."
    case .sessionChanged:
      "The MCP server changed its session identity; reconnect before making another request."
    }
  }
}
