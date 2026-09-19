import AppKit
import ComputerMCP
import SwiftUI

struct ProfilesView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel
  @State private var editingProfile: ProfileSummary?

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceHeader(
        "Profiles",
        subtitle: "Permissions for selected tools, workspaces, and connections"
      ) {
        RefreshButton {
          model.refresh(.profiles)
        }
      }

      Divider()

      switch model.profiles {
      case .idle, .loading:
        LoadingWorkspaceView(title: "Loading profiles")
      case .failed(let message):
        FailedWorkspaceView(message: message) {
          model.refresh(.profiles)
        }
      case .loaded(let profiles) where profiles.isEmpty:
        EmptyWorkspaceView(
          title: "No profiles configured",
          detail: "Add a validated profile to the Computer MCP configuration.",
          systemImage: "person.badge.key"
        )
      case .loaded(let profiles):
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(profiles) { profile in
              profileRow(profile)
              Divider()
            }
          }
          .padding(.horizontal, 16)
        }
      }
    }
    .sheet(item: $editingProfile) { profile in
      ProfilePermissionsEditor(
        initial: profile.permissions,
        workspaces: availableWorkspaces,
        save: { try await model.updateProfilePermissions($0) })
    }
    .alert(item: $model.pendingProfileConfirmation) { confirmation in
      switch confirmation.kind {
      case .activate:
        Alert(
          title: AppLocalization.verbatimText(
            AppLocalization.formatted(
              "Activate %@?",
              confirmation.profile.displayName
            )
          ),
          message: Text(
            "New connections use this profile. Existing connections keep their current profile; active work is not stopped.",
            bundle: AppLocalization.resourceBundle
          ),
          primaryButton: .destructive(Text("Activate")) {
            model.activateProfile(id: confirmation.profile.id)
          },
          secondaryButton: .cancel()
        )
      case .enableFullShell:
        Alert(
          title: Text("Enable Full Shell?"),
          message: Text(
            "Full Shell gives authorized callers the current macOS user's effective file, process, network, and credential access. Workspace grants are not a containment boundary while it is enabled."
          ),
          primaryButton: .destructive(Text("Enable Full Shell")) {
            model.setFullShellEnabled(true, profileID: confirmation.profile.id)
          },
          secondaryButton: .cancel()
        )
      }
    }
  }

  private func profileRow(_ profile: ProfileSummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(verbatim: AppLocalization.string(profile.displayName))
          .font(.headline)

        if profile.isActive {
          StateBadge(text: "Active", color: .green, systemImage: "checkmark.circle.fill")
        }

        StateBadge(text: profile.riskLevel.label, color: profile.riskLevel.color)

        Spacer()

        Button {
          editingProfile = profile
        } label: {
          Text("Edit permissions", bundle: AppLocalization.resourceBundle)
        }
        .accessibilityIdentifier("profile.\(profile.id).permissions")

        if !profile.isActive {
          Button {
            model.requestProfileActivation(profile)
          } label: {
            Label("Activate", systemImage: "checkmark.circle")
          }
          .accessibilityIdentifier("profile.\(profile.id).activate")
          .disabled(
            !profile.isEnabled || model.isActionRunning("profile.activate.\(profile.id)")
          )
        }
      }

      Text(verbatim: AppLocalization.string(profile.summary))
        .foregroundStyle(.secondary)
      Text(verbatim: AppLocalization.string(profile.permissions.confirmationPolicy.permissionLabel))
        .font(.caption).foregroundStyle(.secondary)

      HStack(spacing: 18) {
        Label {
          Text(
            verbatim: AppLocalization.string(
              profile.permitsRemoteAccess ? "Tunnel eligible" : "Local only"
            )
          )
        } icon: {
          Image(systemName: profile.permitsRemoteAccess ? "network" : "lock.fill")
        }
        .foregroundStyle(.secondary)

        if profile.supportsFullShell {
          Toggle(
            "Full Shell",
            isOn: Binding(
              get: { profile.fullShellEnabled },
              set: { enabled in
                model.requestFullShellChange(enabled, profile: profile)
              }
            )
          )
          .toggleStyle(.switch)
          .disabled(model.isActionRunning("profile.shell.\(profile.id)"))
          .help(
            AppLocalization.string(
              profile.permitsRemoteAccess
                ? "Arbitrary shell execution for authorized remote callers"
                : "Arbitrary shell execution for this local profile"
            )
          )
        }
      }
      .font(.caption)
    }
    .padding(.vertical, 8)
  }

  private var availableWorkspaces: [WorkspaceSummary] {
    if case .loaded(let workspaces) = model.workspaces { return workspaces }
    return []
  }

}

