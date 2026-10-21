import Foundation
import Testing

@testable import ComputerMCPApp
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlugins
@testable import ComputerMCPProcess

@Suite(.timeLimit(.minutes(1)))
struct PluginRefusalPresentationTests {
  @Test
  func detailsNameWhatThePluginDeclaredAndWhatThisHostSupports() throws {
    let catalog = try compiledCatalog()
    defer { try? FileManager.default.removeItem(at: catalog) }
    let bundle = try #require(Bundle(url: catalog))
    let version = try PluginVersion("1.2.3")
    let host = try PluginVersion("0.1.0")
    let cases: [(PluginCompatibilityRefusal, String, String)] = [
      (
        .init(
          pluginID: "cursor", version: version, reason: .hostUpdateRequired,
          requirement: .pluginAPI(declared: 2, supported: .supported)),
        "“cursor” 1.2.3 uses plugin API 2. This version of Computer MCP supports plugin API 1.",
        "“cursor” 1.2.3 使用插件 API 2，此版本的 Computer MCP 支持插件 API 1。"
      ),
      (
        .init(
          pluginID: "cursor", version: version, reason: .pluginUpdateRequired,
          requirement: .pluginAPI(declared: 1, supported: PluginAPIVersions(2...3))),
        "“cursor” 1.2.3 uses plugin API 1, which this version of Computer MCP no longer supports. It supports plugin API 2–3.",
        "“cursor” 1.2.3 使用插件 API 1，此版本的 Computer MCP 已不再支持；当前支持插件 API 2–3。"
      ),
      (
        .init(
          pluginID: "cursor", version: version, reason: .hostUpdateRequired,
          requirement: .hostVersion(
            minimum: try PluginVersion("0.2.0"), maximum: nil, current: host)),
        "“cursor” 1.2.3 requires Computer MCP 0.2.0 or later. This is Computer MCP 0.1.0.",
        "“cursor” 1.2.3 需要 Computer MCP 0.2.0 或更高版本；当前为 Computer MCP 0.1.0。"
      ),
      (
        .init(
          pluginID: "cursor", version: version, reason: .pluginUpdateRequired,
          requirement: .hostVersion(
            minimum: nil, maximum: try PluginVersion("0.1.0"), current: host)),
        "“cursor” 1.2.3 supports Computer MCP versions earlier than 0.1.0. This is Computer MCP 0.1.0.",
        "“cursor” 1.2.3 仅支持低于 0.1.0 的 Computer MCP 版本；当前为 Computer MCP 0.1.0。"
      ),
      (
        .init(
          pluginID: "cursor", version: version, reason: .platformUnsupported,
          requirement: .platform(
            declared: try PluginPlatformCompatibility(
              platforms: ["macos"], architectures: ["x86_64"]),
            artifacts: [], platform: "macos", architecture: "arm64")),
        "“cursor” 1.2.3 has no package for this Mac (Apple silicon).",
        "“cursor” 1.2.3 没有适用于这台 Mac（Apple 芯片）的安装包。"
      ),
    ]
    for (refusal, english, chinese) in cases {
      #expect(refusal.detail(locale: Locale(identifier: "en"), bundle: bundle) == english)
      #expect(refusal.detail(locale: Locale(identifier: "zh-Hans"), bundle: bundle) == chinese)
    }
  }

  /// Compiles the App catalog into a temporary bundle the caller removes.
  private func compiledCatalog() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComputerMCPRefusalLocalization-\(UUID().uuidString)")
    let result = try ProcessCommandRunner().run(
      executable: "/usr/bin/xcrun",
      arguments: [
        "xcstringstool", "compile",
        root.appendingPathComponent("Sources/ComputerMCPApp/Resources/Localizable.xcstrings").path,
        "--output-directory", output.path, "--serialization-format", "binary",
      ], workingDirectory: root, environment: [:], timeoutMilliseconds: 30_000,
      maxOutputBytes: 16_384)
    try #require(result.exitCode == 0, "\(result.stderr)")
    return output
  }
}
