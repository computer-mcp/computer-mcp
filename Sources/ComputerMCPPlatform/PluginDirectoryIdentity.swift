import Foundation

/// Local ownership evidence, not plugin metadata or an importable authorization.
package struct PluginDirectoryIdentity: Codable, Equatable, Sendable {
  package let url: URL
  package let volumeUUID: UUID?
  // Kept current during verified recovery so a previous host can read the receipt on rollback.
  package let device: Int32
  package let inode: UInt64
  package let birthSeconds: Int
  package let birthNanoseconds: Int

  private enum CodingKeys: String, CodingKey {
    case url, volumeUUID, device, inode, birthSeconds, birthNanoseconds
  }

  package init(
    url: URL, volumeUUID: UUID?, device: Int32, inode: UInt64, birthSeconds: Int,
    birthNanoseconds: Int
  ) {
    self.url = url
    self.volumeUUID = volumeUUID
    self.device = device
    self.inode = inode
    self.birthSeconds = birthSeconds
    self.birthNanoseconds = birthNanoseconds
  }

  /// Legacy provenance may conservatively retain files, but cannot authorize their adoption.
  package func mayReferToSameDirectory(as other: Self) -> Bool {
    url == other.url && inode == other.inode && birthSeconds == other.birthSeconds
      && birthNanoseconds == other.birthNanoseconds
      && (volumeUUID == nil || other.volumeUUID == nil || volumeUUID == other.volumeUUID)
  }
}
