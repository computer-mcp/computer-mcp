#if os(Windows)
  import Foundation
  import WinSDK

  extension WorkspacePathResolver {
    package static func resolve(_ path: String, relativeTo workspaceURL: URL) throws -> URL {
      guard let lexicalRoot = normalized(workspaceURL),
        let target = WindowsFilePath.absolute(path, cwd: lexicalRoot)
      else { throw inspectionError(path, ERROR_INVALID_NAME) }
      let workspace = try observe(lexicalRoot)
      guard workspace.isDirectory else { throw inspectionError(lexicalRoot, ERROR_DIRECTORY) }
      // Lexical admission is only a precheck; native identity proves physical containment below.
      guard
        lexicalContains(target, root: lexicalRoot)
          || lexicalContains(target, root: workspace.path)
      else { throw WorkspacePathResolutionError.escapesWorkspace }

      var ancestor = target
      var missing: [String] = []
      while true {
        let probe = CreateFileW(
          Array(ancestor.utf16) + [0], DWORD(FILE_READ_ATTRIBUTES),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT), nil)
        if let probe, probe != INVALID_HANDLE_VALUE {
          CloseHandle(probe)
          break
        }
        let code = GetLastError()
        guard code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND,
          missing.count < 1_024, let parent = parent(ancestor), parent != ancestor
        else { throw inspectionError(ancestor, code) }
        missing.insert(
          String(ancestor.dropFirst(parent.count)).trimmingCharacters(in: slash), at: 0)
        ancestor = parent
      }

      let existing = try observe(ancestor)
      guard missing.isEmpty || existing.isDirectory else {
        throw inspectionError(ancestor, ERROR_DIRECTORY)
      }
      var current = existing
      var visited = Set<String>()
      while current.identity != workspace.identity {
        guard visited.count < 1_024, visited.insert(current.path).inserted,
          let parent = parent(current.path), parent != current.path
        else {
          throw WorkspacePathResolutionError.escapesWorkspace
        }
        current = try observe(parent)
      }
      var resolved = existing.path
      for component in missing {
        resolved += (resolved.hasSuffix("\\") ? "" : "\\") + component
      }
      guard WindowsFilePath.isValid(resolved) else {
        throw inspectionError(resolved, ERROR_INVALID_NAME)
      }
      return URL(fileURLWithPath: resolved)
    }

    package static func canonicalWorkspace(_ workspaceURL: URL) throws -> URL {
      guard let path = normalized(workspaceURL) else {
        throw inspectionError(workspaceURL.path, ERROR_INVALID_NAME)
      }
      let result = try observe(path)
      guard result.isDirectory else { throw inspectionError(path, ERROR_DIRECTORY) }
      return URL(fileURLWithPath: result.path)
    }

    package static func lexicallyNormalized(_ url: URL) -> URL {
      normalized(url).map { URL(fileURLWithPath: $0) } ?? url
    }

    /// A lexical precheck only; use resolve for physical filesystem containment.
    package static func contains(_ candidate: URL, in workspace: URL) -> Bool {
      guard let candidate = normalized(candidate), let root = normalized(workspace) else {
        return false
      }
      return lexicalContains(candidate, root: root)
    }

    private static let slash = CharacterSet(charactersIn: "\\")

    private static func normalized(_ url: URL) -> String? {
      guard let path = WindowsFilePath.native(url), WindowsFilePath.isAbsolute(path) else {
        return nil
      }
      return WindowsFilePath.absolute(path, cwd: path)
    }

    private static func lexicalContains(_ candidate: String, root: String) -> Bool {
      let candidate = candidate.lowercased().replacingOccurrences(of: "/", with: "\\")
      let root = root.lowercased().replacingOccurrences(of: "/", with: "\\")
      let prefix = root.hasSuffix("\\") ? root : root + "\\"
      return candidate == root || candidate.hasPrefix(prefix)
    }

    private static func parent(_ path: String) -> String? {
      let url = URL(fileURLWithPath: path).deletingLastPathComponent()
      guard let result = normalized(url), result != path else { return nil }
      return result
    }

    private struct Identity: Equatable {
      let volume: UInt64
      let file: Data
    }

    private struct Observation {
      let path: String
      let identity: Identity
      let isDirectory: Bool
    }

    private static func observe(_ path: String) throws -> Observation {
      guard WindowsFilePath.isValid(path), WindowsFilePath.isAbsolute(path) else {
        throw inspectionError(path, ERROR_INVALID_NAME)
      }
      // Following reparses is intentional: the final object must prove ancestry by identity.
      let handle = CreateFileW(
        Array(path.utf16) + [0], DWORD(FILE_READ_ATTRIBUTES),
        DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING),
        DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw inspectionError(path, GetLastError())
      }
      defer { CloseHandle(handle) }
      var info = BY_HANDLE_FILE_INFORMATION()
      guard GetFileType(handle) == FILE_TYPE_DISK else {
        throw inspectionError(path, ERROR_INVALID_HANDLE)
      }
      guard GetFileInformationByHandle(handle, &info) else {
        throw inspectionError(path, GetLastError())
      }
      var identifier = FILE_ID_INFO()
      guard
        GetFileInformationByHandleEx(
          handle, FileIdInfo, &identifier, DWORD(MemoryLayout.size(ofValue: identifier)))
      else { throw inspectionError(path, GetLastError()) }
      var output = [WCHAR](repeating: 0, count: 32_768)
      let count = GetFinalPathNameByHandleW(
        handle, &output, DWORD(output.count), DWORD(FILE_NAME_NORMALIZED | VOLUME_NAME_DOS))
      guard count > 0 else { throw inspectionError(path, GetLastError()) }
      guard count < output.count else { throw inspectionError(path, ERROR_FILENAME_EXCED_RANGE) }
      let final = String(decoding: output.prefix(Int(count)), as: UTF16.self)
      let canonical: String
      if final.hasPrefix("\\\\?\\UNC\\") {
        canonical = "\\\\" + final.dropFirst(8)
      } else if final.hasPrefix("\\\\?\\") {
        canonical = String(final.dropFirst(4))
      } else {
        throw inspectionError(path, ERROR_INVALID_NAME)
      }
      guard WindowsFilePath.isValid(canonical), WindowsFilePath.isAbsolute(canonical) else {
        throw inspectionError(path, ERROR_INVALID_NAME)
      }
      return Observation(
        path: canonical,
        identity: Identity(
          volume: identifier.VolumeSerialNumber,
          file: withUnsafeBytes(of: identifier.FileId) { Data($0) }),
        isDirectory: info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0)
    }

    private static func inspectionError(_ path: String, _ code: DWORD)
      -> WorkspacePathResolutionError
    {
      .cannotInspectExistingAncestor(path: path, code: Int32(bitPattern: code))
    }
  }
#endif
