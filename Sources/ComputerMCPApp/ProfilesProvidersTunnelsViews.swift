import AppKit
import ComputerMCP
import SwiftUI

struct ProfilesView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceHeader(
        "Profiles",
        subtitle: "Static capability boundaries for local and remote callers"
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
            "This profile expands the capabilities available to its configured callers. The change is local and takes effect immediately."
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

}

struct ProvidersView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceHeader(
        "Providers",
        subtitle: "CLI, MCP, Codex, Computer Use, and external runtimes"
      ) {
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
