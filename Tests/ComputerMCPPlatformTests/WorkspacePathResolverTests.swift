import Foundation
import Testing

@testable import ComputerMCPPlatform

#if os(Windows)
  import WinSDK
#endif

struct PlatformWorkspacePathResolverTests {
  @Test
  func resolvesExistingAndMissingUnicodeChildrenWithoutCreatingThem() throws {
    let fixture = try WorkspacePathFixture()
    defer { fixture.cleanup() }
    let child = try fixture.directory("workspace/资料 空间")
    let file = child.appendingPathComponent("content.txt")
    try Data("untouched".utf8).write(to: file)
    for path in ["资料 空间/content.txt", file.path, "资料 空间/../资料 空间/content.txt"] {
      let result = try WorkspacePathResolver.resolve(path, relativeTo: fixture.workspace)
      #expect(try Data(contentsOf: result) == Data("untouched".utf8))
    }
    let future = try WorkspacePathResolver.resolve(
      "资料 空间/new/deep/file.txt", relativeTo: fixture.workspace)
    #expect(!FileManager.default.fileExists(atPath: future.path))
    #expect(future.lastPathComponent == "file.txt")
    #expect(try FileManager.default.contentsOfDirectory(atPath: child.path) == ["content.txt"])
  }

  @Test
  func rejectsParentTraversalAndSamePrefixSibling() throws {
    let fixture = try WorkspacePathFixture()
    defer { fixture.cleanup() }
    let sibling = try fixture.directory("workspace-other")
    for path in ["../outside/absent.txt", sibling.appendingPathComponent("future.txt").path] {
      #expect(throws: WorkspacePathResolutionError.escapesWorkspace) {
        try WorkspacePathResolver.resolve(path, relativeTo: fixture.workspace)
      }
    }
    #expect(!WorkspacePathResolver.contains(sibling, in: fixture.workspace))
  }

  @Test
  func followsInternalLinksAndRejectsExistingMissingAndDanglingEscapes() throws {
    let fixture = try WorkspacePathFixture()
    defer { fixture.cleanup() }
    let inside = try fixture.directory("workspace/inside")
    try fixture.link("workspace/local", to: inside)
    try fixture.link("workspace/escape", to: fixture.outside)
    try fixture.link("workspace/dangling", to: fixture.outside.appendingPathComponent("missing"))
    try Data("outside".utf8).write(to: fixture.outside.appendingPathComponent("existing.txt"))
    let result = try WorkspacePathResolver.resolve("local/new.txt", relativeTo: fixture.workspace)
    #expect(result.deletingLastPathComponent().lastPathComponent == "inside")
    for path in ["escape/existing.txt", "escape/missing/deep.txt", "dangling/new.txt"] {
      #expect(throws: (any Error).self) {
        try WorkspacePathResolver.resolve(path, relativeTo: fixture.workspace)
      }
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path) == ["existing.txt"])
  }

  @Test
  func acceptsBothLexicalAndPhysicalPathsForLinkedWorkspaceRoot() throws {
    let fixture = try WorkspacePathFixture()
    defer { fixture.cleanup() }
    let alias = fixture.root.appendingPathComponent("alias")
    try fixture.link("alias", to: fixture.workspace)
    let physical = try WorkspacePathResolver.canonicalWorkspace(alias)
    for path in [
      "future/file.txt", alias.appendingPathComponent("future/file.txt").path,
      physical.appendingPathComponent("future/file.txt").path,
    ] {
      let result = try WorkspacePathResolver.resolve(path, relativeTo: alias)
      #expect(result.lastPathComponent == "file.txt")
      #expect(result.deletingLastPathComponent().deletingLastPathComponent().path == physical.path)
    }
  }

  #if os(Windows)
    @Test(arguments: [
      "", "C:relative", "\\rooted", "\\\\", "\\\\server", "\\\\.\\pipe\\test",
      "\\\\?\\C:\\test", "file.txt:secret", "NUL", "CON.txt", "COM¹", "LPT9",
      "file.", "file ", "bad\0path", "bad\npath", "bad?path", String(repeating: "a", count: 32_767),
    ])
    func rejectsAmbiguousNamesWithoutMutatingTheWorkspace(path: String) throws {
      let fixture = try WorkspacePathFixture()
      defer { fixture.cleanup() }
      #expect(throws: (any Error).self) {
        try WorkspacePathResolver.resolve(path, relativeTo: fixture.workspace)
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path).isEmpty)
    }

    @Test
    func rejectsMissingChildBeneathAFile() throws {
      let fixture = try WorkspacePathFixture()
      defer { fixture.cleanup() }
      try Data("file".utf8).write(to: fixture.workspace.appendingPathComponent("file"))
      #expect(throws: (any Error).self) {
        try WorkspacePathResolver.resolve("file/child.txt", relativeTo: fixture.workspace)
      }
    }

    @Test
    func usesNativeIdentityForCaseAliasesAndDistinctCaseSensitiveDirectories() throws {
      let fixture = try WorkspacePathFixture()
      defer { fixture.cleanup() }
      let alias = try WorkspacePathResolver.resolve(
        fixture.workspace.path.uppercased(), relativeTo: fixture.workspace)
      #expect(try alias.path == WorkspacePathResolver.canonicalWorkspace(fixture.workspace).path)
      let sensitive = try fixture.directory("sensitive")
      let path = try #require(WindowsFilePath.native(sensitive))
      let handle = try #require(
        CreateFileW(
          Array(path.utf16) + [0], DWORD(FILE_WRITE_ATTRIBUTES),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
          DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil))
      try #require(handle != INVALID_HANDLE_VALUE)
      defer { CloseHandle(handle) }
      var info = FILE_CASE_SENSITIVE_INFO()
      info.Flags = ULONG(FILE_CS_FLAG_CASE_SENSITIVE_DIR)
      try #require(
        SetFileInformationByHandle(
          handle, FileCaseSensitiveInfo, &info, DWORD(MemoryLayout.size(ofValue: info))),
        "Enabling case sensitivity failed: \(GetLastError())")
      let selected = try fixture.directory("sensitive/Project")
      let other = try fixture.directory("sensitive/project")
      #expect(throws: WorkspacePathResolutionError.escapesWorkspace) {
        try WorkspacePathResolver.resolve(other.path, relativeTo: selected)
      }
      #expect(throws: WorkspacePathResolutionError.escapesWorkspace) {
        try WorkspacePathResolver.resolve(
          other.appendingPathComponent("missing").path, relativeTo: selected)
      }
    }

    @Test
    func resolvesNativeJunctionsAndRejectsJunctionEscapes() throws {
      let fixture = try WorkspacePathFixture()
      defer { fixture.cleanup() }
      let inside = try fixture.directory("workspace/inside")
      try fixture.junction("workspace/local", to: inside)
      try fixture.junction("workspace/escape", to: fixture.outside)
      let resolved = try WorkspacePathResolver.resolve(
        "local/new.txt", relativeTo: fixture.workspace)
      #expect(resolved.deletingLastPathComponent().lastPathComponent == "inside")
      #expect(throws: WorkspacePathResolutionError.escapesWorkspace) {
        try WorkspacePathResolver.resolve("escape/new.txt", relativeTo: fixture.workspace)
      }
    }
  #endif
}

