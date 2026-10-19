import Foundation
import Testing

@testable import ComputerMCPPlatform

struct PluginExecutablePathsTests {
  @Test
  func nativeEntryPointsRoundTripAndRequireADeclaredPlatform() throws {
    let paths = try PluginExecutablePaths([
      "macos": "bin/adapter"
    ])
    #expect(try paths.path(for: "macos") == "bin/adapter")
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
    #"{"windows":"bin/adapter.exe"}"#,
    #"{"macos":"/adapter"}"#,
    #"{"macos":"bin//adapter"}"#,
    #"{"macos":"bin/./adapter"}"#,
    #"{"macos":false}"#,
  ])
  func invalidPathsCannotSelectAliasesOrEscapePackageRoots(json: String) {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(PluginExecutablePaths.self, from: Data(json.utf8))
    }
  }

  @Test
  func platformPathsPreserveMacOSNames() throws {
    let paths = try PluginExecutablePaths(["macos": "bin/name:variant"])
    #expect(try paths.path(for: "macos") == "bin/name:variant")
    #expect(
      try PluginExecutablePaths(["macos": "bin/运行"]).path(for: "macos") == "bin/运行")
  }
}
