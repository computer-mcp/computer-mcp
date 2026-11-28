import ComputerMCPCore
import ComputerMCPPlatformPOSIX
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

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
  guard let access = HostPathAccess.current else {
    return try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { includeHidden || !$0.hasPrefix(".") }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      .map { directory.appendingPathComponent($0) }
  }
  try access.check(directory, operation: .listDirectory)
  let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
  guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
  guard let stream = fdopendir(fd) else {
    close(fd)
    throw POSIXError(.init(rawValue: errno) ?? .EIO)
  }
  defer { closedir(stream) }
  let actual = try authorizedDescriptorURL(fd)
  try access.check(actual, operation: .listDirectory)
  var names: [String] = []
  errno = 0
  while let entry = readdir(stream) {
    let name = withUnsafePointer(to: &entry.pointee.d_name) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
    }
    if name != ".", name != "..", includeHidden || !name.hasPrefix(".") { names.append(name) }
    errno = 0
  }
  guard errno == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
  try access.check(authorizedDescriptorURL(fd), operation: .listDirectory)
  return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    .map { actual.appendingPathComponent($0) }
    .filter { child in
      if access.isAccessible(child, operation: .read) { return true }
      var isDirectory = ObjCBool(false)
      return FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory)
        && isDirectory.boolValue && access.isAccessible(child, operation: .openDirectory)
    }
}

package func readBoundedFileData(url: URL, path: String, maxBytes: Int) throws -> Data {
  let handle = try AuthorizedFileReader(url: url)
  defer { try? handle.close() }
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
