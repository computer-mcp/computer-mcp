import Foundation

/// Values are selected by the host; the parent process environment is never merged into these.
package struct ExecutionEnvironment: Sendable, Equatable {
  package let searchPath: [SandboxPath]
  package let home: SandboxPath
  package let temporary: SandboxPath
  package let cache: SandboxPath
  package let locale: String
  package let terminal: String
  package let developerDirectory: SandboxPath?

  package init(
    searchPath: [SandboxPath], home: SandboxPath, temporary: SandboxPath,
    cache: SandboxPath, locale: String = "en_US.UTF-8", terminal: String = "dumb",
    developerDirectory: SandboxPath? = nil
  ) throws {
    guard !searchPath.isEmpty, searchPath.allSatisfy({ !$0.value.contains(":") }),
      [locale, terminal].allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 32 && $0 < 127 } })
    else { throw ExecutionEnvironmentError.invalidConfiguration("Invalid execution environment") }
    self.searchPath = searchPath
    self.home = home
    self.temporary = temporary
    self.cache = cache
    self.locale = locale
    self.terminal = terminal
    self.developerDirectory = developerDirectory
  }

  package func variables(sandbox: SandboxConfiguration? = nil) throws -> [String: String] {
    if let sandbox {
      guard home == sandbox.homeDirectory, temporary == sandbox.temporaryDirectory,
        cache == sandbox.cacheDirectory
      else {
        throw ExecutionEnvironmentError.invalidConfiguration(
          "Environment directories must match the sandbox")
      }
    }
    var result = [
      "PATH": searchPath.map(\.value).joined(separator: ":"), "HOME": home.value,
      "TMPDIR": temporary.value + "/", "TMP": temporary.value, "TEMP": temporary.value,
      "LANG": locale, "LC_ALL": locale, "TERM": terminal,
      "XDG_CACHE_HOME": cache.value, "XDG_CONFIG_HOME": home.value + "/.config",
      "CLANG_MODULE_CACHE_PATH": cache.value + "/clang",
      "SWIFT_MODULECACHE_PATH": cache.value + "/swift",
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_TERMINAL_PROMPT": "0", "NO_PROXY": "", "no_proxy": "",
    ]
    if let developerDirectory { result["DEVELOPER_DIR"] = developerDirectory.value }
    if let proxy = sandbox?.proxy {
      for key in ["http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY"] {
        result[key] = "http://127.0.0.1:\(proxy.http)"
      }
      for key in ["all_proxy", "ALL_PROXY"] {
        result[key] = "socks5h://127.0.0.1:\(proxy.socks)"
      }
    }
    if let git = sandbox?.git {
      result["GIT_OBJECT_DIRECTORY"] = git.privateObjects.value
      // Git's alternate path syntax uses C quoting when the value starts with a quote.
      result["GIT_ALTERNATE_OBJECT_DIRECTORIES"] =
        "\""
        + git.sharedObjects.value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    return result
  }

  /// SwiftBuild loses TMPDIR in link tasks. Keep the outer sandbox and use private native build state.
  package func swiftBuildArguments() -> [String] {
    [
      "build", "--build-system", "native", "--disable-sandbox", "--cache-path",
      cache.value + "/swiftpm",
      "--config-path", home.value + "/.swiftpm/configuration", "--security-path",
      home.value + "/.swiftpm/security",
    ]
  }
}
