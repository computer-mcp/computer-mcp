import ComputerMCPSandbox
import Foundation
import Testing

@Suite struct SandboxConfigurationTests {
  @Test(arguments: ["relative", "/a/../b", "/a/./b", "/a//b", "/a/", "/a\nb", "/a\0b"])
  func invalidPaths(value: String) {
    #expect(throws: ExecutionEnvironmentError.self) { try SandboxPath(value) }
  }

  @Test func environmentIsConstructed() throws {
    let root = try SandboxPath("/test")
    let environment = try ExecutionEnvironment(
      searchPath: [root], home: root, temporary: root, cache: root)
    let sandbox = try SandboxConfiguration(
      worktree: root, temporaryDirectory: root,
      homeDirectory: root, cacheDirectory: root, readableRoots: [],
      proxy: .init(http: 12400, socks: 12401))
    let values = try environment.variables(sandbox: sandbox)
    #expect(
      Set(values.keys)
        == Set([
          "PATH", "HOME", "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL", "TERM",
          "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH",
          "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_TERMINAL_PROMPT", "NO_PROXY", "no_proxy",
          "http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY",
        ]))
    #expect(values["ALL_PROXY"] == "socks5h://127.0.0.1:12401")
    #expect(values["TMPDIR"] == "/test/")
    #expect(environment.swiftBuildArguments().prefix(3) == ["build", "--build-system", "native"])
  }

  @Test func pathBoundaries() throws {
    let root = try SandboxPath("/project")
    #expect(root.contains(try SandboxPath("/project/a")))
    #expect(!root.contains(try SandboxPath("/project-other")))
    #expect(throws: ExecutionEnvironmentError.self) {
      try SandboxReadRegion(path: root, exceptions: [SandboxPath("/outside")])
    }
    #expect(throws: ExecutionEnvironmentError.self) { try SandboxProxyPorts(http: 0, socks: 80) }
  }
}
