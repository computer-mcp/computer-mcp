import SwiftUI

struct AppShellView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel

  var body: some View {
    NavigationSplitView {
      List(selection: $model.selectedWorkspace) {
        ForEach(AppWorkspaceGroup.allCases) { group in
          Section(AppLocalization.string(group.title)) {
            ForEach(AppWorkspace.allCases.filter { $0.group == group }) { workspace in
              Label {
                Text(verbatim: AppLocalization.string(workspace.title))
              } icon: {
                Image(systemName: workspace.systemImage)
              }
              .tag(workspace)
            }
          }
        }

        Section {
          Button {
            model.showWelcome()
          } label: {
            Label("Show Welcome", systemImage: "sparkles")
          }
          .buttonStyle(.plain)
        }
      }
      .navigationTitle("Computer MCP")
      .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
    } detail: {
      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    .sheet(
      isPresented: Binding(
        get: { model.isPresentingWelcome },
        set: { if !$0 { model.finishWelcome() } }
      )
    ) {
      WelcomeView()
        .environmentObject(model)
    }
    .alert(item: $model.presentedError) { error in
      Alert(
        title: Text(verbatim: AppLocalization.string(error.title)),
        message: Text(verbatim: AppLocalization.errorDescription(error.message)),
        dismissButton: .default(Text("OK"))
      )
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch model.selectedWorkspace ?? .home {
    case .home:
      HomeView()
    case .chatgpt:
      JourneyView(journey: .chatgpt)
    case .cloudflare:
      JourneyView(journey: .cloudflare)
    case .workspaces:
      WorkspacesView()
    case .profiles:
      ProfilesView()
    case .providers:
      ProvidersView()
    case .tunnels:
      TunnelsView()
    case .permissions:
      PermissionsView()
    case .audit:
      AuditView()
    case .diagnostics:
      DiagnosticsView()
    }
  }
}

private struct WelcomeView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Welcome to Computer MCP")
            .font(.largeTitle.weight(.semibold))
          Text("Choose the connection you want to set up. You can return here at any time.")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          model.finishWelcome()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Close Welcome")
        .accessibilityLabel("Close Welcome")
      }

      VStack(spacing: 12) {
        WelcomeChoice(
          title: "Connect ChatGPT",
          detail:
            "Configure OpenAI Secure MCP, start the gateway, and verify a real Connector request.",
          systemImage: "bubble.left.and.text.bubble.right"
        ) {
          model.finishWelcome(selecting: .chatgpt)
        }
        WelcomeChoice(
          title: "Connect through Cloudflare",
          detail: "Publish the access-token-protected gateway through your named tunnel.",
          systemImage: "cloud"
        ) {
          model.finishWelcome(selecting: .cloudflare)
        }
        WelcomeChoice(
          title: "Connect a local MCP client",
          detail: "Copy the stdio command or register Computer MCP with Codex.",
          systemImage: "terminal"
        ) {
          model.finishWelcome(selecting: .home)
        }
      }

      HStack {
        Text("Normal App use does not require a TOML file.")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Explore Dashboard") {
          model.finishWelcome(selecting: .home)
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(30)
    .frame(minWidth: 680, idealWidth: 760, minHeight: 560)
  }
}

private struct WelcomeChoice: View {
  let title: String
  let detail: String
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 16) {
        Image(systemName: systemImage)
          .font(.title2)
          .foregroundStyle(.tint)
          .frame(width: 36)
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: AppLocalization.string(title))
            .font(.headline)
            .foregroundStyle(.primary)
          Text(verbatim: AppLocalization.string(detail))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .foregroundStyle(.secondary)
      }
      .padding(15)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(.background, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .stroke(.separator, lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityHint(
      AppLocalization.formatted("Opens the %@ setup page", AppLocalization.string(title))
    )
  }
}
