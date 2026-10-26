import SwiftUI

extension EnvironmentValues {
  /// A directory of compiled `.lproj` tables to read instead of the App's own resources.
  @Entry var localizationResources: Bundle?
}

/// Text resolved for a view's environment locale.
struct PrivacyText {
  let locale: Locale
  var resources: Bundle?

  func callAsFunction(_ key: String) -> String {
    AppLocalization.string(key, locale: locale, resources: resources)
  }

  func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: callAsFunction(key), locale: locale, arguments: arguments)
  }
}

private struct PrivacySymbol: View {
  let name: String

  var body: some View {
    Image(systemName: name)
      .symbolRenderingMode(.multicolor)
      .frame(width: 22)
  }
}

enum PrivacyRoute: Hashable {
  case permission(PrivacyPermissionKind)
  case principal(String)
}

struct PrivacySecurityView: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { PrivacyText(locale: locale, resources: resources) }
  @ObservedObject var model: PrivacySecurityModel
  @State private var path: [PrivacyRoute] = []
  @State private var prompted: PrivacyRequest?

  var body: some View {
    NavigationStack(path: $path) {
      Form {
        if model.snapshot.suspendedForReview { restoredSection }
        if !model.snapshot.requests.isEmpty { requestsSection }
        permissionsSection
        principalsSection
        if !model.snapshot.managedSources.isEmpty { managedSection }
        systemSection
      }
      .formStyle(.grouped)
      .navigationTitle(l("Privacy & Security"))
      .navigationDestination(for: PrivacyRoute.self) { route in
        switch route {
        case .permission(let kind): PrivacyPermissionDetailView(model: model, permission: kind)
        case .principal(let id): PrivacyPrincipalDetailView(model: model, principalID: id)
        }
      }
    }
    .sheet(item: $prompted) { request in
      PrivacyRequestPrompt(request: request) { answer in
        prompted = nil
        Task { await model.answer(request, answer) }
      }
    }
    .alert(
      l("The change couldn't be made."),
      isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })
    ) {
      Button(l("OK"), role: .cancel) {}
    } message: {
      Text(verbatim: model.failure ?? "")
    }
    .task { await model.refresh() }
  }

  private var restoredSection: some View {
    Section {
      Label {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: l("Permissions are paused"))
            .font(.headline)
          Text(
            verbatim: l(
              "The permission store is older than the authority already used, for example after a restore from a backup. Review the permissions below, then confirm them to resume."
            )
          )
          .foregroundStyle(.secondary)
        }
      } icon: {
        PrivacySymbol(name: "exclamationmark.triangle.fill")
      }
      Button(l("Confirm Permissions")) {
        Task { await model.confirmRestoredPermissions() }
      }
    }
  }

  private var requestsSection: some View {
    Section(l("Requests")) {
      ForEach(model.snapshot.requests) { request in
        Button {
          prompted = request
        } label: {
          HStack {
            PrivacySymbol(name: request.principal.systemImage)
            VStack(alignment: .leading, spacing: 2) {
              let text1 = PrivacyRequestPrompt.requestSentence(for: request, using: l)
              Text(verbatim: text1)
                .foregroundStyle(.primary)
              Text(verbatim: l(request.permission.title))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
              .foregroundStyle(.tertiary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("privacy.request.\(request.id)")
      }
    }
  }

  private var permissionsSection: some View {
    Section(l("Permissions")) {
      ForEach(PrivacyPermissionKind.allCases) { kind in
        NavigationLink(value: PrivacyRoute.permission(kind)) {
          HStack {
            Label {
              Text(verbatim: l(kind.title))
            } icon: {
              PrivacySymbol(name: kind.systemImage)
            }
            Spacer()
            let holders = model.holders(of: kind)
            if holders > 0 {
              Text(verbatim: "\(holders)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          }
        }
        .accessibilityIdentifier("privacy.permission.\(kind.rawValue)")
      }
    }
  }

  private var principalsSection: some View {
    Section(l("Clients and Plugins")) {
      if model.snapshot.principals.isEmpty {
        Text(verbatim: l("No clients or plugins are connected yet."))
          .foregroundStyle(.secondary)
      }
      ForEach(model.snapshot.principals) { principal in
        NavigationLink(value: PrivacyRoute.principal(principal.id)) {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: principal.name)
              let text2 = PrivacyPrincipalDetailView.principalSummary(for: principal, using: l)
              Text(verbatim: text2)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            PrivacySymbol(name: principal.systemImage)
          }
        }
        .accessibilityIdentifier("privacy.principal.\(principal.id)")
      }
    }
  }

  private var managedSection: some View {
    Section {
      ForEach(model.snapshot.managedSources) { source in
        LabeledContent {
          Text(
            verbatim: l(source.state == .active ? "Applied" : "Can't Be Read")
          )
          .foregroundStyle(source.state == .active ? Color.secondary : Color.red)
        } label: {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: l(source.name))
              Text(verbatim: source.location)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
          } icon: {
            PrivacySymbol(name: "building.columns.fill")
          }
        }
      }
    } header: {
      Text(verbatim: l("Managed Limits"))
    } footer: {
      Text(
        verbatim: l(
          "Managed limits cap what can be granted here. A source that can't be read limits everything it could limit until it can be read."
        )
      )
    }
  }

  private var systemSection: some View {
    Section {
      ForEach(model.snapshot.systemPermissions) { permission in
        LabeledContent {
          HStack(spacing: 8) {
            Text(verbatim: l(Self.stateTitle(permission.state)))
              .foregroundStyle(.secondary)
            if permission.state != .allowed {
              Button(l("Open System Settings")) {
                model.openSystemSettings(for: permission.kind)
              }
            }
          }
        } label: {
          Label {
            let text3 = Self.systemPermissionName(permission.kind, using: l)
            Text(verbatim: text3)
          } icon: {
            PrivacySymbol(name: Self.systemImage(permission.kind))
          }
        }
      }
    } header: {
      Text(verbatim: l("This Mac"))
    } footer: {
      Text(
        verbatim: l(
          "Computer MCP holds these macOS permissions for everything it runs in the sandbox. What each client or plugin may use of them is set above."
        )
      )
    }
  }

  static func systemPermissionName(_ kind: PrivacySystemPermission.Kind, using l: PrivacyText)
    -> String
  {
    switch kind {
    case .screenRecording: l("Screen Recording")
    case .accessibility: l("Accessibility")
    case .automation(let app):
      l.format("Automation of %@", app)
    }
  }

  static func systemImage(_ kind: PrivacySystemPermission.Kind) -> String {
    switch kind {
    case .screenRecording: "rectangle.dashed.badge.record"
    case .accessibility: "accessibility"
    case .automation: "gearshape.2.fill"
    }
  }

  static func stateTitle(_ state: PrivacySystemPermission.State) -> String {
    switch state {
    case .allowed: "Allowed"
    case .notAllowed: "Not Allowed"
    case .notDetermined: "Not Requested"
    }
  }
}

struct PrivacyPermissionDetailView: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { PrivacyText(locale: locale, resources: resources) }
  @ObservedObject var model: PrivacySecurityModel
  let permission: PrivacyPermissionKind

  var body: some View {
    Form {
      Section {
        Text(verbatim: l(permission.summary))
          .foregroundStyle(.secondary)
      }
      if permission == .fullAccess {
        fullAccessRows
      } else if permission.isPerObject {
        perObjectSections
      } else {
        perPrincipalRows
      }
    }
    .formStyle(.grouped)
    .navigationTitle(l(permission.title))
  }

  private var perPrincipalRows: some View {
    Section {
      let grants = model.grants(for: permission)
      if grants.isEmpty { emptyRow }
      ForEach(grants) { grant in
        PrivacyGrantRow(
          model: model, grant: grant, title: model.principal(grant.principalID)?.name,
          systemImage: model.principal(grant.principalID)?.systemImage)
      }
    }
  }

  @ViewBuilder private var perObjectSections: some View {
    let grants = model.grants(for: permission)
    if grants.isEmpty { Section { emptyRow } }
    let objects = Dictionary(grouping: grants) { $0.object?.id ?? "" }
    ForEach(objects.keys.sorted(), id: \.self) { key in
      let rows = objects[key] ?? []
      Section {
        ForEach(rows) { grant in
          PrivacyGrantRow(
            model: model, grant: grant, title: model.principal(grant.principalID)?.name,
            systemImage: model.principal(grant.principalID)?.systemImage)
        }
      } header: {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: rows.first?.object?.name ?? "")
          if let detail = rows.first?.object?.detail {
            Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      }
    }
  }

  private var fullAccessRows: some View {
    Section {
      let principals = model.snapshot.principals
      if principals.isEmpty { emptyRow }
      ForEach(principals) { principal in
        LabeledContent {
          Text(verbatim: l(PrivacyPrincipalDetailView.executionTitle(principal.execution)))
            .foregroundStyle(.secondary)
        } label: {
          Label {
            Text(verbatim: principal.name)
          } icon: {
            PrivacySymbol(name: principal.systemImage)
          }
        }
      }
    } footer: {
      Text(
        verbatim: l(
          "Full Access is turned on from a client's or plugin's page, and needs your confirmation on this Mac."
        )
      )
    }
  }

  private var emptyRow: some View {
    Text(verbatim: l("No clients or plugins have asked for this permission."))
      .foregroundStyle(.secondary)
  }
}

struct PrivacyGrantRow: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { PrivacyText(locale: locale, resources: resources) }
  @ObservedObject var model: PrivacySecurityModel
  let grant: PrivacyGrant
  let title: String?
  let systemImage: String?

  var body: some View {
    Picker(selection: binding) {
      Text(verbatim: l("Ask")).tag(PrivacyGrantValue.ask)
      ForEach(grant.permission.grantedValues, id: \.self) { level in
        Text(verbatim: l(level.title)).tag(PrivacyGrantValue.granted(level))
      }
      Text(verbatim: l("Don't Allow")).tag(PrivacyGrantValue.denied)
    } label: {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: title ?? grant.object?.name ?? "")
          if let caption {
            Text(verbatim: caption).font(.caption).foregroundStyle(.secondary)
          }
        }
      } icon: {
        PrivacySymbol(name: systemImage ?? grant.permission.systemImage)
      }
    }
    .disabled(managed)
    .accessibilityIdentifier("privacy.grant.\(grant.id)")
  }

  private var managed: Bool {
    if case .managedLimit = grant.source { true } else { false }
  }

  private var caption: String? {
    var parts: [String] = []
    if let network = grant.network { parts.append(Self.networkTitle(network, using: l)) }
    switch grant.source {
    case .owner: break
    case .pluginDeclaration: parts.append(l("Declared by the plugin"))
    case .managedLimit(let source): parts.append(l.format("Set by %@", l(source)))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  static func networkTitle(_ network: PrivacyNetworkAccess, using l: PrivacyText) -> String {
    switch network {
    case .none: l("Network: None")
    case .trusted: l("Network: Trusted Hosts")
    case .full: l("Network: Any Host")
    case .custom(let hosts, let includesTrusted):
      l.format(
        includesTrusted ? "Network: Trusted Hosts and %@" : "Network: %@",
        ListFormatter.localizedString(byJoining: hosts))
    }
  }

  private var binding: Binding<PrivacyGrantValue> {
    Binding(
      get: { grant.value },
      set: { value in Task { await model.set(grant, to: value) } })
  }
}

struct PrivacyPrincipalDetailView: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { PrivacyText(locale: locale, resources: resources) }
  @ObservedObject var model: PrivacySecurityModel
  let principalID: String
  @State private var confirmRevoke = false
  @State private var confirmFullAccess = false

  var body: some View {
    if let principal = model.principal(principalID) {
      Form {
        Section {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: principal.name).font(.title3.weight(.semibold))
              let text4 = Self.principalSummary(for: principal, using: l)
              Text(verbatim: text4).foregroundStyle(.secondary)
            }
          } icon: {
            PrivacySymbol(name: principal.systemImage).font(.title2)
          }
        }
        executionSection(principal)
        let grants = model.grants(for: principal)
        let single = grants.filter { !$0.permission.isPerObject }
        if !single.isEmpty {
          Section(l("Permissions")) {
            ForEach(PrivacyPermissionKind.allCases) { kind in
              ForEach(single.filter { $0.permission == kind }) { grant in
                PrivacyGrantRow(
                  model: model, grant: grant, title: l(kind.title), systemImage: kind.systemImage)
              }
            }
          }
        }
        ForEach(
          PrivacyPermissionKind.allCases.filter { kind in
            kind.isPerObject && grants.contains { $0.permission == kind }
          }
        ) { kind in
          Section(l(kind.title)) {
            ForEach(grants.filter { $0.permission == kind }) { grant in
              PrivacyGrantRow(
                model: model, grant: grant, title: grant.object?.name,
                systemImage: kind.systemImage)
            }
          }
        }
        Section {
          Button(role: .destructive) {
            confirmRevoke = true
          } label: {
            Text(verbatim: l("Revoke All Access…"))
              .foregroundStyle(.red)
          }
          .buttonStyle(.borderless)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(principal.name)
      .confirmationDialog(
        l.format("Revoke all access for “%@”?", principal.name),
        isPresented: $confirmRevoke
      ) {
        Button(l("Revoke All Access"), role: .destructive) {
          Task { await model.revokeAll(principal) }
        }
      } message: {
        Text(
          verbatim: l(
            "Every permission returns to Ask, and running programs that depend on them end."
          ))
      }
      .confirmationDialog(
        l.format("Give “%@” Full Access?", principal.name),
        isPresented: $confirmFullAccess
      ) {
        Button(l("Give Full Access"), role: .destructive) {
          Task { await model.setExecution(principal, .fullAccessSaved) }
        }
      } message: {
        Text(verbatim: l(PrivacyPermissionKind.fullAccess.summary))
      }
    } else {
      ContentUnavailableView(
        l("This client or plugin is no longer available."),
        systemImage: "questionmark.circle")
    }
  }

  private func executionSection(_ principal: PrivacyPrincipal) -> some View {
    Section {
      Picker(
        selection: Binding(
          get: { principal.execution == .sandbox ? 0 : 1 },
          set: { choice in
            if choice == 0 {
              Task { await model.setExecution(principal, .sandbox) }
            } else {
              confirmFullAccess = true
            }
          })
      ) {
        Text(verbatim: l("Sandbox")).tag(0)
        Text(verbatim: l("Full Access")).tag(1)
      } label: {
        Text(verbatim: l("Execution"))
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("privacy.execution.\(principal.id)")
    } footer: {
      Text(verbatim: l(Self.executionFootnote(principal.execution)))
    }
  }

  static func principalSummary(for principal: PrivacyPrincipal, using l: PrivacyText) -> String {
    var parts = [l(principal.kindTitle)]
    switch principal.kind {
    case .client(let connection): parts.append(connection)
    case .plugin(let version): parts.append(version)
    case .localServer: break
    }
    parts.append(l(executionTitle(principal.execution)))
    return parts.joined(separator: " · ")
  }

  static func executionTitle(_ execution: PrivacyPrincipal.Execution) -> String {
    switch execution {
    case .sandbox: "Sandbox"
    case .fullAccessSaved: "Full Access"
    case .fullAccessConnection: "Full Access for This Connection"
    }
  }

  static func executionFootnote(_ execution: PrivacyPrincipal.Execution) -> String {
    switch execution {
    case .sandbox:
      "Programs run in the sandbox and change projects only in worktrees."
    case .fullAccessSaved, .fullAccessConnection:
      "Programs run as you without the sandbox. They don't inherit Computer MCP's macOS permissions."
    }
  }
}

