#if canImport(Glibc)
  import CSystemPOSIX
  import Glibc
  import Foundation

  package enum LinuxSystemCalls {
    package static func openIdentity(_ parent: Int32, _ name: String) -> Int32 {
      computer_mcp_openat_identity(parent, name)
    }

    package static func birthTime(_ descriptor: Int32) throws -> (
      seconds: Int64, nanoseconds: Int64
    )? {
      var seconds: Int64 = 0
      var nanoseconds: Int64 = 0
      let result = computer_mcp_birthtime(descriptor, &seconds, &nanoseconds)
      guard result >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
      return result == 0 ? nil : (seconds, nanoseconds)
    }

    package static func chmodIdentity(_ descriptor: Int32, _ mode: mode_t) -> Int32 {
      computer_mcp_chmod_identity(descriptor, mode)
    }

    /// The filesystem must support atomic no-replace rename; errors never fall back to replacement.
    package static func renameExclusive(
      _ source: Int32, _ name: String, _ target: Int32, _ leaf: String
    ) -> Int32 {
      computer_mcp_renameat_noreplace(source, name, target, leaf)
    }

    package static func addWorkingDirectory(
      _ descriptor: Int32, to actions: UnsafeMutablePointer<posix_spawn_file_actions_t>
    ) -> Int32 {
      computer_mcp_spawn_addfchdir(actions, descriptor)
    }
  }
#endif
