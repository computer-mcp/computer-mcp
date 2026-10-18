import Darwin
import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct MCPInheritedSocketTransportTests {
  @Test
  func standardMCPClientAndServerShareTheInheritedTransport() async throws {
    let pair = try MCPInheritedSocketTransport.makePair()
    let serverTransport = try MCPInheritedSocketTransport(takingOwnershipOf: pair.0)
    let clientTransport = try MCPInheritedSocketTransport(takingOwnershipOf: pair.1)
    let server = MCP.Server(name: "fixture-host", version: "1", capabilities: .init(tools: .init()))
    await server.withMethodHandler(MCP.CallTool.self) { params in
      .init(
        content: [.text(text: params.name, annotations: nil, _meta: nil)],
        structuredContent: .object(params.arguments ?? [:]), isError: false)
    }
    let client = MCP.Client(name: "fixture-plugin", version: "1")
    do {
      try await server.start(transport: serverTransport)
      _ = try await client.connect(transport: clientTransport)
      try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<16 {
          group.addTask {
            let request: RequestContext<MCP.CallTool.Result> = try await client.callTool(
              name: "echo", arguments: ["index": .int(index)])
            let response = try await request.value
            #expect(response.structuredContent == .object(["index": .int(index)]))
          }
        }
        try await group.waitForAll()
      }
      await client.disconnect()
      await server.stop()
      await clientTransport.disconnect()
      await serverTransport.disconnect()
    } catch {
      await clientTransport.disconnect()
      await serverTransport.disconnect()
      await client.disconnect()
      await server.stop()
      throw error
    }
  }

  @Test(arguments: ["unfinished", "oversized-line", "invalid-utf8", "empty"])
  func malformedPeerFramesFailClosed(kind: String) async throws {
    let pair = try MCPInheritedSocketTransport.makePair()
    let transport = try MCPInheritedSocketTransport(
      takingOwnershipOf: pair.0, maximumMessageBytes: 64)
    defer { try? pair.1.close() }
    try await transport.connect()
    let data: Data
    switch kind {
    case "unfinished": data = Data(repeating: 120, count: 65)
    case "oversized-line": data = Data(repeating: 120, count: 65) + Data([10])
    case "invalid-utf8": data = Data([255, 10])
    default: data = Data([10])
    }
    try pair.1.write(contentsOf: data)
    var stream = await transport.receive().makeAsyncIterator()
    await #expect(throws: (any Error).self) { _ = try await stream.next() }
    await #expect(throws: (any Error).self) { try await transport.send(Data("{}".utf8)) }
    await transport.disconnect()
  }

  @Test
  func peerEOFCompletesStreamAndRepeatedCloseIsSafe() async throws {
    let pair = try MCPInheritedSocketTransport.makePair()
    let transport = try MCPInheritedSocketTransport(takingOwnershipOf: pair.0)
    try await transport.connect()
    try pair.1.close()
    var stream = await transport.receive().makeAsyncIterator()
    #expect(try await stream.next() == nil)
    async let first: Void = transport.disconnect()
    async let second: Void = transport.disconnect()
    _ = await (first, second)
  }

  @Test
  func descriptorsAreCloseOnExecAndOnlyConnectedUnixStreamsAreAccepted() throws {
    let pair = try MCPInheritedSocketTransport.makePair()
    defer {
      try? pair.0.close()
      try? pair.1.close()
    }
    #expect(fcntl(pair.0.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
    #expect(fcntl(pair.1.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
    let pipe = Pipe()
    #expect(throws: (any Error).self) {
      _ = try MCPInheritedSocketTransport(takingOwnershipOf: pipe.fileHandleForReading)
    }
  }

  @Test
  func callerSideInvalidFramesDoNotCorruptTheReusableConnection() async throws {
    let pair = try MCPInheritedSocketTransport.makePair()
    let left = try MCPInheritedSocketTransport(takingOwnershipOf: pair.0, maximumMessageBytes: 64)
    let right = try MCPInheritedSocketTransport(takingOwnershipOf: pair.1)
    try await left.connect()
    try await right.connect()
    for data in [Data(), Data("{}\n{}".utf8), Data([255]), Data(repeating: 120, count: 65)] {
      await #expect(throws: (any Error).self) { try await left.send(data) }
    }
    try await left.send(Data("{}".utf8))
    var stream = await right.receive().makeAsyncIterator()
    #expect(try await stream.next() == Data("{}".utf8))
    await left.disconnect()
    await right.disconnect()
  }
}
