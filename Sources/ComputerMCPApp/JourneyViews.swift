import AppKit
import ComputerMCP
import SwiftUI

struct JourneyView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel
  @State private var openAIEditor: OpenAITunnelEditorPresentation?
  @State private var cloudflareEditor: CloudflareEditorPresentation?

  let journey: ProductJourney

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceHeader(title, subtitle: subtitle) {
        HStack {
          Button {
            if journey == .chatgpt {
              openAIEditor = .new
            } else {
              cloudflareEditor = .new
            }
          } label: {
            Label("Add Connection", systemImage: "plus")
          }
          RefreshButton {
            model.refresh(workspace)
          }
        }
      }

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          readinessContent
          prerequisites
          tunnelContent
          consumerVerification
          recovery
        }
        .padding(24)
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
      }
    }
    .sheet(item: $openAIEditor) { presentation in
      OpenAITunnelEditorView(presentation: presentation)
        .environmentObject(model)
    }
    .sheet(item: $cloudflareEditor) { presentation in
      CloudflareTunnelEditorView(presentation: presentation)
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
  }

  private var title: String {
    journey == .chatgpt ? "Connect ChatGPT" : "Connect through Cloudflare"
  }

  private var subtitle: String {
    if journey == .chatgpt {
      return "OpenAI Secure MCP setup, lifecycle, and real-request verification"
    }
    return "Cloudflare named tunnel setup, protected origin, and real-request verification"
  }

  private var workspace: AppWorkspace {
    journey == .chatgpt ? .chatgpt : .cloudflare
  }

  @ViewBuilder
  private var readinessContent: some View {
    switch model.readiness {
    case .idle, .loading:
      JourneyCard(title: "Checking this connection", systemImage: "stethoscope") {
        ProgressView()
          .accessibilityLabel("Checking connection readiness")
      }
    case .failed(let message):
      JourneyCard(title: "Readiness check unavailable", systemImage: "exclamationmark.triangle") {
        Text(verbatim: AppLocalization.string(message))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Button("Retry") { model.refresh(workspace) }
      }
    case .loaded(let snapshots):
      if let snapshot = snapshots.first(where: { $0.journey == journey }) {
        JourneyCard(title: "Connection status", systemImage: snapshot.status.systemImage) {
          HStack {
            StateBadge(
              text: snapshot.status.label,
              color: snapshot.status.color,
              systemImage: snapshot.status.systemImage
            )
            Text(verbatim: AppLocalization.string(statusExplanation(snapshot.status)))
              .foregroundStyle(.secondary)
          }

          if let action = snapshot.nextAction {
            Divider()
            HStack(alignment: .firstTextBaseline) {
              VStack(alignment: .leading, spacing: 3) {
                Text("Next step").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(verbatim: AppLocalization.string(action.label)).font(.headline)
              }
              Spacer()
              nextActionButton(action)
            }
          }

          Divider()
          VStack(spacing: 0) {
            ForEach(snapshot.checks) { check in
              ReadinessCheckRow(check: check)
              if check.id != snapshot.checks.last?.id {
                Divider().padding(.leading, 30)
              }
            }
          }

          if let request = snapshot.verifiedRequest {
            Divider()
            Label("Verified by a real successful request", systemImage: "checkmark.seal.fill")
              .font(.headline)
              .foregroundStyle(.green)
            LabeledContent("Capability", value: request.capability)
            LabeledContent("Request ID") {
              Text(request.requestID)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            }
            LabeledContent(
              "Received",
              value: DateFormatter.computerMCPDateTime.string(from: request.timestamp)
            )
          }
        }
      }
    }
  }

  @ViewBuilder
  private var prerequisites: some View {
    JourneyCard(title: "Before you begin", systemImage: "checklist") {
      if journey == .chatgpt {
        InstructionRow(
          number: 1,
          title: "Confirm your ChatGPT plan supports Connectors",
          detail: "Account availability and organization policy are managed in ChatGPT."
        )
        InstructionRow(
          number: 2,
          title: "Install OpenAI tunnel-client",
          detail: "Computer MCP detects the executable and version; it does not download it."
        )
        Link(
          destination: URL(
            string:
              "https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt"
          )!
        ) {
          Label("Open OpenAI MCP documentation", systemImage: "arrow.up.right.square")
        }
        Link(destination: URL(string: "https://github.com/openai/tunnel-client/releases/latest")!) {
          Label("Download tunnel-client", systemImage: "arrow.down.circle")
        }
      } else {
        InstructionRow(
          number: 1,
          title: "Create a remotely managed named tunnel",
          detail: "Quick Tunnel and unauthenticated origins are not supported for this journey."
        )
        InstructionRow(
          number: 2,
          title: "Install cloudflared",
          detail: "Computer MCP detects the executable and version; it does not download it."
        )
        Link(
          destination: URL(
            string:
              "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
          )!
        ) {
          Label("Open Cloudflare install documentation", systemImage: "arrow.up.right.square")
        }
      }
    }
  }

  @ViewBuilder
  private var tunnelContent: some View {
    if journey == .chatgpt {
      chatGPTTunnelContent
    } else {
      cloudflareTunnelContent
    }
  }

  @ViewBuilder
  private var chatGPTTunnelContent: some View {
    JourneyCard(title: "OpenAI Secure MCP connection", systemImage: "network") {
      switch model.openAITunnels {
      case .idle, .loading:
        ProgressView().accessibilityLabel("Loading ChatGPT connections")
      case .failed(let message):
        Text(verbatim: AppLocalization.string(message))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Button("Retry") { model.refresh(.chatgpt) }
      case .loaded(let tunnels) where tunnels.isEmpty:
        Text(
          "Add the tunnel ID, tunnel-client profile, gateway profile, and OpenAI API key. The API key is stored in Keychain."
        )
        .foregroundStyle(.secondary)
        Button("Add ChatGPT Connection") { openAIEditor = .new }
      case .loaded(let tunnels):
        ForEach(tunnels) { tunnel in
          TunnelTaskRow(
            title: tunnel.displayName,
            detail: tunnel.tunnelIdentifier.map {
              AppLocalization.formatted("Tunnel %@ · %@", $0, tunnel.profileID)
            }
              ?? tunnel.profileID,
            state: tunnel.state,
            start: { model.startOpenAITunnel(id: tunnel.id) },
            stop: { model.stopOpenAITunnel(id: tunnel.id) },
            doctor: { model.doctorOpenAITunnel(id: tunnel.id) },
            edit: { openAIEditor = .edit(tunnel) }
          )
        }
      }
    }
  }

  @ViewBuilder
  private var cloudflareTunnelContent: some View {
    JourneyCard(title: "Cloudflare named tunnel", systemImage: "cloud") {
      switch model.cloudflareTunnels {
      case .idle, .loading:
        ProgressView().accessibilityLabel("Loading Cloudflare connections")
      case .failed(let message):
        Text(verbatim: AppLocalization.string(message))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Button("Retry") { model.refresh(.cloudflare) }
      case .loaded(let tunnels) where tunnels.isEmpty:
        Text(
          "Add the hostname and named-tunnel token. Computer MCP will create an access token for the protected loopback origin when requested."
        )
        .foregroundStyle(.secondary)
        Button("Add Cloudflare Connection") { cloudflareEditor = .new }
      case .loaded(let tunnels):
        ForEach(tunnels) { tunnel in
          TunnelTaskRow(
            title: tunnel.tunnelName,
            detail: "https://\(tunnel.publicHostname)/mcp · \(tunnel.profileID)",
            state: tunnel.state,
            start: { model.startCloudflareTunnel(id: tunnel.id) },
            stop: { model.stopCloudflareTunnel(id: tunnel.id) },
            doctor: { model.doctorCloudflareTunnel(id: tunnel.id) },
            edit: { cloudflareEditor = .edit(tunnel) }
          )
        }
      }
    }
  }

  @ViewBuilder
  private var consumerVerification: some View {
    JourneyCard(title: "Verify with a real request", systemImage: "checkmark.seal") {
      if journey == .chatgpt {
        Text(
          "After the gateway and tunnel are Ready, open ChatGPT, create or update the Connector with the tunnel endpoint, then invoke one Computer MCP tool in a new chat."
        )
        .foregroundStyle(.secondary)
        Link(destination: URL(string: "https://chatgpt.com")!) {
          Label("Open ChatGPT", systemImage: "arrow.up.right.square")
        }
      } else {
        Text(
          "After the gateway and named tunnel are Ready, connect the intended public MCP consumer using the one-time Computer MCP Access Token, then invoke one tool."
        )
        .foregroundStyle(.secondary)
        Text(
          "The journey becomes Verified only when the audit event matches this tunnel, profile, caller identity, and current start time."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      Button("Check for Request") { model.refresh(workspace) }
    }
  }

  private var recovery: some View {
    JourneyCard(title: "Need help?", systemImage: "lifepreserver") {
      Text(
        "You can retry any step without recreating the connection. Secrets remain in Keychain and are never included in diagnostics."
      )
      .foregroundStyle(.secondary)
      HStack {
        Button("Retry All Checks") { model.refresh(workspace) }
        Button("Open Advanced Diagnostics") {
          model.selectedWorkspace = .diagnostics
        }
      }
    }
  }

  private func statusExplanation(_ status: ProductReadinessStatus) -> String {
    switch status {
    case .notConfigured: "Add a connection to begin."
    case .blocked: "A required dependency or component is unavailable."
    case .needsAttention: "Complete the next required step."
    case .ready: "The transport is healthy. Send a real request to verify it."
    case .verified: "A matching successful request has been observed."
    }
  }

  @ViewBuilder
  private func nextActionButton(_ action: ProductReadinessNextAction) -> some View {
    switch action.kind {
    case .openURL:
      if let url = URL(string: action.redactedTarget) {
        Link(destination: url) {
          Text(verbatim: AppLocalization.string(action.label))
        }
      }
    case .openApp:
      Button {
        perform(action)
      } label: {
        Text(verbatim: AppLocalization.string(action.label))
      }
    case .runCommand:
      Button {
        perform(action)
      } label: {
        Text(verbatim: AppLocalization.string(action.label))
      }
    }
  }

  private func perform(_ action: ProductReadinessNextAction) {
    if action.redactedTarget == "gateway.start"
      || (action.redactedTarget == "home" && model.currentServiceState != .running)
    {
      model.startGateway()
    } else if action.redactedTarget == "home" {
      model.selectedWorkspace = .home
    } else if action.redactedTarget == "diagnostics" {
      model.selectedWorkspace = .diagnostics
    } else if action.redactedTarget.contains("tunnel") {
      model.selectedWorkspace = workspace
    } else {
      model.refresh(workspace)
    }
  }
}

private struct JourneyCard<Content: View>: View {
  let title: String
  let systemImage: String
  let content: Content

  init(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Text(verbatim: AppLocalization.string(title))
      } icon: {
        Image(systemName: systemImage)
      }
      .font(.title3.weight(.semibold))
      content
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12).stroke(.separator)
    }
  }
}

