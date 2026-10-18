import Foundation
import Testing

@testable import ComputerMCP

struct MCPSSEDecoderTests {
  @Test(arguments: ["\n", "\r", "\r\n"])
  func lineEndingsUnicodeAndFieldsAreDecodedIncrementally(ending: String) throws {
    let source = [
      "\u{FEFF}: comment", "id: events-1", "retry: 1200", "data: 你好", "data: second", "", "",
    ].joined(separator: ending)
    let events = try decode(Data(source.utf8))
    #expect(
      events == [.init(data: Data("你好\nsecond".utf8), id: "events-1", retryMilliseconds: 1200)])
  }

  @Test
  func primingAndCursorResetDoNotRequireJSONData() throws {
    let events = try decode(
      Data("id: first\ndata:\n\nid:\nretry: -1\n\nid: invalid\0id\nretry: abc\n\n".utf8))
    #expect(events[0] == .init(data: Data(), id: "first", retryMilliseconds: nil))
    #expect(events[1] == .init(data: nil, id: "", retryMilliseconds: nil))
    #expect(events[2] == .init(data: nil, id: nil, retryMilliseconds: nil))
  }

  @Test
  func incompleteEventsAreNotDispatched() throws {
    #expect(try decode(Data("data: incomplete\n".utf8)).isEmpty)
  }

  @Test
  func invalidUTF8AndUnterminatedOversizedLinesAreRejected() throws {
    #expect(throws: MCPHTTPTransportError.invalidUTF8) { _ = try decode(Data([0xff, 10])) }
    var decoder = MCPSSEDecoder(maxEventBytes: 8)
    #expect(throws: MCPHTTPTransportError.messageTooLarge) {
      for byte in "data: more than eight".utf8 { _ = try decoder.append(byte) }
    }
  }

  private func decode(_ bytes: Data) throws -> [MCPSSEDecoder.Event] {
    var decoder = MCPSSEDecoder()
    return try bytes.compactMap { try decoder.append($0) }
  }
}