private struct ProfilePermissionsEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var grant: ProfileGrant
  @State private var capabilities: String
  @State private var mcpServers: String
  @State private var isSaving = false
  @State private var confirmSave = false
  @State private var errorMessage: String?
  let workspaces: [WorkspaceSummary]
  let save: (ProfileGrant) async throws -> Void

  init(
    initial: ProfileGrant, workspaces: [WorkspaceSummary],
    save: @escaping (ProfileGrant) async throws -> Void
  ) {
    _grant = State(initialValue: initial)
    _capabilities = State(initialValue: initial.capabilityIDs.sorted().joined(separator: "\n"))
    _mcpServers = State(initialValue: initial.mcpServerIDs.sorted().joined(separator: "\n"))
    self.workspaces = workspaces
    self.save = save
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        LabeledContent("Profile", value: grant.id.rawValue)
        Section {
          Picker(selection: $grant.mode) {
            ForEach(GatewayPermissionMode.allCases, id: \.self) { mode in
              Text(verbatim: AppLocalization.string(mode.permissionLabel)).tag(mode)
            }
          } label: {
            Text("Permission mode", bundle: AppLocalization.resourceBundle)
          }
          .accessibilityIdentifier("profile.permissions.mode")
          Picker(selection: $grant.confirmationPolicy) {
            ForEach(GatewayConfirmationPolicy.allCases, id: \.self) { policy in
              Text(verbatim: AppLocalization.string(policy.permissionLabel)).tag(policy)
            }
          } label: {
            Text("Confirmation policy", bundle: AppLocalization.resourceBundle)
          }
          .accessibilityIdentifier("profile.permissions.confirmation-policy")
          if grant.mode == .localFullAccess {
            Toggle(isOn: $grant.fullShellEnabled) {
              Text("Allow arbitrary execution", bundle: AppLocalization.resourceBundle)
            }
            .accessibilityIdentifier("profile.permissions.arbitrary-execution")
            Text(
              "Arbitrary execution has this macOS user's file, process, network, and credential access. A workspace is not a sandbox.",
              bundle: AppLocalization.resourceBundle
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Text(
            "Host permissions do not replace Codex's native sandbox or approval settings.",
            bundle: AppLocalization.resourceBundle
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Section {
          Toggle(isOn: selection("*", in: $grant.workspaceIDs)) {
            Text("All registered and future workspaces", bundle: AppLocalization.resourceBundle)
          }
          .accessibilityIdentifier("profile.permissions.all-workspaces")
          if workspaces.isEmpty {
            Text("Register a workspace to select it here.", bundle: AppLocalization.resourceBundle)
          }
          ForEach(workspaces) { workspace in
            Toggle(isOn: selection(workspace.id, in: $grant.workspaceIDs)) {
              Text(verbatim: workspace.displayName)
            }
            .disabled(grant.workspaceIDs.contains("*"))
            .accessibilityIdentifier("profile.permissions.workspace.\(workspace.id)")
          }
        } header: {
          Text("Workspaces", bundle: AppLocalization.resourceBundle)
        }
        DisclosureGroup {
          TextField(text: $capabilities, axis: .vertical) {
            Text("Capability IDs, one per line", bundle: AppLocalization.resourceBundle)
          }
          .lineLimit(3...8)
          .accessibilityIdentifier("profile.permissions.capabilities")
          TextField(text: $mcpServers, axis: .vertical) {
            Text("MCP registration IDs, one per line", bundle: AppLocalization.resourceBundle)
          }
          .lineLimit(2...5)
          .accessibilityIdentifier("profile.permissions.mcp-servers")
          Text(
            "Only selected capabilities are granted. Empty lists grant none; a registration grant includes its host-selected tools.",
            bundle: AppLocalization.resourceBundle
          )
          .font(.caption).foregroundStyle(.secondary)
          ForEach(
            [GatewayCallerKind.localApp, .localCLI, .localMCP, .secureTunnel, .cloudflareTunnel],
            id: \.self
          ) { caller in
            Toggle(isOn: selection(caller, in: $grant.allowedCallers)) {
              Text(verbatim: AppLocalization.string(caller.permissionLabel))
            }
            .accessibilityIdentifier("profile.permissions.caller.\(caller.rawValue)")
          }
        } label: {
          Text("Advanced permissions", bundle: AppLocalization.resourceBundle)
        }
        .accessibilityIdentifier("profile.permissions.advanced")
      }
      .formStyle(.grouped)
      .disabled(isSaving)
      .onChange(of: grant.mode) { _, mode in
        if mode != .localFullAccess { grant.fullShellEnabled = false }
      }
      if let errorMessage {
        Text(verbatim: errorMessage).foregroundStyle(.red).textSelection(.enabled).padding()
      }
      Divider()
      HStack {
        Button {
          dismiss()
        } label: {
          Text("Cancel", bundle: AppLocalization.resourceBundle)
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("profile.permissions.cancel")
        Spacer()
        if isSaving { ProgressView().controlSize(.small) }
        Button {
          confirmSave = true
        } label: {
          Text("Save", bundle: AppLocalization.resourceBundle)
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("profile.permissions.save")
      }
      .padding().disabled(isSaving)
    }
    .frame(minWidth: 560, minHeight: 540)
    .confirmationDialog("Apply permission changes?", isPresented: $confirmSave) {
      Button(role: .destructive) {
        apply()
      } label: {
        Text("Apply", bundle: AppLocalization.resourceBundle)
      }
      .accessibilityIdentifier("profile.permissions.apply")
    } message: {
      Text(
        "New requests use these settings immediately. Existing work is not stopped. Pending confirmations become invalid.",
        bundle: AppLocalization.resourceBundle)
    }
  }

  private func selection<Value: Hashable>(_ value: Value, in values: Binding<Set<Value>>)
    -> Binding<Bool>
  {
    Binding(
      get: { values.wrappedValue.contains(value) },
      set: { selected in
        if selected { values.wrappedValue.insert(value) } else { values.wrappedValue.remove(value) }
      })
  }

  private func apply() {
    grant.capabilityIDs = identifiers(capabilities)
    grant.mcpServerIDs = identifiers(mcpServers)
    isSaving = true
    errorMessage = nil
    Task {
      defer { isSaving = false }
      do {
        try await save(grant)
        dismiss()
      } catch {
        errorMessage = AppLocalization.errorDescription(error)
      }
    }
  }

  private func identifiers(_ text: String) -> Set<String> {
    Set(
      text.split(whereSeparator: \.isNewline).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty })
  }
}

extension GatewayPermissionMode {
  fileprivate var permissionLabel: String {
    switch self {
    case .readOnly: "Read-only"
    case .workspaceOperations: "Workspace operations"
    case .localFullAccess: "Local Full Access"
    }
  }
}

extension GatewayConfirmationPolicy {
  fileprivate var permissionLabel: String {
    switch self {
    case .riskBased: "Confirm risky actions"
    case .allWrites: "Confirm all writes"
    case .never: "No confirmation"
    }
  }
}

extension GatewayCallerKind {
  fileprivate var permissionLabel: String {
    switch self {
    case .localApp: "Local App"
    case .localCLI: "Local CLI"
    case .localMCP: "Local MCP clients"
    case .secureTunnel: "Secure Tunnel"
    case .cloudflareTunnel: "Cloudflare Tunnel"
    }
  }
}

struct ProvidersView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel
  @State private var showingMCPRegistrations = false

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceHeader(
        "Providers",
        subtitle: "CLI, MCP, Codex, Computer Use, and external runtimes"
      ) {
        Button(AppLocalization.string("Manage MCP")) { showingMCPRegistrations = true }
        RefreshButton {
          model.refresh(.providers)
        }
      }

      Divider()

      switch model.providers {
      case .idle, .loading:
        LoadingWorkspaceView(title: "Loading providers")
      case .failed(let message):
        FailedWorkspaceView(message: message) {
          model.refresh(.providers)
        }
      case .loaded(let providers) where providers.isEmpty:
        EmptyWorkspaceView(
          title: "No providers configured",
          detail: "Register providers in the active configuration before starting them.",
          systemImage: "shippingbox"
        )
      case .loaded(let providers):
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(providers) { provider in
              ProviderRow(provider: provider)
              Divider()
            }
          }
          .padding(.horizontal, 16)
        }
      }
    }
    .sheet(isPresented: $showingMCPRegistrations) {
      MCPRegistrationsView(model: model.mcpRegistrations) { pluginID in
        model.pluginManagement.selectedID = pluginID
        model.selectedWorkspace = .plugins
      }
    }
  }
}

