import ComputerMCPCore
import ComputerMCPGateway
import SwiftUI

struct PrivacyOwnerPolicyTarget: Identifiable {
  let id: GatewayOwnerPolicyTarget
  let title: String

  var actionID: String {
    switch id {
    case .profile(let id): "privacy.policySource.profile.\(id.rawValue).editButton"
    case .provider(.package(let id)): "privacy.policySource.package.\(id).editButton"
    case .provider(.localServer(let id)): "privacy.policySource.localServer.\(id).editButton"
    }
  }

  var symbol: String {
    switch id {
    case .profile: "person.crop.circle"
    case .provider(.package): "puzzlepiece.extension"
    case .provider(.localServer): "server.rack"
    }
  }

  static func all(in snapshot: PrivacySnapshot, using l: PrivacyText) -> [Self] {
    let profiles = snapshot.reviewedProfiles.map {
      Self(id: .profile($0.id), title: l($0.id.displayName))
    }
    let providers = snapshot.reviewedProviders.values.compactMap { provider in
      provider.approval.map { _ in
        Self(id: .provider(provider.identity), title: provider.name)
      }
    }
    return (profiles + providers).sorted {
      ($0.title, $0.actionID) < ($1.title, $1.actionID)
    }
  }

  func source(in snapshot: PrivacySnapshot) -> PrivacyManagedSource? {
    snapshot.managedSources.first {
      switch id {
      case .profile(let id): $0.profileID == id
      case .provider(let id): $0.provider == id
      }
    }
  }
}

struct PrivacyPolicySourcesSection: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { .init(locale: locale, resources: resources) }
  let snapshot: PrivacySnapshot
  let open: (PrivacyOwnerPolicyTarget) -> Void

  var body: some View {
    let readOnly = snapshot.managedSources.filter { $0.profileID == nil && $0.provider == nil }
    let targets = PrivacyOwnerPolicyTarget.all(in: snapshot, using: l)
    if !readOnly.isEmpty || !targets.isEmpty {
      Section {
        ForEach(readOnly) { source in
          DisclosureGroup {
            PolicySourceDetails(source: source)
          } label: {
            LabeledContent {
              PolicySourceStatusText(state: source.state)
            } label: {
              Label {
                Text(verbatim: l(source.name))
              } icon: {
                PrivacySymbol(
                  name: source.name == "Machine Policy" ? "desktopcomputer" : "slider.horizontal.3")
              }
            }
          }
          .accessibilityIdentifier("privacy.policySource.\(source.id)")
        }
        ForEach(targets) { target in
          let state = target.source(in: snapshot)?.state ?? .absent
          LabeledContent {
            HStack(spacing: 10) {
              PolicySourceStatusText(state: state)
              Button(l(state == .absent ? "Add…" : "Edit…")) { open(target) }
                .buttonStyle(.bordered)
                .accessibilityLabel(
                  l.format(
                    state == .absent ? "Add owner policy for %@" : "Edit owner policy for %@",
                    target.title)
                )
                .accessibilityIdentifier(target.actionID)
            }
          } label: {
            Label {
              Text(verbatim: target.title)
            } icon: {
              PrivacySymbol(name: target.symbol)
            }
          }
        }
      } header: {
        Text(verbatim: l("Managed Limits"))
      } footer: {
        Text(
          verbatim: l(
            "Owner policies are saved in Computer MCP. Use the machine policy file or configuration profile to manage limits for this Mac."
          ))
      }
      .accessibilityIdentifier("privacy.policySources")
    }
  }
}

struct PolicySourceStatusText: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  let state: PrivacyManagedSource.State

  var body: some View {
    let l = PrivacyText(locale: locale, resources: resources)
    let title =
      switch state {
      case .active: "Applied"
      case .absent: "Not Set"
      case .unreadable: "Can't Be Read"
      }
    Text(verbatim: l(title))
      .foregroundStyle(state == .unreadable ? Color.red : Color.secondary)
  }
}

struct PolicySourceDetails: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  let source: PrivacyManagedSource

  var body: some View {
    let l = PrivacyText(locale: locale, resources: resources)
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: source.location)
        .font(.callout.monospaced())
        .textSelection(.enabled)
      if let failure = source.failure {
        Text(verbatim: l(failure))
          .foregroundStyle(.red)
          .textSelection(.enabled)
        Text(verbatim: l("This source limits everything it could limit until it can be read."))
          .foregroundStyle(.secondary)
      }
      if let revision = source.revision, source.state != .absent {
        let version = l.format("Source revision %@", revision)
        Text(verbatim: version)
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
