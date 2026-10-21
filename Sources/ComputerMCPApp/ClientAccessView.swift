import ComputerMCPAuthorization
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPGateway
import SwiftUI

struct ClientAccessView: View {
  @ObservedObject var model: ClientAccessModel
  var editPermissions: ((GatewayProfileID) -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Connected clients", bundle: AppLocalization.resourceBundle).font(.title3.bold())
        Spacer()
        if model.isRefreshing || model.isSaving { ProgressView().controlSize(.small) }
      }
      Text(verbatim: model.statusText).foregroundStyle(.secondary)
        .accessibilityIdentifier("client-access.status")
      if let error = model.errorMessage {
        Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
      }
      if let snapshot = model.snapshot {
        if !model.pendingOAuthRequests.isEmpty {
          Text("Sign-in requests", bundle: AppLocalization.resourceBundle).font(.headline)
          Text(
            "Approve only if the code matches the one shown in the browser where you are signing in.",
            bundle: AppLocalization.resourceBundle
          ).font(.callout).foregroundStyle(.secondary)
          ForEach(model.pendingOAuthRequests) { request in
            OAuthRequestRow(model: model, request: request)
            Divider()
          }
        }
        if snapshot.sessions.isEmpty, model.isAvailable {
          Text("Clients appear here when they connect.", bundle: AppLocalization.resourceBundle)
            .foregroundStyle(.secondary)
        }
        ForEach(snapshot.sessions) { session in
          sessionRow(session)
          Divider()
        }
        if !snapshot.sessions.isEmpty {
          Text(
            "Access changes apply to new requests. Already started work is not cancelled.",
            bundle: AppLocalization.resourceBundle
          ).font(.callout).foregroundStyle(.secondary)
        }
        if !model.activeOAuthGrants.isEmpty {
          Text("Signed-in remote clients", bundle: AppLocalization.resourceBundle)
            .font(.headline)
          Text(
            "Revoking ends a client's sign-in immediately. It must ask for your approval again to reconnect.",
            bundle: AppLocalization.resourceBundle
          ).font(.callout).foregroundStyle(.secondary)
          ForEach(model.activeOAuthGrants) { grant in
            OAuthGrantRow(model: model, grant: grant)
          }
        }
        let trusts = snapshot.trusts.filter(\.fullAccessAllowed)
        if !trusts.isEmpty {
          Text("Saved client approvals", bundle: AppLocalization.resourceBundle).font(.headline)
          Text(
            "New connections can restore Full Access only while the approved permissions remain unchanged. Revoke to require your approval again.",
            bundle: AppLocalization.resourceBundle
          ).font(.callout).foregroundStyle(.secondary)
          ForEach(trusts) { trust in
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: clientAccessIdentity(trust.principalID)).font(.headline)
                Text(verbatim: AppLocalization.string(trust.caller.clientAccessLabel))
                Text(verbatim: AppLocalization.string(trust.profileID.displayName))
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button(role: .destructive) {
                Task { await model.revoke(trust) }
              } label: {
                Text("Revoke", bundle: AppLocalization.resourceBundle)
              }
              .accessibilityIdentifier("client-access.trust.\(trust.id).revoke")
              .disabled(!model.isAvailable)
            }
          }
        }
      } else if model.isRefreshing {
        Text("Checking client access…", bundle: AppLocalization.resourceBundle)
      }
    }
    .disabled(model.isSaving)
    .sheet(item: $model.pendingConsent) { draft in
      ClientConsentView(model: model, draftID: draft.id)
    }
  }

  private func sessionRow(_ session: GatewayControlSessionSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: AppLocalization.string(session.caller.clientAccessLabel)).font(.headline)
        Text(verbatim: clientAccessIdentity(session.principalID)).foregroundStyle(.secondary)
        Spacer()
        Text(verbatim: AppLocalization.string(accessLabel(session)))
          .font(.callout.weight(.medium))
          .foregroundStyle(session.ended ? Color.secondary : .primary)
      }
      HStack {
        Text(verbatim: AppLocalization.string(session.profileID.displayName))
        AppLocalization.verbatimText(
          AppLocalization.formatted("Connection %@", String(session.id.prefix(8))))
      }.font(.caption).foregroundStyle(.secondary)
      if let consent = session.fullAccessConsent {
        AppLocalization.verbatimText(
          AppLocalization.string(
            consent.lifetime == .thisSession ? "This Session" : "Always Allow this Client")
        ).font(.callout)
      }
      if !session.ended {
        if session.profile?.grant.allowedCallers.contains(session.caller) == false {
          Text(
            "This connection type is not allowed by its profile. Review the connection permissions to allow it.",
            bundle: AppLocalization.resourceBundle
          ).font(.callout).foregroundStyle(.secondary)
        }
        HStack {
          Menu {
            Button {
              Task { await model.limit(session, to: .readOnly) }
            } label: {
              Text("Observe", bundle: AppLocalization.resourceBundle)
            }
            Button {
              Task { await model.limit(session, to: .workspaceOperations) }
            } label: {
              Text("Control — Restricted Access", bundle: AppLocalization.resourceBundle)
            }
            .disabled(session.profile?.grant.mode == .readOnly)
            Button {
              model.requestFullAccess(session)
            } label: {
              Text("Control — Full Access…", bundle: AppLocalization.resourceBundle)
            }
          } label: {
            Text("Change access", bundle: AppLocalization.resourceBundle)
          }
          .accessibilityIdentifier("client-access.session.\(session.id).change")
          .disabled(!model.isAvailable || session.currentAccess == nil)
          if let editPermissions, session.profileID != .localAdmin {
            Button {
              editPermissions(session.profileID)
            } label: {
              Text("Choose restricted permissions…", bundle: AppLocalization.resourceBundle)
            }.disabled(!model.isAvailable)
          }
          Spacer()
          Button(role: .destructive) {
            Task { await model.end(session) }
          } label: {
            Text("End access", bundle: AppLocalization.resourceBundle)
          }
          .accessibilityIdentifier("client-access.session.\(session.id).end")
          .disabled(!model.isAvailable)
        }
      }
    }
  }

  private func accessLabel(_ session: GatewayControlSessionSnapshot) -> String {
    if session.ended { return "Access ended" }
    switch session.currentAccess {
    case .readOnly: return "Observe"
    case .workspaceOperations: return "Control — Restricted Access"
    case .localFullAccess: return "Control — Full Access"
    case nil: return "Access unavailable"
    }
  }
}