private struct ProviderRow: View {
  @EnvironmentObject private var model: ComputerMCPAppModel
  let provider: ProviderSummary

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: providerIcon)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 26)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(verbatim: AppLocalization.string(provider.displayName))
            .fontWeight(.medium)
          StateBadge(
            text: provider.state.label,
            color: provider.state.color,
            systemImage: provider.state.systemImage
          )
          Text(verbatim: AppLocalization.string(provider.kind.label))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        providerDetail

        if let doctor = provider.lastDoctorMessage {
          Text(verbatim: AppLocalization.string(doctor))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        if let lastError = provider.lastError {
          Label {
            Text(verbatim: AppLocalization.errorDescription(lastError))
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
        }
      }

      Spacer(minLength: 16)

      if provider.lifecycleManaged {
        if provider.state == .running || provider.state == .degraded {
          Button {
            model.stopProvider(id: provider.id)
          } label: {
            Label("Stop", systemImage: "stop.fill")
          }
          .disabled(model.isActionRunning("provider.stop.\(provider.id)"))
        } else {
          Button {
            model.startProvider(id: provider.id)
          } label: {
            Label("Start", systemImage: "play.fill")
          }
          .disabled(
            provider.state == .starting
              || provider.state == .stopping
              || model.isActionRunning("provider.start.\(provider.id)")
          )
        }
      }

      Button {
        model.doctorProvider(id: provider.id)
      } label: {
        Label("Run Diagnostics", systemImage: "stethoscope")
      }
      .disabled(model.isActionRunning("provider.doctor.\(provider.id)"))
    }
    .padding(.vertical, 7)
  }

  @ViewBuilder
  private var providerDetail: some View {
    HStack(spacing: 12) {
      if let version = provider.version {
        AppLocalization.verbatimText(AppLocalization.formatted("Version %@", version))
      }
      if let toolCount = provider.toolCount {
        AppLocalization.verbatimText(AppLocalization.formatted("%@ tools", String(toolCount)))
      }
      if let executablePath = provider.executablePath {
        Text(executablePath)
          .font(.system(.caption, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(executablePath)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var providerIcon: String {
    switch provider.kind {
    case .builtin: "wrench.and.screwdriver"
    case .cli: "terminal"
    case .mcp: "point.3.connected.trianglepath.dotted"
    case .codex: "chevron.left.forwardslash.chevron.right"
    case .computerUse: "display"
    case .external: "shippingbox"
    }
  }
}

struct TunnelsView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel
  @State private var transport: RemoteTunnelTransportSelection = .openAI
  @State private var editor: OpenAITunnelEditorPresentation?
  @State private var pendingDeletion: OpenAITunnelSummary?
  @State private var logTunnel: OpenAITunnelSummary?
  @State private var cloudflareEditor: CloudflareEditorPresentation?
  @State private var pendingCloudflareDeletion: CloudflareTunnelSummary?
  @State private var cloudflareLogTunnel: CloudflareTunnelSummary?

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceHeader(
        "Tunnels",
        subtitle: "Independent OpenAI Secure MCP and Cloudflare named tunnel lifecycles"
      ) {
        HStack {
          Picker("Transport", selection: $transport) {
            Text("OpenAI").tag(RemoteTunnelTransportSelection.openAI)
            Text("Cloudflare").tag(RemoteTunnelTransportSelection.cloudflare)
          }
          .pickerStyle(.segmented)
          .frame(width: 210)

          Button {
            if transport == .openAI { editor = .new } else { cloudflareEditor = .new }
          } label: {
            Label("Add", systemImage: "plus")
          }

          RefreshButton { model.refresh(.tunnels) }
        }
      }

      Divider()

      if transport == .openAI {
        openAIContent
      } else {
        cloudflareContent
      }
    }
    .sheet(item: $editor) { presentation in
      OpenAITunnelEditorView(presentation: presentation)
        .environmentObject(model)
    }
    .sheet(item: $logTunnel) { tunnel in
      OpenAITunnelLogsView(tunnel: tunnel)
        .environmentObject(model)
    }
    .sheet(item: $cloudflareEditor) { presentation in
      CloudflareTunnelEditorView(presentation: presentation)
        .environmentObject(model)
    }
    .sheet(item: $cloudflareLogTunnel) { tunnel in
      CloudflareTunnelLogsView(tunnel: tunnel)
        .environmentObject(model)
    }
    .sheet(
      isPresented: Binding(
        get: { model.generatedAccessToken != nil },
        set: { if !$0 { model.generatedAccessToken = nil } }
      )
    ) {
      GeneratedAccessTokenView(token: model.generatedAccessToken ?? "") {
        model.generatedAccessToken = nil
      }
    }
    .alert(item: $pendingDeletion) { tunnel in
      Alert(
        title: AppLocalization.verbatimText(
          AppLocalization.formatted("Delete %@?", tunnel.displayName)
        ),
        message: Text(
          "The local Tunnel profile and its Keychain API key will be removed. The OpenAI Tunnel registration is not deleted."
        ),
        primaryButton: .destructive(Text("Delete")) { model.deleteOpenAITunnel(id: tunnel.id) },
        secondaryButton: .cancel()
      )
    }
    .alert(item: $pendingCloudflareDeletion) { tunnel in
      Alert(
        title: AppLocalization.verbatimText(
          AppLocalization.formatted("Delete %@?", tunnel.tunnelName)
        ),
        message: Text(
          "The local named-tunnel profile and its Keychain secrets will be removed. The Cloudflare account tunnel remains user-owned."
        ),
        primaryButton: .destructive(Text("Delete")) {
          model.deleteCloudflareTunnel(id: tunnel.id)
        },
        secondaryButton: .cancel()
      )
    }
  }

  @ViewBuilder
  private var openAIContent: some View {
    switch model.openAITunnels {
    case .idle, .loading:
      LoadingWorkspaceView(title: "Loading OpenAI tunnels")
    case .failed(let message):
      FailedWorkspaceView(message: message) {
        model.refresh(.tunnels)
      }
    case .loaded(let tunnels) where tunnels.isEmpty:
      EmptyWorkspaceView(
        title: "No tunnels configured",
        detail: "Add a Tunnel manifest and local Keychain credentials.",
        systemImage: "point.3.connected.trianglepath.dotted"
      )
    case .loaded(let tunnels):
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(tunnels) { tunnel in
            OpenAITunnelRow(
              tunnel: tunnel,
              onEdit: {
                editor = .edit(tunnel)
              },
              onDelete: {
                pendingDeletion = tunnel
              },
              onLogs: {
                logTunnel = tunnel
              }
            )
            Divider()
          }
        }
        .padding(.horizontal, 16)
      }
    }
  }

  @ViewBuilder
  private var cloudflareContent: some View {
    switch model.cloudflareTunnels {
    case .idle, .loading:
      LoadingWorkspaceView(title: "Loading Cloudflare tunnels")
    case .failed(let message):
      FailedWorkspaceView(message: message) { model.refresh(.tunnels) }
    case .loaded(let tunnels) where tunnels.isEmpty:
      EmptyWorkspaceView(
        title: "No named tunnels configured",
        detail:
          "Add a remotely managed named tunnel. Quick Tunnel and noauth are Validation development-only.",
        systemImage: "cloud"
      )
    case .loaded(let tunnels):
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(tunnels) { tunnel in
            CloudflareTunnelRow(
              tunnel: tunnel,
              onEdit: { cloudflareEditor = .edit(tunnel) },
              onDelete: { pendingCloudflareDeletion = tunnel },
              onLogs: { cloudflareLogTunnel = tunnel }
            )
            Divider()
          }
        }
        .padding(.horizontal, 16)
      }
    }
  }
}

