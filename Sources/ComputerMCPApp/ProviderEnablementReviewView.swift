import ComputerMCPConfiguration
import ComputerMCPControlPlane
import ComputerMCPGateway
import ComputerMCPPermissions
import ComputerMCPPlugins
import SwiftUI
import UniformTypeIdentifiers

struct ProviderEnablementReviewView: View {
  @Environment(\.locale) private var locale
  @Environment(\.localizationResources) private var resources
  private var l: PrivacyText { PrivacyText(locale: locale, resources: resources) }

  let review: ProviderEnablementReview
  let isBusy: Bool
  let onConfirm: (ProviderEnablementSelection) async -> Void
  let onDecline: () -> Void

  @State private var draft = EnablementDraft()
  @State private var readExceptions: [GatewayReadExceptionReview] = []
  @State private var readExceptionReplacements: [String: CanonicalPath] = [:]
  @State private var approvedReadExceptionPaths: Set<String> = []
  @State private var importingReplacement = false
  @State private var replacementTargetPath: String?
  @State private var editingCustomNetwork = false
  @State private var localError: String?
  @State private var submitting = false

  init(
    review: ProviderEnablementReview,
    isBusy: Bool,
    onConfirm: @escaping (ProviderEnablementSelection) async -> Void,
    onDecline: @escaping () -> Void
  ) {
    self.review = review
    self.isBusy = isBusy
    self.onConfirm = onConfirm
    self.onDecline = onDecline
  }

  private var busy: Bool { isBusy || submitting }

  private var declaredFullAccess: Bool { review.requestedMode != .sandbox }

  private var usesFullAccess: Bool { draft.fullAccess || declaredFullAccess }

  private var fullAccessIsRestricted: Bool {
    review.provider.limits.modeDenial(.fullAccess(.standing)) != nil
  }

  private var approvalIsBlocked: Bool {
    usesFullAccess && (!draft.fullAccessConsented || fullAccessIsRestricted)
  }

  private var contributionIDs: [String] {
    review.mcpContributionIDs.sorted()
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        providerHeaderSection
        containerAndExecutionSection
        permissionsSection
        if !contributionIDs.isEmpty {
          contributionRequirementsSection
        }
        if !usesFullAccess {
          sandboxNetworkSection
          if !(review.provider.declarations?.sandbox?.readExceptions ?? []).isEmpty {
            readExceptionsSection
          }
        }
      }
      .formStyle(.grouped)
      .disabled(busy)

      if let message = localError {
        Text(verbatim: message)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .accessibilityIdentifier("enablement.error")
      }

      Divider()