private struct OAuthRequestRow: View {
  @ObservedObject var model: ClientAccessModel
  let request: OAuthPendingAuthorization
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: request.pairingCode)
          .font(.system(.title2, design: .monospaced).weight(.semibold))
          .textSelection(.enabled)
          .accessibilityIdentifier("client-access.oauth.\(request.id).code")
        Spacer()
        TimelineView(.periodic(from: .now, by: 30)) { _ in
          AppLocalization.verbatimText(
            AppLocalization.formatted(
              "Expires %@", locale: locale,
              request.expiresAt.formatted(
                Date.RelativeFormatStyle(presentation: .named, locale: locale)))
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
        GridRow {
          Text("Client", bundle: AppLocalization.resourceBundle).foregroundStyle(.secondary)
          Text(verbatim: request.clientHost)
        }
        GridRow {
          Text("Returns to", bundle: AppLocalization.resourceBundle).foregroundStyle(.secondary)
          Text(verbatim: request.redirectHost)
        }
      }
      HStack {
        if let selected = model.oauthProfile(for: request) {
          Picker(
            selection: Binding(
              get: { selected },
              set: { model.oauthProfileChoices[request.id] = $0 }
            )
          ) {
            ForEach(model.oauthProfileOptions, id: \.self) { profile in
              Text(verbatim: AppLocalization.string(profile.displayName)).tag(profile)
            }
          } label: {
            Text("Profile", bundle: AppLocalization.resourceBundle)
          }
          .fixedSize()
          .accessibilityIdentifier("client-access.oauth.\(request.id).profile")
        } else {
          Text(
            "No profile allows Cloudflare tunnel connections. Allow them in a profile to approve this request.",
            bundle: AppLocalization.resourceBundle
          ).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button(role: .destructive) {
          Task { await model.deny(request) }
        } label: {
          Text("Deny", bundle: AppLocalization.resourceBundle)
        }
        .accessibilityIdentifier("client-access.oauth.\(request.id).deny")
        Button {
          Task { await model.approve(request) }
        } label: {
          Text("Approve", bundle: AppLocalization.resourceBundle)
        }
        .accessibilityIdentifier("client-access.oauth.\(request.id).approve")
        .disabled(model.oauthProfile(for: request) == nil)
      }
      .disabled(!model.isAvailable || model.isSaving)
    }
  }
}

