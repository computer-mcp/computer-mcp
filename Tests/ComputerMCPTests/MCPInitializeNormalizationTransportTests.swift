import Foundation
import Logging
import MCP
import Testing

@testable import ComputerMCP

struct MCPInitializeNormalizationTransportTests {
  @Test
  func reconnectNegotiatesAgainInsteadOfReusingPreviousCapabilities() async throws {
    let pair = await InMemoryTransport.createConnectedPair()
    let normalization = MCPInitializeNormalizationTransport(wrapping: pair.server)
    for id in 0...1 {
      try await pair.client.connect()
      try await normalization.connect()
      var incoming = await normalization.receive().makeAsyncIterator()
      var replies = await pair.client.receive().makeAsyncIterator()
      let request = Self.initialize(id: id)
      try await pair.client.send(request)
      #expect(try await incoming.next() == request)
      let response = Self.initializeResponse(id: id)
      try await normalization.send(response)
      #expect(try await replies.next() == response)
      await normalization.disconnect()
      // Join the previous receive loop before reconnecting the transport.
      #expect(try await incoming.next() == nil)
    }
  }

  @Test
  func reusedRequestIDCannotReplaceInitializationWhileItsWriteIsFinishing() async throws {
    let pair = await InMemoryTransport.createConnectedPair()
    try await pair.client.connect()
    try await pair.server.connect()
    let delayed = InitializeWritePause(wrapping: pair.server, incoming: await pair.server.receive())
    let normalization = MCPInitializeNormalizationTransport(wrapping: delayed)
    try await normalization.connect()
    var incoming = await normalization.receive().makeAsyncIterator()
    var replies = await pair.client.receive().makeAsyncIterator()
    try await pair.client.send(Self.initialize(id: 0))
    _ = try #require(try await incoming.next())
    let response = Self.initializeResponse(id: 0)
    let firstWrite = Task { try await normalization.send(response) }
    do {
      #expect(try await replies.next() == response)
      await delayed.waitUntilPaused()
      // A client may reuse an ID after receiving its completed initialization.
      let toolResponse = Data(
        #"{"jsonrpc":"2.0","id":0,"result":{"content":[],"isError":false}}"#.utf8)
      try await normalization.send(toolResponse)
      #expect(try await replies.next() == toolResponse)
      try await pair.client.send(Self.initialize(id: 1))
      let replay = try #require(try await replies.next())
      let value = try JSONDecoder().decode(JSONValue.self, from: replay)
      #expect(
        value.objectValue?["result"]?.objectValue?["protocolVersion"] == .string("2025-11-25"))
      await delayed.release()
      try await firstWrite.value
      await normalization.disconnect()
    } catch {
      await delayed.release()
      await normalization.disconnect()
      _ = await firstWrite.result
      throw error
    }
  }

  @Test
  func initializationFailureCompletesEveryQueuedHandshake() async throws {
    let pair = await InMemoryTransport.createConnectedPair()
    try await pair.client.connect()
    let normalization = MCPInitializeNormalizationTransport(wrapping: pair.server)
    try await normalization.connect()
    var incoming = await normalization.receive().makeAsyncIterator()
    var replies = await pair.client.receive().makeAsyncIterator()
    try await pair.client.send(Self.initialize(id: 0))
    _ = try #require(try await incoming.next())
    try await pair.client.send(Self.initialize(id: 1))
    let barrier = Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8)
    try await pair.client.send(barrier)
    #expect(try await incoming.next() == barrier)
    let failure = Data(
      #"{"jsonrpc":"2.0","id":0,"error":{"code":-32602,"message":"unsupported protocol"}}"#.utf8)
    try await normalization.send(failure)
    #expect(try await replies.next() == failure)
    await normalization.disconnect()
    let replay = try await replies.next()
    #expect(replay != nil)
    if let replay {
      let value = try JSONDecoder().decode(JSONValue.self, from: replay)
      #expect(value.objectValue?["id"] == .number(1))
      #expect(value.objectValue?["error"]?.objectValue?["code"] == .number(-32602))
    }
  }

  private static func initialize(id: Int) -> Data {
    Data(
      "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"fixture\",\"version\":\"1\"}}}"
        .utf8)
  }

  private static func initializeResponse(id: Int) -> Data {
    Data(
      "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fixture\",\"version\":\"1\"}}}"
        .utf8)
  }