      HStack(spacing: 12) {
        Spacer()
        if busy {
          ProgressView().controlSize(.small)
        }
        Button(role: .cancel) {
          onDecline()
        } label: {
          Text(verbatim: l("Decline"))
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("enablement.decline")

        Button {
          confirmSelection()
        } label: {
          Text(verbatim: l("Approve & Enable"))
        }
        .keyboardShortcut(.defaultAction)
        .disabled(approvalIsBlocked)
        .accessibilityIdentifier("enablement.confirm")
      }
      .padding(16)
      .disabled(busy)
    }
    .frame(minWidth: 620, idealWidth: 680, minHeight: 540, idealHeight: 720)
    .interactiveDismissDisabled()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("enablement.review")
    .task(id: review.id) {
      reloadReadExceptions(with: [:])
    }
    .sheet(isPresented: $editingCustomNetwork) {
      PrivacyNetworkSheet(
        network: initialCustomNetwork,
        failureMessage: { l("This network access exceeds the reviewed limits.") }
      ) { network in
        guard allowsNetwork(network) else { return false }
        draft.network = network
        return true
      }
    }
    .fileImporter(
      isPresented: $importingReplacement,
      allowedContentTypes: [.item, .folder]
    ) { result in
      guard let declaredPath = replacementTargetPath else { return }
      replacementTargetPath = nil
      switch result {
      case .success(let url):
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
          var replacements = readExceptionReplacements
          replacements[declaredPath] = try CanonicalPath(url.path)
          reloadReadExceptions(with: replacements, changedPath: declaredPath)
        } catch {
          localError = AppLocalization.errorDescription(error)
        }
      case .failure(let error):
        localError = AppLocalization.errorDescription(error)
      }
    }
  }

  private var initialCustomNetwork: PrivacyNetworkAccess {
    if case .custom = draft.network {
      return draft.network
    }
    if let declaredNetwork, case .custom = declaredNetwork { return declaredNetwork }
    return draft.network
  }

  // MARK: - Provider Header

  private var providerHeaderSection: some View {
    Section {
      Label {
        VStack(alignment: .leading, spacing: 3) {
          Text(verbatim: review.provider.name)
            .font(.title3.weight(.semibold))
          Text(verbatim: providerSubtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } icon: {
        PrivacySymbol(name: providerSymbolName)
          .font(.title2)
      }

      if let availabilityNotice = availabilityNotice {
        Label {
          Text(verbatim: availabilityNotice)
            .foregroundStyle(.secondary)
        } icon: {
          PrivacySymbol(name: "exclamationmark.triangle.fill")
        }
        .accessibilityIdentifier("enablement.availabilityNotice")
      }

      if let server = review.localServer {
        if let command = server.command, !command.isEmpty {
          LabeledContent(l("Executable")) {
            Text(verbatim: command)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
          }
        } else if let url = server.url, !url.isEmpty {
          LabeledContent(l("Server URL")) {
            Text(verbatim: url)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        if let cwd = server.cwd, !cwd.isEmpty {
          LabeledContent(l("Working directory")) {
            Text(verbatim: cwd)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        LabeledContent(l("Allowed tools")) {
          Text(
            verbatim: server.allowAnyTool
              ? l("All current and future tools")
              : (server.allowedTools.isEmpty
                ? l("No tools selected")
                : server.allowedTools.joined(separator: ", "))
          )
          .foregroundStyle(.secondary)
        }
      }

      if review.provider.sourceDigest != nil || review.provider.declarationDigest != nil {
        DisclosureGroup(l("Verification details")) {
          if let sourceDigest = review.provider.sourceDigest {
            LabeledContent(l("Source digest")) {
              Text(verbatim: sourceDigest)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            }
          }
          if let declarationDigest = review.provider.declarationDigest {
            LabeledContent(l("Declaration digest")) {
              Text(verbatim: declarationDigest)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            }
          }
        }
      }
    } header: {
      Text(verbatim: l("Review Provider Enablement"))
    }
  }

  private var providerSymbolName: String {
    switch review.provider.identity {
    case .package: "puzzlepiece.extension.fill"
    case .localServer: "server.rack"
    }
  }

  private var providerSubtitle: String {
    var parts: [String] = []
    switch review.provider.identity {
    case .package(let id):
      parts.append(l("Plugin Package"))
      if id != review.provider.name { parts.append(id) }
    case .localServer(let id):
      parts.append(l("Local MCP Server"))
      if id != review.provider.name { parts.append(id) }
    }
    if let version = review.provider.version, !version.isEmpty {
      parts.append(version)
    }
    return parts.joined(separator: " · ")
  }

  private var availabilityNotice: String? {
    switch review.provider.availability {
    case .needsSourceReview:
      l(
        "The provider source changed since your previous approval. Review and confirm its permissions before enabling."
      )
    case .needsRestoreReview:
      l("Permissions were restored from an earlier state. Review and confirm them before enabling.")
    case .unavailable, .disabled, .needsApproval, .active:
      nil
    }
  }

  // MARK: - Container & Execution Mode

  private var containerAndExecutionSection: some View {
    Section {
      if review.allowsModeSelection {
        Picker(selection: fullAccessBinding) {
          Text(verbatim: l("Sandbox")).tag(false)
          Text(verbatim: l("Full Access")).tag(true).disabled(fullAccessIsRestricted)
        } label: {
          Text(verbatim: l("Execution"))
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("enablement.executionMode")

      } else {
        let mode = declaredFullAccess ? l.format("Requested: %@", l("Full Access")) : l("Sandbox")
        LabeledContent(l("Execution")) {
          Text(verbatim: mode).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("enablement.executionMode")
      }

      if !usesFullAccess {
        LabeledContent(l("Sandbox container")) {
          Text(verbatim: containerDisplayName)
            .font(.callout.monospaced())
            .textSelection(.enabled)
        }
        .accessibilityIdentifier("enablement.container")
        Text(verbatim: containerBehaviorDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let purpose = review.provider.declarations?.sandbox?.purpose, declaredFullAccess {
        LabeledContent(l("Declared purpose")) {
          Text(verbatim: purpose)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }

      if fullAccessIsRestricted && (review.allowsModeSelection || declaredFullAccess) {
        Text(verbatim: l("Managed limits prevent Full Access."))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if usesFullAccess && !fullAccessIsRestricted {
        VStack(alignment: .leading, spacing: 10) {
          Label {
            Text(
              verbatim: l(
                "Full Access runs this provider outside the sandbox with direct access to your Mac as your user account. Sandbox network and read-exception restrictions do not apply."
              )
            )
            .font(.callout)
            .foregroundStyle(.primary)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }

          Toggle(isOn: $draft.fullAccessConsented) {
            Text(
              verbatim: l(
                "I understand and consent on this Mac to run this provider with Full Access."
              )
            )
          }
          .accessibilityIdentifier("enablement.fullAccess.consent")
        }
        .padding(.vertical, 4)
      }
    } header: {
      Text(verbatim: l("Container & Execution"))
    }
  }

  private var fullAccessBinding: Binding<Bool> {
    Binding(
      get: { draft.fullAccess },
      set: { enabled in
        guard !enabled || !fullAccessIsRestricted else { return }
        draft.fullAccess = enabled
        if !enabled {
          draft.fullAccessConsented = false
        }
      }
    )
  }

  private var containerDisplayName: String {
    switch review.sandboxContainer {
    case .package(let id): id
    case .localServer(let id): id
    }
  }

  private var containerBehaviorDescription: String {
    switch review.sandboxContainer {
    case .package:
      l(
        "All MCP servers and CLIs contributed by this package share one provider sandbox container, along with its approved permissions, network access, and read exceptions."
      )
    case .localServer:
      l(
        "This local MCP server runs in its own provider sandbox container when Sandbox is selected, using the permissions, network access, and read exceptions approved here."
      )
    }
  }

  // MARK: - Permissions (Declared & Optional)

  @ViewBuilder
  private var permissionsSection: some View {
    let declared = review.provider.declarations?.permissions ?? []
    if !declared.isEmpty {
      Section {
        ForEach(Array(declared.enumerated()), id: \.offset) { _, declaration in
          declarationView(for: declaration)
        }
      } header: {
        Text(verbatim: l("Declared Permissions"))
      }
    } else {
      Section {
        Text(
          verbatim: review.localServer != nil
            ? l(
              "Local MCP registrations do not include a permission manifest. Permissions default to Ask unless granted below."
            )
            : l("This package does not declare additional permissions.")
        )
        .foregroundStyle(.secondary)

        if review.localServer != nil {
          DisclosureGroup(l("Optional initial permissions")) {
            perObjectPermissionBlock(kind: .project, declaration: nil)
            perObjectPermissionBlock(kind: .plugin, declaration: nil)
            perObjectPermissionBlock(kind: .mcpServer, declaration: nil)
          }
          .accessibilityIdentifier("enablement.optionalPermissions")
        }
      } header: {
        Text(verbatim: l("Permissions"))
      }
    }
  }

  @ViewBuilder
  private func declarationView(for declaration: PluginPermissionDeclaration) -> some View {
    switch declaration.id {
    case .project:
      perObjectPermissionBlock(kind: .project, declaration: declaration)
    case .plugin:
      perObjectPermissionBlock(kind: .plugin, declaration: declaration)
    case .mcpServer:
      perObjectPermissionBlock(kind: .mcpServer, declaration: declaration)
    case .filesAndFolders:
      if let folder = declaration.category {
        let kind = PrivacyPermissionKind.filesAndFolders
        let object = PrivacyObject(id: folder.value.rawValue, name: "", detail: nil)
        singlePermissionRow(
          declaration, permission: .filesAndFolders(folder.value),
          title: Self.folderTitle(for: folder),
          systemImage: kind.systemImage(for: object),
          id: "\(kind.rawValue).\(folder.value.rawValue)")
      }
    case .screen:
      singlePermissionRow(declaration, permission: .screen, kind: .screen)
    case .desktopControl:
      singlePermissionRow(declaration, permission: .desktopControl, kind: .desktopControl)
    case .localNetwork:
      singlePermissionRow(declaration, permission: .localNetwork, kind: .localNetwork)
    case .machine:
      singlePermissionRow(declaration, permission: .machineInformation, kind: .machineInformation)
    case .unifiedLogs:
      singlePermissionRow(declaration, permission: .unifiedLogs, kind: .unifiedLogs)
    case .skills:
      singlePermissionRow(declaration, permission: .skills, kind: .skills)
    }
  }

  private func singlePermissionRow(
    _ declaration: PluginPermissionDeclaration, permission: Permission, kind: PrivacyPermissionKind
  ) -> some View {
    singlePermissionRow(
      declaration, permission: permission, title: kind.title, systemImage: kind.systemImage,
      id: kind.rawValue)
  }

  private func singlePermissionRow(
    _ declaration: PluginPermissionDeclaration, permission: Permission, title: String,
    systemImage: String, id: String
  ) -> some View {
    permissionPicker(permission, levels: [declaration.value]) {
      Label {
        permissionHeading(title, declaration: declaration)
      } icon: {
        PrivacySymbol(name: systemImage)
      }
    }
    .accessibilityIdentifier("enablement.permission.\(id)")
  }

  private func permissionHeading(
    _ title: String, declaration: PluginPermissionDeclaration?
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: l(title))
      if let declaration {
        let requested = l.format(
          "Requested: %@", l(EnablementPermissionChoice.granted(declaration.value).title))
        Text(verbatim: requested)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(verbatim: declaration.purpose)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private enum PerObjectKind {
    case project
    case plugin
    case mcpServer

    var privacyKind: PrivacyPermissionKind {
      switch self {
      case .project: .projects
      case .plugin: .plugins
      case .mcpServer: .mcpServers
      }
    }

    var wildcardTitleKey: String {
      switch self {
      case .project: "All current and future projects"
      case .plugin: "All current and future plugins"
      case .mcpServer: "All current and future MCP servers"
      }
    }

    var levels: [PermissionValue] {
      switch self {
      case .project: [.read, .write]
      case .plugin: [.use]
      case .mcpServer: [.read, .all]
      }
    }

    func permission(for objectID: String) -> Permission {
      switch self {
      case .project: .project(objectID)
      case .plugin: .plugin(objectID)
      case .mcpServer: .mcpServer(objectID)
      }
    }
  }

  private func registeredObjects(for kind: PerObjectKind) -> [(id: String, name: String)] {
    let source: [String: String] =
      switch kind {
      case .project: review.names.projects
      case .plugin: review.names.plugins
      case .mcpServer: review.names.mcpServers
      }
    return
      source
      .filter { $0.key != "*" }
      .map { (id: $0.key, name: $0.value) }
      .sorted { lhs, rhs in
        let compare = lhs.name.localizedStandardCompare(rhs.name)
        return compare == .orderedSame ? lhs.id < rhs.id : compare == .orderedAscending
      }
  }

  private func perObjectPermissionBlock(
    kind: PerObjectKind, declaration: PluginPermissionDeclaration?
  ) -> some View {
    let objects = registeredObjects(for: kind)
    let wildcard = kind.permission(for: "*")
    let levels = kind.levels.filter { level in
      declaration.map { ComputerMCPPermissions.PermissionState.granted($0.value).allows(level) }
        ?? true
    }
    let identifier = "enablement.permission.\(kind.privacyKind.rawValue)"

    return VStack(alignment: .leading, spacing: 10) {
      Label {
        permissionHeading(kind.privacyKind.title, declaration: declaration)
      } icon: {
        PrivacySymbol(name: kind.privacyKind.systemImage)
      }
      VStack(alignment: .leading, spacing: 8) {
        ForEach(objects, id: \.id) { item in
          permissionPicker(kind.permission(for: item.id), levels: levels) {
            VStack(alignment: .leading, spacing: 1) {
              Text(verbatim: item.name)
              if item.id != item.name {
                Text(verbatim: item.id)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
              }
            }
          }
          .accessibilityIdentifier("\(identifier).object.\(item.id)")
        }
        if !objects.isEmpty { Divider() }
        permissionPicker(wildcard, levels: levels) {
          Text(verbatim: l(kind.wildcardTitleKey))
        }
        .accessibilityIdentifier("\(identifier).wildcard")
      }
      .padding(.leading, 28)
    }
    .padding(.vertical, 4)
  }

  private func permissionPicker<Title: View>(
    _ permission: Permission, levels: [PermissionValue], @ViewBuilder label: () -> Title
  ) -> some View {
    let limits = review.provider.limits
    let inherited = draft.inheritedChoice(for: permission)
    let selection = Binding(
      get: { draft.choice(for: permission) },
      set: {
        guard draft.allows($0, for: permission, limits: limits) else { return }
        draft.choices[permission] = $0 == .inherit ? nil : $0
      })
    let restricted =
      levels.contains { !draft.allows(.granted($0), for: permission, limits: limits) }
      || (inherited != nil && !draft.allows(.inherit, for: permission, limits: limits))
    return Picker(selection: selection) {
      if let inherited {
        let title = l.format("Use wildcard setting (%@)", l(inherited.title))
        Text(verbatim: title).tag(EnablementPermissionChoice.inherit)
          .disabled(!draft.allows(.inherit, for: permission, limits: limits))
      }
      Text(verbatim: l("Ask")).tag(EnablementPermissionChoice.ask)
      ForEach(levels, id: \.self) { level in
        let choice = EnablementPermissionChoice.granted(level)
        Text(verbatim: l(choice.title)).tag(choice)
          .disabled(!draft.allows(choice, for: permission, limits: limits))
      }
      Text(verbatim: l("Don't Allow")).tag(EnablementPermissionChoice.denied)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        label()
        if restricted {
          Text(verbatim: l("Managed limits restrict these choices."))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: - Contribution Requirements

  private var contributionRequirementsSection: some View {
    Section {
      ForEach(contributionIDs, id: \.self) { contributionID in
        let contribution = review.provider.declarations?.mcp[contributionID]
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: contributionID)
            .font(.headline)

          if let defaults = contribution?.requirements {
            LabeledContent(l("Default tool requirements")) {
              Text(verbatim: requirementsSummary(defaults))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          let toolEntries = (contribution?.toolRequirements ?? [:]).sorted { $0.key < $1.key }
          if !toolEntries.isEmpty {
            ForEach(toolEntries, id: \.key) { toolName, requirements in
              LabeledContent {
                Text(verbatim: requirementsSummary(requirements))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } label: {
                Text(verbatim: toolName)
                  .font(.system(.callout, design: .monospaced))
              }
              .padding(.leading, 12)
            }
          }

          if contribution?.requirements == nil && toolEntries.isEmpty {
            Text(verbatim: l("No specific tool requirements declared."))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("enablement.contribution.\(contributionID)")
      }
    } header: {
      Text(verbatim: l("Contribution Requirements"))
    }
  }

  private func requirementsSummary(_ requirements: PluginToolRequirements) -> String {
    var parts: [String] = []
    switch requirements.project {
    case .none:
      parts.append(l("Project: None"))
    case .read:
      parts.append(l("Project: Read"))
    case .write:
      parts.append(l("Project: Read & Write"))
    }
    if !requirements.permissions.isEmpty {
      let names = requirements.permissions.map { l(Self.privacyPermissionTitle($0)) }
      parts.append(l.list(names))
    }
    if !requirements.filesAndFolders.isEmpty {
      let folders = requirements.filesAndFolders.map { l(Self.folderTitle(for: $0)) }
      parts.append(l.format("Files & Folders: %@", l.list(folders)))
    }
    return parts.joined(separator: " · ")
  }

  // MARK: - Sandbox Network

  private enum NetworkPickerChoice: Hashable {
    case none
    case trusted
    case full
    case declaredCustom
    case custom
    case edit
  }

  private var declaredNetwork: PrivacyNetworkAccess? {
    guard let declared = review.provider.declarations?.sandbox?.network else { return nil }
    switch declared {
    case .none: return PrivacyNetworkAccess.none
    case .trusted: return .trusted
    case .full: return .full
    case .custom(let hosts, let includeTrusted):
      return .custom(hosts: hosts, includesTrusted: includeTrusted)
    }
  }

  private var sandboxNetworkSection: some View {
    Section {
      if let declaredNetwork {
        LabeledContent(l("Declared network")) {
          let value = PrivacyGrantRow.networkValue(declaredNetwork, using: l)
          Text(verbatim: value).foregroundStyle(.secondary)
        }
      }
      if let purpose = review.provider.declarations?.sandbox?.purpose {
        LabeledContent(l("Declared purpose")) {
          Text(verbatim: purpose)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }

      Picker(selection: networkSelectionBinding) {
        Text(verbatim: l("None")).tag(NetworkPickerChoice.none)
        Text(verbatim: l("Trusted Hosts")).tag(NetworkPickerChoice.trusted)
          .disabled(!allowsNetwork(.trusted))
        Text(verbatim: l("Any Host")).tag(NetworkPickerChoice.full)
          .disabled(!allowsNetwork(.full))
        if let declaredNetwork, case .custom = declaredNetwork {
          let value = l.format(
            "Declared: %@", PrivacyGrantRow.networkValue(declaredNetwork, using: l))
          Text(verbatim: value)
            .tag(NetworkPickerChoice.declaredCustom)
            .disabled(!allowsNetwork(declaredNetwork))
        }
        if case .custom = draft.network, draft.network != declaredNetwork {
          let value = PrivacyGrantRow.networkValue(draft.network, using: l)
          Text(verbatim: value).tag(NetworkPickerChoice.custom)
        }
        Divider()
        Text(verbatim: l("Custom…")).tag(NetworkPickerChoice.edit)
          .disabled(!allowsNetwork(.trusted) && !allowsCustomNetwork)
      } label: {
        Label {
          Text(verbatim: l("Network"))
        } icon: {
          PrivacySymbol(name: "globe")
        }
      }
      .accessibilityIdentifier("enablement.sandbox.network")

      if !review.trustedHosts.isEmpty {
        DisclosureGroup(l("Trusted hosts")) {
          Text(verbatim: review.trustedHosts.sorted().joined(separator: ", "))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }

    } header: {
      Text(verbatim: l("Sandbox Network"))
    }
  }

  private var allowsCustomNetwork: Bool {
    if review.provider.declarations == nil { return true }
    switch declaredNetwork {
    case .some(.trusted), .some(.full), .some(.custom): return true
    case .some(.none), nil: return false
    }
  }

  private func allowsNetwork(_ network: PrivacyNetworkAccess) -> Bool {
    if let declarations = review.provider.declarations,
      !network.permissionAccess.fits(
        within: declarations.sandbox?.network?.value ?? .none, trustedHosts: review.trustedHosts)
    {
      return false
    }
    return review.provider.limits.sources.values.allSatisfy { source in
      switch source {
      case .absent: true
      case .unreadable: false
      case .available(let limits):
        network.permissionAccess.fits(within: limits.network, trustedHosts: review.trustedHosts)
      }
    }
  }

  private var networkSelectionBinding: Binding<NetworkPickerChoice> {
    Binding(
      get: {
        switch draft.network {
        case .none: return .none
        case .trusted: return .trusted
        case .full: return .full
        case .custom:
          return draft.network == declaredNetwork ? .declaredCustom : .custom
        }
      },
      set: { choice in
        switch choice {
        case .none: draft.network = PrivacyNetworkAccess.none
        case .trusted: draft.network = .trusted
        case .full: draft.network = .full
        case .declaredCustom:
          if let declaredNetwork { draft.network = declaredNetwork }
        case .custom: break
        case .edit: editingCustomNetwork = true
        }
      }
    )
  }

  // MARK: - Read Exceptions

  private var readExceptionsSection: some View {
    Section {
      if readExceptions.isEmpty {
        Text(verbatim: l("No resolvable read exceptions."))
          .foregroundStyle(.secondary)
      } else {
        ForEach(readExceptions, id: \.declaredPath) { item in
          VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: readExceptionToggleBinding(for: item)) {
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.declaredPath)
                  .font(.system(.body, design: .monospaced))
                Text(verbatim: item.purpose)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .disabled(item.approval == nil)
            .accessibilityIdentifier("enablement.readException.\(item.declaredPath)")

            if let approval = item.approval {
              let resolved = l.format(
                approval.isDirectory ? "Resolved folder: %@" : "Resolved file: %@",
                approval.path.string)
              Text(verbatim: resolved)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 24)
            } else {
              Text(
                verbatim: l(
                  "This declared path could not be resolved automatically. Choose an existing local path to allow it, or leave it off."
                )
              )
              .font(.caption)
              .foregroundStyle(.orange)
              .padding(.leading, 24)
            }

            HStack(spacing: 10) {
              Button(l("Choose path…")) {
                replacementTargetPath = item.declaredPath
                importingReplacement = true
              }
              .accessibilityIdentifier("enablement.readException.choose.\(item.declaredPath)")

              if readExceptionReplacements[item.declaredPath] != nil {
                Button(l("Reset path")) {
                  var replacements = readExceptionReplacements
                  replacements.removeValue(forKey: item.declaredPath)
                  reloadReadExceptions(with: replacements, changedPath: item.declaredPath)
                }
              }
            }
            .controlSize(.small)
            .padding(.leading, 24)
          }
          .padding(.vertical, 4)
        }
      }

    } header: {
      Text(verbatim: l("Sandbox Read Exceptions"))
    } footer: {
      Text(
        verbatim: l(
          "Approved read exceptions grant read-only access inside the sandbox to the exact resolved paths shown."
        )
      )
    }
  }

  private func readExceptionToggleBinding(for item: GatewayReadExceptionReview) -> Binding<Bool> {
    Binding(
      get: { item.approval != nil && approvedReadExceptionPaths.contains(item.declaredPath) },
      set: { enabled in
        if enabled, item.approval != nil {
          approvedReadExceptionPaths.insert(item.declaredPath)
        } else {
          approvedReadExceptionPaths.remove(item.declaredPath)
        }
      }
    )
  }

  private func reloadReadExceptions(
    with replacements: [String: CanonicalPath], changedPath: String? = nil
  ) {
    do {
      let resolved = try review.readExceptions(replacements: replacements)
      let previous = Dictionary(uniqueKeysWithValues: readExceptions.map { ($0.declaredPath, $0) })
      // Keep the evidence the owner actually approved while refreshing unrelated rows.
      readExceptions = resolved.map { item in
        guard item.declaredPath != changedPath, let old = previous[item.declaredPath] else {
          approvedReadExceptionPaths.remove(item.declaredPath)
          return item
        }
        return old
      }
      readExceptionReplacements = replacements
      localError = nil
    } catch {
      localError = AppLocalization.errorDescription(error)
    }
  }

  // MARK: - Submission

  private func confirmSelection() {
    guard !busy, !approvalIsBlocked else { return }
    localError = nil
    do {
      let permissions = try draft.permissions()

      let approvedExceptions = Set(
        readExceptions.compactMap { item -> ApprovedReadException? in
          guard approvedReadExceptionPaths.contains(item.declaredPath) else { return nil }
          return item.approval
        }
      )

      let sandboxSettings =
        usesFullAccess
        ? ProviderSandboxSettings()
        : Self.makeSandboxSettings(network: draft.network, readExceptions: approvedExceptions)

      let selection = ProviderEnablementSelection(
        permissions: permissions,
        sandboxSettings: sandboxSettings,
        fullAccess: usesFullAccess
      )

      submitting = true
      Task {
        await onConfirm(selection)
        submitting = false
      }
    } catch {
      localError = AppLocalization.errorDescription(error)
    }
  }

  // MARK: - Mapping Helpers

  private static func makeSandboxSettings(
    network: PrivacyNetworkAccess,
    readExceptions: Set<ApprovedReadException>
  ) -> ProviderSandboxSettings {
    var settings = ProviderSandboxSettings()
    settings.defaults.network = network.permissionAccess
    settings.defaults.readExceptions = readExceptions
    return settings
  }

  private static func folderTitle(for category: PluginFolderCategory) -> String {
    switch category {
    case .desktop: "Desktop"
    case .documents: "Documents"
    case .downloads: "Downloads"
    case .iCloudDrive: "iCloud Drive"
    case .networkVolumes: "Network Volumes"
    case .removableVolumes: "Removable Volumes"
    }
  }

  private static func privacyPermissionTitle(_ permission: PluginPrivacyPermission) -> String {
    switch permission {
    case .screen: "Screen"
    case .desktopControl: "Desktop Control"
    case .localNetwork: "Local Network"
    case .machine: "Machine Information"
    case .unifiedLogs: "Unified Logs"
    case .skills: "Skills"
    }
  }

}

enum EnablementPermissionChoice: Hashable {
  case inherit
  case ask
  case granted(PermissionValue)
  case denied

  var title: String {
    switch self {
    case .inherit, .ask: "Ask"
    case .granted(.read): "Read"
    case .granted(.write): "Read & Write"
    case .granted(.use): "Use"
    case .granted(.all): "All"
    case .granted(.access): "Allow"
    case .denied: "Don't Allow"
    }
  }

  var permissionState: ComputerMCPPermissions.PermissionState {
    switch self {
    case .inherit, .ask: .notGranted
    case .granted(let value): .granted(value)
    case .denied: .denied
    }
  }
}

struct EnablementDraft {
  var choices: [Permission: EnablementPermissionChoice] = [:]
  var network: PrivacyNetworkAccess = .none
  var fullAccess = false
  var fullAccessConsented = false

  func inheritedChoice(for permission: Permission) -> EnablementPermissionChoice? {
    guard let wildcard = permission.fallback, wildcard != permission else { return nil }
    switch choices[wildcard] {
    case .granted, .denied: return choices[wildcard]
    default: return nil
    }
  }

  func choice(for permission: Permission) -> EnablementPermissionChoice {
    choices[permission] ?? (inheritedChoice(for: permission) == nil ? .ask : .inherit)
  }

  func permissions() throws -> Permissions {
    var permissions = Permissions()
    for (permission, choice) in choices where choice != .inherit {
      try permissions.set(choice.permissionState, for: permission)
    }
    return permissions
  }

  func allows(
    _ choice: EnablementPermissionChoice, for permission: Permission, limits: ManagedLimits
  ) -> Bool {
    let target: Permission
    let value: PermissionValue
    switch choice {
    case .granted(let granted):
      target = permission
      value = granted
    case .inherit:
      guard let wildcard = permission.fallback, case .granted(let granted) = choices[wildcard]
      else { return true }
      target = wildcard
      value = granted
    case .ask, .denied:
      return true
    }
    do {
      var proposed = try permissions()
      if choice == .inherit {
        proposed.removeEntry(for: permission)
      } else {
        try proposed.set(.granted(value), for: permission)
      }
      return try GatewayPermissionService.allowsProviderGrant(
        value, for: target, in: proposed, limits: limits)
    } catch {
      return false
    }
  }

}

struct PluginEnablementReviewForm: View {
  @ObservedObject var model: PluginManagementModel
  let review: ProviderEnablementReview
  let onComplete: (Bool) -> Void

  var body: some View {
    ProviderEnablementReviewView(review: review, isBusy: model.isSaving) { selection in
      onComplete(await model.confirmEnablement(reviewID: review.id, selection: selection))
    } onDecline: {
      model.cancelEnablement(reviewID: review.id)
      onComplete(false)
    }
    .onDisappear { model.cancelEnablement(reviewID: review.id) }
  }
}