struct PrivacyRequestPrompt: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { PrivacyText(locale: locale, resources: resources) }
  let request: PrivacyRequest
  let answer: (PrivacyRequestAnswer) -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: request.principal.systemImage)
        .symbolRenderingMode(.multicolor)
        .font(.system(size: 44))
        .padding(.top, 8)
      VStack(spacing: 8) {
        let text5 = Self.requestSentence(for: request, using: l)
        Text(verbatim: text5)
          .font(.headline)
          .multilineTextAlignment(.center)
        if let purpose = request.purpose {
          Text(verbatim: purpose)
            .multilineTextAlignment(.center)
        }
        Text(verbatim: l(request.permission.summary))
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      VStack(spacing: 8) {
        Button {
          answer(.onlyThisTime)
        } label: {
          Text(verbatim: l("Only This Time")).frame(maxWidth: .infinity)
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("privacy.prompt.once")
        Button {
          answer(.always)
        } label: {
          Text(verbatim: l("Always")).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("privacy.prompt.always")
        Button(role: .cancel) {
          answer(.dontAllow)
        } label: {
          Text(verbatim: l("Don't Allow")).frame(maxWidth: .infinity)
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("privacy.prompt.deny")
      }
      .controlSize(.large)
      Text(
        verbatim: l(
          "Only This Time covers the retried request and the program it starts.")
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(width: 340)
  }

  static func requestSentence(for request: PrivacyRequest, using l: PrivacyText) -> String {
    let object = request.object?.name ?? l(request.permission.title)
    switch request.level {
    case .readWrite:
      return l.format(
        "“%1$@” wants to read and change “%2$@”.", request.principal.name, object)
    case .read:
      return l.format(
        "“%1$@” wants to read “%2$@”.", request.principal.name, object)
    default:
      return l.format(
        "“%1$@” wants to use “%2$@”.", request.principal.name, object)
    }
  }
}