private enum RemoteTunnelTransportSelection: Hashable {
  case openAI
  case cloudflare
}

private struct CloudflareTunnelRow: View {
  @EnvironmentObject private var model: ComputerMCPAppModel
  let tunnel: CloudflareTunnelSummary
  let onEdit: () -> Void
  let onDelete: () -> Void
  let onLogs: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 9) {
        Text(tunnel.tunnelName).font(.headline)
        StateBadge(
          text: tunnel.state.label,
          color: tunnel.state.color,
          systemImage: tunnel.state.systemImage
        )
        Text(tunnel.profileID).font(.caption).foregroundStyle(.secondary)
        Spacer()
        if tunnel.state == .running || tunnel.state == .degraded {
          Button {
            model.stopCloudflareTunnel(id: tunnel.id)
          } label: {
            Label("Stop", systemImage: "stop.fill")
          }
        } else {
          Button {
            model.startCloudflareTunnel(id: tunnel.id)
          } label: {
            Label("Start", systemImage: "play.fill")
          }
        }
        Button {
          model.doctorCloudflareTunnel(id: tunnel.id)
        } label: {
          Label("Run Diagnostics", systemImage: "stethoscope")
        }
        Button(action: onLogs) { Image(systemName: "doc.text.magnifyingglass") }
          .help("Show Cloudflare logs")
        Button(action: onEdit) { Image(systemName: "pencil") }
          .disabled(tunnel.state == .running || tunnel.state == .starting)
        Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
          .disabled(tunnel.state == .running || tunnel.state == .starting)
      }
      Text(verbatim: "https://" + tunnel.publicHostname + "/mcp")
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
      AppLocalization.verbatimText(
        AppLocalization.formatted(
          "Loopback origin 127.0.0.1:%@ · metrics 127.0.0.1:%@",
          String(tunnel.localPort),
          String(tunnel.metricsPort)
        )
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      if let processIdentifier = tunnel.processIdentifier {
        AppLocalization.verbatimText(
          AppLocalization.formatted(
            "cloudflared PID %@",
            String(processIdentifier)
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if let lastError = tunnel.lastError {
        Label {
          Text(verbatim: AppLocalization.errorDescription(lastError))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(.red)
      }
    }
    .padding(.vertical, 8)
  }
}

struct CloudflareEditorPresentation: Identifiable {
  let id = UUID()
  var draft: CloudflareTunnelConfigurationDraft
  var isEditing: Bool

  static var new: Self {
    Self(
      draft: CloudflareTunnelConfigurationDraft(
        id: "cloudflare",
        tunnelName: "",
        publicHostname: "",
        gatewayProfileID: GatewayProfileID.cloudflareObserve.rawValue,
        localPort: 8_765,
        metricsPort: 20_241,
        cloudflaredPath: nil,
        tunnelToken: nil,
        regenerateAccessToken: false
      ),
      isEditing: false
    )
  }

  static func edit(_ tunnel: CloudflareTunnelSummary) -> Self {
    Self(
      draft: CloudflareTunnelConfigurationDraft(
        id: tunnel.id,
        tunnelName: tunnel.tunnelName,
        publicHostname: tunnel.publicHostname,
        gatewayProfileID: tunnel.profileID,
        localPort: tunnel.localPort,
        metricsPort: tunnel.metricsPort,
        cloudflaredPath: nil,
        tunnelToken: nil,
        regenerateAccessToken: false
      ),
      isEditing: true
    )
  }
}

struct CloudflareTunnelEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: ComputerMCPAppModel
  @State private var draft: CloudflareTunnelConfigurationDraft
  let isEditing: Bool

  init(presentation: CloudflareEditorPresentation) {
    _draft = State(initialValue: presentation.draft)
    self.isEditing = presentation.isEditing
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(
            AppLocalization.string(isEditing ? "Edit Cloudflare Tunnel" : "Add Cloudflare Tunnel")
          )
          .font(.title2.weight(.semibold))
          Text(
            "Remotely managed named tunnels only. The App owns the access-token-protected loopback origin."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)
      Divider()
      Form {
        TextField("Profile ID", text: $draft.id).disabled(isEditing)
        TextField("Named tunnel", text: $draft.tunnelName)
        TextField("Public hostname", text: $draft.publicHostname)
          .textContentType(.URL)
        Picker("Gateway profile", selection: $draft.gatewayProfileID) {
          Text("Cloudflare Observe").tag(GatewayProfileID.cloudflareObserve.rawValue)
          Text("Cloudflare Operate").tag(GatewayProfileID.cloudflareOperate.rawValue)
        }
        SecureField(
          AppLocalization.string(
            isEditing ? "Replace named-tunnel token" : "Named-tunnel token"
          ),
          text: Binding(
            get: { draft.tunnelToken ?? "" },
            set: { draft.tunnelToken = $0 }
          )
        )
        Toggle("Generate a new Computer MCP Access Token", isOn: $draft.regenerateAccessToken)
        Text("Cloudflare Access service tokens belong to consumers and are never stored here.")
          .font(.caption)
          .foregroundStyle(.secondary)
        DisclosureGroup("Advanced") {
          LabeledContent("Origin port") {
            TextField("8765", value: $draft.localPort, format: .number).frame(width: 100)
          }
          LabeledContent("Metrics port") {
            TextField("20241", value: $draft.metricsPort, format: .number).frame(width: 100)
          }
          TextField(
            "cloudflared executable",
            text: Binding(
              get: { draft.cloudflaredPath ?? "" },
              set: { draft.cloudflaredPath = $0 }
            )
          )
        }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button {
          model.saveCloudflareTunnelConfiguration(draft)
          dismiss()
        } label: {
          Text(verbatim: AppLocalization.string(isEditing ? "Save" : "Add"))
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          draft.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.publicHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!isEditing
              && (draft.tunnelToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        )
      }
      .padding(16)
    }
    .frame(width: 600, height: 620)
  }
}

private struct CloudflareTunnelLogsView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: ComputerMCPAppModel
  let tunnel: CloudflareTunnelSummary

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Cloudflare Tunnel Logs").font(.title2.weight(.semibold))
        Spacer()
        Button("Refresh") { model.loadCloudflareTunnelLogs(id: tunnel.id) }
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .padding(16)
      Divider()
      switch model.cloudflareTunnelLogs[tunnel.id] ?? .idle {
      case .idle, .loading:
        LoadingWorkspaceView(title: "Loading redacted Cloudflare logs")
      case .failed(let message):
        FailedWorkspaceView(message: message) { model.loadCloudflareTunnelLogs(id: tunnel.id) }
      case .loaded(let logs):
        VStack(alignment: .leading, spacing: 12) {
          if logs.truncated { Label("Showing bounded log tails", systemImage: "scissors") }
          cloudflareLogSection("Standard output", logs.stdout)
          cloudflareLogSection("Standard error", logs.stderr)
        }
        .padding(16)
      }
    }
    .frame(width: 760, height: 560)
    .task { model.loadCloudflareTunnelLogs(id: tunnel.id) }
  }

  private func cloudflareLogSection(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading) {
      Text(verbatim: AppLocalization.string(title)).font(.headline)
      ScrollView {
        Text(text.isEmpty ? AppLocalization.string("No output.") : text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .frame(maxHeight: .infinity)
  }
}

struct GeneratedAccessTokenView: View {
  let token: String
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Computer MCP Access Token created").font(.title2.weight(.semibold))
      Text("Copy this once into the external consumer. Computer MCP stores it only in Keychain.")
      Text(token)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .padding(10)
        .background(.quaternary)
      HStack {
        Spacer()
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(token, forType: .string)
        }
        Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 560)
  }
}

