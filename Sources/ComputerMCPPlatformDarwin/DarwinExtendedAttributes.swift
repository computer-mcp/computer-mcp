import ComputerMCPCore
import ComputerMCPPlatform
import Darwin
import Foundation

package struct DarwinExtendedAttributes: ExtendedAttributes {
  package init() {}

  package func names(at url: URL) throws -> [String] {
    let size = url.withUnsafeFileSystemRepresentation { pathPointer -> Int in
      guard let pathPointer else {
        errno = EINVAL
        return -1
      }
      return listxattr(pathPointer, nil, 0, 0)
    }
    guard size >= 0 else {
      throw extendedAttributeError("listxattr", url: url, errno: errno)
    }
    guard size > 0 else {
      return []
    }

    var buffer = [CChar](repeating: 0, count: size)
    let bytesRead = url.withUnsafeFileSystemRepresentation { pathPointer -> Int in
      guard let pathPointer else {
        errno = EINVAL
        return -1
      }
      return buffer.withUnsafeMutableBufferPointer { pointer in
        listxattr(pathPointer, pointer.baseAddress, pointer.count, 0)
      }
    }
    guard bytesRead >= 0 else {
      throw extendedAttributeError("listxattr", url: url, errno: errno)
    }

    var names: [String] = []
    var start = 0
    for index in 0..<bytesRead where buffer[index] == 0 {
      if index > start {
        names.append(
          String(
            decoding: buffer[start..<index].map { UInt8(bitPattern: $0) },
            as: UTF8.self
          ))
      }
      start = index + 1
    }
    return names
  }

  package func size(of name: String, at url: URL) throws -> Int {
    let size = url.withUnsafeFileSystemRepresentation { pathPointer -> Int in
      guard let pathPointer else {
        errno = EINVAL
        return -1
      }
      return name.withCString { namePointer in
        getxattr(pathPointer, namePointer, nil, 0, 0, 0)
      }
    }
    guard size >= 0 else {
      throw extendedAttributeError("getxattr", url: url, errno: errno)
    }
    return size
  }

  package func value(
    of name: String,
    at url: URL,
    size: Int,
    maxBytes: Int
  ) throws -> Data {
    let bytesToRead = min(size, maxBytes)
    guard bytesToRead > 0 else {
      return Data()
    }

    var data = Data(count: bytesToRead)
    let bytesRead = data.withUnsafeMutableBytes { rawBuffer -> Int in
      url.withUnsafeFileSystemRepresentation { pathPointer -> Int in
        guard let pathPointer else {
          errno = EINVAL
          return -1
        }
        return name.withCString { namePointer in
          getxattr(pathPointer, namePointer, rawBuffer.baseAddress, bytesToRead, 0, 0)
        }
      }
    }
    guard bytesRead >= 0 else {
      throw extendedAttributeError("getxattr", url: url, errno: errno)
    }
    if bytesRead < data.count {
      data.removeSubrange(bytesRead..<data.count)
    }
    return data
  }

  package func remove(_ name: String, descriptor: Int32) throws {
    guard fremovexattr(descriptor, name, 0) == 0 else {
      throw GatewayToolError.executionFailed(
        "fremovexattr failed: \(String(cString: strerror(errno)))")
    }
  }

  private func extendedAttributeError(_ operation: String, url: URL, errno error: Int32)
    -> GatewayToolError
  {
    GatewayToolError.executionFailed(
      "\(operation) failed for \(url.path): \(String(cString: strerror(error)))"
    )
  }

}
