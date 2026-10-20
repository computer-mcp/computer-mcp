import Foundation
import Testing

@testable import ComputerMCPPlatformPOSIX

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

struct PeerCredentialsTests {
  @Test
  func socketPairReportsTheEffectiveUserAtBothEnds() throws {
    var descriptors: [Int32] = [-1, -1]
    #if canImport(Darwin)
      let type = SOCK_STREAM
    #else
      let type = Int32(SOCK_STREAM.rawValue)
    #endif
    try #require(socketpair(AF_UNIX, type, 0, &descriptors) == 0)
    defer { for descriptor in descriptors { close(descriptor) } }
    for descriptor in descriptors {
      #expect(try PeerCredentials.effectiveUserID(ofSocket: descriptor) == geteuid())
    }
  }

  @Test
  func invalidDescriptorThrowsPOSIXError() {
    #expect(throws: POSIXError(.EBADF)) {
      try PeerCredentials.effectiveUserID(ofSocket: -1)
    }
  }
}