private struct ReadinessCheckRow: View {
  let check: ProductReadinessCheck

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: check.status.systemImage)
        .foregroundStyle(check.status.color)
        .accessibilityHidden(true)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(verbatim: AppLocalization.string(check.summary)).fontWeight(.medium)
          if !check.required {
            Text("Optional").font(.caption).foregroundStyle(.secondary)
          }
        }
        Text(verbatim: AppLocalization.string(check.detail))
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
    .accessibilityValue(check.status.localizedLabel)
  }
}

private struct InstructionRow: View {
  let number: Int
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text(String(number))
        .font(.caption.weight(.bold))
        .frame(width: 22, height: 22)
        .background(.quaternary, in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: AppLocalization.string(title)).fontWeight(.medium)
        Text(verbatim: AppLocalization.string(detail))
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct TunnelTaskRow: View {
  let title: String
  let detail: String
  let state: ServiceState
  let start: () -> Void
  let stop: () -> Void
  let doctor: () -> Void
  let edit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text(title).font(.headline)
        StateBadge(text: state.label, color: state.color, systemImage: state.systemImage)
        Spacer()
        if state == .running || state == .degraded {
          Button("Stop", action: stop)
        } else {
          Button("Start", action: start)
            .disabled(state == .starting || state == .stopping)
        }
        Button("Run Diagnostics", action: doctor)
        Button("Edit", action: edit)
          .disabled(state == .running || state == .starting)
      }
      Text(detail)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    .padding(.vertical, 6)
  }
}
