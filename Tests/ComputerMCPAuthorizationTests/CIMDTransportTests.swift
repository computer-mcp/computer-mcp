import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import ComputerMCPAuthorization

struct CIMDTransportTests {
  #if os(macOS)
    @Test func realFetcherRejectsAllowlistedLocalhostWithoutConnecting() async throws {
      let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      let connections = CIMDConnectionCount()
      let listener: Channel
      do {
        listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
          connections.connected()
          return channel.pipeline.addHandler(LocalCIMDDocument())
        }.bind(host: "localhost", port: 0).get()
      } catch {
        try? await group.shutdownGracefully()
        throw error
      }
      do {
        let port = try #require(listener.localAddress?.port)
        let url = try #require(URL(string: "https://localhost:\(port)/metadata"))
        let fetcher = URLSessionCIMDFetcher()
        let identifier = CIMDClientIdentifier(fetcher: fetcher)
        await #expect(throws: OAuthError.invalidClient) {
          try await identifier.identify(
            clientID: url.absoluteString, redirectURI: "https://consumer.example/callback",
            allowlist: ["localhost"])
        }
        // Exercise DNS/public-address validation in the real adapter too, beyond
        // the identifier's lexical localhost rejection.
        await #expect(throws: OAuthError.invalidClient) {
          try await fetcher.fetch(
            url, maxBytes: OAuthLimits.metadataMaxBytes, timeout: OAuthLimits.metadataTimeout)
        }
        try await listener.close()
        try await group.shutdownGracefully()
        #expect(connections.count == 0)
      } catch {
        try? await listener.close()
        try? await group.shutdownGracefully()
        throw error
      }
    }
  #else
    @Test func networkAdapterFailsBeforeSendingOnLinux() async throws {
      await #expect(throws: OAuthError.networkUnavailable) {
        try await URLSessionCIMDFetcher().fetch(
          URL(string: "https://localhost/metadata")!, maxBytes: OAuthLimits.metadataMaxBytes,
          timeout: OAuthLimits.metadataTimeout)
      }
    }
  #endif
}

#if os(macOS)
  private final class CIMDConnectionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func connected() { lock.withLock { value += 1 } }
  }

  private final class LocalCIMDDocument: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      let port = context.localAddress!.port!
      let document =
        #"{"client_id":"https://localhost:\#(port)/metadata","redirect_uris":["https://consumer.example/callback"]}"#
      var response = context.channel.allocator.buffer(capacity: document.utf8.count + 128)
      response.writeString(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(document.utf8.count)\r\nConnection: close\r\n\r\n"
          + document)
      let channel = context.channel
      context.writeAndFlush(wrapOutboundOut(response)).whenComplete { _ in
        channel.close(promise: nil)
      }
    }
  }
#endif
