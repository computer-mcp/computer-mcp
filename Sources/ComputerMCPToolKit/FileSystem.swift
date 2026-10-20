import ComputerMCPCore
import Foundation

package func fileType(_ attribute: Any?) -> String {
  guard let type = attribute as? FileAttributeType else {
    return "unknown"
  }
  switch type {
  case .typeDirectory:
    return "directory"
  case .typeRegular:
    return "file"
  case .typeSymbolicLink:
    return "symlink"
  case .typeSocket:
    return "socket"
  case .typeCharacterSpecial:
    return "character_special"
  case .typeBlockSpecial:
    return "block_special"
  default:
    return "unknown"
  }
}

package func relativePath(fromDirectoryPath rootPath: String, to url: URL) -> String {
  let path = url.standardizedFileURL.resolvingSymlinksInPath().path
  let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
  guard path.hasPrefix(prefix) else {
    return url.lastPathComponent
  }
  return String(path.dropFirst(prefix.count))
}
