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

  @Test(arguments: [false, true])
  func explicitHostVariablesPreserveSandboxLocationsAndNetwork(proxyEnabled: Bool) throws {
    let root = try SandboxPath("/test")
    let environment = try ExecutionEnvironment(
      searchPath: [root], home: root, temporary: root, cache: root,
      hostVariables: [
        "HOME": "/owner", "TMPDIR": "/owner/tmp", "TMP": "/owner", "TEMP": "/owner",
        "XDG_CONFIG_HOME": "/owner", "XDG_CACHE_HOME": "/owner",
        "CLANG_MODULE_CACHE_PATH": "/owner", "SWIFT_MODULECACHE_PATH": "/owner",
        "http_proxy": "http://outside", "HTTP_PROXY": "http://outside",
        "https_proxy": "http://outside", "HTTPS_PROXY": "http://outside",
        "all_proxy": "socks5://outside", "ALL_PROXY": "socks5://outside",
        "NO_PROXY": "*", "no_proxy": "*", "LC_ALL": "C", "GIT_NO_LAZY_FETCH": "1",
      ])
    let sandbox = try SandboxConfiguration(
      worktree: root, temporaryDirectory: root, homeDirectory: root, cacheDirectory: root,
      readableRoots: [], proxy: proxyEnabled ? .init(http: 12400, socks: 12401) : nil)
    let values = try environment.variables(sandbox: sandbox)
    #expect(!values.values.contains { $0.contains("/owner") || $0.contains("outside") })
    #expect(values["HOME"] == root.value)
    #expect(values["TMPDIR"] == root.value + "/")
    #expect(values["NO_PROXY"] == "" && values["no_proxy"] == "")
    #expect(values["HTTP_PROXY"] == (proxyEnabled ? "http://127.0.0.1:12400" : nil))
    #expect(values["ALL_PROXY"] == (proxyEnabled ? "socks5h://127.0.0.1:12401" : nil))
    #expect(values["LC_ALL"] == "C")
    #expect(values["GIT_NO_LAZY_FETCH"] == "1")
  }

  @Test func providerEnvironmentAndReadOnlyWritesStayInsideVerifiedStorage() throws {
    let container = try SandboxProviderContainer(
      root: .init("/providers/one"), home: .init("/providers/one/home"),
      cache: .init("/providers/one/cache"), state: .init("/providers/one/state"))
    let scratch = try SandboxPath("/scratch/one")
    let sandbox = try SandboxConfiguration(
      readOnly: true, worktree: scratch, temporaryDirectory: scratch, homeDirectory: container.home,
      cacheDirectory: container.cache, readableRoots: [container.root], providerContainer: container
    )
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")], home: container.home, temporary: scratch, cache: container.cache,
      state: container.state, hostVariables: ["XDG_STATE_HOME": "/owner/state"])
    let values = try environment.variables(sandbox: sandbox)
    #expect(values["XDG_STATE_HOME"] == container.state.value)
    #expect(values["HOME"] == container.home.value)
    #expect(Set(sandbox.writableDirectories) == [scratch, container.root])
    #expect(throws: ExecutionEnvironmentError.self) {
      try ExecutionEnvironment(
        searchPath: [.init("/bin")], home: container.home, temporary: scratch,
        cache: container.cache
      ).variables(sandbox: sandbox)
    }
    #expect(throws: ExecutionEnvironmentError.self) {
      try SandboxConfiguration(
        readOnly: true, worktree: scratch, temporaryDirectory: container.home,
        homeDirectory: container.home, cacheDirectory: container.cache, readableRoots: [],
        providerContainer: container)
    }
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
