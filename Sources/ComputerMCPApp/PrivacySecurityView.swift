import ComputerMCPGateway
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

  func list(_ items: [String]) -> String {
    let formatter = ListFormatter()
    formatter.locale = locale
    return formatter.string(from: items) ?? items.joined(separator: ", ")
  }
}

struct PrivacySymbol: View {
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
  @State private var policyTarget: PrivacyOwnerPolicyTarget?
  @State private var prompted: PrivacyRequest?
  @State private var promptedSnapshot = PrivacySnapshot()

  var body: some View {
    NavigationStack(path: $model.path) {
      Form {
        if model.snapshot.suspendedForReview { restoredSection }
        if !model.snapshot.requests.isEmpty { requestsSection }
        permissionsSection
        principalsSection
        PrivacyPolicySourcesSection(snapshot: model.snapshot) { policyTarget = $0 }
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
    .sheet(item: $policyTarget) { target in
      OwnerPolicyEditorView(
        model: OwnerPolicyEditorModel(target: target, privacy: model)
      ) {
        policyTarget = nil
      }
    }
    .sheet(item: $prompted) { request in
      PrivacyRequestPrompt(request: request) { answer in
        let reviewed = promptedSnapshot
        prompted = nil
        Task { await model.answer(request, answer, reviewed: reviewed) }
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
        let reviewed = model.snapshot
        Task { await model.confirmRestoredPermissions(reviewed: reviewed) }
      }
    }
  }

  private var requestsSection: some View {
    Section(l("Requests")) {
      ForEach(model.snapshot.requests) { request in
        Button {
          promptedSnapshot = model.snapshot
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
    }
  }

  static func systemImage(_ kind: PrivacySystemPermission.Kind) -> String {
    switch kind {
    case .screenRecording: "rectangle.dashed.badge.record"
    case .accessibility: "accessibility"
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
  @State private var collapsed: Set<String> = []

  var body: some View {
    Form {
      Section {
        Text(verbatim: l(permission.summary))
          .foregroundStyle(.secondary)
      }
      PrivacyUnreadableNotice(grants: model.grants(for: permission))
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

  /// Each client or plugin with its objects beneath it, as Files & Folders lists each app.
  private var perObjectSections: some View {
    Section {
      let grants = model.grants(for: permission)
      let holders = model.snapshot.principals.filter { principal in
        grants.contains { $0.principalID == principal.id }
      }
      if holders.isEmpty { emptyRow }
      ForEach(holders) { principal in
        DisclosureGroup(isExpanded: expansion(principal.id)) {
          ForEach(grants.filter { $0.principalID == principal.id }) { grant in
            PrivacyGrantRow(
              model: model, grant: grant, title: grant.object?.name,
              systemImage: permission.systemImage(for: grant.object),
              showsNetwork: permission != .projects
            )
            .padding(.leading, 24)
            .help(Text(verbatim: grant.object?.detail ?? ""))
            if grant.showsNetwork {
              PrivacyNetworkPicker(model: model, grant: grant).padding(.leading, 52)
            }
          }
        } label: {
          Label {
            Text(verbatim: principal.name)
          } icon: {
            PrivacySymbol(name: principal.systemImage)
          }
        }
        .accessibilityIdentifier("privacy.holder.\(principal.id)")
      }
    }
  }

  private func expansion(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !collapsed.contains(id) },
      set: { expanded in
        if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
      })
  }

  private var fullAccessRows: some View {
    Section {
      let principals = model.snapshot.principals
      if principals.isEmpty { emptyRow }
      ForEach(principals) { principal in
        LabeledContent {
          if let clientAccess = model.clientAccess {
            PrivacyClientExecutionLabel(model: clientAccess, principal: principal)
          } else {
            let title = l(PrivacyPrincipalDetailView.executionTitle(principal.execution))
            Text(verbatim: title).foregroundStyle(.secondary)
          }
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
          "Each connection needs approval on this Mac before programs can run without the sandbox."
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
  /// Off where a separate row edits the project's network access.
  var showsNetwork = true

  var body: some View {
    Picker(selection: binding) {
      if let inheritedTitle = Self.inheritedTitle(grant, using: l) {
        Text(verbatim: inheritedTitle).tag(PrivacyGrantChoice.inherited)
          .disabled(!grant.allowsInheritance)
        Divider()
      }
      Text(verbatim: l("Ask")).tag(PrivacyGrantChoice.explicit(.ask))
      ForEach(grant.permission.grantedValues, id: \.self) { level in
        Text(verbatim: l(level.title)).tag(PrivacyGrantChoice.explicit(.granted(level)))
          .disabled(!grant.availableLevels.contains(level))
      }
      Text(verbatim: l("Don't Allow")).tag(PrivacyGrantChoice.explicit(.denied))
    } label: {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          let name = title ?? grant.object?.name ?? ""
          let rowTitle =
            grant.object?.id == "*" || grant.permission == .filesAndFolders ? l(name) : name
          Text(verbatim: rowTitle)
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
    grant.availableLevels.isEmpty
  }

  private var caption: String? {
    var parts: [String] = []
    if grant.object?.isRegistered == false { parts.append(l("Not registered")) }
    if showsNetwork, let network = grant.network {
      parts.append(Self.networkTitle(network, using: l))
    }
    switch grant.source {
    case .owner: break
    case .pluginDeclaration: parts.append(l("Declared by the plugin"))
    }
    parts += grant.limitNotices.filter(\.isPerRow).map { $0.text(using: l) }
    if showsNetwork {
      parts += grant.networkLimitNotices.filter(\.isPerRow).map { $0.text(using: l) }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// The network level alone, as a picker shows its current value.
  nonisolated static func networkValue(_ network: PrivacyNetworkAccess, using l: PrivacyText)
    -> String
  {
    switch network {
    case .none: l("None")
    case .trusted: l("Trusted Hosts")
    case .full: l("Any Host")
    case .custom(let hosts, let includesTrusted):
      includesTrusted
        ? l.format("Trusted Hosts and %@", l.list(hosts))
        : l.list(hosts)
    }
  }

  static func networkTitle(_ network: PrivacyNetworkAccess, using l: PrivacyText) -> String {
    switch network {
    case .none: l("Network: None")
    case .trusted: l("Network: Trusted Hosts")
    case .full: l("Network: Any Host")
    case .custom(let hosts, let includesTrusted):
      l.format(
        includesTrusted ? "Network: Trusted Hosts and %@" : "Network: %@",
        l.list(hosts))
    }
  }

  static func inheritedTitle(_ grant: PrivacyGrant, using l: PrivacyText) -> String? {
    guard let value = grant.inheritedValue else { return nil }
    if value == .ask { return l("Ask") }
    let name: String
    switch grant.permission {
    case .projects: name = "All Projects"
    case .plugins: name = "All Plugins"
    case .mcpServers: name = "All MCP Servers"
    default: return nil
    }
    return l.format("Same as %1$@ (%2$@)", l(name), l(value.title))
  }

  private var binding: Binding<PrivacyGrantChoice> {
    Binding(
      get: { grant.choice },
      set: { choice in
        let reviewed = model.snapshot
        Task { await model.set(grant, choice: choice, reviewed: reviewed) }
      })
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
        PrivacyUnreadableNotice(grants: model.grants(for: principal))
        executionSection(principal)
        if let clientAccess = model.clientAccess {
          PrivacyConnectionsSection(model: clientAccess, principal: principal)
        }
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
                systemImage: kind.systemImage(for: grant.object),
                showsNetwork: kind != .projects)
              if grant.showsNetwork {
                PrivacyNetworkPicker(model: model, grant: grant).padding(.leading, 28)
              }
            }
          }
        }
        Section {
        } footer: {
          HStack {
            Spacer()
            Button(l("Revoke All Access…")) { confirmRevoke = true }
              .accessibilityIdentifier("privacy.revoke.\(principal.id)")
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(principal.name)
      .confirmationDialog(
        l.format("Revoke all access for “%@”?", principal.name),
        isPresented: $confirmRevoke
      ) {
        Button(l("Revoke All Access"), role: .destructive) {
          let reviewed = model.snapshot
          Task { await model.revokeAll(principal, reviewed: reviewed) }
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
          let reviewed = model.snapshot
          Task { await model.setExecution(principal, .fullAccessAllowed, reviewed: reviewed) }
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
              let reviewed = model.snapshot
              Task { await model.setExecution(principal, .sandbox, reviewed: reviewed) }
            } else if principal.fullAccessLimitSources.isEmpty {
              confirmFullAccess = true
            }
          })
      ) {
        Text(verbatim: l("Sandbox")).tag(0)
        Text(verbatim: l("Full Access Allowed")).tag(1)
          .disabled(!principal.fullAccessLimitSources.isEmpty)
      } label: {
        Text(verbatim: l("Execution"))
      }
      .pickerStyle(.segmented)
      .disabled(!principal.fullAccessLimitSources.isEmpty && principal.execution == .sandbox)
      .accessibilityIdentifier("privacy.execution.\(principal.id)")
    } footer: {
      let footnote = l(Self.executionFootnote(principal.execution))
      Text(verbatim: footnote)
      if !principal.fullAccessLimitSources.isEmpty {
        let source = l.list(principal.fullAccessLimitSources.map { l($0) })
        let message = l.format("Set by %@", source)
        Text(verbatim: message)
      }
    }
  }

  static func principalSummary(for principal: PrivacyPrincipal, using l: PrivacyText) -> String {
    var parts = [l(principal.kindTitle)]
    switch principal.kind {
    case .client(let connection): parts.append(l(connection))
    case .plugin(let version): parts.append(version)
    case .localServer: break
    }
    parts.append(l(executionTitle(principal.execution)))
    return parts.joined(separator: " · ")
  }

  static func executionTitle(_ execution: PrivacyPrincipal.Execution) -> String {
    switch execution {
    case .sandbox: "Sandbox"
    case .fullAccessAllowed: "Full Access Allowed"
    }
  }

  static func executionFootnote(_ execution: PrivacyPrincipal.Execution) -> String {
    switch execution {
    case .sandbox:
      "Programs run in the sandbox and change projects only in worktrees."
    case .fullAccessAllowed:
      "Each connection needs approval on this Mac before programs can run without the sandbox."
    }
  }
}

/// A project's network access, with Custom… opening the host editor.
struct PrivacyNetworkPicker: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { PrivacyText(locale: locale, resources: resources) }
  @ObservedObject var model: PrivacySecurityModel
  let grant: PrivacyGrant
  @State private var customEdit: PrivacyNetworkEdit?

  private enum Choice: Hashable { case none, trusted, full, custom, edit }

  var body: some View {
    Picker(selection: selection) {
      Text(verbatim: l("None")).tag(Choice.none)
      Text(verbatim: l("Trusted Hosts")).tag(Choice.trusted)
        .disabled(!grant.allowsNetwork(.trusted))
      Text(verbatim: l("Any Host")).tag(Choice.full)
        .disabled(!grant.allowsNetwork(.full))
      if case .custom = network {
        let hosts = PrivacyGrantRow.networkValue(network, using: l)
        Text(verbatim: hosts).tag(Choice.custom)
      }
      Divider()
      Text(verbatim: l("Custom…")).tag(Choice.edit)
    } label: {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: l("Network"))
          let notices = grant.networkLimitNotices.filter(\.isPerRow)
          if !notices.isEmpty {
            let caption = notices.map { $0.text(using: l) }.joined(separator: " · ")
            Text(verbatim: caption).font(.caption).foregroundStyle(.secondary)
          }
        }
      } icon: {
        PrivacySymbol(name: "globe")
      }
    }
    .disabled(managed)
    .accessibilityIdentifier("privacy.network.\(grant.id)")
    .sheet(item: $customEdit) { edit in
      PrivacyNetworkSheet(
        network: edit.grant.network ?? .none, grant: edit.grant,
        failureMessage: { model.failure }
      ) { network in
        await model.setNetwork(edit.grant, to: network, reviewed: edit.snapshot)
      }
    }
  }

  private var network: PrivacyNetworkAccess { grant.network ?? PrivacyNetworkAccess.none }

  private var managed: Bool {
    grant.networkLimits.contains(.none)
  }

  private var selection: Binding<Choice> {
    Binding(
      get: {
        switch network {
        case .none: .none
        case .trusted: .trusted
        case .full: .full
        case .custom: .custom
        }
      },
      set: { choice in
        let access: PrivacyNetworkAccess
        switch choice {
        case .none: access = PrivacyNetworkAccess.none
        case .trusted: access = .trusted
        case .full: access = .full
        case .custom: return
        case .edit:
          customEdit = PrivacyNetworkEdit(grant: grant, snapshot: model.snapshot)
          return
        }
        guard grant.allowsNetwork(access) else { return }
        let reviewed = model.snapshot
        Task { await model.setNetwork(grant, to: access, reviewed: reviewed) }
      })
  }
}

struct PrivacyNetworkEdit: Identifiable {
  let id = UUID()
  let grant: PrivacyGrant
  let snapshot: PrivacySnapshot
}

struct PrivacyNetworkSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { PrivacyText(locale: locale, resources: resources) }
  @State private var draft: PrivacyNetworkDraft
  @State private var failure: String?
  @State private var saving = false
  let grant: PrivacyGrant?
  let failureMessage: () -> String?
  let save: (PrivacyNetworkAccess) async -> Bool

  init(
    network: PrivacyNetworkAccess, grant: PrivacyGrant? = nil,
    failureMessage: @escaping () -> String? = { nil },
    save: @escaping (PrivacyNetworkAccess) async -> Bool
  ) {
    self.grant = grant
    self.failureMessage = failureMessage
    _draft = State(initialValue: PrivacyNetworkDraft(network))
    self.save = save
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(verbatim: l("Custom Network Access")).font(.headline)
      Text(verbatim: l("Hosts")).font(.subheadline)
      TextEditor(text: $draft.hosts)
        .font(.body.monospaced())
        .frame(height: 120)
        .border(Color.secondary.opacity(0.25))
        .accessibilityLabel(l("Hosts"))
      Text(
        verbatim: l(
          "Enter one host per line or separate hosts with commas. Use *. to include subdomains.")
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Toggle(l("Include trusted hosts"), isOn: $draft.includesTrusted)
        .disabled(grant?.allowsNetwork(.trusted) == false)
      if let failure {
        Text(verbatim: failure).foregroundStyle(.red).font(.callout)
      }
      HStack {
        Spacer()
        Button(l("Cancel"), role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(l("Save")) {
          let network: PrivacyNetworkAccess
          do {
            network = try draft.network()
          } catch {
            failure = AppLocalization.errorDescription(error)
            return
          }
          guard grant?.allowsNetwork(network) != false else {
            failure = l("This network access is not allowed by the managed limits.")
            return
          }
          saving = true
          Task {
            if await save(network) {
              dismiss()
            } else {
              failure = failureMessage() ?? l("The change couldn't be made.")
            }
            saving = false
          }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 440)
    .disabled(saving)
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
        if let path = request.object?.detail {
          Text(verbatim: path)
            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            .lineLimit(2).truncationMode(.middle)
            .help(Text(verbatim: path))
            .accessibilityIdentifier("privacy.prompt.path")
        }
        let requester = Self.requesterCaption(for: request, using: l)
        Text(verbatim: requester).font(.caption).foregroundStyle(.secondary)
        if let purpose = request.purpose {
          Text(verbatim: purpose)
            .multilineTextAlignment(.center)
        }
        let detail = Self.detail(for: request, using: l)
        Text(verbatim: detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        if request.registration == nil {
          Text(
            verbatim: l(
              "Only This Time covers the retried request and the program it starts.")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          if case .client = request.principal.kind {
            let shared = l.format(
              "Always applies to every connection that uses “%@”.", request.principal.name)
            Text(verbatim: shared).font(.caption).foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
        }
      }
      VStack(spacing: 8) {
        if request.registration == nil {
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
        } else {
          Button {
            answer(.always)
          } label: {
            Text(verbatim: l("Allow")).frame(maxWidth: .infinity)
          }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("privacy.prompt.allow")
        }
        Button(role: .cancel) {
          answer(.dontAllow)
        } label: {
          Text(verbatim: l("Don't Allow")).frame(maxWidth: .infinity)
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("privacy.prompt.deny")
      }
      .controlSize(.large)
    }
    .padding(24)
    .frame(width: 340)
  }

  static func requesterCaption(for request: PrivacyRequest, using l: PrivacyText) -> String {
    let connection: String
    switch request.principal.kind {
    case .client(let name): connection = l(name)
    case .plugin: connection = l("Plugin")
    case .localServer: connection = l("Local MCP Server")
    }
    return request.tool + " · " + connection
  }

  static func detail(for request: PrivacyRequest, using l: PrivacyText) -> String {
    if request.host != nil {
      return l("Allowing adds the host to the project's network access in the sandbox.")
    }
    switch request.registration {
    case .newProject:
      return l.format(
        "Allowing registers this folder as a project and gives “%@” access to it and its worktrees until you revoke it.",
        request.principal.name)
    case .existingProject:
      return l.format(
        "Allowing gives “%@” access to this project and all its worktrees until you revoke it.",
        request.principal.name)
    case nil:
      return l(request.permission.summary)
    }
  }

  static func requestSentence(for request: PrivacyRequest, using l: PrivacyText) -> String {
    let name = request.object?.name ?? request.permission.title
    let object =
      request.object == nil || request.permission == .filesAndFolders || request.object?.id == "*"
      ? l(name) : name
    if let host = request.host {
      return l.format(
        "“%1$@” would like to connect to “%2$@” from “%3$@”.", request.principal.name, host, object)
    }
    switch request.level {
    case .readWrite:
      return l.format(
        "“%1$@” would like to read and change “%2$@”.", request.principal.name, object)
    case .read:
      return l.format(
        "“%1$@” would like to read “%2$@”.", request.principal.name, object)
    default:
      return l.format(
        "“%1$@” would like to use “%2$@”.", request.principal.name, object)
    }
  }
}

struct PrivacyClientExecutionLabel: View {
  @ObservedObject var model: ClientAccessModel
  let principal: PrivacyPrincipal
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources

  var body: some View {
    let l = PrivacyText(locale: locale, resources: resources)
    let title = l(model.privacyExecutionTitle(for: principal))
    Text(verbatim: title).foregroundStyle(.secondary)
  }
}

struct PrivacyConnectionsSection: View {
  @ObservedObject var model: ClientAccessModel
  let principal: PrivacyPrincipal
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { PrivacyText(locale: locale, resources: resources) }

  var body: some View {
    Group {
      connections
      savedApprovals
    }
    .disabled(!model.isAvailable || model.isSaving)
    .sheet(item: $model.pendingConsent) { draft in
      ClientConsentView(model: model, draftID: draft.id)
    }
  }

  private var connections: some View {
    Section(l("Connections")) {
      if let error = model.errorMessage {
        Text(verbatim: error).foregroundStyle(.red)
      }
      let sessions = model.activeSessions.filter { $0.profileID.rawValue == principal.id }
      if sessions.isEmpty {
        Text(verbatim: l("No connected clients")).foregroundStyle(.secondary)
      }
      ForEach(sessions) { session in
        LabeledContent {
          HStack(spacing: 8) {
            let status = l(session.privacyExecutionTitle)
            Text(verbatim: status).foregroundStyle(.secondary)
            if session.fullAccessConsent == nil {
              Button(l("Give Full Access…")) { model.requestFullAccess(session) }
                .disabled(
                  principal.execution == .sandbox || !principal.fullAccessLimitSources.isEmpty
                    || !session.accessLimit.allowsFullAccess
                    || session.profile?.grant.fullAccess != true)
            }
          }
        } label: {
          let connection = l(LivePrivacySecurityService.connectionName(session.caller))
          Text(verbatim: connection)
          let identity = clientAccessIdentity(session.principalID, using: l)
          Text(verbatim: identity).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private var savedApprovals: some View {
    let trusts = (model.snapshot?.trusts ?? []).filter {
      $0.profileID.rawValue == principal.id && $0.fullAccessAllowed
    }
    if !trusts.isEmpty {
      Section(l("Saved client approvals")) {
        ForEach(trusts) { trust in
          LabeledContent {
            Button(l("Revoke")) { Task { await model.revoke(trust) } }
          } label: {
            let identity = clientAccessIdentity(trust.principalID, using: l)
            Text(verbatim: identity)
            let caller = l(LivePrivacySecurityService.connectionName(trust.caller))
            Text(verbatim: caller).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

/// One notice for policy sources that can't be read, instead of a caption on every row they
/// disable.
struct PrivacyUnreadableNotice: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { PrivacyText(locale: locale, resources: resources) }
  let grants: [PrivacyGrant]

  var body: some View {
    let sources = Set(
      grants.flatMap { $0.limitNotices + $0.networkLimitNotices }
        .filter { !$0.isPerRow }.map(\.source)
    ).sorted()
    if !sources.isEmpty {
      Section {
        Label {
          let names = l.list(sources.map { l($0) })
          let text = l.format(
            "%@ can't be read. Until it can, nothing it limits is allowed; the settings below apply again once it can be read.",
            names)
          Text(verbatim: text)
        } icon: {
          PrivacySymbol(name: "exclamationmark.triangle.fill")
        }
      }
    }
  }
}

extension PrivacyLimitNotice {
  /// Unreadable sources disable everything they could limit and are explained once per page.
  var isPerRow: Bool {
    if case .unreadable = effect { false } else { true }
  }

  func text(using l: PrivacyText) -> String {
    switch effect {
    case .unreadable:
      l.format("Not allowed while %@ can't be read", l(source))
    case .permission(let level):
      if let level {
        l.format("%@ allows at most %@", l(source), l(level.title))
      } else {
        l.format("Not allowed by %@", l(source))
      }
    case .network(let network):
      l.format("%@ allows at most %@", l(source), PrivacyGrantRow.networkValue(network, using: l))
    }
  }
}
