import ComputerMCPSandbox
import Dispatch
import Foundation
import NIOCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// A stream keeps at most one requested read and one pending write. EOF observes that same demand.
package protocol EgressStream: AnyObject, Sendable {
  var connected: EventLoopFuture<Void> { get }
  var closed: EventLoopFuture<Void> { get }
  func read(maxBytes: Int) -> EventLoopFuture<ByteBuffer>
  func write(_ bytes: ByteBuffer) -> EventLoopFuture<Void>
  func finishOutput() -> EventLoopFuture<Void>
  func close()
}

/// Socket state and descriptor access belong to the queue. Dispatch source cancellation completes
/// before the descriptor is closed, so queued readiness notifications cannot address a reused fd.
package final class EgressSocket: EgressStream, @unchecked Sendable {
  private let queue = DispatchQueue(label: "computer-mcp.egress.socket")
  private let descriptor: Int32
  private let loop: any EventLoop
  private let readSource: any DispatchSourceRead
  private let writeSource: any DispatchSourceWrite
  private let connection: EventLoopPromise<Void>
  private let closure: EventLoopPromise<Void>
  private var readActive = false
  private var writeActive = false
  private var ended = false
  private var connecting: Bool
  private var readRequest: (Int, EventLoopPromise<ByteBuffer>)?
  private var writeRequest: (ByteBuffer, EventLoopPromise<Void>)?

  package var connected: EventLoopFuture<Void> { connection.futureResult }
  package var closed: EventLoopFuture<Void> { closure.futureResult }

  package static func connect(to address: SocketAddress, route: EgressRoute, on loop: any EventLoop)
    throws -> EgressSocket
  {
    #if canImport(Darwin)
      let family = address.protocol.rawValue
      let descriptor = socket(family, SOCK_STREAM, 0)
      guard descriptor >= 0 else { throw socketError() }
      do {
        try configure(descriptor)
        var index = route.interfaceIndex
        guard
          setsockopt(
            descriptor, family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP,
            family == AF_INET6 ? IPV6_BOUND_IF : IP_BOUND_IF, &index,
            socklen_t(MemoryLayout<UInt32>.size)) == 0
        else {
          throw socketError()
        }
      } catch {
        Darwin.close(descriptor)
        throw error
      }
      let stream = EgressSocket(descriptor: descriptor, on: loop, connecting: true)
      stream.queue.async {
        let result = address.withSockAddr { Darwin.connect(descriptor, $0, socklen_t($1)) }
        if result == 0 {
          stream.connecting = false
          stream.connection.succeed(())
        } else if errno == EINPROGRESS {
          stream.setWriteActive(true)
        } else {
          stream.closeOnQueue(error: socketError())
        }
      }
      return stream
    #else
      throw ExecutionEnvironmentError.unavailable(
        "Interface-bound egress requires a platform backend")
    #endif
  }

  static func accept(descriptor: Int32, on loop: any EventLoop) throws -> EgressSocket {
    do { try configure(descriptor) } catch {
      closeDescriptor(descriptor)
      throw error
    }
    return EgressSocket(descriptor: descriptor, on: loop, connecting: false)
  }

  private init(descriptor: Int32, on loop: any EventLoop, connecting: Bool) {
    self.descriptor = descriptor
    self.loop = loop
    self.connecting = connecting
    connection = loop.makePromise()
    closure = loop.makePromise()
    readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    writeSource = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
    readSource.setEventHandler { [weak self] in self?.readReady() }
    writeSource.setEventHandler { [weak self] in self?.writeReady() }
    let cancellation = DispatchGroup()
    cancellation.enter()
    cancellation.enter()
    readSource.setCancelHandler { cancellation.leave() }
    writeSource.setCancelHandler { cancellation.leave() }
    let closure = self.closure
    cancellation.notify(queue: queue) {
      closeDescriptor(descriptor)
      closure.succeed(())
    }
    if !connecting { connection.succeed(()) }
  }

  package func read(maxBytes: Int) -> EventLoopFuture<ByteBuffer> {
    let promise = loop.makePromise(of: ByteBuffer.self)
    queue.async {
      guard !self.ended else {
        promise.fail(ChannelError.ioOnClosedChannel)
        return
      }
      guard maxBytes > 0, self.readRequest == nil, !self.connecting else {
        promise.fail(EgressConnectionError.bufferLimit)
        return
      }
      self.readRequest = (maxBytes, promise)
      self.readReady()
    }
    return promise.futureResult
  }

  package func write(_ bytes: ByteBuffer) -> EventLoopFuture<Void> {
    let promise = loop.makePromise(of: Void.self)
    queue.async {
      guard !self.ended else {
        promise.fail(ChannelError.ioOnClosedChannel)
        return
      }
      guard self.writeRequest == nil, !self.connecting else {
        promise.fail(EgressConnectionError.bufferLimit)
        return
      }
      self.writeRequest = (bytes, promise)
      self.writeReady()
    }
    return promise.futureResult
  }

  package func finishOutput() -> EventLoopFuture<Void> {
    let promise = loop.makePromise(of: Void.self)
    queue.async {
      guard !self.ended else {
        promise.fail(ChannelError.ioOnClosedChannel)
        return
      }
      guard self.writeRequest == nil else {
        promise.fail(EgressConnectionError.bufferLimit)
        return
      }
      if shutdown(self.descriptor, Int32(SHUT_WR)) == 0 {
        promise.succeed(())
      } else {
        promise.fail(socketError())
      }
    }
    return promise.futureResult
  }

  package func close() { queue.async { self.closeOnQueue(error: ChannelError.ioOnClosedChannel) } }

  func socketOption(level: Int32, name: Int32) -> EventLoopFuture<Int32> {
    let promise = loop.makePromise(of: Int32.self)
    queue.async {
      guard !self.ended else {
        promise.fail(ChannelError.ioOnClosedChannel)
        return
      }
      var result: Int32 = 0
      var size = socklen_t(MemoryLayout<Int32>.size)
      if getsockopt(self.descriptor, level, name, &result, &size) == 0 {
        promise.succeed(result)
      } else {
        promise.fail(socketError())
      }
    }
    return promise.futureResult
  }

  private func readReady() {
    guard !ended, let (maximum, promise) = readRequest else {
      setReadActive(false)
      return
    }
    var bytes = ByteBufferAllocator().buffer(capacity: maximum)
    var received = 0
    var failure: Int32 = 0
    bytes.writeWithUnsafeMutableBytes(minimumWritableBytes: maximum) { storage -> Int in
      repeat {
        received = recv(descriptor, storage.baseAddress, maximum, 0)
      } while received < 0 && errno == EINTR
      if received < 0 { failure = errno }
      return max(0, received)
    }
    if received >= 0 {
      readRequest = nil
      setReadActive(false)
      promise.succeed(bytes)
    } else if failure == EAGAIN || failure == EWOULDBLOCK {
      setReadActive(true)
    } else {
      closeOnQueue(error: POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO))
    }
  }

  private func writeReady() {
    guard !ended else { return }
    if connecting {
      var error: Int32 = 0
      var size = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else {
        closeOnQueue(error: socketError())
        return
      }
      guard error == 0 else {
        closeOnQueue(error: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
        return
      }
      connecting = false
      setWriteActive(false)
      connection.succeed(())
      return
    }
    guard let (pendingBytes, promise) = writeRequest else {
      setWriteActive(false)
      return
    }
    var bytes = pendingBytes
    while bytes.readableBytes > 0 {
      let count = bytes.withUnsafeReadableBytes { storage in
        #if canImport(Darwin)
          send(descriptor, storage.baseAddress, storage.count, 0)
        #else
          send(descriptor, storage.baseAddress, storage.count, Int32(MSG_NOSIGNAL))
        #endif
      }
      if count > 0 {
        bytes.moveReaderIndex(forwardBy: count)
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        writeRequest = (bytes, promise)
        setWriteActive(true)
        return
      }
      closeOnQueue(error: socketError())
      return
    }
    writeRequest = nil
    setWriteActive(false)
    promise.succeed(())
  }

  private func setReadActive(_ value: Bool) {
    guard value != readActive else { return }
    readActive = value
    if value { readSource.resume() } else { readSource.suspend() }
  }

  private func setWriteActive(_ value: Bool) {
    guard value != writeActive else { return }
    writeActive = value
    if value { writeSource.resume() } else { writeSource.suspend() }
  }

  private func closeOnQueue(error: any Error) {
    guard !ended else { return }
    ended = true
    if connecting {
      connecting = false
      connection.fail(error)
    }
    readRequest?.1.fail(error)
    writeRequest?.1.fail(error)
    readRequest = nil
    writeRequest = nil
    readSource.cancel()
    writeSource.cancel()
    setReadActive(true)
    setWriteActive(true)
  }
}

