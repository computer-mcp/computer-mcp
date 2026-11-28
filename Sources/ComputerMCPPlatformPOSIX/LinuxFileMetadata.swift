#if canImport(Glibc)
  import CSystemPOSIX
  import Foundation
  import Glibc

  package enum LinuxFileMetadata {
    package static func names(_ descriptor: Int32) throws -> [String] {
      let count = computer_mcp_flistxattr(descriptor, nil, 0)
      if count < 0, errno == ENOTSUP { return [] }
      guard count >= 0 else { throw failure() }
      guard count > 0 else { return [] }
      var buffer = [CChar](repeating: 0, count: count)
      let read = computer_mcp_flistxattr(descriptor, &buffer, buffer.count)
      guard read >= 0 else { throw failure() }
      return buffer.prefix(read).split(separator: 0).map {
        String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      }
    }

    package static func value(_ name: String, descriptor: Int32) throws -> Data {
      let count = computer_mcp_fgetxattr(descriptor, name, nil, 0)
      guard count >= 0 else { throw failure() }
      // A nonempty buffer distinguishes an empty attribute from one that grew after the size query.
      var value = Data(count: max(1, count))
      let read = value.withUnsafeMutableBytes {
        computer_mcp_fgetxattr(descriptor, name, $0.baseAddress, $0.count)
      }
      guard read >= 0 else { throw failure() }
      value.count = read
      return value
    }

    package static func set(_ name: String, value: Data, descriptor: Int32) throws {
      let result = value.withUnsafeBytes {
        computer_mcp_fsetxattr(descriptor, name, $0.baseAddress, $0.count)
      }
      guard result == 0 else { throw failure() }
    }

    package static func remove(_ name: String, descriptor: Int32) throws {
      guard computer_mcp_fremovexattr(descriptor, name) == 0 else { throw failure() }
    }

    /// Copies visible xattrs, including POSIX ACLs, before applying the final mode and times.
    /// Ownership stays with the created destination; Linux has no native resource fork or BSD flags.
    package static func copy(_ input: Int32, to output: Int32, original: stat) throws {
      var attributes: [String: Data] = [:]
      for name in try names(input) {
        attributes[name] = try value(name, descriptor: input)
      }
      // A destination can inherit a default ACL or other attributes from its parent.
      for name in try names(output) where attributes[name] == nil {
        try remove(name, descriptor: output)
      }
      for (name, value) in attributes {
        try set(name, value: value, descriptor: output)
      }
      guard fchmod(output, original.st_mode & 0o7777) == 0 else { throw failure() }
      guard futimens(output, [original.st_atim, original.st_mtim]) == 0 else { throw failure() }
    }

    private static func failure() -> POSIXError {
      POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
#endif
