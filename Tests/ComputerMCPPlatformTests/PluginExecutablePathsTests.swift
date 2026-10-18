import Foundation
import Testing

@testable import ComputerMCPPlatform

struct PluginExecutablePathsTests {
  @Test
  func nativeEntryPointsRetainOneDeclarationAcrossPlatformArchives() throws {
    let paths = try PluginExecutablePaths([
      "macos": "bin/adapter", "windows": "bin/adapter.exe",
    ])
    #expect(try paths.path(for: "macos") == "bin/adapter")
    #expect(try paths.path(for: "windows") == "bin/adapter.exe")
    #expect(try paths.path(for: PluginPlatformCompatibility.currentPlatform).hasPrefix("bin/"))
    #expect(
      try JSONDecoder().decode(PluginExecutablePaths.self, from: JSONEncoder().encode(paths))
        == paths)
    #expect(throws: (any Error).self) { try paths.path(for: "linux") }
    let single = try PluginExecutablePaths(["macos": "bin/adapter"])
    #expect(throws: (any Error).self) { try single.path(for: "windows") }
  }

  @Test(arguments: [
    #"{}"#,
    #"{"linux":"bin/adapter"}"#,
    #"{"MacOS":"bin/adapter"}"#,
    #"{"macos":"../adapter"}"#,
    #"{"windows":"C:/adapter.exe"}"#,
    #"{"windows":"bin/adapter.exe:stream"}"#,
    #"{"windows":"bin/NUL.exe"}"#,
    #"{"windows":"bin/COM¹.exe"}"#,
    #"{"windows":"bin/.. /adapter.exe"}"#,
    #"{"windows":"bin./adapter.exe"}"#,
    #"{"windows":"bin/adapter?.exe"}"#,
    #"{"windows":"bin//adapter.exe"}"#,
    #"{"windows":"bin/adapter.exe","macos":false}"#,
  ])
  func invalidPathsCannotSelectAliasesOrEscapePackageRoots(json: String) {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(PluginExecutablePaths.self, from: Data(json.utf8))
    }
  }

  @Test
  func platformGrammarDoesNotChangeLegacyMacOSNames() throws {
    let paths = try PluginExecutablePaths(["macos": "bin/name:variant"])
    #expect(try paths.path(for: "macos") == "bin/name:variant")
    #expect(
      try PluginExecutablePaths(["windows": "bin/运行.exe"]).path(for: "windows") == "bin/运行.exe")
  }
}
