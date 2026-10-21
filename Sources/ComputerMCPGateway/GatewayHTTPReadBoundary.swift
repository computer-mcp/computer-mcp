import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1

/// Event-loop-confined read sizing. The HTTP decoder remains the framing validator;
/// this handler only keeps a socket read from crossing into the next request head.
/// Header reads are byte-granular so an asynchronous admission never retains body
/// read-ahead. Admitted bodies read in bounded chunks within their framing boundary.
final class GatewayHTTPReadBoundary: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  private enum Phase {
    case head
    case sizedBody(Int)
    case chunkSize([UInt8])
    case chunkBody(Int)
    case chunkDelimiter(Int)
    case trailers
    case granularBody
  }
  private var phase = Phase.head
  private static let maxReadBytes = 64 * 1_024
  private static let maxChunkSizeLineBytes = 128

  func beginBody(_ head: HTTPRequestHead, channel: Channel) {
    if let length = head.headers.first(name: "Content-Length").flatMap(Int.init), length > 0 {
      phase = .sizedBody(length)
    } else if head.headers.first(name: "Transfer-Encoding") != nil {
      phase = .chunkSize([])
    }
    configureRead(channel)
  }

  func finishRequest(channel: Channel) {
    phase = .head
    configureRead(channel)
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let bytes = unwrapInboundIn(data)
    switch phase {
    case .sizedBody(let remaining):
      phase = remaining > bytes.readableBytes ? .sizedBody(remaining - bytes.readableBytes) : .head
    case .chunkBody(let remaining):
      phase =
        remaining > bytes.readableBytes
        ? .chunkBody(remaining - bytes.readableBytes) : .chunkDelimiter(2)
    case .chunkDelimiter(let remaining):
      phase =
        remaining > bytes.readableBytes
        ? .chunkDelimiter(remaining - bytes.readableBytes) : .chunkSize([])
    case .chunkSize(var line):
      for byte in bytes.readableBytesView {
        guard line.count < Self.maxChunkSizeLineBytes else {
          phase = .granularBody
          break
        }
        line.append(byte)
        if byte == 10 {
          let field = String(decoding: line, as: UTF8.self).split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if let size = Int(field, radix: 16), size >= 0 {
            phase = size == 0 ? .trailers : .chunkBody(size)
          } else {
            phase = .granularBody
          }
        } else {
          phase = .chunkSize(line)
        }
      }
    case .head, .trailers, .granularBody: break
    }
    context.fireChannelRead(data)
    configureRead(context.channel)
  }

  private func configureRead(_ channel: Channel) {
    let size: Int
    switch phase {
    case .sizedBody(let remaining), .chunkBody(let remaining):
      size = min(Self.maxReadBytes, remaining)
    case .head, .chunkSize, .chunkDelimiter, .trailers, .granularBody: size = 1
    }
    channel.setOption(
      ChannelOptions.recvAllocator, value: GatewayHTTPReadAllocator(capacity: size)
    )
    .whenFailure { _ in channel.close(promise: nil) }
  }
}

/// SwiftNIO's pooled allocator treats sizes as minimum capacities and can reuse a
/// larger body buffer for the next head. Exact slices and fresh allocation keep
/// the requested boundary authoritative even after a large authenticated body.
struct GatewayHTTPReadAllocator: RecvByteBufferAllocator {
  let capacity: Int

  func buffer(allocator: ByteBufferAllocator) -> ByteBuffer {
    var storage = allocator.buffer(capacity: capacity)
    storage.moveWriterIndex(to: capacity)
    var slice = storage.getSlice(at: 0, length: capacity)!
    slice.moveWriterIndex(to: 0)
    return slice
  }

  func nextBufferSize() -> Int? { nil }
  mutating func record(actualReadBytes: Int) -> Bool { true }
}
