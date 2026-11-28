import SwiftUI

struct PermissionGrantRow<Actions: View>: View {
  let title: String
  let symbol: String
  let saved: String
  let effective: String?
  let explanation: String?
  let isInherited: Bool
  let isLimited: Bool
  @ViewBuilder var actions: () -> Actions

  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources

  var body: some View {
    let l = PrivacyText(locale: locale, resources: resources)
    let unavailable = effective == nil
    LabeledContent {
      actions()
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        PrivacySymbol(name: symbol).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(verbatim: title)
            if unavailable {
              GrantStatusBadge(title: l("grant.status.unavailable"), tone: .unavailable)
            } else if isLimited {
              GrantStatusBadge(title: l("grant.status.limited"), tone: .limited)
            } else if isInherited {
              GrantStatusBadge(title: l("grant.status.inherited"), tone: .inherited)
            }
          }
          AppLocalization.verbatimText(l.format("grant.saved.format", saved))
            .font(.caption).foregroundStyle(.secondary)
          AppLocalization.verbatimText(
            l.format("grant.effective.format", effective ?? l("grant.status.unavailable"))
          )
          .font(.caption).foregroundStyle(.secondary)
          if let explanation {
            Text(verbatim: explanation)
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .accessibilityElement(children: .combine)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct GrantStatusBadge: View {
  enum Tone { case limited, unavailable, inherited }

  let title: String
  let tone: Tone

  private var symbol: String {
    switch tone {
    case .limited: "exclamationmark.triangle.fill"
    case .unavailable: "minus.circle"
    case .inherited: "arrow.turn.down.right"
    }
  }

  var body: some View {
    Label {
      Text(verbatim: title).font(.caption)
    } icon: {
      Image(systemName: symbol).font(.caption).accessibilityHidden(true)
    }
    .foregroundStyle(tone == .limited ? Color.primary : Color.secondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      Capsule().fill(tone == .limited ? Color.orange.opacity(0.14) : Color.secondary.opacity(0.12))
    )
    .overlay(
      Capsule().strokeBorder(
        tone == .limited ? Color.orange.opacity(0.35) : Color.secondary.opacity(0.25),
        lineWidth: 0.5)
    )
    .accessibilityElement(children: .combine)
  }
}

struct PrincipalSummaryRow: View {
  let principal: PrivacyPrincipal

  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources

  var body: some View {
    let l = PrivacyText(locale: locale, resources: resources)
    HStack(spacing: 10) {
      PrivacySymbol(name: principal.systemImage)
        .frame(width: 28, height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: principal.name)
        let subtitle = PrivacyPrincipalDetailView.principalSummary(for: principal, using: l)
        Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary)
        if let status = principal.availabilityTitle {
          Text(verbatim: l(status)).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

struct PrivacyEditSourceLink: View {
  let route: PrivacyRoute

  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources

  var body: some View {
    let l = PrivacyText(locale: locale, resources: resources)
    NavigationLink(value: route) {
      Label(l("grant.source.editAction"), systemImage: "arrow.up.forward")
    }
    .buttonStyle(.link)
    .controlSize(.small)
    .accessibilityHint(l("grant.a11y.openSourceHint"))
  }
}

struct PrivacyRevocationButton: View {
  let principalName: String
  let permissionTitle: String?
  let snapshot: PrivacySnapshot
  let confirm: (PrivacySnapshot) -> Void

  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  @State private var reviewed: PrivacySnapshot?

  var body: some View {
    let l = PrivacyText(locale: locale, resources: resources)
    let scoped = permissionTitle != nil
    let title =
      permissionTitle.map {
        l.format("revocation.dialog.scopedTitle", $0, principalName)
      } ?? l.format("Revoke all access for “%@”?", principalName)
    Button(l(scoped ? "principal.action.revoke" : "Revoke All Access…")) {
      reviewed = snapshot
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .accessibilityLabel(l.format("principal.a11y.revoke", principalName))
    .confirmationDialog(
      title,
      isPresented: Binding(get: { reviewed != nil }, set: { if !$0 { reviewed = nil } }),
      titleVisibility: .visible,
      presenting: reviewed
    ) { snapshot in
      Button(l(scoped ? "revocation.dialog.confirm" : "Revoke All Access"), role: .destructive) {
        confirm(snapshot)
      }
      Button(l("revocation.dialog.cancel"), role: .cancel) {}
    } message: { _ in
      Text(
        verbatim: l(
          scoped
            ? "revocation.dialog.message"
            : "Saved permissions are revoked and running programs that depend on them end."))
    }
  }
}
