import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

package enum PeerCredentials {
  package static func effectiveUserID(ofSocket descriptor: Int32) throws -> uid_t {
    #if canImport(Darwin)
      var userID: uid_t = 0
      var groupID: gid_t = 0
      guard getpeereid(descriptor, &userID, &groupID) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return userID
    #else
      var credentials = SocketCredentials()
      var length = socklen_t(MemoryLayout<SocketCredentials>.size)
      guard getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return credentials.userID
    #endif
  }

  #if os(Linux)
    // Linux SO_PEERCRED returns struct ucred in pid, uid, gid order.
    private struct SocketCredentials {
      var processID: pid_t = 0
      var userID: uid_t = 0
      var groupID: gid_t = 0
    }
  #endif
}
