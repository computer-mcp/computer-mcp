#if os(Windows)
  import Foundation
  import WinSDK

  extension ExecutableInspection {
    /// Resolves against the complete child PATH and cwd, then inspects without launching.
    /// The process owner must use the returned absolute path; no shell/PATHEXT expansion occurs.
    package static func inspect(
      _ executable: String, workingDirectory: URL, environment: [String: String]
    ) -> Self {
      let explicit =
        executable.contains("/") || executable.contains("\\") || executable.contains(":")
      var result = Self(
        executable: executable.utf16.count < 32_767 ? executable : "", path: nil,
        source: explicit
          ? (WindowsFilePath.isAbsolute(executable) ? "absolute_path" : "relative_path") : "path")
      guard WindowsFilePath.isValid(executable), workingDirectory.isFileURL else {
        result.status = .invalidPath
        return result
      }
      let cwd = workingDirectory.withUnsafeFileSystemRepresentation {
        $0.map(String.init(cString:))
      }
      guard let cwd, WindowsFilePath.isAbsolute(cwd) else {
        result.status = .invalidPath
        return result
      }
      let candidates: [String]
      if explicit {
        guard let path = WindowsFilePath.absolute(executable, cwd: cwd) else {
          result.status = .invalidPath
          return result
        }
        candidates = [withExecutableExtension(path)]
      } else {
        let paths = environment.filter { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }
        guard paths.count <= 1 else {
          result.status = .invalidPath
          return result
        }
        guard let path = paths.first?.value else { return result }
        guard !path.contains("\0") else {
          result.status = .invalidPath
          return result
        }
        guard path.utf16.count <= 65_536, path.filter({ $0 == ";" }).count < 1_024 else {
          result.status = .unverified
          return result
        }
        candidates = path.split(separator: ";", omittingEmptySubsequences: false).compactMap {
          var directory = String($0)
          if directory.hasPrefix("\""), directory.hasSuffix("\""), directory.count >= 2 {
            directory = String(directory.dropFirst().dropLast())
          }
          guard let root = WindowsFilePath.absolute(directory.isEmpty ? "." : directory, cwd: cwd)
          else {
            return nil
          }
          return root + "\\" + withExecutableExtension(executable)
        }
      }
      guard
        let path = candidates.first(where: { path in
          if explicit { return true }
          let attributes = Array(path.utf16) + [0]
          let value = GetFileAttributesW(attributes)
          return value != INVALID_FILE_ATTRIBUTES && value & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
        })
      else { return result }
      result.path = path
      let wide = Array(path.utf16) + [0]
      let attributes = GetFileAttributesW(wide)
      guard attributes != INVALID_FILE_ATTRIBUTES else {
        let code = GetLastError()
        result.status =
          code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND ? .missing : .unreadable
        return result
      }
      result.exists = true
      guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_DEVICE) == 0 else {
        result.status = .notRegularFile
        return result
      }
      // Inspect the reparse object itself, so a replacement cannot redirect an open to a pipe/device.
      let handle = CreateFileW(
        wide, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
        nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        result.status = .unreadable
        return result
      }
      defer { CloseHandle(handle) }
      var information = BY_HANDLE_FILE_INFORMATION()
      guard GetFileType(handle) == FILE_TYPE_DISK,
        GetFileInformationByHandle(handle, &information),
        information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_DEVICE) == 0
      else {
        result.status = .notRegularFile
        return result
      }
      guard information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        result.status = .unverified
        return result
      }
      result.isRegularFile = true
      var bytes = [UInt8](repeating: 0, count: 512)
      var count: DWORD = 0
      guard ReadFile(handle, &bytes, DWORD(bytes.count), &count, nil) else {
        result.status = .unreadable
        return result
      }
      bytes.removeSubrange(Int(count)...)
      let suffix = (path as NSString).pathExtension.lowercased()
      if ["cmd", "bat", "ps1", "py", "sh"].contains(suffix) || bytes.starts(with: [35, 33]) {
        result.isScript = true
        result.status = .interpreterRequired
        return result
      }
      // MZ is a bounded file observation, not PE validation or an architecture/ACL guarantee.
      result.isExecutable = bytes.starts(with: [77, 90])
      result.status = result.isExecutable ? .passed : .unverified
      return result
    }

    private static func withExecutableExtension(_ path: String) -> String {
      (path as NSString).pathExtension.isEmpty ? path + ".exe" : path
    }

  }
#endif
