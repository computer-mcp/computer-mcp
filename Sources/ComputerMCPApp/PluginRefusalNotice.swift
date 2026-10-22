import ComputerMCPPlugins
import SwiftUI

/// Tells the owner which side has to change before a refused plugin package can load.
struct PluginRefusalNotice: View {
  let refusal: PluginCompatibilityRefusal
  /// Offered only when updating the plugin resolves the refusal.
  var findUpdate: (() -> Void)? = nil
  @Environment(\.locale) private var locale

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 4) {
        title.font(.headline)
        Text(verbatim: refusal.detail(locale: locale))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        if refusal.reason == .pluginUpdateRequired, let findUpdate {
          Button(action: findUpdate) {
            Text("Search official plugins", bundle: AppLocalization.resourceBundle)
          }
          .padding(.top, 4)
        }
      }
    } icon: {
      // A shared icon width keeps titles aligned across notices.
      Image(systemName: refusal.symbolName)
        .symbolRenderingMode(.multicolor)
        .frame(width: 22)
    }
    .accessibilityElement(children: .contain)
  }

  private var title: Text {
    switch refusal.reason {
    case .hostUpdateRequired:
      Text("Update Computer MCP to use this plugin", bundle: AppLocalization.resourceBundle)
    case .pluginUpdateRequired:
      Text("This plugin needs an update", bundle: AppLocalization.resourceBundle)
    case .platformUnsupported:
      Text("This plugin isn't available for this Mac", bundle: AppLocalization.resourceBundle)
    }
  }
}

/// A one-line status for lists, matching the notice's title.
struct PluginRefusalStatus: View {
  let refusal: PluginCompatibilityRefusal

  var body: some View {
    Label {
      switch refusal.reason {
      case .hostUpdateRequired:
        Text("Needs a Computer MCP update", bundle: AppLocalization.resourceBundle)
      case .pluginUpdateRequired:
        Text("Needs a plugin update", bundle: AppLocalization.resourceBundle)
      case .platformUnsupported:
        Text("Not available for this Mac", bundle: AppLocalization.resourceBundle)
      }
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .symbolRenderingMode(.multicolor)
    }
  }
}

extension PluginCompatibilityRefusal {
  fileprivate var symbolName: String {
    switch reason {
    case .hostUpdateRequired: "arrow.up.circle.fill"
    case .pluginUpdateRequired: "puzzlepiece.extension.fill"
    case .platformUnsupported: "desktopcomputer.trianglebadge.exclamationmark"
    }
  }

  /// What the plugin declared and what this host supports, in the owner's language.
  func detail(locale: Locale, bundle: Bundle? = nil) -> String {
    let plugin = pluginID
    let version = version.description
    switch requirement {
    case .pluginAPI(let declared, let supported):
      let range = Self.describe(supported)
      if reason == .hostUpdateRequired {
        return AppLocalization.formatted(
          "“%1$@” %2$@ uses plugin API %3$@. This version of Computer MCP supports plugin API %4$@.",
          locale: locale, bundle: bundle, plugin, version, String(declared), range)
      }
      return AppLocalization.formatted(
        "“%1$@” %2$@ uses plugin API %3$@, which this version of Computer MCP no longer supports. It supports plugin API %4$@.",
        locale: locale, bundle: bundle, plugin, version, String(declared), range)
    case .hostVersion(let minimum, let maximum, let current):
      if reason == .hostUpdateRequired, let minimum {
        return AppLocalization.formatted(
          "“%1$@” %2$@ requires Computer MCP %3$@ or later. This is Computer MCP %4$@.",
          locale: locale, bundle: bundle, plugin, version, minimum.description, current.description)
      }
      if let maximum {
        return AppLocalization.formatted(
          "“%1$@” %2$@ supports Computer MCP versions earlier than %3$@. This is Computer MCP %4$@.",
          locale: locale, bundle: bundle, plugin, version, maximum.description, current.description)
      }
      return message
    case .platform(_, _, let platform, let architecture):
      return AppLocalization.formatted(
        "“%1$@” %2$@ has no package for this Mac (%3$@).", locale: locale, bundle: bundle, plugin,
        version,
        Self.describeMac(
          platform: platform, architecture: architecture, locale: locale, bundle: bundle))
    }
  }

  private static func describe(_ versions: PluginAPIVersions) -> String {
    versions.minimum == versions.maximum
      ? String(versions.minimum) : "\(versions.minimum)–\(versions.maximum)"
  }

  private static func describeMac(
    platform: String, architecture: String, locale: Locale, bundle: Bundle?
  ) -> String {
    switch (platform, architecture) {
    case ("macos", "arm64"):
      AppLocalization.formatted("Apple silicon", locale: locale, bundle: bundle)
    case ("macos", "x86_64"): AppLocalization.formatted("Intel", locale: locale, bundle: bundle)
    default: "\(platform)/\(architecture)"
    }
  }
}