private struct OpenAITunnelRow: View {
  @EnvironmentObject private var model: ComputerMCPAppModel
  let tunnel: OpenAITunnelSummary
  let onEdit: () -> Void
  let onDelete: () -> Void
  let onLogs: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 9) {
        Text(tunnel.displayName)
          .font(.headline)
        StateBadge(
          text: tunnel.state.label,
          color: tunnel.state.color,
          systemImage: tunnel.state.systemImage
        )
        Text(tunnel.profileID)
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        if tunnel.state == .running || tunnel.state == .degraded {
          Button {
            model.stopOpenAITunnel(id: tunnel.id)
          } label: {
            Label("Stop", systemImage: "stop.fill")
          }
          .disabled(model.isActionRunning("tunnel.stop.\(tunnel.id)"))
        } else {
          Button {
            model.startOpenAITunnel(id: tunnel.id)
          } label: {
            Label("Start", systemImage: "play.fill")
          }
          .disabled(
            tunnel.state == .starting
              || tunnel.state == .stopping
              || model.isActionRunning("tunnel.start.\(tunnel.id)")
          )
        }

        Button {
          model.doctorOpenAITunnel(id: tunnel.id)
        } label: {
          Label("Run Diagnostics", systemImage: "stethoscope")
        }
        .disabled(model.isActionRunning("tunnel.doctor.\(tunnel.id)"))

        Button {
          model.reconnectOpenAITunnel(id: tunnel.id)
        } label: {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
        .help("Reconnect Tunnel")
        .disabled(
          tunnel.state == .starting
            || tunnel.state == .stopping
            || model.isActionRunning("tunnel.reconnect.\(tunnel.id)")
        )

        Button(action: onLogs) {
          Image(systemName: "doc.text.magnifyingglass")
        }
        .help("Show Tunnel logs")
        .disabled(tunnel.state == .stopped && tunnel.connectedAt == nil)

        Button {
          model.provisionOpenAITunnel(id: tunnel.id)
        } label: {
          Image(systemName: "arrow.down.to.line.compact")
        }
        .help("Provision or update the tunnel-client profile")
        .disabled(model.isActionRunning("tunnel.provision.\(tunnel.id)"))

        Button(action: onEdit) {
          Image(systemName: "pencil")
        }
        .help("Edit Tunnel")
        .disabled(tunnel.state == .running || tunnel.state == .starting)

        Button(role: .destructive, action: onDelete) {
          Image(systemName: "trash")
        }
        .help("Delete Tunnel")
        .disabled(
          tunnel.state == .running
            || tunnel.state == .starting
            || model.isActionRunning("tunnel.delete.\(tunnel.id)")
        )
      }

      if let tunnelIdentifier = tunnel.tunnelIdentifier {
        Text(tunnelIdentifier)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      HStack(spacing: 14) {
        if let endpoint = tunnel.endpoint {
          Text(endpoint)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(endpoint)
        }
        if let connectedAt = tunnel.connectedAt {
          AppLocalization.verbatimText(
            AppLocalization.formatted(
              "Connected %@",
              connectedAt.formatted(.relative(presentation: .named))
            )
          )
        }
        if tunnel.reconnectAttempt > 0 {
          AppLocalization.verbatimText(
            AppLocalization.formatted(
              "Reconnect attempt %@",
              String(tunnel.reconnectAttempt)
            )
          )
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if let lastError = tunnel.lastError {
        Label {
          Text(verbatim: AppLocalization.errorDescription(lastError))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
      }
    }
    .padding(.vertical, 8)
  }
}

private struct OpenAITunnelLogsView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: ComputerMCPAppModel
  let tunnel: OpenAITunnelSummary

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Tunnel Logs")
            .font(.title2.weight(.semibold))
          Text(tunnel.displayName)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          model.loadOpenAITunnelLogs(id: tunnel.id)
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
      }
      .padding(16)

      Divider()

      Group {
        switch model.openAITunnelLogs[tunnel.id] ?? .idle {
        case .idle, .loading:
          LoadingWorkspaceView(title: "Loading redacted Tunnel logs")
        case .failed(let message):
          FailedWorkspaceView(message: message) {
            model.loadOpenAITunnelLogs(id: tunnel.id)
          }
        case .loaded(let snapshot):
          VStack(alignment: .leading, spacing: 12) {
            StateBadge(
              text: snapshot.state.label,
              color: snapshot.state.color,
              systemImage: snapshot.state.systemImage
            )
            logSection(title: "Standard output", text: snapshot.stdout)
            logSection(title: "Standard error", text: snapshot.stderr)
          }
          .padding(16)
        }
      }
    }
    .frame(width: 760, height: 560)
    .task {
      model.loadOpenAITunnelLogs(id: tunnel.id)
    }
  }

  private func logSection(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(verbatim: AppLocalization.string(title))
        .font(.headline)
      ScrollView {
        Text(text.isEmpty ? AppLocalization.string("No output.") : text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(8)
      }
      .background(.background)
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(.separator)
      }
    }
    .frame(maxHeight: .infinity)
  }
}