/// One accepted descriptor may await the event loop; the listener does not accumulate callbacks.
final class EgressListener: @unchecked Sendable {
  let port: UInt16
  let closed: EventLoopFuture<Void>
  private let queue = DispatchQueue(label: "computer-mcp.egress.listener")
  private let source: any DispatchSourceRead
  private var paused = false
  private var ended = false

  init(
    address: SocketAddress, on loop: any EventLoop,
    acceptSocket: @escaping @Sendable (Int32) -> Int32 = acceptDescriptor,
    accept: @escaping @Sendable (Int32) -> Void
  ) throws {
    #if canImport(Darwin)
      let descriptor = socket(address.protocol.rawValue, SOCK_STREAM, 0)
    #else
      let descriptor = socket(address.protocol.rawValue, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { throw socketError() }
    do {
      try configure(descriptor)
      if address.protocol.rawValue == AF_INET6 {
        var enabled: Int32 = 1
        guard
          setsockopt(
            descriptor, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &enabled,
            socklen_t(MemoryLayout<Int32>.size))
            == 0
        else { throw socketError() }
      }
      guard address.withSockAddr({ bind(descriptor, $0, socklen_t($1)) }) == 0,
        listen(descriptor, 128) == 0
      else { throw socketError() }
      var local = sockaddr_in6()
      var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
      guard
        withUnsafeMutablePointer(
          to: &local,
          {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              getsockname(descriptor, $0, &length)
            }
          }) == 0
      else { throw socketError() }
      port = UInt16(bigEndian: local.sin6_port)
    } catch {
      closeDescriptor(descriptor)
      throw error
    }
    let completion = loop.makePromise(of: Void.self)
    closed = completion.futureResult
    source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    source.setCancelHandler {
      closeDescriptor(descriptor)
      completion.succeed(())
    }
    source.setEventHandler { [weak self] in
      guard let self, !self.ended else { return }
      let child = acceptSocket(descriptor)
      guard child >= 0 else {
        // A full descriptor table leaves the listener readable. Pause to avoid a busy loop.
        if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
          self.source.suspend()
          self.paused = true
          self.queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self, !self.ended, self.paused else { return }
            self.paused = false
            self.source.resume()
          }
        }
        return
      }
      self.source.suspend()
      self.paused = true
      loop.execute {
        accept(child)
        self.queue.async {
          if self.paused {
            self.paused = false
            self.source.resume()
          }
        }
      }
    }
    source.resume()
  }

  func close() {
    queue.async {
      guard !self.ended else { return }
      self.ended = true
      self.source.cancel()
      if self.paused {
        self.paused = false
        self.source.resume()
      }
    }
  }
}

private func configure(_ descriptor: Int32) throws {
  guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
    fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0
  else { throw socketError() }
  #if canImport(Darwin)
    var enabled: Int32 = 1
    guard
      setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw socketError() }
  #endif
}

func closeDescriptor(_ descriptor: Int32) {
  #if canImport(Darwin)
    Darwin.close(descriptor)
  #else
    Glibc.close(descriptor)
  #endif
}

private func socketError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

func acceptDescriptor(_ descriptor: Int32) -> Int32 {
  #if canImport(Darwin)
    Darwin.accept(descriptor, nil, nil)
  #else
    Glibc.accept(descriptor, nil, nil)
  #endif
}