  @Test
  func removesOpenEndedExperimentalCapabilitiesFromInitializeRequest() throws {
    let input = try #require(
      """
      {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
          "protocolVersion": "2025-11-25",
          "capabilities": {
            "experimental": {
              "openai": {"formElicitation": true},
              "custom_feature": "supported"
            },
            "roots": {"listChanged": true}
          },
          "clientInfo": {"name": "ChatGPT", "version": "1"}
        }
      }
      """.data(using: .utf8)
    )

    let output = MCPInitializeNormalization.normalize(input)
    let object = try #require(
      JSONSerialization.jsonObject(with: output) as? [String: Any]
    )
    let parameters = try #require(object["params"] as? [String: Any])
    let capabilities = try #require(parameters["capabilities"] as? [String: Any])
    let experimental = try #require(capabilities["experimental"] as? [String: Any])

    #expect(experimental.keys.sorted() == ["custom_feature"])
    #expect(experimental["custom_feature"] as? String == "supported")
    #expect(capabilities["roots"] != nil)
  }

  @Test
  func preservesInitializeRequestWhenExperimentalCapabilitiesAreStrings() throws {
    let input = try #require(
      """
      {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"custom_feature":"supported"}}}}
      """.data(using: .utf8)
    )

    #expect(MCPInitializeNormalization.normalize(input) == input)
  }

  @Test
  func preservesNonInitializeMessages() throws {
    let input = try #require(
      """
      {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"experimental":{"openai":{}}}}
      """.data(using: .utf8)
    )

    #expect(MCPInitializeNormalization.normalize(input) == input)
  }

  @Test
  func replaysSuccessfulInitializeResponseForRepeatedRequest() async throws {
    let transports = await InMemoryTransport.createConnectedPair()
    let normalization = MCPInitializeNormalizationTransport(wrapping: transports.server)
    try await transports.client.connect()
    try await normalization.connect()

    let serverMessages = await normalization.receive()
    let clientMessages = await transports.client.receive()
    var serverIterator = serverMessages.makeAsyncIterator()
    var clientIterator = clientMessages.makeAsyncIterator()

    let firstRequest = try #require(
      """
      {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"experimental":{"openai/visibility":{"enabled":true}}},"clientInfo":{"name":"openai-mcp","version":"1.0.0"}}}
      """.data(using: .utf8)
    )
    try await transports.client.send(firstRequest)

    let normalizedRequest = try #require(try await serverIterator.next())
    let normalizedObject = try #require(
      JSONDecoder().decode(JSONValue.self, from: normalizedRequest).objectValue
    )
    let normalizedParameters = try #require(normalizedObject["params"]?.objectValue)
    let normalizedCapabilities = try #require(
      normalizedParameters["capabilities"]?.objectValue
    )
    #expect(normalizedCapabilities["experimental"] == nil)

    let firstResponse = try #require(
      """
      {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"computer-mcp","version":"0.1.0"}}}
      """.data(using: .utf8)
    )
    try await normalization.send(firstResponse)
    #expect(try await clientIterator.next() == firstResponse)

    let repeatedRequest = try #require(
      """
      {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"openai-mcp","version":"1.0.0"}}}
      """.data(using: .utf8)
    )
    try await transports.client.send(repeatedRequest)

    let replayedData = try #require(try await clientIterator.next())
    let replayed = try #require(
      JSONDecoder().decode(JSONValue.self, from: replayedData).objectValue
    )
    #expect(replayed["id"] == .number(0))
    #expect(replayed["result"] != nil)

    await normalization.disconnect()
  }
}

private actor InitializeWritePause: Transport {
  nonisolated let logger = Logger(label: "test.initialize-write")
  private let underlying: any Transport
  private let incoming: AsyncThrowingStream<Data, any Error>
  private var paused = false
  private let ready = AsyncStream<Void>.makeStream()
  private let resume = AsyncStream<Void>.makeStream()

  init(wrapping underlying: any Transport, incoming: AsyncThrowingStream<Data, any Error>) {
    self.underlying = underlying
    self.incoming = incoming
  }
  func connect() async throws { try await underlying.connect() }
  func disconnect() async {
    resume.continuation.finish()
    await underlying.disconnect()
  }
  func receive() -> AsyncThrowingStream<Data, any Error> { incoming }
  func send(_ data: Data) async throws {
    let delay = !paused && String(decoding: data, as: UTF8.self).contains("protocolVersion")
    if delay { paused = true }
    try await underlying.send(data)
    if delay {
      ready.continuation.yield(())
      ready.continuation.finish()
      for await _ in resume.stream {}
    }
  }
  func waitUntilPaused() async { for await _ in ready.stream {} }
  func release() { resume.continuation.finish() }
}