private struct OAuthGrantRow: View {
  @ObservedObject var model: ClientAccessModel
  let grant: OAuthGrant
  @Environment(\.locale) private var locale

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: URL(string: grant.clientID)?.host ?? grant.clientID).font(.headline)
        Text(verbatim: AppLocalization.string(grant.profileID.displayName))
        if let lastUsed = grant.lastUsedAt {
          AppLocalization.verbatimText(
            AppLocalization.formatted(
              "Last used %@", locale: locale,
              lastUsed.formatted(Date.RelativeFormatStyle(presentation: .named, locale: locale)))
          ).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button(role: .destructive) {
        Task { await model.revoke(grant) }
      } label: {
        Text("Revoke", bundle: AppLocalization.resourceBundle)
      }
      .accessibilityIdentifier("client-access.oauth-grant.\(grant.id).revoke")
      .disabled(!model.isAvailable)
    }
  }
}

struct ClientConsentView: View {
  @ObservedObject var model: ClientAccessModel
  let draftID: UUID
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let draft = model.pendingConsent, draft.id == draftID {
        Text("Allow Full Access?", bundle: AppLocalization.resourceBundle).font(.title2.bold())
        Text(verbatim: AppLocalization.string(draft.session.caller.clientAccessLabel))
          .font(.headline)
        Text(verbatim: clientAccessIdentity(draft.session.principalID))
        Text(
          "This client can run commands and access files, processes, the network, and credentials available to your macOS user. A workspace does not limit this access. macOS privacy permissions still apply.",
          bundle: AppLocalization.resourceBundle)
        Picker(
          selection: Binding(
            get: { model.pendingConsent?.lifetime ?? .thisSession },
            set: { if model.pendingConsent?.id == draftID { model.pendingConsent?.lifetime = $0 } }
          )
        ) {
          Text("This Session", bundle: AppLocalization.resourceBundle)
            .tag(GatewayFullAccessLifetime.thisSession)
          Text("Always Allow this Client", bundle: AppLocalization.resourceBundle)
            .tag(GatewayFullAccessLifetime.alwaysAllowClient)
        } label: {
          Text("Allow for", bundle: AppLocalization.resourceBundle)
        }
        .accessibilityIdentifier("client-access.consent.lifetime")
        Text(
          "Clients sharing the same connection credential share a trusted identity. Ending this session does not revoke an always-allowed client.",
          bundle: AppLocalization.resourceBundle
        ).font(.callout).foregroundStyle(.secondary)
        if let error = model.errorMessage {
          Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
        }
        if !model.consentIsCurrent {
          Text(
            "Client access changed. Close this window and review the connection again.",
            bundle: AppLocalization.resourceBundle
          ).foregroundStyle(.secondary)
        }
        HStack {
          Button {
            model.pendingConsent = nil
            dismiss()
          } label: {
            Text("Cancel", bundle: AppLocalization.resourceBundle)
          }.keyboardShortcut(.cancelAction)
          Spacer()
          if model.isSaving { ProgressView().controlSize(.small) }
          Button(role: .destructive) {
            Task { if await model.approve() { dismiss() } }
          } label: {
            Text("Allow Full Access", bundle: AppLocalization.resourceBundle)
          }
          .accessibilityIdentifier("client-access.consent.allow")
          .disabled(!model.isAvailable || !model.consentIsCurrent)
        }
      }
    }
    .padding(24).frame(width: 500)
    .disabled(model.isSaving)
    .interactiveDismissDisabled(model.isSaving)
  }
}

struct ClientAccessMenuStatus: View {
  @ObservedObject var model: ClientAccessModel
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      Text(verbatim: model.statusText)
    }
  }
}

struct ClientAccessMenuLabel: View {
  @ObservedObject var model: ClientAccessModel
  let serviceSystemImage: String

  var body: some View {
    if !model.pendingOAuthRequests.isEmpty {
      Label(model.statusText, systemImage: "person.badge.key")
    } else {
      Label(
        model.controllingSessions.isEmpty ? "Computer MCP" : model.statusText,
        systemImage: model.controllingSessions.isEmpty ? serviceSystemImage : "cursorarrow.rays")
    }
  }
}
