import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import SwiftUI

struct PermissionAuthorityReviewSnapshot: Identifiable {
  let id = UUID()
  let view: GatewayPermissionView
  let names: PermissionObjectNames
}

struct PermissionAuthorityReview: View {
  let snapshot: PermissionAuthorityReviewSnapshot
  let confirm: @MainActor () async throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var isConfirming = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section(AppLocalization.string("Review saved authority")) {
          Text(
            "Confirming activates every saved profile below for the current epoch. Review all permissions, including wildcard rules and entries for unavailable objects.",
            bundle: AppLocalization.resourceBundle)
          LabeledContent(
            AppLocalization.string("Epoch"), value: snapshot.view.epoch?.uuidString ?? "—")
          LabeledContent(
            AppLocalization.string("Permission revision"), value: String(snapshot.view.revision))
          LabeledContent(
            AppLocalization.string("Unconfirmed profiles"),
            value: snapshot.view.unconfirmedProfileIDs.map(PermissionObjectNames.profile).sorted()
              .joined(
                separator: ", "))
        }
        ForEach(snapshot.view.profiles.sorted { $0.id.rawValue < $1.id.rawValue }, id: \.id) {
          profile in
          Section(PermissionObjectNames.profile(profile.id)) {
            LabeledContent(
              AppLocalization.string("Profile revision"),
              value: String(profile.authorizationRevision))
            LabeledContent(
              AppLocalization.string("Full access"),
              value: AppLocalization.string(profile.fullAccess ? "Allow" : "Deny"))
            LabeledContent(
              AppLocalization.string("Allow connections from"),
              value: profile.allowedCallers.map(\.rawValue).sorted().joined(separator: ", "))
            ForEach(ProfileAuthorityReviewRow.rows(for: profile, names: snapshot.names)) { row in
              LabeledContent(row.title, value: row.value)
            }
          }
        }
        if !snapshot.view.sources.isEmpty {
          Section(AppLocalization.string("Managed sources")) {
            ForEach(Array(snapshot.view.sources.enumerated()), id: \.offset) { _, source in
              VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: source.location)
                Text(verbatim: source.revision).font(.caption).foregroundStyle(.secondary)
                if let failure = source.failure { Text(verbatim: failure).foregroundStyle(.red) }
              }
            }
          }
        }
      }.formStyle(.grouped).textSelection(.enabled)
      if let errorMessage {
        Text(verbatim: errorMessage).foregroundStyle(.red).padding()
        Text(
          "Close and reopen to review the current saved authority.",
          bundle: AppLocalization.resourceBundle
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      HStack {
        Button(AppLocalization.string("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if isConfirming { ProgressView().controlSize(.small) }
        Button(AppLocalization.string("Confirm saved authority")) {
          isConfirming = true
          errorMessage = nil
          Task {
            defer { isConfirming = false }
            do {
              try await confirm()
              dismiss()
            } catch { errorMessage = AppLocalization.errorDescription(error) }
          }
        }.accessibilityIdentifier("permission.authority.confirm")
      }.padding().disabled(isConfirming)
    }.frame(width: 680, height: 740)
      .interactiveDismissDisabled(isConfirming)
  }
}

struct ProfileAuthorityReviewRow: Identifiable, Equatable {
  let id: String
  let title: String
  let value: String

  static func rows(for profile: ProfileGrant, names: PermissionObjectNames = .init()) -> [Self] {
    let permissions = profile.permissions.entries.map { permission, state in
      let value =
        switch state {
        case .notGranted: AppLocalization.string("Ask")
        case .denied: AppLocalization.string("Deny")
        case .granted(let value): AppLocalization.string(value.permissionTitle)
        }
      return Self(
        id: "permission:\(permission)", title: names.title(for: permission),
        value: value)
    }
    let networks = profile.projectNetworks.map { id, network in
      let value =
        switch network.configuration {
        case .none: AppLocalization.string("None")
        case .trusted: AppLocalization.string("Trusted hosts")
        case .full: AppLocalization.string("Full network")
        case .custom(let hosts, let includesTrusted):
          hosts.sorted().joined(separator: ", ")
            + (includesTrusted ? " · " + AppLocalization.string("Trusted hosts") : "")
        }
      return Self(
        id: "network:\(id)", title: AppLocalization.string("Network") + " · " + names.project(id),
        value: value)
    }
    let automation = profile.automation.map { target, access in
      Self(
        id: "automation:\(target)", title: AppLocalization.string("Automation") + " · " + target,
        value: AppLocalization.string(access.rawValue == "allow" ? "Allow" : "Deny"))
    }
    return (permissions + networks + automation).sorted { $0.id < $1.id }
  }
}
