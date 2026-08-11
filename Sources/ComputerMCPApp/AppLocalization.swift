import Foundation
import SwiftUI

enum AppLocalization {
  private static var resourceBundle: Bundle {
    let main = Bundle.main
    if main.url(forResource: "Localizable", withExtension: "strings") != nil {
      return main
    }
    return .module
  }

  private static var preferredLocalizations: [String] {
    resourceBundle.preferredLocalizations
  }

  static func string(_ key: String) -> String {
    resourceBundle.localizedString(forKey: key, value: key, table: nil)
  }

  static func errorDescription(_ error: any Error) -> String {
    errorDescription(error.localizedDescription)
  }

  static func errorDescription(
    _ message: String,
    preferredLocalizations: [String] = AppLocalization.preferredLocalizations,
    localizationBundle: Bundle? = nil
  ) -> String {
    let localization =
      Bundle.preferredLocalizations(
        from: ["en", "zh-Hans"],
        forPreferences: preferredLocalizations
      ).first ?? "en"
    let localized = localizedString(
      message,
      localization: localization,
      localizationBundle: localizationBundle
    )
    if localization == "en" || localized != message || containsHan(message) {
      return localized
    }
    return localizedString(
      "The operation failed. Open Diagnostics for technical details.",
      localization: localization,
      localizationBundle: localizationBundle
    )
  }

  static func formatted(_ key: String, _ arguments: CVarArg...) -> String {
    String(
      format: string(key),
      locale: Locale.current,
      arguments: arguments
    )
  }

  static func verbatimText(_ value: String) -> Text {
    Text(verbatim: value)
  }

  private static func localizedString(
    _ key: String,
    localization: String,
    localizationBundle: Bundle?
  ) -> String {
    if let localizationBundle {
      return localizationBundle.localizedString(
        forKey: key,
        value: key,
        table: "Localizable"
      )
    }
    guard
      let localizationURL = resourceBundle.url(
        forResource: localization,
        withExtension: "lproj"
      ),
      let localizedBundle = Bundle(url: localizationURL)
    else {
      return string(key)
    }
    return localizedBundle.localizedString(forKey: key, value: key, table: "Localizable")
  }

  private static func containsHan(_ value: String) -> Bool {
    value.range(of: #"\p{Han}"#, options: .regularExpression) != nil
  }
}
