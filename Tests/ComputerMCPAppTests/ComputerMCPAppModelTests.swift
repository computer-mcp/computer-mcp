import Foundation
import Testing

@testable import ComputerMCPApp

@Suite

final class ComputerMCPAppModelTests {
  @Test
  func testEveryServiceStateHasALocalizedLabel() {
    let states: [ServiceState] = [
      .stopped, .starting, .running, .stopping, .degraded, .failed,
    ]

    for state in states {
      #expect(state.label.isEmpty == false)
    }
  }

  @Test
  func testRefreshKeepsLoadedContentVisible() {
    var state = LoadState.loaded("current")

    state.beginRefresh()
    state.failRefresh(with: "temporary failure")

    guard case .loaded(let value) = state else {
      Issue.record("A refresh replaced already loaded content")
      return
    }
    #expect(value == "current")
  }

  @Test
  func testInitialRefreshStillSurfacesFailures() {
    var state = LoadState<String>.idle

    state.beginRefresh()
    guard case .loading = state else {
      Issue.record("An initial refresh did not enter the loading state")
      return
    }

    state.failRefresh(with: "unavailable")
    guard case .failed(let message) = state else {
      Issue.record("An initial refresh failure was hidden")
      return
    }
    #expect(message == "unavailable")
  }

  @Test
  func testReleaseAppProhibitsMultipleInstances() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let infoPlist = root.appendingPathComponent("Resources/ComputerMCPApp/Info.plist")
    let properties = try #require(
      NSDictionary(contentsOf: infoPlist) as? [String: Any]
    )

    #expect(properties["LSMultipleInstancesProhibited"] as? Bool == true)
  }

  @MainActor
  @Test
  func testProfileActivationRefreshesProfileDependentSections() {
    let refresh = ComputerMCPAppModel.profileActivationRefresh
    #expect((refresh) == ([.profiles, .workspaces, .home, .providers, .tunnels]))
  }

  @MainActor
  @Test
  func testOnboardingStoresOnlyTheVersionAndCanBeDerivedOnRelaunch() throws {
    let suiteName = "ComputerMCPAppTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = UserDefaultsOnboardingPreferences(defaults: defaults)

    #expect(preferences.completedVersion == 0)
    preferences.markCompleted(version: 1)
    #expect(preferences.completedVersion == 1)
    #expect(defaults.dictionaryRepresentation().keys.contains("onboarding_version"))
    #expect(defaults.object(forKey: "chatgpt_completed") == nil)
    #expect(defaults.object(forKey: "cloudflare_completed") == nil)

    let relaunched = UserDefaultsOnboardingPreferences(defaults: defaults)
    #expect(relaunched.completedVersion == 1)
  }

  @Test
  func testStringCatalogHasCompleteEnglishAndSimplifiedChineseEntries() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let catalogURL = root.appendingPathComponent(
      "Sources/ComputerMCPApp/Resources/Localizable.xcstrings"
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
    )
    let strings = try #require(object["strings"] as? [String: Any])
    #expect(strings.count >= 450)

    for (key, rawEntry) in strings {
      let entry = try #require(rawEntry as? [String: Any], "Malformed entry: \(key)")
      let localizations = try #require(
        entry["localizations"] as? [String: Any],
        "Missing localizations: \(key)"
      )
      let english = try localizedValue("en", in: localizations, key: key)
      let chinese = try localizedValue("zh-Hans", in: localizations, key: key)
      #expect(english.isEmpty == false)
      #expect(chinese.isEmpty == false)
      #expect(placeholders(in: english) == placeholders(in: chinese))
    }
  }

  @Test
  func testCompiledLocalizationBundleLoadsSimplifiedChinese() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComputerMCPAppLocalizationTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: output) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
      "xcstringstool",
      "compile",
      root.appendingPathComponent(
        "Sources/ComputerMCPApp/Resources/Localizable.xcstrings"
      ).path,
      "--output-directory",
      output.path,
      "--serialization-format",
      "binary",
    ]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let localizationURL = output.appendingPathComponent("zh-Hans.lproj")
    let chineseBundle = try #require(Bundle(url: localizationURL))

    #expect(
      chineseBundle.localizedString(
        forKey: "Gateway runtime and local data plane",
        value: nil,
        table: "Localizable"
      ) == "网关运行状态与本地数据平面"
    )
    #expect(
      chineseBundle.localizedString(
        forKey: "Unable to start gateway",
        value: nil,
        table: "Localizable"
      ) == "无法启动网关"
    )
    #expect(
      AppLocalization.errorDescription(
        "Tunnel diagnostics failed.",
        preferredLocalizations: ["zh-Hans"],
        localizationBundle: chineseBundle
      ) == "隧道诊断失败。"
    )
    #expect(
      AppLocalization.errorDescription(
        "An unmapped technical failure.",
        preferredLocalizations: ["zh-Hans"],
        localizationBundle: chineseBundle
      ) == "操作失败。请打开“诊断”查看技术细节。"
    )
  }

  @Test
  func testUserFacingErrorsNeverFallBackToUntranslatedEnglishInChinese() {
    #expect(
      AppLocalization.errorDescription(
        "An unmapped technical failure.",
        preferredLocalizations: ["en"]
      ) == "An unmapped technical failure."
    )
    #expect(
      AppLocalization.errorDescription(
        "已经本地化的错误。",
        preferredLocalizations: ["zh-Hans"]
      ) == "已经本地化的错误。"
    )
  }

  @Test
  func testRepositoryLocalizationGate() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [root.appendingPathComponent("Scripts/verify-localization.sh").path]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let message =
      String(
        data: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""

    #expect(process.terminationStatus == 0, Comment(rawValue: message))
  }

  @Test
  func testLocalizedInfoPlistStringsContainBothTCCDescriptions() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    for locale in ["en", "zh-Hans"] {
      let url = root.appendingPathComponent(
        "Resources/ComputerMCPApp/\(locale).lproj/InfoPlist.strings"
      )
      let content = try String(contentsOf: url, encoding: .utf8)
      #expect(content.contains("NSAccessibilityUsageDescription"))
      #expect(content.contains("NSScreenCaptureUsageDescription"))
      #expect(content.lowercased().contains("token") == false)
    }
  }

  private func localizedValue(
    _ language: String,
    in localizations: [String: Any],
    key: String
  ) throws -> String {
    let localization = try #require(
      localizations[language] as? [String: Any],
      "Missing \(language): \(key)"
    )
    let unit = try #require(
      localization["stringUnit"] as? [String: Any],
      "Missing string unit: \(key)"
    )
    return try #require(unit["value"] as? String, "Missing value: \(key)")
  }

  private func placeholders(in value: String) -> [String] {
    let pattern = #"%(?:\d+\$)?[@dfiu]"#
    let expression = try? NSRegularExpression(pattern: pattern)
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression?.matches(in: value, range: range).compactMap {
      Range($0.range, in: value).map { String(value[$0]) }
    } ?? []
  }
}