private struct WorkspacePathFixture {
  let root: URL
  let workspace: URL
  let outside: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "computer-mcp-path-\(UUID())")
    workspace = root.appendingPathComponent("workspace")
    outside = root.appendingPathComponent("outside")
    for url in [workspace, outside] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }

  func directory(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func link(_ name: String, to destination: URL) throws {
    let url = root.appendingPathComponent(name)
    #if os(Windows)
      let result = CreateSymbolicLinkW(
        Array(try #require(WindowsFilePath.native(url)).utf16) + [0],
        Array(try #require(WindowsFilePath.native(destination)).utf16) + [0],
        DWORD(SYMBOLIC_LINK_FLAG_DIRECTORY | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE))
      try #require(result != 0, "Creating directory link failed: \(GetLastError())")
    #else
      try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
    #endif
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }

  #if os(Windows)
    func junction(_ name: String, to destination: URL) throws {
      var system = [WCHAR](repeating: 0, count: 32_768)
      let count = GetSystemDirectoryW(&system, UINT(system.count))
      try #require(count > 0 && count < system.count)
      let command = String(decoding: system.prefix(Int(count)), as: UTF16.self) + "\\cmd.exe"
      let link = try #require(WindowsFilePath.native(root.appendingPathComponent(name)))
      let target = try #require(WindowsFilePath.native(destination))
      // Only generated fixture paths reach the command interpreter; reject its metacharacters.
      try #require(
        ![command, link, target].contains { $0.contains { "\"%\r\n&|<>^".contains($0) } })
      var line = Array("\"\(command)\" /d /c mklink /J \"\(link)\" \"\(target)\"".utf16) + [0]
      var startup = STARTUPINFOW()
      startup.cb = DWORD(MemoryLayout.size(ofValue: startup))
      var process = PROCESS_INFORMATION()
      try #require(
        CreateProcessW(
          Array(command.utf16) + [0], &line, nil, nil, false, DWORD(CREATE_NO_WINDOW),
          nil, nil, &startup, &process), "Creating junction helper failed: \(GetLastError())")
      defer {
        CloseHandle(process.hThread)
        CloseHandle(process.hProcess)
      }
      let result = WaitForSingleObject(process.hProcess, 5_000)
      if result != WAIT_OBJECT_0 {
        TerminateProcess(process.hProcess, 1)
        #expect(WaitForSingleObject(process.hProcess, 5_000) == WAIT_OBJECT_0)
      }
      try #require(result == WAIT_OBJECT_0, "Junction helper did not exit within its deadline.")
      var code: DWORD = 1
      try #require(GetExitCodeProcess(process.hProcess, &code) && code == 0)
    }
  #endif
}
