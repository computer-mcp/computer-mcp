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

package func sortedDirectoryChildren(_ directory: URL, includeHidden: Bool) throws -> [URL] {
  try FileManager.default.contentsOfDirectory(atPath: directory.path)
    .filter { includeHidden || !$0.hasPrefix(".") }
    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    .map { directory.appendingPathComponent($0) }
}

package func readBoundedFileData(url: URL, path: String, maxBytes: Int) throws -> Data {
  let handle = try FileHandle(forReadingFrom: url)
  defer {
    try? handle.close()
  }
  let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
  guard data.count <= maxBytes else {
    throw GatewayToolError.invalidArguments("File exceeds max_bytes: \(path)")
  }
  return data
}

package func existingFileSizeBytes(url: URL, existed: Bool) throws -> UInt64 {
  guard existed else {
    return 0
  }
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  guard let number = attributes[.size] as? NSNumber else {
    return 0
  }
  return number.uint64Value
}

package func requireDirectory(_ url: URL, originalPath: String) throws {
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
    throw GatewayToolError.invalidArguments("Directory does not exist: \(originalPath)")
  }
  guard isDirectory.boolValue else {
    throw GatewayToolError.invalidArguments("Path is not a directory: \(originalPath)")
  }
}
