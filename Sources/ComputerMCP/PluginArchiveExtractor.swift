import CSystemArchive
import Darwin
import Foundation

/// Streaming decoder for a private, already downloaded/copied archive snapshot.
/// It does not verify publisher identity, activate packages, or execute their code.
/// Cancellation is cooperative between parser calls; untrusted parsing belongs
/// in an installer worker with independent CPU/memory/time limits.
struct PluginArchiveExtractor {
  struct Result: Equatable, Sendable {
    let root: URL
    let entries: Int
    let bytes: Int
  }

  let limits: PluginArchiveLimits

  init(limits: PluginArchiveLimits = PluginArchiveLimits()) {
    self.limits = limits
  }

  func extract(
    _ source: URL, toNewDirectory destination: URL,
    checkCancellation: () throws -> Void = { try Task.checkCancellation() }
  ) throws -> Result {
    try limits.validate()
    try checkCancellation()
    guard source.isFileURL, source.path.hasPrefix("/"), !source.path.contains("\0") else {
      throw PluginArchiveError.invalidInput
    }
    let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard input >= 0 else { throw PluginArchiveError.invalidInput }
    defer { Darwin.close(input) }
    var status = stat()
    guard fstat(input, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_size > 0
    else { throw PluginArchiveError.invalidInput }
    guard status.st_size <= limits.archiveBytes else { throw PluginArchiveError.limitExceeded }
    guard let archive = archive_read_new() else { throw PluginArchiveError.invalidArchive }
    defer { archive_read_free(archive) }
    // Register only built-in parsers/filters. support_filter_all can introduce
    // external helper processes for compression formats absent from the library.
    guard archive_read_support_filter_gzip(archive) == 0,
      archive_read_support_format_tar(archive) == 0,
      archive_read_support_format_zip(archive) == 0,
      archive_read_open_fd(archive, input, 65_536) == 0
    else { throw PluginArchiveError.invalidArchive }
    let directory = try PluginArchiveDirectory(at: destination)
    do {
      let result = try decode(archive, into: directory, checkCancellation: checkCancellation)
      guard archive_read_close(archive) == 0 else { throw PluginArchiveError.invalidArchive }
      try checkCancellation()
      try directory.finish()
      return result
    } catch {
      // A cleanup failure is actionable; never report that partial files were
      // removed if the owned staging root could not be safely reclaimed.
      try directory.discard()
      throw error
    }
  }

  private func decode(
    _ archive: OpaquePointer, into directory: PluginArchiveDirectory,
    checkCancellation: () throws -> Void
  ) throws -> Result {
    var paths = Paths()
    var entryCount = 0
    var total = 0
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      try checkCancellation()
      var entry: OpaquePointer?
      let code = archive_read_next_header(archive, &entry)
      try validateStream(archive)
      if code == 1 { break }
      guard code == 0, let entry else { throw PluginArchiveError.invalidArchive }
      guard entryCount < limits.entries else { throw PluginArchiveError.limitExceeded }
      entryCount += 1
      let type = archive_entry_filetype(entry)
      let isDirectory = type == S_IFDIR
      guard isDirectory || type == S_IFREG,
        archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil,
        archive_entry_is_encrypted(entry) == 0, archive_entry_sparse_count(entry) == 0
      else { throw PluginArchiveError.unsupportedEntry }
      guard let pointer = archive_entry_pathname_utf8(entry),
        strnlen(pointer, limits.pathBytes + 1) <= limits.pathBytes,
        let path = String(validatingCString: pointer)
      else { throw PluginArchiveError.unsafePath }
      let parts = try pathComponents(path, isDirectory: isDirectory)
      try paths.insert(parts, isDirectory: isDirectory)
      guard paths.entries.count <= limits.entries else { throw PluginArchiveError.limitExceeded }
      let size = archive_entry_size(entry)
      guard size >= 0, !isDirectory || size == 0 else { throw PluginArchiveError.invalidArchive }
      guard size <= limits.fileBytes, size <= limits.expandedBytes - total else {
        throw PluginArchiveError.limitExceeded
      }
      if isDirectory {
        try directory.createDirectory(parts)
      } else {
        try directory.createFile(parts, executable: archive_entry_perm(entry) & 0o111 != 0) {
          file in
          var written = 0
          while true {
            try checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
              archive_read_data(archive, $0.baseAddress, $0.count)
            }
            try validateStream(archive)
            guard count >= 0 else { throw PluginArchiveError.invalidArchive }
            if count == 0 { break }
            guard count <= limits.fileBytes - written, count <= limits.expandedBytes - total else {
              throw PluginArchiveError.limitExceeded
            }
            try buffer.withUnsafeBytes { data in
              var offset = 0
              while offset < count {
                let result = Darwin.write(
                  file, data.baseAddress?.advanced(by: offset), count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw PluginArchiveError.fileSystemFailure }
                offset += result
              }
            }
            written += count
            total += count
          }
          if archive_entry_size_is_set(entry) != 0, written != size {
            throw PluginArchiveError.invalidArchive
          }
        }
      }
    }
    guard entryCount > 0 else { throw PluginArchiveError.invalidArchive }
    return Result(root: directory.url, entries: entryCount, bytes: total)
  }

  private func validateStream(_ archive: OpaquePointer) throws {
    let format = archive_format(archive) & 0xFF0000
    guard format == 0x30000 || format == 0x50000 else { throw PluginArchiveError.invalidArchive }
    let filters = archive_filter_count(archive)
    guard filters > 0, filters <= 2 else { throw PluginArchiveError.invalidArchive }
    for index in 0..<filters {
      let filter = archive_filter_code(archive, index)
      guard filter == 0 || filter == 1 else { throw PluginArchiveError.invalidArchive }
    }
    // The extra allowance covers bounded archive headers/padding, not file
    // payload. File payload has its own stricter cumulative bound.
    guard archive_filter_bytes(archive, -1) <= limits.archiveBytes,
      archive_filter_bytes(archive, 0) <= Int64(limits.expandedBytes) + 64 * 1_024 * 1_024
    else { throw PluginArchiveError.limitExceeded }
  }

  private func pathComponents(_ path: String, isDirectory: Bool) throws -> [String] {
    guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw PluginArchiveError.unsafePath }
    var normalized = path
    while normalized.hasPrefix("./") { normalized.removeFirst(2) }
    if isDirectory, normalized.hasSuffix("/") { normalized.removeLast() }
    if isDirectory, normalized == "." || normalized.isEmpty { return [] }
    let parts = normalized.components(separatedBy: "/")
    guard parts.count <= limits.pathDepth,
      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
    else { throw PluginArchiveError.unsafePath }
    return parts
  }

  private struct Paths {
    struct Entry {
      let spelling: String
      let directory: Bool
      var explicit: Bool
    }
    var entries: [String: Entry] = [:]

    mutating func insert(_ parts: [String], isDirectory: Bool) throws {
      if parts.isEmpty {
        guard entries[""] == nil else { throw PluginArchiveError.conflictingPath }
        entries[""] = Entry(spelling: "", directory: true, explicit: true)
        return
      }
      for index in parts.indices {
        let path = parts[...index].joined(separator: "/")
        let key = path.folding(
          options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")
        )
        .precomposedStringWithCanonicalMapping
        let explicit = index == parts.count - 1
        let directory = !explicit || isDirectory
        if var existing = entries[key] {
          guard existing.spelling.utf8.elementsEqual(path.utf8), existing.directory, directory,
            !explicit || !existing.explicit
          else { throw PluginArchiveError.conflictingPath }
          existing.explicit = existing.explicit || explicit
          entries[key] = existing
        } else {
          entries[key] = Entry(spelling: path, directory: directory, explicit: explicit)
        }
      }
    }
  }
}
