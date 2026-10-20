import Logging
import MCP

/// Bridges official stdio MCP framing to the app-hosted local socket transport.
package enum GatewayStdioSocketBridge {
  package static func run(
    configuration: GatewaySocketConfiguration,
    logger: Logger = Logger(label: "computer-mcp.gateway-socket.bridge")
  ) async throws {
    let stdioTransport = StdioTransport(logger: logger)
    let socketTransport = GatewaySocketTransport(
      configuration: configuration,
      logger: logger
    )
    try await run(
      stdioTransport: stdioTransport,
      socketTransport: socketTransport
    )
  }

  /// Runs the byte bridge with injectable transports for deterministic tests.
  ///
  /// Both transports exchange complete MCP messages. No JSON decoding, routing,
  /// normalization, or tool handling occurs in this bridge.
  package static func run(
    stdioTransport: any Transport,
    socketTransport: any Transport
  ) async throws {
    try await socketTransport.connect()
    do {
      try await stdioTransport.connect()
    } catch {
      await socketTransport.disconnect()
      throw error
    }

    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await pump(from: stdioTransport, to: socketTransport)
        }
        group.addTask {
          try await pump(from: socketTransport, to: stdioTransport)
        }

        do {
          _ = try await group.next()
        } catch {
          group.cancelAll()
          await stdioTransport.disconnect()
          await socketTransport.disconnect()
          throw error
        }

        group.cancelAll()
        await stdioTransport.disconnect()
        await socketTransport.disconnect()
      }
    } onCancel: {
      Task {
        await stdioTransport.disconnect()
        await socketTransport.disconnect()
      }
    }
  }

  private static func pump(
    from source: any Transport,
    to destination: any Transport
  ) async throws {
    let stream = await source.receive()
    do {
      for try await message in stream {
        try Task.checkCancellation()
        try await destination.send(message)
      }
    } catch MCPError.connectionClosed {
      return
    } catch is CancellationError {
      return
    }
  }
}
