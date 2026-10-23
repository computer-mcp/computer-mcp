// CONNECT/SOCKS flow adapted from anthropics/sandbox-runtime, Apache-2.0.
// Revision aceba124fd725f4a43d7016ed3f5651d61f83115, src/sandbox/http-proxy.ts and socks-proxy.ts.
// Modified: bounded Swift parser, execution identity comes from the listener, TCP CONNECT only.
// See THIRD_PARTY_NOTICES.md and Licenses/sandbox-runtime-Apache-2.0.txt.
import Foundation
import NIOCore

struct EgressTarget: Sendable, Equatable {
  let host: String
  let port: UInt16
}

struct EgressHandshake {
  enum ProtocolKind { case http, socks }
  enum Step {
    case more
    case reply([UInt8])
    case connect(EgressTarget)
  }
  private(set) var kind: ProtocolKind?
  private var greeted = false

  mutating func consume(_ buffer: inout ByteBuffer) throws -> Step {
    guard let first: UInt8 = buffer.getInteger(at: buffer.readerIndex) else { return .more }
    if kind == nil { kind = first == 5 ? .socks : .http }
    if kind == .http {
      let bytes = Array(buffer.readableBytesView)
      guard
        let end = bytes.indices.dropLast(3).first(where: {
          Array(bytes[$0..<($0 + 4)]) == [13, 10, 13, 10]
        })
      else { return .more }
      guard let request = String(bytes: bytes.prefix(end), encoding: .ascii),
        let line = request.components(separatedBy: "\r\n").first
      else { throw EgressConnectionError.malformedRequest }
      let fields = line.split(separator: " ", omittingEmptySubsequences: false)
      guard fields.count == 3, fields[0] == "CONNECT", ["HTTP/1.0", "HTTP/1.1"].contains(fields[2])
      else {
        throw EgressConnectionError.malformedRequest
      }
      let authority = String(fields[1])
      guard let delimiter = authority.lastIndex(of: ":"),
        let port = UInt16(authority[authority.index(after: delimiter)...]), port > 0
      else { throw EgressConnectionError.malformedRequest }
      let rawHost = String(authority[..<delimiter])
      guard !rawHost.contains(":") || (rawHost.hasPrefix("[") && rawHost.hasSuffix("]")) else {
        throw EgressConnectionError.malformedRequest
      }
      let host = try EgressPolicy.normalizeHost(rawHost)
      buffer.moveReaderIndex(forwardBy: end + 4)
      return .connect(EgressTarget(host: host, port: port))
    }
    if !greeted {
      guard let count: UInt8 = buffer.getInteger(at: buffer.readerIndex + 1),
        buffer.readableBytes >= Int(count) + 2
      else { return .more }
      guard first == 5, count > 0,
        buffer.getBytes(at: buffer.readerIndex + 2, length: Int(count))!.contains(0)
      else {
        throw EgressConnectionError.malformedRequest
      }
      buffer.moveReaderIndex(forwardBy: Int(count) + 2)
      greeted = true
      return .reply([5, 0])
    }
    guard buffer.readableBytes >= 4 else { return .more }
    let bytes = Array(buffer.readableBytesView)
    guard bytes[0] == 5, bytes[1] == 1, bytes[2] == 0 else {
      throw EgressConnectionError.malformedRequest
    }
    let count: Int
    let start: Int
    switch bytes[3] {
    case 1:
      count = 4
      start = 4
    case 4:
      count = 16
      start = 4
    case 3:
      guard bytes.count >= 5 else { return .more }
      count = Int(bytes[4])
      start = 5
      guard count > 0 else { throw EgressConnectionError.malformedRequest }
    default: throw EgressConnectionError.malformedRequest
    }
    guard bytes.count >= start + count + 2 else { return .more }
    let rawHost: String
    switch bytes[3] {
    case 1: rawHost = bytes[start..<(start + count)].map(String.init).joined(separator: ".")
    case 4:
      rawHost = stride(from: start, to: start + count, by: 2).map {
        String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16)
      }.joined(separator: ":")
    default:
      guard let host = String(bytes: bytes[start..<(start + count)], encoding: .ascii) else {
        throw EgressConnectionError.malformedRequest
      }
      rawHost = host
    }
    let port = UInt16(bytes[start + count]) << 8 | UInt16(bytes[start + count + 1])
    guard port != 0 else { throw EgressConnectionError.malformedRequest }
    let host = try EgressPolicy.normalizeHost(rawHost)
    buffer.moveReaderIndex(forwardBy: start + count + 2)
    return .connect(EgressTarget(host: host, port: port))
  }

  func response(host: String, success: Bool, policyDenied: Bool = true) -> [UInt8] {
    if kind == .socks {
      // RFC 1928's domain address carries the rejected target; the event also retains its name.
      let name = Array(host.utf8.prefix(253))
      return [5, success ? 0 : (policyDenied ? 2 : 1), 0, 3, UInt8(name.count)] + name + [0, 0]
    }
    if success { return Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8) }
    return Array(
      ("HTTP/1.1 \(policyDenied ? "403" : "502") \(host)\r\n"
        + "X-Blocked-Host: \(host)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n").utf8)
  }
}
