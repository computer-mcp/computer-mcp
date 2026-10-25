import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// Pins the project and walks every component without following symbolic links.
/// Mutation methods recheck the opened inode and its directory chain at the point of use.
package final class ProjectFileAccess {
  package enum MutationPhase: Sendable { case willCheck, willMutate, didMutate, didCheck }

  private let root: URL
  private let lexicalRoot: URL
  private let descriptor: Int32
  private struct Identity: Hashable {
    let device: dev_t
    let inode: ino_t

    init(_ value: CreatedIdentity) {
      device = value.device
      inode = value.inode
    }

    init(_ value: stat) {
      device = value.st_dev
      inode = value.st_ino
    }
  }
  package struct BirthTime: Equatable {
    package let seconds: Int64
    package let nanoseconds: Int64

    package init(seconds: Int64, nanoseconds: Int64) {
      self.seconds = seconds
      self.nanoseconds = nanoseconds
    }
  }

  package struct CreatedIdentity {
    package var device: dev_t
    package var inode: ino_t
    package var birthTime: BirthTime?

    package init(_ value: stat, birthTime: BirthTime?) {
      device = value.st_dev
      inode = value.st_ino
      self.birthTime = birthTime
    }
  }

  private struct CreatedEntry {
    let birthTime: BirthTime?
    let descriptor: Int32?
  }

  package static let fallbackDescriptorLimit = 64
  private static let cleanupDescriptorReserve = 32
  private var createdEntries: [Identity: CreatedEntry] = [:]
  private var cleanupReserve: [Int32] = []
  private var fallbackCount = 0
  private let identityReader: (Int32) throws -> CreatedIdentity
  private var configurationFiles: Set<String> = []
  private let mutationObserver: ((String, URL, MutationPhase) throws -> Void)?

  package init(
    project: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
    commands: RegisteredCommands? = nil,
    mutationObserver: ((String, URL, MutationPhase) throws -> Void)? = nil,
    identityReader: ((Int32) throws -> CreatedIdentity)? = nil
  )
    throws
  {
    self.identityReader = identityReader ?? Self.createdIdentity
    self.mutationObserver = mutationObserver
    lexicalRoot = ProjectPathResolver.lexicallyNormalized(project)
    root = try ProjectPathResolver.canonicalProject(project)
    if let commands {
      try commands.validateProjectGitLayout(at: root)
    } else {
      try ProjectGitLayout.validate(project: root, environment: environment)
    }
    descriptor = try Self.openDirectory(root.path)
    let home = environment["HOME"] ?? NSHomeDirectory()
    let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
    for path in [
      "/etc/gitconfig", home + "/.gitconfig", xdg + "/git/config", environment["GIT_CONFIG_GLOBAL"],
      environment["GIT_CONFIG_SYSTEM"],
    ].compactMap({ $0 }) {
      try protectConfiguration(URL(fileURLWithPath: path))
    }
  }

  deinit {
    for entry in createdEntries.values { if let fd = entry.descriptor { close(fd) } }
    releaseCleanupReserve()
    close(descriptor)
  }

  package func url(
    _ path: String, allowFinalSymlink: Bool = false, allowHardLinks: Bool = false
  ) throws -> URL {
    guard !path.contains("\0"), !path.split(separator: "/").contains("..") else {
      throw denied("Path escapes project or contains invalid components.")
    }
    let url = ProjectPathResolver.lexicallyNormalized(
      path.hasPrefix("/") ? URL(fileURLWithPath: path) : lexicalRoot.appendingPathComponent(path))
    try validate(url, allowFinalSymlink: allowFinalSymlink, allowHardLinks: allowHardLinks)
    return url
  }

  package func validate(
    _ url: URL, recursive: Bool = false, allowFinalSymlink: Bool = false,
    allowHardLinks: Bool = false
  ) throws {
    let parts = try components(url)
    try checkProtected(url)
    if parts.isEmpty { return }
    try withParent(url, allowMissing: true) { parent, name in
      guard let status = try statusAt(parent, name) else { return }
      if allowFinalSymlink, status.st_mode & S_IFMT == S_IFLNK { return }
      try check(status, allowHardLinks: allowHardLinks)
      if status.st_mode & S_IFMT == S_IFDIR {
        let child = try openChild(parent, name, directory: true)
        defer { close(child) }
        try checkDirectory(child)
        if recursive {
          for entry in try names(child) {
            try validate(
              url.appendingPathComponent(entry), recursive: true, allowHardLinks: allowHardLinks)
          }
        }
      }
    }
  }

  package func validateTrash(_ url: URL) throws {
    guard try !components(url).isEmpty else { throw denied("Cannot trash the project root.") }
    try validate(url, recursive: true, allowHardLinks: true)
  }

  /// The staging directory is pinned for cleanup, including when its parent is moved.
  /// Destination times can be preserved across successful or failed staging operations.
  package func withStagingDirectory<T>(
    in destination: URL, destinationIdentity: stat? = nil, preservingDestinationTimes: Bool = false,
    _ body: (URL, Int32) throws -> T
  ) throws -> T {
    let url = destination.appendingPathComponent(".computer-mcp-\(UUID().uuidString).tmp")
    do {
      return try withParent(url) { parent, name in
        if let destinationIdentity, !same(destinationIdentity, try status(parent)) {
          throw denied("Destination directory changed.")
        }
        let original = preservingDestinationTimes ? try status(parent) : nil
        let result = Result {
          guard let created = try mkdirChecked(parent, name, at: url, mode: 0o700) else {
            throw denied("Staging directory already exists.")
          }
          let fd = try openChild(parent, name, directory: true)
          defer { close(fd) }
          guard same(created, try status(fd)) else { throw denied("Staging directory changed.") }
          func clean() throws {
            let location = descriptorURL(fd) ?? url
            do {
              guard fchmod(fd, 0o700) == 0 else { throw failure() }
              let retained = try discardContents(fd, at: location)
              guard retained.isEmpty else {
                throw denied("Retained: \(retained.joined(separator: ", ")).")
              }
              try removeCreated(parent, name, identity: created, directory: true)
            } catch {
              throw denied(
                "Cleanup left staging at \(location.path) (entry: \(url.path)): \(error.localizedDescription)"
              )
            }
          }
          let result: T
          do {
            result = try body(url, fd)
            try verifyParent(parent, of: url)
            guard same(created, try statusAt(parent, name)) else {
              throw denied("Staging directory changed.")
            }
          } catch {
            try clean()
            throw error
          }
          try clean()
          return result
        }
        if let original {
          func restoreTimes(_ value: stat) throws {
            #if canImport(Darwin)
              let times = [value.st_atimespec, value.st_mtimespec]
            #else
              let times = [value.st_atim, value.st_mtim]
            #endif
            try preservingBirthTime(parent) {
              guard futimens(parent, times) == 0 else { throw failure() }
            }
          }
          let published = try status(parent)
          try mutate("futimens", anchors: [(parent, url)]) {
            try restoreTimes(original)
          } undo: { _ in
            try restoreTimes(published)
          }
        }
        return try result.get()
      }
    } catch {
      throw denied("Staging operation failed at \(url.path): \(error.localizedDescription)")
    }
  }

  /// Includes implicit parent directories, and refuses links and special entries.
  package func tree(_ url: URL) throws -> [String: Bool] {
    var entries: [String: Bool] = [:]
    func walk(_ fd: Int32, at directory: URL, prefix: String) throws {
      for name in try names(fd) {
        let childURL = directory.appendingPathComponent(name)
        try checkProtected(childURL)
        let child = try openChild(fd, name)
        defer { close(child) }
        let entry = try status(child)
        try check(entry)
        guard try owns(child) else {
          throw denied("Staging contains an entry this operation did not create: \(childURL.path)")
        }
        guard same(entry, try statusAt(fd, name)) else { throw denied("Entry changed.") }
        try verifyParent(fd, of: childURL)
        let path = prefix + name
        let directory = entry.st_mode & S_IFMT == S_IFDIR
        entries[path] = directory
        if directory { try walk(child, at: childURL, prefix: path + "/") }
      }
    }
    try withParent(url) { parent, name in
      let fd = try openChild(parent, name, directory: true)
      defer { close(fd) }
      try walk(fd, at: url, prefix: "")
      try verifyParent(parent, of: url)
      guard same(try status(fd), try statusAt(parent, name)) else {
        throw denied("Directory changed.")
      }
    }
    return entries
  }

  private func discardContents(_ fd: Int32, at url: URL) throws -> [String] {
    releaseCleanupReserve()
    var retained: [String] = []
    for name in try names(fd) {
      guard let entry = try statusAt(fd, name) else { continue }
      let childURL = url.appendingPathComponent(name)
      let kind = entry.st_mode & S_IFMT
      guard kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK else {
        retained.append(childURL.path)
        continue
      }
      let permission = try openIdentity(fd, name)
      defer { close(permission) }
      guard same(entry, try status(permission)), try owns(permission) else {
        retained.append(childURL.path)
        continue
      }
      let directory = entry.st_mode & S_IFMT == S_IFDIR
      if directory {
        #if canImport(Glibc)
          let changed = LinuxSystemCalls.chmodIdentity(permission, (entry.st_mode & 0o7777) | 0o700)
        #else
          let changed = fchmod(permission, (entry.st_mode & 0o7777) | 0o700)
        #endif
        guard changed == 0 else { throw failure() }
        let child = try openChild(fd, name, directory: true)
        defer { close(child) }
        guard same(entry, try status(child)) else {
          retained.append(childURL.path)
          continue
        }
        let children = try discardContents(child, at: childURL)
        if !children.isEmpty {
          retained += children
          continue
        }
      }
      do {
        try removeCreated(fd, name, identity: entry, directory: directory)
      } catch {
        retained.append(childURL.path)
      }
    }
    return retained
  }

  private func descriptorURL(_ fd: Int32) -> URL? {
    #if canImport(Darwin)
      var path = [CChar](repeating: 0, count: Int(PATH_MAX))
      guard fcntl(fd, F_GETPATH, &path) == 0 else { return nil }
      return URL(
        fileURLWithPath: String(
          decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    #elseif canImport(Glibc)
      var path = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
      let count = readlink("/proc/self/fd/\(fd)", &path, path.count)
      guard count >= 0, count < path.count else { return nil }
      return URL(fileURLWithPath: String(decoding: path.prefix(count), as: UTF8.self))
    #else
      return nil
    #endif
  }

  package func write(
    _ data: Data, to url: URL, overwrite: Bool = true, createDirectories: Bool = false
  ) throws {
    try writeGenerated(to: url, overwrite: overwrite, createDirectories: createDirectories) { fd in
      try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
    }
  }

  /// Publishes only a fully produced regular file; a failed producer leaves the destination intact.
  package func writeGenerated<T>(
    to url: URL, overwrite: Bool, createDirectories: Bool,
    maximumBytes: Int? = nil, creationMode: UInt16 = 0o600, produce: (Int32) throws -> T
  ) throws -> T {
    var result: T?
    try withParent(url, create: createDirectories) { parent, name in
      let existing = try statusAt(parent, name)
      if let existing {
        try check(existing, regular: true)
        guard overwrite else { throw denied("Destination already exists.") }
      }
      let temporary = ".computer-mcp-\(UUID().uuidString).tmp"
      let fd = try createTemporary(parent, name: temporary, for: url, mode: mode_t(creationMode))
      defer {
        if let created = try? status(fd), same(created, try? statusAt(parent, temporary)) {
          try? removeCreated(parent, temporary, identity: created)
        }
        close(fd)
      }
      result = try preservingBirthTime(fd) { try produce(fd) }
      let produced = try status(fd)
      try check(produced, regular: true)
      if let maximumBytes, produced.st_size > maximumBytes {
        throw denied("Output exceeds its byte limit.")
      }
      guard same(produced, try statusAt(parent, temporary)) else {
        throw denied("Temporary file changed.")
      }
      if let existing { guard fchmod(fd, existing.st_mode & 0o777) == 0 else { throw failure() } }
      try verifyParent(parent, of: url)
      let current = try statusAt(parent, name)
      if let current { try check(current, regular: true) }
      guard same(existing, current) else {
        throw denied("Destination changed during the operation.")
      }
      let finalProduced = try status(fd)
      try check(finalProduced, regular: true)
      guard same(finalProduced, try statusAt(parent, temporary)) else {
        throw denied("Temporary file changed.")
      }
      let backup = ".computer-mcp-\(UUID().uuidString).tmp"
      var backupIdentity = existing
      var backedUp = false
      var published = false
      do {
        if let existing {
          try renameChecked(
            parent, name, to: parent, backup, identity: existing, source: url, destination: url)
          backedUp = true
        }
        try renameChecked(
          parent, temporary, to: parent, name, identity: finalProduced, source: url,
          destination: url)
        published = true
        if backedUp {
          try unlinkChecked(parent, backup, at: url, restored: { backupIdentity = $0 })
          backedUp = false
        }
      } catch {
        if published { try removeCreated(parent, name, identity: produced) }
        if backedUp, let backupIdentity {
          try restoreMoved(parent, backup, to: parent, name, identity: backupIdentity)
        }
        throw error
      }
    }
    return result!
  }

  package func append(_ data: Data, to url: URL, create: Bool, createDirectories: Bool) throws
    -> UInt64
  {
    var size: UInt64 = 0
    try withParent(url, create: createDirectories) { parent, name in
      let original = try statusAt(parent, name)
      if let original {
        try check(original, regular: true)
        size = UInt64(original.st_size)
      } else if !create {
        throw denied("File does not exist.")
      }
      try writeGenerated(to: url, overwrite: true, createDirectories: false) { output in
        if let original {
          let input = try openChild(parent, name)
          defer { close(input) }
          guard same(original, try status(input)) else { throw denied("File changed.") }
          try stream(input, to: output)
          try check(try status(input), regular: true)
        }
        guard same(original, try statusAt(parent, name)) else { throw denied("File changed.") }
        try FileHandle(fileDescriptor: output, closeOnDealloc: false).write(contentsOf: data)
      }
    }
    return size
  }

  package func read(_ url: URL, maximumBytes: Int? = nil) throws -> Data {
    try withReadDescriptor(url) { fd in
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      if let maximumBytes { return try handle.read(upToCount: maximumBytes) ?? Data() }
      return try handle.readToEnd() ?? Data()
    }
  }

  package func withReadDescriptor<T>(_ url: URL, _ body: (Int32) throws -> T) throws -> T {
    try withParent(url) { parent, name in
      let fd = try openChild(parent, name)
      defer { close(fd) }
      try check(try status(fd), regular: true)
      return try body(fd)
    }
  }

  package func withTemporaryFile<T>(in directory: URL, _ body: (Int32) throws -> T) throws -> T {
    let url = directory.appendingPathComponent(".computer-mcp-\(UUID().uuidString).tmp")
    return try withParent(url) { parent, name in
      let fd = try createTemporary(parent, name: name, for: url)
      defer { close(fd) }
      let created = try status(fd)
      let result = Result {
        let result = try body(fd)
        try check(try status(fd), regular: true)
        return result
      }
      guard same(created, try statusAt(parent, name)) else {
        throw denied("Temporary file changed; left at \(url.path).")
      }
      try removeCreated(parent, name, identity: created)
      return try result.get()
    }
  }

  @discardableResult
  package func mkdir(_ url: URL, recursive: Bool, mode: UInt16 = 0o755) throws -> stat? {
    if try components(url).isEmpty { return nil }
    var created: stat?
    try withParent(url, create: recursive) { parent, name in
      created = try mkdirChecked(parent, name, at: url, mode: mode_t(mode))
      let fd = try openChild(parent, name, directory: true)
      close(fd)
    }
    return created
  }

  package func chmod(_ url: URL, mode: Int) throws {
    try withDescriptor(url, operation: "fchmod") { fd in
      guard fchmod(fd, mode_t(mode)) == 0 else { throw failure() }
    }
  }

  package func touch(_ url: URL, create: Bool, createDirectories: Bool) throws {
    try withParent(url, create: createDirectories) { parent, name in
      if try statusAt(parent, name) == nil {
        guard create else { throw denied("File does not exist.") }
        try write(Data(), to: url, overwrite: false)
      }
      try withDescriptor(url, operation: "futimens") { fd in
        guard futimens(fd, nil) == 0 else { throw failure() }
      }
    }
  }

  /// Restores an archive member's metadata through its checked descriptor.
  package func setArchiveMetadata(
    _ url: URL, identity: stat? = nil, mode: UInt16? = nil, seconds: Int64, nanoseconds: Int
  ) throws {
    guard let seconds = Int(exactly: seconds), (0..<1_000_000_000).contains(nanoseconds) else {
      throw denied("Archive modification time is outside the supported range.")
    }
    try withDescriptor(url, identity: identity, operation: "futimens") { fd in
      let opened = try status(fd)
      #if canImport(Darwin)
        let accessed = opened.st_atimespec
      #else
        let accessed = opened.st_atim
      #endif
      let values = [accessed, timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
      if let mode { guard fchmod(fd, mode_t(mode)) == 0 else { throw failure() } }
      guard futimens(fd, values) == 0 else { throw failure() }
    }
  }

  /// The callback may use only descriptor-based APIs; it must not reopen the URL.
  package func withDescriptor<T>(
    _ url: URL, identity: stat? = nil, operation: String = "metadata",
    affectedXattrs: [String] = [],
    _ body: (Int32) throws -> T
  ) throws -> T {
    try withParent(url) { parent, name in
      let fd = try openChild(parent, name)
      defer { close(fd) }
      let opened = try status(fd)
      if let identity, !same(identity, opened) { throw denied("Path changed.") }
      try check(opened)
      try checkDirectory(fd)
      try verifyParent(parent, of: url)
      guard same(opened, try statusAt(parent, name)) else { throw denied("Path changed.") }
      try check(try status(fd))
      let attributes = try snapshotXattrs(fd, names: affectedXattrs)
      func restore() throws {
        try restoreXattrs(fd, values: attributes)
        guard fchmod(fd, opened.st_mode & 0o7777) == 0 else { throw failure() }
        #if canImport(Darwin)
          let times = [opened.st_atimespec, opened.st_mtimespec]
        #else
          let times = [opened.st_atim, opened.st_mtim]
        #endif
        try preservingBirthTime(fd) {
          guard futimens(fd, times) == 0 else { throw failure() }
        }
      }
      return try mutate(operation, anchors: [(parent, url)]) {
        try check(try status(fd))
        guard same(opened, try statusAt(parent, name)) else { throw denied("Path changed.") }
        do { return try preservingBirthTime(fd) { try body(fd) } } catch {
          try restore()
          throw error
        }
      } validate: { _ in
        try check(try status(fd))
        // A directory's final mode can prevent traversal through its own descriptor.
        // Its checked parent and matching entry identity still establish containment.
        if opened.st_mode & S_IFMT == S_IFDIR { try verifyContainment(parent) }
        guard same(opened, try statusAt(parent, name)) else { throw denied("Path changed.") }
      } undo: { _ in
        try restore()
      }
    }
  }

  package func copy(_ source: URL, to destination: URL, overwrite: Bool, createDirectories: Bool)
    throws
  {
    guard !ProjectPathResolver.contains(destination, in: source) else {
      throw denied("Destination must be outside the source tree.")
    }
    try validate(source, recursive: true)
    try validate(destination, recursive: true)
    try withParent(destination, create: createDirectories) { _, _ in
      try withStagingDirectory(in: destination.deletingLastPathComponent()) { staging, _ in
        let copy = staging.appendingPathComponent("copy")
        try copyMember(source, to: copy, createDirectories: false)
        try move(copy, to: destination, overwrite: overwrite, createDirectories: false)
      }
    }
  }

  package func move(_ source: URL, to destination: URL, overwrite: Bool, createDirectories: Bool)
    throws
  {
    guard !ProjectPathResolver.contains(destination, in: source) else {
      throw denied("Destination must be outside the source tree.")
    }
    try validate(source, recursive: true)
    try validate(destination, recursive: true)
    try withParent(source) { inputParent, inputName in
      let input = try openChild(inputParent, inputName)
      defer { close(input) }
      let original = try status(input)
      try check(original)
      try verifyMoveVolume(input, to: destination)
      try withParent(destination, create: createDirectories) { outputParent, outputName in
        try requireSameVolume(input, outputParent)
        let existing = try statusAt(outputParent, outputName)
        if existing != nil {
          let output = try openChild(outputParent, outputName)
          defer { close(output) }
          try requireSameVolume(input, output)
          guard overwrite else { throw denied("Destination already exists.") }
          try removeIfPresent(destination)
        }
        guard same(original, try statusAt(inputParent, inputName)) else {
          throw denied("Source changed.")
        }
        try renameChecked(
          inputParent, inputName, to: outputParent, outputName, identity: original,
          source: source, destination: destination)
        do { try validate(destination, recursive: true) } catch {
          try restoreMoved(outputParent, outputName, to: inputParent, inputName, identity: original)
          throw error
        }
      }
    }
  }

  /// Checks the nearest existing destination directory before creating parents or removing entries.
  private func verifyMoveVolume(_ input: Int32, to destination: URL) throws {
    var parent = dup(descriptor)
    guard parent >= 0 else { throw failure() }
    defer { close(parent) }
    for part in try components(destination).dropLast() {
      let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      if next < 0, errno == ENOENT {
        try requireSameVolume(input, parent)
        return
      }
      guard next >= 0 else {
        throw denied("Cannot open destination directory without following links.")
      }
      close(parent)
      parent = next
      try checkDirectory(parent)
    }
    try requireSameVolume(input, parent)
    if try statusAt(parent, destination.lastPathComponent) != nil {
      let output = try openChild(parent, destination.lastPathComponent)
      defer { close(output) }
      try requireSameVolume(input, output)
    }
  }

  private func requireSameVolume(_ source: Int32, _ destination: Int32) throws {
    guard try status(source).st_dev == status(destination).st_dev else {
      throw denied("Cross-volume moves are not supported; copy and then delete the source.")
    }
  }

  package func symlink(_ target: String, at url: URL, overwrite: Bool, createDirectories: Bool)
    throws
  {
    try withParent(url, create: createDirectories) { parent, name in
      let existing = try statusAt(parent, name)
      if let existing {
        guard overwrite else { throw denied("Destination already exists.") }
        if existing.st_mode & S_IFMT != S_IFLNK { try check(existing, regular: true) }
      }
      try verifyParent(parent, of: url)
      guard same(existing, try statusAt(parent, name)) else { throw denied("Path changed.") }
      if existing != nil { try unlinkChecked(parent, name, at: url) }
      try mutate("symlinkat", anchors: [(parent, url)]) {
        try checkCreationBudget()
        guard symlinkat(target, parent, name) == 0 else { throw failure() }
        let created = try statusAt(parent, name)!
        try recordCreatedSymbolicLink(parent, name, identity: created)
        return created
      } undo: { created in
        try removeCreated(parent, name, identity: created)
      }
    }
  }

  private func copyMember(_ source: URL, to destination: URL, createDirectories: Bool) throws {
    try withParent(source) { parent, name in
      let fd = try openChild(parent, name)
      defer { close(fd) }
      let sourceStatus = try status(fd)
      try check(sourceStatus)
      if sourceStatus.st_mode & S_IFMT == S_IFDIR {
        try mkdir(destination, recursive: createDirectories)
        for child in try names(fd) {
          try copyMember(
            source.appendingPathComponent(child), to: destination.appendingPathComponent(child),
            createDirectories: false)
        }
        try withDescriptor(destination, operation: "fcopyfile") { output in
          try copyMetadata(fd, to: output, original: sourceStatus)
          try verifyParent(parent, of: source)
          try check(try status(fd))
          guard same(sourceStatus, try statusAt(parent, name)) else {
            throw denied("Source changed.")
          }
        }
      } else {
        try writeGenerated(to: destination, overwrite: false, createDirectories: createDirectories)
        { output in
          try mutationObserver?("fcopyfile", source, .willMutate)
          try check(try status(fd), regular: true)
          try copyFile(fd, to: output)
          try mutationObserver?("fcopyfile", source, .didMutate)
          try verifyParent(parent, of: source)
          try check(try status(fd), regular: true)
          guard same(sourceStatus, try statusAt(parent, name)) else {
            throw denied("Source changed.")
          }
        }
      }
    }
  }

  private func stream(_ input: Int32, to output: Int32) throws {
    let reader = FileHandle(fileDescriptor: input, closeOnDealloc: false)
    let writer = FileHandle(fileDescriptor: output, closeOnDealloc: false)
    while let data = try reader.read(upToCount: 65_536), !data.isEmpty {
      try writer.write(contentsOf: data)
    }
  }

  private func removeIfPresent(_ url: URL) throws {
    try withParent(url, allowMissing: true) { parent, name in
      guard let before = try statusAt(parent, name) else { return }
      try check(before)
      if before.st_mode & S_IFMT == S_IFDIR {
        let fd = try openChild(parent, name, directory: true)
        defer { close(fd) }
        for child in try names(fd) { try removeIfPresent(url.appendingPathComponent(child)) }
      }
      try verifyParent(parent, of: url)
      guard same(before, try statusAt(parent, name)) else { throw denied("Path changed.") }
      try unlinkChecked(parent, name, at: url, directory: before.st_mode & S_IFMT == S_IFDIR)
    }
  }

  private func components(_ url: URL) throws -> [String] {
    let normalized = ProjectPathResolver.lexicallyNormalized(url)
    for base in [root, lexicalRoot] {
      if ProjectPathResolver.contains(normalized, in: base), !normalized.path.contains("\0") {
        return Array(normalized.pathComponents.dropFirst(base.pathComponents.count))
      }
    }
    throw denied("Path escapes project.")
  }

  private func withParent(
    _ url: URL, create: Bool = false, allowMissing: Bool = false,
    _ body: (Int32, String) throws -> Void
  ) throws {
    let parts = try components(url)
    try checkProtected(url)
    guard let name = parts.last else { throw denied("Cannot mutate the project root.") }
    var fd = dup(descriptor)
    guard fd >= 0 else { throw failure() }
    defer { close(fd) }
    var created: [(Int32, String, stat)] = []
    var completed = false
    defer {
      for (parent, name, identity) in created.reversed() {
        if !completed { try? removeCreated(parent, name, identity: identity, directory: true) }
        close(parent)
      }
    }
    try checkDirectory(fd)
    var walked = root
    for part in parts.dropLast() {
      walked.appendPathComponent(part)
      if create, let entry = try mkdirChecked(fd, part, at: walked) {
        let pinned = dup(fd)
        guard pinned >= 0 else { throw failure() }
        created.append((pinned, part, entry))
      }
      let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      if next < 0, allowMissing, errno == ENOENT { return }
      guard next >= 0 else {
        throw denied("Path contains a symbolic link or inaccessible directory.")
      }
      close(fd)
      fd = next
      try checkDirectory(fd)
    }
    try checkProtected(url)
    try body(fd, name)
    completed = true
  }

  private func withParent<T>(_ url: URL, _ body: (Int32, String) throws -> T) throws -> T {
    var value: T?
    try withParent(url, create: false, allowMissing: false) { fd, name in value = try body(fd, name)
    }
    return value!
  }

  private func verifyParent(_ fd: Int32, of url: URL) throws {
    try checkProtected(url)
    var current = try Self.openDirectory(root.path)
    guard current >= 0 else { throw failure() }
    defer { close(current) }
    guard same(try status(current), try status(descriptor)) else {
      throw denied("Project root changed.")
    }
    try checkDirectory(current)
    for part in try components(url).dropLast() {
      let next = try openChild(current, part, directory: true)
      close(current)
      current = next
      try checkDirectory(current)
    }
    try checkProtected(url)
    guard same(try status(fd), try status(current)) else {
      throw denied("Directory changed during the operation.")
    }
    try verifyContainment(fd)
  }

  /// Walking upward catches an ancestor moved after the forward lookup opened it.
  private func verifyContainment(_ fd: Int32) throws {
    let project = try status(descriptor)
    var current = dup(fd)
    guard current >= 0 else { throw failure() }
    defer { close(current) }
    for _ in 0..<1_024 {
      let entry = try status(current)
      try checkDirectory(current)
      if same(entry, project) { return }
      let parent = try openChild(current, "..", directory: true)
      let parentStatus = try status(parent)
      close(current)
      current = parent
      guard !same(entry, parentStatus) else { break }
    }
    throw denied("Directory left the project during the operation.")
  }

  @discardableResult
  private func mutate<T>(
    _ operation: String, anchors: [(Int32, URL)], _ body: () throws -> T,
    validate: (T) throws -> Void = { _ in },
    undo: (T) throws -> Void
  ) throws -> T {
    for (fd, url) in anchors {
      try mutationObserver?(operation, url, .willCheck)
      try verifyParent(fd, of: url)
    }
    try mutationObserver?(operation, anchors[0].1, .willMutate)
    let result = try body()
    do {
      try mutationObserver?(operation, anchors[0].1, .didMutate)
      for (fd, url) in anchors { try verifyParent(fd, of: url) }
      try validate(result)
      try mutationObserver?(operation, anchors[0].1, .didCheck)
    } catch {
      try undo(result)
      throw error
    }
    return result
  }

  @discardableResult
  private func mkdirChecked(
    _ parent: Int32, _ name: String, at url: URL, mode: mode_t = 0o755
  ) throws -> stat? {
    try mutate("mkdirat", anchors: [(parent, url)]) {
      let pinPermissions = mode & 0o500 != 0o500
      if try statusAt(parent, name) == nil { try checkCreationBudget() }
      if mkdirat(parent, name, pinPermissions ? mode | 0o700 : mode) != 0 {
        guard errno == EEXIST else { throw failure() }
        return nil
      }
      guard let created = try statusAt(parent, name) else {
        throw denied("Created directory changed.")
      }
      let fd: Int32
      do { fd = try openChild(parent, name, directory: true) } catch {
        throw denied("Cannot pin created directory; entry retained at \(url.path): \(error)")
      }
      defer { close(fd) }
      guard same(created, try status(fd)) else { throw denied("Created directory changed.") }
      do {
        try recordCreated(fd)
        if pinPermissions {
          guard fchmod(fd, created.st_mode & mode & 0o777) == 0 else { throw failure() }
        }
      } catch {
        try removeAnchored(parent, name, descriptor: fd, directory: true)
        throw error
      }
      return created
    } undo: { created in
      if let created { try removeCreated(parent, name, identity: created, directory: true) }
    }
  }

  private func createTemporary(_ parent: Int32, name: String, for url: URL, mode: mode_t = 0o600)
    throws -> Int32
  {
    try mutate("openat", anchors: [(parent, url)]) {
      try checkCreationBudget()
      let fd = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
      guard fd >= 0 else { throw failure() }
      do { try recordCreated(fd) } catch {
        defer { close(fd) }
        try removeAnchored(parent, name, descriptor: fd)
        throw error
      }
      return fd
    } undo: { fd in
      defer { close(fd) }
      try removeCreated(parent, name, identity: status(fd))
    }
  }

  private func renameExclusive(_ source: Int32, _ name: String, _ target: Int32, _ leaf: String)
    -> Int32
  {
    #if canImport(Darwin)
      renameatx_np(source, name, target, leaf, UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY))
    #elseif canImport(Glibc)
      // Both names are single components in pinned directories; rename never follows the leaf.
      LinuxSystemCalls.renameExclusive(source, name, target, leaf)
    #else
      errno = ENOTSUP
      return -1
    #endif
  }

  private func renameChecked(
    _ sourceParent: Int32, _ name: String, to targetParent: Int32, _ leaf: String,
    identity original: stat, source: URL, destination: URL
  ) throws {
    let input = try openChild(sourceParent, name)
    defer { close(input) }
    guard same(original, try status(input)) else { throw denied("Source changed concurrently.") }
    try check(try status(input))
    try requireSameVolume(input, targetParent)
    try mutate("renameatx_np", anchors: [(sourceParent, source), (targetParent, destination)]) {
      let current = try statusAt(sourceParent, name)
      guard same(original, current), let current else { throw denied("Source changed.") }
      try check(current)
      try requireSameVolume(input, targetParent)
      guard renameExclusive(sourceParent, name, targetParent, leaf) == 0 else {
        if errno == EXDEV {
          throw denied("Cross-volume moves are not supported; copy and then delete the source.")
        }
        throw failure()
      }
    } validate: { _ in
      guard let moved = try statusAt(targetParent, leaf), same(original, moved) else {
        throw denied("Renamed file changed.")
      }
      try check(moved)
    } undo: { _ in
      try restoreMoved(targetParent, leaf, to: sourceParent, name, identity: original)
    }
  }

  private func restoreMoved(
    _ parent: Int32, _ name: String, to destination: Int32, _ leaf: String, identity: stat
  ) throws {
    guard same(identity, try statusAt(parent, name)) else {
      throw denied("Entry changed concurrently; rollback left it in place.")
    }
    guard renameExclusive(parent, name, destination, leaf) == 0 else { throw failure() }
  }

  private func unlinkChecked(
    _ parent: Int32, _ name: String, at url: URL, directory: Bool = false,
    restored: (stat) -> Void = { _ in }
  ) throws {
    let original = try statusAt(parent, name)
    guard let original else { throw denied("Path changed.") }
    if original.st_mode & S_IFMT != S_IFLNK { try check(original) }
    let input = original.st_mode & S_IFMT == S_IFLNK ? -1 : try openChild(parent, name)
    defer { if input >= 0 { close(input) } }
    if input >= 0 {
      let opened = try status(input)
      guard same(original, opened) else { throw denied("Path changed.") }
      try check(opened)
    }
    let link = original.st_mode & S_IFMT == S_IFLNK ? try linkTarget(parent, name) : nil
    try mutate("unlinkat", anchors: [(parent, url)]) {
      guard let current = try statusAt(parent, name), same(original, current) else {
        throw denied("Path changed.")
      }
      if current.st_mode & S_IFMT != S_IFLNK { try check(current) }
      guard unlinkat(parent, name, directory ? AT_REMOVEDIR : 0) == 0 else { throw failure() }
    } undo: { _ in
      guard try statusAt(parent, name) == nil else {
        throw denied("Entry changed concurrently; rollback left it in place.")
      }
      try checkCreationBudget()
      let recovered: stat
      if directory {
        guard mkdirat(parent, name, original.st_mode & 0o777) == 0 else { throw failure() }
        let output = try openChild(parent, name, directory: true)
        defer { close(output) }
        recovered = try status(output)
        try recordCreated(output)
        try preservingBirthTime(output) { try copyMetadata(input, to: output) }
      } else if let link {
        guard symlinkat(link, parent, name) == 0 else { throw failure() }
        recovered = try statusAt(parent, name)!
        try recordCreatedSymbolicLink(parent, name, identity: recovered)
      } else {
        let output = openat(
          parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw failure() }
        defer { close(output) }
        recovered = try status(output)
        try recordCreated(output)
        try preservingBirthTime(output) { try copyFile(input, to: output) }
      }
      guard same(recovered, try statusAt(parent, name)) else {
        throw denied("Entry changed concurrently; rollback left it in place.")
      }
      restored(recovered)
    }
  }

  private func linkTarget(_ parent: Int32, _ name: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlinkat(parent, name, &buffer, buffer.count - 1)
    guard count >= 0, count < buffer.count - 1 else { throw failure() }
    return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  package static func createdIdentity(_ fd: Int32) throws -> CreatedIdentity {
    var value = stat()
    guard fstat(fd, &value) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    return CreatedIdentity(value, birthTime: try birthTime(fd))
  }

  private static func birthTime(_ fd: Int32) throws -> BirthTime? {
    #if canImport(Darwin)
      var value = stat()
      guard fstat(fd, &value) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
      return BirthTime(
        seconds: Int64(value.st_birthtimespec.tv_sec),
        nanoseconds: Int64(value.st_birthtimespec.tv_nsec))
    #elseif canImport(Glibc)
      let time = try LinuxSystemCalls.birthTime(fd)
      return time.map { BirthTime(seconds: $0.seconds, nanoseconds: $0.nanoseconds) }
    #else
      throw POSIXError(.ENOTSUP)
    #endif
  }

  private func releaseCleanupReserve() {
    for fd in cleanupReserve { close(fd) }
    cleanupReserve.removeAll()
  }

  private func checkCreationBudget() throws {
    guard fallbackCount < Self.fallbackDescriptorLimit else {
      releaseCleanupReserve()
      throw denied(
        "Created-entry descriptor limit (\(Self.fallbackDescriptorLimit)) exceeded on a filesystem without birth time."
      )
    }
  }

  private func recordCreated(_ fd: Int32) throws {
    let read = try identityReader(fd)
    let identity = Identity(read)
    let birthTime = read.birthTime
    if let birthTime {
      createdEntries[identity] = CreatedEntry(birthTime: birthTime, descriptor: nil)
      return
    }
    try checkCreationBudget()
    // Reserve actual slots before retaining any fallback descriptor. Release them for rollback.
    do {
      if cleanupReserve.isEmpty {
        for _ in 0..<Self.cleanupDescriptorReserve {
          let reserved = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
          guard reserved >= 0 else { throw failure() }
          cleanupReserve.append(reserved)
        }
      }
      let pinned = fcntl(fd, F_DUPFD_CLOEXEC, 0)
      guard pinned >= 0 else { throw failure() }
      createdEntries[identity] = CreatedEntry(birthTime: nil, descriptor: pinned)
      fallbackCount += 1
    } catch {
      releaseCleanupReserve()
      throw error
    }
  }

  private func owns(_ fd: Int32) throws -> Bool {
    let read = try identityReader(fd)
    guard let entry = createdEntries[Identity(read)] else { return false }
    if let birthTime = entry.birthTime { return read.birthTime == birthTime }
    return entry.descriptor != nil
  }

  private func openIdentity(_ parent: Int32, _ name: String) throws -> Int32 {
    #if canImport(Darwin)
      let fd = openat(parent, name, O_EVTONLY | O_SYMLINK | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    #elseif canImport(Glibc)
      let fd = LinuxSystemCalls.openIdentity(parent, name)
    #else
      let fd: Int32 = -1
    #endif
    guard fd >= 0 else { throw failure() }
    return fd
  }

  // Darwin metadata copies and backdated mtime writes can change birth time. Keep the
  // creation identity on the still-open inode before releasing its writing descriptor.
  private func preservingBirthTime<T>(_ fd: Int32, _ body: () throws -> T) throws -> T {
    #if canImport(Darwin)
      let original = try status(fd)
      guard createdEntries[Identity(original)] != nil else { return try body() }
      let result = Result { try body() }
      let current = try status(fd)
      if current.st_birthtimespec.tv_sec != original.st_birthtimespec.tv_sec
        || current.st_birthtimespec.tv_nsec != original.st_birthtimespec.tv_nsec
      {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var birth = original.st_birthtimespec
        guard fsetattrlist(fd, &attributes, &birth, MemoryLayout<timespec>.size, 0) == 0 else {
          throw failure()
        }
      }
      return try result.get()
    #else
      return try body()
    #endif
  }

  private func recordCreatedSymbolicLink(_ parent: Int32, _ name: String, identity: stat) throws {
    #if canImport(Darwin)
      let fd = openat(parent, name, O_SYMLINK | O_CLOEXEC)
    #elseif canImport(Glibc)
      let fd = LinuxSystemCalls.openIdentity(parent, name)
    #else
      let fd: Int32 = -1
    #endif
    guard fd >= 0 else {
      let path = descriptorURL(parent)?.appendingPathComponent(name).path ?? name
      throw denied("Cannot pin symbolic link without following it; entry retained at \(path).")
    }
    defer { close(fd) }
    guard same(identity, try status(fd)) else { throw denied("Created symbolic link changed.") }
    do { try recordCreated(fd) } catch {
      try removeAnchored(parent, name, descriptor: fd)
      throw error
    }
  }

  private func removeCreated(
    _ parent: Int32, _ name: String, identity: stat, directory: Bool = false
  ) throws {
    releaseCleanupReserve()
    let fd = try openIdentity(parent, name)
    defer { close(fd) }
    guard same(identity, try status(fd)), try owns(fd) else {
      throw denied("Entry changed concurrently; rollback left it in place.")
    }
    try removeAnchored(parent, name, descriptor: fd, directory: directory)
  }

  /// The live descriptor prevents reuse when recording identity itself failed.
  private func removeAnchored(
    _ parent: Int32, _ name: String, descriptor fd: Int32, directory: Bool = false
  ) throws {
    guard same(try status(fd), try statusAt(parent, name)) else {
      throw denied("Entry changed concurrently; rollback left it in place.")
    }
    guard unlinkat(parent, name, directory ? AT_REMOVEDIR : 0) == 0 else { throw failure() }
  }

  private func copyFile(_ input: Int32, to output: Int32) throws {
    guard lseek(input, 0, SEEK_SET) >= 0 else { throw failure() }
    #if canImport(Darwin)
      guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
        throw failure()
      }
    #elseif canImport(Glibc)
      let original = try status(input)
      try stream(input, to: output)
      try copyMetadata(input, to: output, original: original)
    #else
      throw denied("Metadata-preserving copy is unavailable on this platform.")
    #endif
  }

  private func snapshotXattrs(_ fd: Int32, names: [String]) throws -> [String: Data] {
    var values: [String: Data] = [:]
    for name in names {
      #if canImport(Darwin)
        let count = fgetxattr(fd, name, nil, 0, 0, 0)
        guard count >= 0 else { throw failure() }
        var value = Data(count: count)
        let read = value.withUnsafeMutableBytes {
          fgetxattr(fd, name, $0.baseAddress, $0.count, 0, 0)
        }
        guard read >= 0 else { throw failure() }
        value.count = read
        values[name] = value
      #elseif canImport(Glibc)
        values[name] = try LinuxFileMetadata.value(name, descriptor: fd)
      #else
        throw denied("Descriptor extended attributes are unavailable on this platform.")
      #endif
    }
    return values
  }

  private func restoreXattrs(_ fd: Int32, values: [String: Data]) throws {
    for (name, value) in values {
      #if canImport(Darwin)
        let result = value.withUnsafeBytes {
          fsetxattr(fd, name, $0.baseAddress, $0.count, 0, 0)
        }
        guard result == 0 else { throw failure() }
      #elseif canImport(Glibc)
        try LinuxFileMetadata.set(name, value: value, descriptor: fd)
      #else
        throw denied("Descriptor extended attributes are unavailable on this platform.")
      #endif
    }
  }

  private func copyMetadata(_ input: Int32, to output: Int32, original: stat? = nil) throws {
    #if canImport(Darwin)
      guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
        throw failure()
      }
    #elseif canImport(Glibc)
      try LinuxFileMetadata.copy(input, to: output, original: original ?? status(input))
    #else
      throw denied("Metadata-preserving copy is unavailable on this platform.")
    #endif
  }

  private static func openDirectory(_ path: String) throws -> Int32 {
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(.EACCES) }
    for part in path.split(separator: "/") {
      let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      close(fd)
      guard next >= 0 else { throw POSIXError(.ELOOP) }
      fd = next
    }
    return fd
  }

  private func openChild(_ parent: Int32, _ name: String, directory: Bool = false) throws -> Int32 {
    let fd = openat(
      parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
    guard fd >= 0 else { throw denied("Cannot open path without following links.") }
    return fd
  }

  private func statusAt(_ parent: Int32, _ name: String) throws -> stat? {
    var value = stat()
    guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return nil }
      throw failure()
    }
    return value
  }

  private func status(_ fd: Int32) throws -> stat {
    var value = stat()
    guard fstat(fd, &value) == 0 else { throw failure() }
    return value
  }

  private func same(_ lhs: stat?, _ rhs: stat?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): true
    case (.some(let a), .some(let b)): a.st_dev == b.st_dev && a.st_ino == b.st_ino
    default: false
    }
  }

  private func check(_ value: stat, regular: Bool = false, allowHardLinks: Bool = false) throws {
    let kind = value.st_mode & S_IFMT
    guard kind == S_IFREG || (!regular && kind == S_IFDIR) else {
      throw denied("Writes refuse symbolic links and special files.")
    }
    guard allowHardLinks || kind != S_IFREG || value.st_nlink == 1 else {
      throw denied("Writes refuse files with more than one hard link.")
    }
  }

  private func names(_ fd: Int32) throws -> [String] {
    let copy = dup(fd)
    guard copy >= 0 else { throw failure() }
    guard let directory = fdopendir(copy) else {
      close(copy)
      throw failure()
    }
    defer { closedir(directory) }
    rewinddir(directory)
    var entries: [String] = []
    errno = 0
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
      }
      if name != ".", name != ".." { entries.append(name) }
      errno = 0
    }
    guard errno == 0 else { throw failure() }
    return entries.sorted()
  }

  private func protectConfiguration(_ file: URL) throws {
    let target = try resolveConfigurationURL(file)
    for url in [file, target] {
      configurationFiles.insert(url.path.precomposedStringWithCanonicalMapping.lowercased())
    }
  }

  /// Resolves links before subsequent parent components, including paths with a missing leaf.
  private func resolveConfigurationURL(_ url: URL) throws -> URL {
    guard !url.path.contains("\0") else { throw denied("Invalid Git configuration path.") }
    var result = URL(fileURLWithPath: "/")
    var missing = false
    for component in url.path.split(separator: "/") {
      if component == "." { continue }
      if component == ".." {
        guard !missing else { throw denied("Cannot inspect Git configuration path.") }
        result.deleteLastPathComponent()
        continue
      }
      result.appendPathComponent(String(component))
      var entry = stat()
      if lstat(result.path, &entry) != 0 {
        guard errno == ENOENT else { throw failure() }
        missing = true
        continue
      }
      guard let resolved = realpath(result.path, nil) else { throw failure() }
      result = URL(fileURLWithPath: String(cString: resolved))
      free(resolved)
    }
    return result
  }

  private func checkDirectory(_ fd: Int32) throws {
    try check(try status(fd))
  }

  private func checkProtected(_ url: URL) throws {
    let canonical = root.appendingPathComponent(try components(url).joined(separator: "/")).path
      .precomposedStringWithCanonicalMapping.lowercased()
    let parts = url.pathComponents.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
    guard !parts.contains(".git"), !parts.contains(".gitconfig"),
      !canonical.hasSuffix("/.config/git/config"),
      !configurationFiles.contains(canonical)
    else { throw denied("File tools cannot write Git metadata or configuration.") }
  }

  private func denied(_ message: String) -> GatewayToolError {
    .invalidArguments("[policy.project_denied] \(message)")
  }

  private func failure() -> GatewayToolError {
    .executionFailed("File operation failed: \(String(cString: strerror(errno)))")
  }
}
