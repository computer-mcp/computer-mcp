import ComputerMCPPlatform
import CoreFoundation
import Darwin
import Foundation

package struct DarwinManagedPolicyReader: ManagedPolicyReading {
  package static let machinePath = "/Library/Application Support/Computer MCP/policy.toml"
  package static let preferencesDomain = "com.showxu.computer-mcp"
  package static let preferencesKey = "Policy"
  private static let maximumBytes = 1_048_576
  private let machinePath: String
  private let expectedOwner: uid_t
  private let preferences: @Sendable () -> ManagedPolicyReadStatus

  package init() {
    machinePath = Self.machinePath
    expectedOwner = 0
    preferences = Self.readManagedPreferences
  }

  /// Isolated paths and a preference adapter let tests exercise failure states
  /// without reading or changing the machine's installed policy.
  init(
    machinePath: String, expectedOwner: uid_t,
    preferences: @escaping @Sendable () -> ManagedPolicyReadStatus
  ) {
    self.machinePath = machinePath
    self.expectedOwner = expectedOwner
    self.preferences = preferences
  }

  package func readSources() -> [ManagedPolicySourceSnapshot] {
    [
      .init(source: .machineFile, location: machinePath, status: readMachineFile()),
      .init(
        source: .managedPreferences, location: Self.preferencesDomain + "/" + Self.preferencesKey,
        status: preferences()),
    ]
  }

  package func canonicalPolicyPath(_ path: String) throws -> String {
    try Self.canonicalPolicyPath(path, openPath: { open($0, $1) })
  }

  static func canonicalPolicyPath(
    _ path: String, openPath: (String, Int32) -> Int32
  ) throws -> String {
    guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    var cursor = URL(fileURLWithPath: path)
    var suffix: [String] = []
    while true {
      let fd = openPath(cursor.path, O_EVTONLY | O_CLOEXEC | O_NONBLOCK)
      if fd >= 0 {
        defer { close(fd) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw CocoaError(.fileReadUnknown) }
        let prefix = String(
          decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return suffix.reversed().reduce(prefix) { ($0 == "/" ? "" : $0) + "/" + $1 }
      }
      // A deny may name another user's or a TCC-protected folder. Resolve the
      // accessible prefix without requiring access to the denied object itself.
      guard [ENOENT, EACCES, EPERM].contains(errno), cursor.path != "/" else {
        throw CocoaError(.fileReadUnknown)
      }
      suffix.append(cursor.lastPathComponent)
      cursor.deleteLastPathComponent()
    }
  }

  /// Descriptor-relative traversal prevents an unprotected directory from turning
  /// an enforced policy into an apparently absent file by rename or unlink.
  private func openMachineFile() -> Int32 {
    let parts = machinePath.split(separator: "/").map(String.init)
    guard machinePath.hasPrefix("/"), let name = parts.last,
      !parts.contains("."), !parts.contains("..")
    else {
      errno = EINVAL
      return -1
    }
    var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parent >= 0 else { return -1 }
    defer { close(parent) }
    for component in parts.dropLast() {
      var info = stat()
      guard fstat(parent, &info) == 0,
        info.st_uid == 0 || info.st_uid == expectedOwner,
        info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0,
        Self.hasProtectedACL(parent)
      else {
        errno = EACCES
        return -1
      }
      let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { return -1 }
      close(parent)
      parent = next
    }
    var info = stat()
    guard fstat(parent, &info) == 0,
      info.st_uid == 0 || info.st_uid == expectedOwner,
      info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0,
      Self.hasProtectedACL(parent)
    else {
      errno = EACCES
      return -1
    }
    return openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
  }

  /// ACL grants can permit replacement even when POSIX mode bits are protected.
  private static func hasProtectedACL(_ descriptor: Int32) -> Bool {
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    var selector = ACL_FIRST_ENTRY
    while true {
      let result = acl_get_entry(acl, selector.rawValue, &entry)
      if result == -1 { return errno == EINVAL }
      guard let entry else { return false }
      selector = ACL_NEXT_ENTRY
      var tag = acl_tag_t(0)
      guard acl_get_tag_type(entry, &tag) == 0 else { return false }
      if tag != ACL_EXTENDED_ALLOW { continue }
      var permissions: acl_permset_t?
      guard acl_get_permset(entry, &permissions) == 0, let permissions else { return false }
      let mutation: [acl_perm_t] = [
        ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE,
        ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES,
        ACL_WRITE_SECURITY, ACL_CHANGE_OWNER,
      ]
      for permission in mutation {
        if acl_get_perm_np(permissions, permission) != 0 { return false }
      }
    }
  }

  private func readMachineFile() -> ManagedPolicyReadStatus {
    let fd = openMachineFile()
    guard fd >= 0 else {
      return errno == ENOENT ? .absent : .unreadable("Machine policy cannot be opened.")
    }
    defer { close(fd) }
    var metadata = stat()
    guard fstat(fd, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == expectedOwner,
      metadata.st_mode & 0o022 == 0, Self.hasProtectedACL(fd), metadata.st_size >= 0,
      metadata.st_size <= Self.maximumBytes
    else {
      return .unreadable(
        "Machine policy must be a protected, administrator-owned regular file within the size limit."
      )
    }
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        return .unreadable("Machine policy cannot be read.")
      }
      guard bytes.count + count <= Self.maximumBytes else {
        return .unreadable("Machine policy exceeds the size limit.")
      }
      bytes.append(contentsOf: buffer.prefix(count))
    }
    var after = stat()
    guard fstat(fd, &after) == 0, metadata.st_size == after.st_size,
      metadata.st_uid == after.st_uid, metadata.st_mode == after.st_mode,
      metadata.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      metadata.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
    else {
      return .unreadable("Machine policy changed while being read.")
    }
    return .available(bytes)
  }

  private static func readManagedPreferences() -> ManagedPolicyReadStatus {
    let domain = preferencesDomain as CFString
    let key = preferencesKey as CFString
    guard CFPreferencesAppSynchronize(domain) else {
      return .unreadable("Managed preferences cannot be refreshed.")
    }
    guard CFPreferencesAppValueIsForced(key, domain) else { return .absent }
    guard let value = CFPreferencesCopyAppValue(key, domain) as? String,
      let bytes = value.data(using: .utf8), bytes.count <= maximumBytes
    else {
      return .unreadable("The managed Policy preference must contain TOML within the size limit.")
    }
    return .available(bytes)
  }
}
