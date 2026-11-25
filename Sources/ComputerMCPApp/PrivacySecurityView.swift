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
  case grantSource(principalID: String, permission: PrivacyPermissionKind, objectID: String?)
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
        case .grantSource(let id, let permission, let objectID):
          PrivacyGrantSourceView(
            model: model, principalID: id, permission: permission, objectID: objectID)
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
      PrivacyRequestPrompt(
        request: request,
        pluginExecutionTargets: Self.pluginExecutionTargets(for: request, in: promptedSnapshot)
      ) { answer in
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
              Text(
                verbatim: l(
                  request.registration == nil
                    ? request.permission.title : "grant.projectRegistration.title")
              )
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
    Section(l("Clients, Plugins, and Local Servers")) {
      if model.snapshot.principals.isEmpty {
        Text(verbatim: l("No clients, plugins, or local servers are available."))
          .foregroundStyle(.secondary)
      }
      ForEach(model.snapshot.principals) { principal in
        NavigationLink(value: PrivacyRoute.principal(principal.id)) {
          PrincipalSummaryRow(principal: principal)
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

  static func pluginExecutionTargets(
    for request: PrivacyRequest, in snapshot: PrivacySnapshot
  ) -> [PrivacyPrincipal] {
    guard request.permission == .plugins, case .client = request.principal.kind,
      let objectID = request.object?.id
    else { return [] }
    return snapshot.plugins(forUseOf: objectID)
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
      PrivacyUnreadableNotice(grants: model.grants(for: permission, includingUnset: true))
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
      let grants = model.grants(for: permission, includingUnset: true)
      if model.snapshot.principals.isEmpty { emptyRow }
      ForEach(model.snapshot.principals) { principal in
        if let grant = grants.first(where: { $0.principalID == principal.id }) {
          PrivacyGrantRow(
            model: model, grant: grant, title: principal.name, systemImage: principal.systemImage)
        } else {
          PrincipalSummaryRow(principal: principal)
        }
      }
    }
  }

  private var perObjectSections: some View {
    Section {
      let grants = model.grants(for: permission, includingUnset: true)
      if model.snapshot.principals.isEmpty { emptyRow }
      ForEach(model.snapshot.principals) { principal in
        let rows = grants.filter { $0.principalID == principal.id }
        if rows.isEmpty {
          PrincipalSummaryRow(principal: principal)
        } else {
          DisclosureGroup(isExpanded: expansion(principal.id)) {
            ForEach(rows) { grant in
              PrivacyGrantRow(
                model: model, grant: grant, title: grant.object?.name,
                systemImage: permission.systemImage(for: grant.object)
              )
              .padding(.leading, 24)
              .help(Text(verbatim: grant.object?.detail ?? ""))
              if grant.showsNetwork {
                PrivacyNetworkPicker(model: model, grant: grant).padding(.leading, 52)
              }
            }
          } label: {
            PrincipalSummaryRow(principal: principal)
          }
          .accessibilityIdentifier("privacy.holder.\(principal.id)")
        }
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
    Group {
      if model.snapshot.principals.isEmpty { Section { emptyRow } }
      ForEach(model.snapshot.principals) { principal in
        Section {
          PrivacyExecutionRow(model: model, principal: principal, showsName: true)
        }
      }
    }
  }

  private var emptyRow: some View {
    Text(verbatim: l("No clients, plugins, or local servers are available."))
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

  private var rowTitle: String {
    let name = title ?? grant.object?.name ?? l(grant.permission.title)
    return grant.object?.id == "*" || grant.permission == .filesAndFolders ? l(name) : name
  }

  var body: some View {
    PermissionGrantRow(
      title: rowTitle, symbol: systemImage ?? grant.permission.systemImage,
      saved: l(grant.value.title), effective: grant.effectiveValue.map { l($0.title) },
      explanation: caption,
      isInherited: grant.inheritsProjectAuthority || usesWildcard
        || model.principal(grant.principalID)?.sharedProfileID != nil,
      isLimited: grant.effectiveValue != grant.value
    ) {
      if let source = model.sourceGrant(for: grant) {
        PrivacyEditSourceLink(
          route: .grantSource(
            principalID: source.principalID, permission: source.permission,
            objectID: source.object?.id))
      } else if model.canEdit(grant) {
        HStack(spacing: 8) {
          grantPicker
          if case .granted = grant.value, let principal = model.principal(grant.principalID) {
            PrivacyRevocationButton(
              principalName: principal.name,
              permissionTitle: grant.object == nil ? l(grant.permission.title) : rowTitle,
              snapshot: model.snapshot
            ) { reviewed in
              Task { await model.set(grant, to: .denied, reviewed: reviewed) }
            }
            .accessibilityIdentifier("privacy.revoke-grant.\(grant.id)")
          }
        }
      }
    }
    .accessibilityIdentifier("privacy.grant.\(grant.id)")
  }

  private var grantPicker: some View {
    Picker(rowTitle, selection: binding) {
      if let inheritedTitle = Self.inheritedTitle(grant, using: l) {
        Text(verbatim: inheritedTitle).tag(PrivacyGrantChoice.inherited)
          .disabled(!grant.allowsInheritance)
        Divider()
      }
      Text(verbatim: l("grant.choice.askEveryTime")).tag(PrivacyGrantChoice.explicit(.ask))
      ForEach(grant.permission.grantedValues, id: \.self) { level in
        Text(verbatim: l(level.title)).tag(PrivacyGrantChoice.explicit(.granted(level)))
          .disabled(!grant.availableLevels.contains(level) || grant.object?.isRegistered == false)
      }
      Text(verbatim: l("grant.choice.dontAllow")).tag(PrivacyGrantChoice.explicit(.denied))
    }
    .labelsHidden().pickerStyle(.menu)
    .accessibilityLabel(rowTitle)
    .accessibilityValue(
      l.format(
        "grant.a11y.savedAndEffective", l(grant.value.title),
        grant.effectiveValue.map { l($0.title) } ?? l("grant.status.unavailable"))
    )
    .accessibilityIdentifier("privacy.grant-picker.\(grant.id)")
  }

  private var caption: String? {
    var parts: [String] = []
    let principal = model.principal(grant.principalID)
    if let principal, !grant.permission.isPerObject {
      parts.append(l(principal.kindTitle))
    }
    if let status = principal?.availabilityTitle { parts.append(l(status)) }
    if grant.object?.isRegistered == false { parts.append(l("Not registered")) }
    if grant.inheritsProjectAuthority, let source = model.sourceGrant(for: grant)?.object {
      parts.append(l.format("Inherited from project %@", source.name))
    }
    if let id = principal?.sharedProfileID?.rawValue {
      parts.append(l.format("Shared profile: %@", model.principal(id)?.name ?? id))
    } else if !grant.inheritsProjectAuthority {
      if usesWildcard, let wildcard = Self.inheritedTitle(grant, using: l) {
        parts.append(wildcard)
      } else if grant.isStored {
        parts.append(l(grant.source == .owner ? "Saved by the owner" : "Declared by the plugin"))
      } else if grant.object?.isRegistered != false {
        parts.append(l("Default setting"))
      }
    }
    if let levels = grant.declarationLevels {
      if let highest = levels.last {
        parts.append(l.format("Plugin declaration allows at most %@", l(highest.title)))
      } else {
        parts.append(l("Permission outside plugin declarations"))
      }
    }
    parts += grant.limitNotices.filter(\.isPerRow).map { $0.text(using: l) }
    if let execution = Self.pluginExecutionSummary(for: pluginExecutionTargets, using: l) {
      parts.append(execution)
      parts.append(Self.pluginExecutionExplanation(for: pluginExecutionTargets, using: l))
    }
    return parts.isEmpty ? nil : parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private var usesWildcard: Bool {
    grant.choice == .inherited
      && model.grant(
        principalID: grant.principalID, permission: grant.permission, objectID: "*")?.isStored
        == true
  }

  private var pluginExecutionTargets: [PrivacyPrincipal] {
    guard grant.permission == .plugins,
      let principal = model.snapshot.principals.first(where: { $0.id == grant.principalID }),
      case .client = principal.kind,
      let objectID = grant.object?.id
    else { return [] }
    return model.snapshot.plugins(forUseOf: objectID)
  }

  static func pluginExecutionSummary(
    for targets: [PrivacyPrincipal], using l: PrivacyText
  ) -> String? {
    guard !targets.isEmpty else { return nil }
    let active = targets.filter { $0.effectiveExecution != nil }
    let fullAccess = active.filter { $0.effectiveExecution == .fullAccessAllowed }
    var parts: [String] = []
    if !active.isEmpty {
      if fullAccess.isEmpty {
        parts.append(l("Execution: Sandbox"))
      } else if fullAccess.count == active.count {
        parts.append(l("Execution: Full Access"))
      } else {
        parts.append(l.format("Sandbox and Full Access (%@)", l.list(fullAccess.map(\.name))))
      }
    }
    let inactive = targets.filter { $0.effectiveExecution == nil }
    if !inactive.isEmpty {
      parts.append(l.format("Inactive plugins: %@", l.list(inactive.map(\.name))))
    }
    return parts.joined(separator: " · ")
  }

  static func pluginExecutionExplanation(
    for targets: [PrivacyPrincipal], using l: PrivacyText
  ) -> String {
    let modes = Set(targets.compactMap(\.effectiveExecution))
    var details: [String] = []
    if modes.contains(.sandbox) {
      details.append(
        l(
          "Sandboxed plugins keep their files private from other principals’ host tools and sandboxed programs."
        ))
    }
    if modes.contains(.fullAccessAllowed) {
      details.append(l("Full Access plugins run outside the sandbox as your user account."))
    }
    return details.joined(separator: " ")
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
    let reviewed = model.snapshot
    return Binding(
      get: { grant.choice },
      set: { choice in
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

  var body: some View {
    if let principal = model.principal(principalID) {
      Form {
        Section { PrincipalSummaryRow(principal: principal) }
        PrivacyUnreadableNotice(grants: model.grants(for: principal))
        Section { PrivacyExecutionRow(model: model, principal: principal) }
        if case .client = principal.kind, let clientAccess = model.clientAccess {
          PrivacyConnectionsSection(
            model: clientAccess, principal: principal,
            verifiedClientID: verifiedClientID(for: principal))
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
                systemImage: kind.systemImage(for: grant.object))
              if grant.showsNetwork {
                PrivacyNetworkPicker(model: model, grant: grant).padding(.leading, 28)
              }
            }
          }
        }
        if canRevoke(principal) {
          Section {
            PrivacyRevocationButton(
              principalName: principal.name, permissionTitle: nil, snapshot: model.snapshot
            ) { reviewed in
              Task { await model.revokeAll(principal, reviewed: reviewed) }
            }
            .accessibilityIdentifier("privacy.revoke.\(principal.id)")
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(principal.name)
    } else {
      ContentUnavailableView(
        l("This principal is no longer available."), systemImage: "questionmark.circle")
    }
  }

  private func verifiedClientID(for principal: PrivacyPrincipal) -> String? {
    guard case .client(let id) = model.snapshot.clientSubjects[principal.id]?.principal else {
      return nil
    }
    return id
  }

  private func canRevoke(_ principal: PrivacyPrincipal) -> Bool {
    if let provider = model.snapshot.reviewedProviders[principal.id] {
      return provider.approval?.enabled == true && provider.epoch != nil
    }
    return principal.sharedProfileID == nil && principal.availabilityTitle == nil
  }

  static func principalSummary(for principal: PrivacyPrincipal, using l: PrivacyText) -> String {
    var parts = [l(principal.kindTitle)]
    switch principal.kind {
    case .client(let connection): parts.append(l(connection))
    case .plugin(let version): parts.append(version)
    case .localServer: break
    }
    return parts.joined(separator: " · ")
  }

  static func executionTitle(_ execution: PrivacyPrincipal.Execution) -> String {
    switch execution {
    case .sandbox: "Sandbox"
    case .fullAccessAllowed: "Full Access Allowed"
    }
  }

}

struct PrivacyGrantSourceView: View {
  @ObservedObject var model: PrivacySecurityModel
  let principalID: String
  let permission: PrivacyPermissionKind
  let objectID: String?

  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources

  var body: some View {
    let l = PrivacyText(locale: locale, resources: resources)
    Form {
      if let principal = model.principal(principalID),
        let grant = model.grant(
          principalID: principalID, permission: permission, objectID: objectID)
      {
        Section { PrincipalSummaryRow(principal: principal) }
        PrivacyUnreadableNotice(grants: [grant])
        Section(l(permission.title)) {
          PrivacyGrantRow(
            model: model, grant: grant, title: nil,
            systemImage: permission.systemImage(for: grant.object))
          if grant.showsNetwork { PrivacyNetworkPicker(model: model, grant: grant) }
        }
      } else {
        ContentUnavailableView(
          l("Permission source unavailable"), systemImage: "questionmark.circle")
      }
    }
    .formStyle(.grouped)
    .navigationTitle(l("Permission Source"))
  }
}

struct PrivacyExecutionRow: View {
  @ObservedObject var model: PrivacySecurityModel
  let principal: PrivacyPrincipal
  var showsName = false

  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  @State private var fullAccessReview: PrivacySnapshot?
  private var l: PrivacyText { PrivacyText(locale: locale, resources: resources) }

  var body: some View {
    PermissionGrantRow(
      title: showsName ? principal.name : l("Execution"),
      symbol: showsName ? principal.systemImage : "lock.open.fill",
      saved: savedTitle, effective: effectiveTitle,
      explanation: explanation, isInherited: principal.sharedProfileID != nil,
      isLimited: !principal.fullAccessLimitSources.isEmpty
    ) {
      if let id = principal.sharedProfileID?.rawValue, model.principal(id) != nil {
        VStack(alignment: .trailing, spacing: 4) {
          PrivacyEditSourceLink(route: .principal(id))
          if showsName, model.clientAccess != nil {
            NavigationLink(l("Connections"), value: PrivacyRoute.principal(principal.id))
              .buttonStyle(.link)
          }
        }
      } else if canChangeMode {
        Picker(l("Execution"), selection: selection) {
          Text(verbatim: l("Sandbox")).tag(PrivacyPrincipal.Execution.sandbox)
          Text(verbatim: l("Full Access Allowed")).tag(PrivacyPrincipal.Execution.fullAccessAllowed)
            .disabled(!principal.fullAccessLimitSources.isEmpty)
        }
        .labelsHidden().pickerStyle(.menu)
        .accessibilityLabel(l("Execution"))
        .accessibilityIdentifier("privacy.execution.\(principal.id)")
      } else if case .plugin = principal.kind, principal.execution == .fullAccessAllowed,
        model.snapshot.reviewedProviders[principal.id]?.approval?.enabled == true
      {
        PrivacyRevocationButton(
          principalName: principal.name, permissionTitle: nil, snapshot: model.snapshot
        ) { reviewed in
          Task { await model.revokeAll(principal, reviewed: reviewed) }
        }
      }
    }
    .confirmationDialog(
      l.format("Give “%@” Full Access?", principal.name),
      isPresented: Binding(
        get: { fullAccessReview != nil }, set: { if !$0 { fullAccessReview = nil } }),
      presenting: fullAccessReview
    ) { reviewed in
      Button(l("Give Full Access"), role: .destructive) {
        Task { await model.setExecution(principal, .fullAccessAllowed, reviewed: reviewed) }
      }
    } message: { _ in
      Text(verbatim: l(PrivacyPermissionKind.fullAccess.summary))
      if case .localServer = principal.kind {
        Text(verbatim: l("Switching to Full Access clears this server’s saved sandbox settings."))
      }
    }
  }

  private var canChangeMode: Bool {
    guard principal.sharedProfileID == nil, principal.availabilityTitle == nil else { return false }
    if case .plugin = principal.kind { return false }
    return true
  }

  private var savedTitle: String {
    if principal.providerAvailability != nil {
      if model.snapshot.reviewedProviders[principal.id]?.approval == nil { return l("No approval") }
      if principal.execution == .fullAccessAllowed { return l("Full Access") }
    }
    return l(PrivacyPrincipalDetailView.executionTitle(principal.execution))
  }

  private var effectiveTitle: String? {
    guard principal.availabilityTitle == nil else { return nil }
    if principal.effectiveExecution == .fullAccessAllowed { return l("Full Access") }
    if principal.providerAvailability != nil && principal.effectiveExecution == nil { return nil }
    if case .client = principal.kind, principal.sharedProfileID == nil {
      if let access = model.clientAccess, access.isAvailable {
        let modes = Set(
          access.activeSessions.filter { $0.profileID.rawValue == principal.id }
            .map(\.privacyExecutionTitle))
        if !modes.isEmpty { return l.list(modes.sorted().map { l($0) }) }
      }
      return l(
        principal.fullAccessLimitSources.isEmpty && principal.execution == .fullAccessAllowed
          ? "Requires connection approval" : "Sandbox")
    }
    return l("Sandbox")
  }

  private var explanation: String {
    var parts: [String] = []
    if showsName { parts.append(l(principal.kindTitle)) }
    if let status = principal.availabilityTitle { parts.append(l(status)) }
    if let id = principal.sharedProfileID?.rawValue {
      parts.append(l.format("Shared profile: %@", model.principal(id)?.name ?? id))
    }
    if !principal.fullAccessLimitSources.isEmpty {
      parts.append(l.format("Set by %@", l.list(principal.fullAccessLimitSources.map { l($0) })))
    }
    switch principal.kind {
    case .client:
      parts.append(
        l("Each connection needs approval on this Mac before programs can run without the sandbox.")
      )
    case .plugin:
      parts.append(l("Plugin execution mode is set when you review its declarations."))
    case .localServer:
      if principal.execution == .sandbox {
        parts.append(l("Sandboxed local servers use a private container for their state."))
      }
    }
    if principal.execution == .fullAccessAllowed {
      parts.append(l(PrivacyPermissionKind.fullAccess.summary))
    } else if case .client = principal.kind {
      parts.append(l("Programs run in the sandbox and change projects only in worktrees."))
    }
    return parts.joined(separator: " · ")
  }

  private var selection: Binding<PrivacyPrincipal.Execution> {
    Binding(
      get: { principal.execution },
      set: { mode in
        guard mode != principal.execution else { return }
        let reviewed = model.snapshot
        if mode == .fullAccessAllowed {
          fullAccessReview = reviewed
        } else {
          Task { await model.setExecution(principal, .sandbox, reviewed: reviewed) }
        }
      })
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
    PermissionGrantRow(
      title: l("Network"), symbol: "globe", saved: PrivacyGrantRow.networkValue(network, using: l),
      effective: grant.effectiveNetwork.map { PrivacyGrantRow.networkValue($0, using: l) },
      explanation: explanation,
      isInherited: grant.inheritsProjectAuthority || !grant.isNetworkStored,
      isLimited: grant.effectiveNetwork != grant.network
    ) {
      if canEdit {
        Picker(l("Network"), selection: selection) {
          Text(verbatim: l("None")).tag(Choice.none)
          Text(verbatim: l("Trusted Hosts")).tag(Choice.trusted)
            .disabled(!grant.allowsNetwork(.trusted))
          Text(verbatim: l("Any Host")).tag(Choice.full)
            .disabled(!grant.allowsNetwork(.full))
          if case .custom = network {
            Text(verbatim: PrivacyGrantRow.networkValue(network, using: l)).tag(Choice.custom)
          }
          Divider()
          Text(verbatim: l("Custom…")).tag(Choice.edit)
            .disabled(grant.networkLimits.contains(.none))
        }
        .labelsHidden().pickerStyle(.menu)
        .accessibilityLabel(l("Network"))
      }
    }
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

  private var canEdit: Bool {
    guard model.canEdit(grant) else { return false }
    let principal = model.principal(grant.principalID)
    return principal?.providerAvailability == nil || principal?.effectiveExecution == .sandbox
  }

  private var explanation: String? {
    var parts = grant.networkLimitNotices.filter(\.isPerRow).map { $0.text(using: l) }
    if !grant.isNetworkStored && !grant.inheritsProjectAuthority && grant.object?.id != "*" {
      parts.append(l("Uses the default project network setting"))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
  let pluginExecutionTargets: [PrivacyPrincipal]
  let answer: (PrivacyRequestAnswer) -> Void

  init(
    request: PrivacyRequest,
    pluginExecutionTargets: [PrivacyPrincipal] = [],
    answer: @escaping (PrivacyRequestAnswer) -> Void
  ) {
    self.request = request
    self.pluginExecutionTargets = pluginExecutionTargets
    self.answer = answer
  }

  var body: some View {
    VStack(spacing: 16) {
      ViewThatFits(in: .vertical) {
        requestContent.fixedSize(horizontal: false, vertical: true)
        ScrollView { requestContent }
      }
      VStack(spacing: 8) {
        ForEach(request.approvalAnswers, id: \.self) { choice in
          if choice == .onlyThisTime {
            approvalButton(choice, title: l("Only This Time"), identifier: "once")
              .keyboardShortcut(.defaultAction)
          } else if request.registration != nil {
            approvalButton(choice, title: l("grant.choice.allow"), identifier: "allow")
              .keyboardShortcut(.defaultAction)
          } else {
            approvalButton(choice, title: l("Always"), identifier: "always")
          }
        }
        Button(role: .cancel) {
          answer(.dontAllow)
        } label: {
          Text(verbatim: l("grant.choice.dontAllow")).frame(maxWidth: .infinity)
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("privacy.prompt.deny")
      }
      .controlSize(.large)
    }
    .padding(24)
    .frame(width: 340)
  }

  private var requestContent: some View {
    VStack(spacing: 8) {
      Image(systemName: request.principal.systemImage)
        .symbolRenderingMode(.multicolor)
        .font(.system(size: 36))
        .accessibilityHidden(true)
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
        if let executionContext = PrivacyGrantRow.pluginExecutionSummary(
          for: pluginExecutionTargets, using: l)
        {
          VStack(spacing: 3) {
            Text(verbatim: executionContext)
              .accessibilityIdentifier("privacy.prompt.execution")
            let explanation = PrivacyGrantRow.pluginExecutionExplanation(
              for: pluginExecutionTargets, using: l)
            Text(verbatim: explanation)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        }
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
          Text(verbatim: l("grant.oneTime.retryClarification"))
            .font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Text(verbatim: l("Only This Time covers the retried request and the program it starts."))
            .font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          if let profile = request.sharedProfileName {
            Text(verbatim: l.format("Always applies to every connection that uses “%@”.", profile))
              .font(.caption).foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func approvalButton(_ choice: PrivacyRequestAnswer, title: String, identifier: String)
    -> some View
  {
    Button {
      answer(choice)
    } label: {
      Text(verbatim: title).frame(maxWidth: .infinity)
    }
    .accessibilityIdentifier("privacy.prompt.\(identifier)")
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
      return l("Always adds this host to the project’s saved network access.")
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
  var verifiedClientID: String?
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
      let sessions = model.activeSessions.filter { session in
        session.profileID.rawValue == (principal.sharedProfileID?.rawValue ?? principal.id)
          && (verifiedClientID.map { id in session.principalID == id } ?? true)
      }
      if sessions.isEmpty {
        Text(verbatim: l("No connected clients")).foregroundStyle(.secondary)
      }
      ForEach(sessions) { session in
        LabeledContent {
          HStack(spacing: 8) {
            let status = l(session.privacyExecutionTitle)
            Text(verbatim: status).foregroundStyle(.secondary)
            if session.privacyExecutionTitle != "Sandbox" {
              Button(l("Use Sandbox")) { Task { await model.useSandbox(session) } }
            } else if session.fullAccessConsent == nil {
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
    let trusts = (model.snapshot?.trusts ?? []).filter { trust in
      trust.profileID.rawValue == (principal.sharedProfileID?.rawValue ?? principal.id)
        && (verifiedClientID.map { trust.principalID == $0 } ?? true) && trust.fullAccessAllowed
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
