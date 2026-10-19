import ComputerMCPPlatform
import Darwin
import Foundation

extension PluginDirectoryIdentity {
  package init(url: URL, status: stat, descriptor: Int32) throws {
    self.init(
      url: url, volumeUUID: try Self.volumeUUID(descriptor: descriptor), device: status.st_dev,
      inode: status.st_ino, birthSeconds: status.st_birthtimespec.tv_sec,
      birthNanoseconds: status.st_birthtimespec.tv_nsec)
  }

  package func matches(_ status: stat, descriptor: Int32) throws -> Bool {
    guard
      inode == status.st_ino
        && birthSeconds == status.st_birthtimespec.tv_sec
        && birthNanoseconds == status.st_birthtimespec.tv_nsec
    else { return false }
    if let volumeUUID { return try volumeUUID == Self.volumeUUID(descriptor: descriptor) }
    return device == status.st_dev
  }

  private static func volumeUUID(descriptor: Int32) throws -> UUID {
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
    // getattrlist packs the length and uuid without the padding of a Swift struct.
    var bytes = [UInt8](repeating: 0, count: 4 + MemoryLayout<uuid_t>.size)
    let result = bytes.withUnsafeMutableBytes {
      fgetattrlist(descriptor, &attributes, $0.baseAddress, $0.count, 0)
    }
    guard result == 0,
      bytes.withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }) == bytes.count,
      bytes.dropFirst(4).contains(where: { $0 != 0 })
    else { throw PluginArchiveError.fileSystemFailure }
    return bytes.withUnsafeBytes {
      UUID(uuid: $0.loadUnaligned(fromByteOffset: 4, as: uuid_t.self))
    }
  }
}
