import ComputerMCPTestSupport
import ComputerMCPTransport
import Darwin
import Foundation
import Testing

@testable import ComputerMCPControlPlane

@Suite(.nativeIntegration)
struct AppControlSocketTests {
  @Test
  func testControlClientTimesOutWhenOwnedSocketNeverResponds() async throws {
    let root = URL(fileURLWithPath: "/tmp/cm-control-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("gateway.sock")
    let server = try UnresponsiveUnixSocketServer(path: socketURL.path)
    defer { server.close() }
    let client = AppControlPlaneServiceClient(socketURL: socketURL)
    let clock = ContinuousClock()
    let deadline = Task {
      try await Task.sleep(for: .milliseconds(100))
      return clock.now
    }
    defer { deadline.cancel() }

    do {
      _ = try await client.call("readiness", timeout: .milliseconds(100))
      Issue.record("Expected an unresponsive control socket to time out.")
    } catch let error as ControlSocketCallError {
      #expect(error.code == "control.timeout")
    }

    let completedAt = clock.now
    // Measure socket delay after a concurrent timer can run, including under suite load.
    #expect(try await deadline.value.duration(to: completedAt) < .seconds(1))
  }
}

private final class UnresponsiveUnixSocketServer: @unchecked Sendable {
  private let descriptor: CInt
  private let path: String
  private let lock = NSLock()
  private var isClosed = false

  init(path: String) throws {
    self.path = path
    descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw GatewaySocketError.ioError(operation: "socket", code: errno)
    }

    var address = try unixSocketAddress(path: path)
    let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, addressLength)
      }
    }
    guard bindResult == 0, chmod(path, 0o600) == 0, listen(descriptor, 1) == 0 else {
      let code = errno
      _ = Darwin.close(descriptor)
      throw GatewaySocketError.ioError(operation: "listen(\(path))", code: code)
    }
  }

  deinit {
    close()
  }

  func close() {
    lock.lock()
    guard !isClosed else {
      lock.unlock()
      return
    }
    isClosed = true
    lock.unlock()
    _ = Darwin.close(descriptor)
    _ = Darwin.unlink(path)
  }
}

private func unixSocketAddress(path: String) throws -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  let maximum = MemoryLayout.size(ofValue: address.sun_path) - 1
  guard bytes.count <= maximum else {
    throw GatewaySocketError.invalidConfiguration(
      "socket path exceeds \(maximum) UTF-8 bytes"
    )
  }
  withUnsafeMutableBytes(of: &address.sun_path) { destination in
    destination.initializeMemory(as: UInt8.self, repeating: 0)
    destination.copyBytes(from: bytes)
  }
  return address
}
