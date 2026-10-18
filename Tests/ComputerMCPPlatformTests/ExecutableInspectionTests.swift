import Foundation
import Testing

@testable import ComputerMCPPlatform

#if os(Windows)
  import WinSDK
#endif

struct PlatformExecutableInspectionTests {
  @Test
  func observesRealExecutableWithoutLaunchingIt() throws {
    #if os(Windows)
      let fixture = try WindowsInspectionFixture()
      defer { fixture.cleanup() }
      let executable = try fixture.copyExecutable("运行 工具.exe")
      let result = fixture.inspect(executable.path)
      #expect(result.status == .passed)
      #expect(result.isExecutable && result.isRegularFile && !result.isScript)
      #expect(result.path != nil)
    #else
      let result = ExecutableInspection.inspect(
        "/bin/echo", workingDirectory: FileManager.default.temporaryDirectory,
        environment: ["PATH": "/usr/bin:/bin"])
      #expect(result.status == .passed)
      #expect(result.path == "/bin/echo")
    #endif
    #expect(
      try JSONDecoder().decode(ExecutableInspection.self, from: JSONEncoder().encode(result))
        == result)
  }

  #if os(Windows)
    @Test
    func resolvesOnlyChildPathAndCwdWithCaseInsensitiveEnvironmentKeys() throws {
      let fixture = try WindowsInspectionFixture()
      defer { fixture.cleanup() }
      let binary = try fixture.copyExecutable("tool.exe")
      for key in ["PATH", "Path", "path"] {
        let result = fixture.inspect("tool", environment: [key: "\"\(fixture.root.path)\""])
        #expect(result.status == .passed)
        #expect(result.source == "path")
      }
      #expect(fixture.inspect("tool", environment: [:]).status == .missing)
      #expect(fixture.inspect("tool", environment: ["PATH": ""]).status == .passed)
      #expect(fixture.inspect(".\\tool", environment: [:]).status == .passed)
      #expect(fixture.inspect(binary.path, environment: [:]).status == .passed)
      #expect(
        fixture.inspect("tool", environment: ["PATH": "", "Path": "other"]).status == .invalidPath)
      #expect(fixture.inspect("tool", environment: ["PATH": "bad\0path"]).status == .invalidPath)
    }

    @Test
    func keepsFirstFileMatchAndSkipsDirectories() throws {
      let fixture = try WindowsInspectionFixture()
      defer { fixture.cleanup() }
      let first = fixture.root.appendingPathComponent("first")
      let second = fixture.root.appendingPathComponent("second")
      try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
      let broken = first.appendingPathComponent("tool.exe")
      try Data("not an executable".utf8).write(to: broken)
      _ = try fixture.copyExecutable("second/tool.exe")
      let environment = ["PATH": "\(first.path);\(second.path)"]
      let result = fixture.inspect("tool", environment: environment)
      #expect(result.status == .unverified)
      #expect(
        result.path?.replacingOccurrences(of: "\\", with: "/").contains("/first/tool.exe") == true)
      try FileManager.default.removeItem(at: broken)
      try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
      #expect(fixture.inspect("tool", environment: environment).status == .passed)
      #expect(fixture.inspect(broken.path).status == .notRegularFile)
    }

    @Test(arguments: ["run.cmd", "run.bat", "run.ps1", "run.py", "run.sh", "shebang.exe"])
    func scriptsRequireAnExplicitInterpreterAndNeverExecute(name: String) throws {
      let fixture = try WindowsInspectionFixture()
      defer { fixture.cleanup() }
      let script = fixture.root.appendingPathComponent(name)
      try Data("#!/bin/sh\necho unsafe > marker\n".utf8).write(to: script)
      let result = fixture.inspect(script.path)
      #expect(result.status == .interpreterRequired)
      #expect(result.hasKnownFailure && result.isScript)
      #expect(
        !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("marker").path))
    }

    @Test(arguments: [
      "", "tool\0ignored", "C:tool.exe", "\\tool.exe", "\\\\.\\pipe\\test",
      "\\\\?\\C:\\tool.exe", "NUL", "CON.exe", "aux.txt", "COM1", "LPT9.exe",
      "file.exe:stream", "file.exe.", "file.exe ", "bad?name.exe",
      "COM¹.exe", "\\\\localhost\\pipe\\test", "\\\\localhost\\mailslot\\test",
      String(repeating: "a", count: 32_767),
    ])
    func rejectsAmbiguousPathsAndDeviceNamespaces(path: String) throws {
      let fixture = try WindowsInspectionFixture()
      defer { fixture.cleanup() }
      #expect(fixture.inspect(path).status == .invalidPath)
    }

    @Test
    func reportsSharingFailureWithoutReadingOrLaunching() throws {
      let fixture = try WindowsInspectionFixture()
      defer { fixture.cleanup() }
      let executable = try fixture.copyExecutable("locked.exe")
      let wide = Array(executable.path.utf16) + [0]
      let handle = try #require(
        CreateFileW(wide, DWORD(GENERIC_READ), 0, nil, DWORD(OPEN_EXISTING), 0, nil))
      #expect(handle != INVALID_HANDLE_VALUE)
      defer { CloseHandle(handle) }
      #expect(fixture.inspect(executable.path).status == .unreadable)
    }

    @Test
    func treatsReparseFilesAsUnverifiedInsteadOfFollowingThem() throws {
      let fixture = try WindowsInspectionFixture()
      defer { fixture.cleanup() }
      let executable = try fixture.copyExecutable("original.exe")
      let link = fixture.root.appendingPathComponent("link.exe")
      let success = CreateSymbolicLinkW(
        Array(link.path.utf16) + [0], Array(executable.path.utf16) + [0],
        DWORD(SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE))
      try #require(success != 0, "CreateSymbolicLinkW failed: \(GetLastError())")
      #expect(fixture.inspect(link.path).status == .unverified)
    }
  #endif
}

#if os(Windows)
  private struct WindowsInspectionFixture {
    let root: URL
    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "computer-mcp-inspection-\(UUID())")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func copyExecutable(_ name: String) throws -> URL {
      var directory = [WCHAR](repeating: 0, count: 32_768)
      let count = GetSystemDirectoryW(&directory, UINT(directory.count))
      try #require(count > 0 && count < directory.count)
      let source = URL(
        fileURLWithPath: String(decoding: directory.prefix(Int(count)), as: UTF16.self)
      )
      .appendingPathComponent("cmd.exe")
      let destination = root.appendingPathComponent(name)
      try FileManager.default.copyItem(at: source, to: destination)
      return destination
    }
    func inspect(_ executable: String, environment: [String: String] = [:]) -> ExecutableInspection
    {
      ExecutableInspection.inspect(executable, workingDirectory: root, environment: environment)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
  }
#endif
