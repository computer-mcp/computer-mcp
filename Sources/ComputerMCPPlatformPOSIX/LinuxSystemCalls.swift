#if canImport(Glibc)
  import CSystemPOSIX
  import Glibc

  package enum LinuxSystemCalls {
    package static func openSymbolicLink(_ parent: Int32, _ name: String) -> Int32 {
      computer_mcp_openat_symlink(parent, name)
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