struct OpenAITunnelEditorPresentation: Identifiable {
  let id = UUID()
  var draft: OpenAITunnelConfigurationDraft
  var isEditing: Bool

  static var new: OpenAITunnelEditorPresentation {
    OpenAITunnelEditorPresentation(
      draft: OpenAITunnelConfigurationDraft(
        id: "chatgpt",
        tunnelClientProfile: "computer-mcp",
        tunnelID: "",
        gatewayProfileID: GatewayProfileID.chatGPTObserve.rawValue,
        tunnelClientPath: nil,
        httpProxy: nil,
        apiKey: nil
      ),
      isEditing: false
    )
  }

  static func edit(_ tunnel: OpenAITunnelSummary) -> OpenAITunnelEditorPresentation {
    OpenAITunnelEditorPresentation(
      draft: OpenAITunnelConfigurationDraft(
        id: tunnel.id,
        tunnelClientProfile: tunnel.displayName,
        tunnelID: tunnel.tunnelIdentifier ?? "",
        gatewayProfileID: tunnel.profileID,
        tunnelClientPath: tunnel.tunnelClientPath,
        httpProxy: tunnel.httpProxy,
        apiKey: nil
      ),
      isEditing: true
    )
  }
}

struct OpenAITunnelEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: ComputerMCPAppModel
  @State private var draft: OpenAITunnelConfigurationDraft
  private let isEditing: Bool

  init(presentation: OpenAITunnelEditorPresentation) {
    _draft = State(initialValue: presentation.draft)
    self.isEditing = presentation.isEditing
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(verbatim: AppLocalization.string(isEditing ? "Edit Tunnel" : "Add Tunnel"))
            .font(.title2.weight(.semibold))
          Text("The App owns the gateway process; tunnel-client connects through its local bridge.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)

      Divider()

      Form {
        TextField("Profile ID", text: $draft.id)
          .disabled(isEditing)
        TextField("Tunnel client profile", text: $draft.tunnelClientProfile)
        TextField("Tunnel ID", text: $draft.tunnelID)
          .textContentType(.none)

        Picker("Gateway profile", selection: $draft.gatewayProfileID) {
          Text("ChatGPT Observe")
            .tag(GatewayProfileID.chatGPTObserve.rawValue)
          Text("ChatGPT Operate")
            .tag(GatewayProfileID.chatGPTOperate.rawValue)
        }

        SecureField(
          AppLocalization.string(isEditing ? "Replace OpenAI API key" : "OpenAI API key"),
          text: Binding(
            get: { draft.apiKey ?? "" },
            set: { draft.apiKey = $0 }
          )
        )

        if isEditing {
          Text("Leave the API key blank to keep the existing Keychain value.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        DisclosureGroup("Advanced") {
          TextField(
            "tunnel-client executable",
            text: Binding(
              get: { draft.tunnelClientPath ?? "" },
              set: { draft.tunnelClientPath = $0 }
            )
          )
          Text("Leave blank to use the configured provider or PATH.")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField(
            "HTTP proxy",
            text: Binding(
              get: { draft.httpProxy ?? "" },
              set: { draft.httpProxy = $0 }
            )
          )
          Text(
            "Leave blank to follow the macOS HTTPS or HTTP proxy. Credentials are not allowed."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button {
          model.saveOpenAITunnelConfiguration(draft)
          dismiss()
        } label: {
          Text(verbatim: AppLocalization.string(isEditing ? "Save" : "Add"))
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          draft.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.tunnelClientProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.tunnelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!isEditing
              && (draft.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        )
      }
      .padding(16)
    }
    .frame(width: 560, height: 570)
  }
}
