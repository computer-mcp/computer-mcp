import Foundation

/// Identifies the physical folder admitted by a runtime, including replacement at the same path.
struct WorkspaceRootIdentity: Hashable, Sendable {
  let path: String
  let device: UInt64
  let inode: UInt64
  let createdAt: Date?

  init(_ root: URL) throws {
    path = root.standardizedFileURL.resolvingSymlinksInPath().path
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: path)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      throw WorkspaceBookmarkError.rootDoesNotExist(path: path)
    } catch {
      throw WorkspaceBookmarkError.rootIdentityUnavailable(path: path)
    }
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
      throw WorkspaceBookmarkError.rootIsNotDirectory(path: path)
    }
    guard let device = attributes[.systemNumber] as? NSNumber,
      let inode = attributes[.systemFileNumber] as? NSNumber
    else { throw WorkspaceBookmarkError.rootIdentityUnavailable(path: path) }
    self.device = device.uint64Value
    self.inode = inode.uint64Value
    createdAt = attributes[.creationDate] as? Date
  }
}
