import Foundation
import Logging
import MCP
import Testing

@testable import ComputerMCP

struct MCPHTTPEventSubscriptionTransportTests {
  @Test
  func catalogChangesBeforeFirstSubscriptionAreCoalescedAndDelivered() async throws {
    let underlying = EventSubscriptionTransportSpy()
    let transport = MCPHTTPEventSubscriptionTransport(wrapping: underlying)
    let change = Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8)
    let response = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
    try await transport.connect()
    for _ in 0..<100 { try await transport.send(change) }
    try await transport.send(response)
    #expect(await underlying.sent == [response])
    try await transport.eventStreamOpened()
    #expect(await underlying.sent == [response, change])
    try await transport.eventStreamOpened()
    #expect(await underlying.sent == [response, change])
    try await transport.send(change)
    #expect(await underlying.sent == [response, change, change])
    await transport.disconnect()
  }

  @Test
  func disconnectDiscardsPendingNoticeAndClosesTheTransport() async throws {
    let underlying = EventSubscriptionTransportSpy()
    let transport = MCPHTTPEventSubscriptionTransport(wrapping: underlying)
    try await transport.connect()
    try await transport.send(
      Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8))
    await transport.disconnect()
    #expect(await underlying.disconnected)
    #expect(await underlying.sent.isEmpty)
    await #expect(throws: MCPError.connectionClosed) { try await transport.eventStreamOpened() }
  }
}

private actor EventSubscriptionTransportSpy: Transport {
  nonisolated let logger = Logger(label: "event-subscription-test")
  private(set) var sent: [Data] = []
  private(set) var disconnected = false
  func connect() async throws {}
  func disconnect() async { disconnected = true }
  func send(_ data: Data) async throws { sent.append(data) }
  func receive() -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { $0.finish() }
  }
}
