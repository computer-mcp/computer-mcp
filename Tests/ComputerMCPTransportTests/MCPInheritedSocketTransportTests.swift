import ComputerMCPCore
import Foundation
import MCP
import Testing

@testable import ComputerMCPTransport

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

@Suite(.timeLimit(.minutes(1)))
struct MCPInheritedSocketTransportTests {
  @Test
  func closedPeerWritesRaiseErrors() async throws {
    #if os(Linux)
      let receiptVariable = "COMPUTER_MCP_SOCKET_WRITE_RECEIPT"
      guard let receipt = ProcessInfo.processInfo.environment[receiptVariable] else {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
          "closed-socket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("write-error")
        let executable = CommandLine.arguments[0]
        let result = try await BlockingOperationExecutor(label: "closed-socket-test").perform {
          let process = Process()
          process.executableURL = URL(fileURLWithPath: executable)
          process.arguments = [
            "--testing-library", "swift-testing", "--filter", "closedPeerWritesRaiseErrors",
          ]
          var environment = ProcessInfo.processInfo.environment
          environment[receiptVariable] = receipt.path
          process.environment = environment
          let output = Pipe()
          process.standardOutput = output
          process.standardError = output
          try process.run()
          process.waitUntilExit()
          let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
          return (process.terminationReason == .exit, process.terminationStatus, text)
        }
        #expect(result.0, "The socket probe terminated by a signal: \(result.2)")
        #expect(result.1 == 0, "The socket probe failed: \(result.2)")
        #expect(try String(contentsOf: receipt, encoding: .utf8) == "EPIPE")
        return
      }
      _ = signal(SIGPIPE, SIG_DFL)
    #endif

    let pair = try MCPInheritedSocketTransport.makePair()
    defer { try? pair.1.close() }
    let transport = try MCPInheritedSocketTransport(takingOwnershipOf: pair.0)
    #if canImport(Darwin)
      var noSigpipe: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      #expect(getsockopt(pair.0.fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, &length) == 0)
      #expect(noSigpipe == 1)
      try pair.1.close()
    #else
      // Keeping the peer's write half open makes this exercise send rather than reader EOF.
      #expect(shutdown(pair.1.fileDescriptor, Int32(SHUT_RD)) == 0)
    #endif
    try await transport.connect()
    do {
      try await transport.send(Data("{}".utf8))
      Issue.record("A write to the peer's closed read half unexpectedly succeeded.")
    } catch MCPError.transportError(let error) {
      #expect((error as? POSIXError)?.code == .EPIPE)
      #if os(Linux)
        if (error as? POSIXError)?.code == .EPIPE {
          try "EPIPE".write(toFile: receipt, atomically: true, encoding: .utf8)
        }
      #endif
    } catch MCPError.connectionClosed {
      #if !canImport(Darwin)
        Issue.record("The reader closed before the write exercised MSG_NOSIGNAL.")
      #endif
    } catch {
      await transport.disconnect()
      throw error
    }
    await transport.disconnect()
  }

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
