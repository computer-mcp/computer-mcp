import AppKit
import ComputerMCP
import SwiftUI

struct StatusView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceHeader(
        "Status",
        subtitle: "Gateway runtime and local data plane"
      ) {
        HStack {
          gatewayAction
          RefreshButton {
            model.refresh(.status)
          }
        }
      }

      Divider()

      switch model.status {
      case .idle, .loading:
        LoadingWorkspaceView(title: "Loading gateway status")
      case .failed(let message):
        FailedWorkspaceView(message: message) {
          model.refresh(.status)
        }
      case .loaded(let snapshot):
        statusContent(snapshot)
      }
    }
  }

  @ViewBuilder
  private var gatewayAction: some View {
    switch model.currentServiceState {
    case .running, .degraded:
      Button {
        model.stopGateway()
      } label: {
        Label("Stop", systemImage: "stop.fill")
      }
      .disabled(model.isActionRunning("gateway.stop"))
    case .starting, .stopping:
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Gateway state changing")
    case .failed, .stopped, .none:
      Button {
        model.startGateway()
      } label: {
        Label("Start", systemImage: "play.fill")
      }
      .disabled(model.isActionRunning("gateway.start"))
    }
  }

  private func statusContent(_ snapshot: AppStatusSnapshot) -> some View {
    Form {
      Section("Gateway") {
        LabeledContent("State") {
          StateBadge(
            text: snapshot.serviceState.label,
            color: snapshot.serviceState.color,
            systemImage: snapshot.serviceState.systemImage
          )
        }

        LabeledContent("Version", value: snapshot.version)

        if let profile = snapshot.activeProfileName {
          LabeledContent("Active profile", value: profile)
        }

        if let startedAt = snapshot.startedAt {
          LabeledContent(
            "Started",
            value: DateFormatter.computerMCPDateTime.string(from: startedAt)
          )
        }

        if let processIdentifier = snapshot.processIdentifier {
          LabeledContent("Process ID", value: String(processIdentifier))
        }

        LabeledContent("Launch at login") {
          HStack(spacing: 10) {
            if snapshot.launchAtLogin == .requiresApproval
              || snapshot.launchAtLogin == .unavailable
            {
              Text(snapshot.launchAtLogin.label)
                .font(.caption)
                .foregroundStyle(
                  snapshot.launchAtLogin == .requiresApproval ? Color.orange : Color.secondary
                )
            }
            Toggle(
              "Launch at login",
              isOn: Binding(
                get: { snapshot.launchAtLogin == .enabled },
                set: { model.setLaunchAtLoginEnabled($0) }
              )
            )
            .labelsHidden()
            .disabled(
              snapshot.launchAtLogin == .unavailable
                || model.isActionRunning("launch-at-login")
            )
          }
        }
      }

      Section("Local data plane") {
        LabeledContent("Workspaces", value: String(snapshot.activeWorkspaceCount))
        LabeledContent(
          "Providers",
          value: "\(snapshot.runningProviderCount) of \(snapshot.providerCount) running"
        )
        LabeledContent("Tunnels", value: String(snapshot.runningTunnelCount))

        if let socketPath = snapshot.socketPath {
          LabeledContent("Socket") {
            Text(socketPath)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
          }
        }
      }

      Section("Command line tool") {
        if let cli = model.cliInstallationStatus {
          LabeledContent("~/.local/bin/computer-mcp", value: cli.state.rawValue)
          if !cli.destinationDirectoryIsOnPath {
            Label(
              "Add ~/.local/bin to PATH to invoke computer-mcp by name.",
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
          }
        }
        Button {
          model.installCommandLineTool()
        } label: {
          Label("Install Command Line Tool", systemImage: "terminal")
        }
        .disabled(model.isActionRunning("cli.install"))
      }

      if let lastError = snapshot.lastError {
        Section("Last error") {
          Label(lastError, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
  }
}

struct WorkspacesView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceHeader(
        "Workspaces",
        subtitle: "Folder grants and persistent bookmark health"
      ) {
        HStack {
          Button(action: chooseWorkspaceFolder) {
            Label("Add", systemImage: "plus")
          }
          .accessibilityIdentifier("workspace.add")
          .disabled(model.isActionRunning("workspace.add"))

          RefreshButton {
            model.refresh(.workspaces)
          }
        }
      }

      Divider()

      switch model.workspaces {
      case .idle, .loading:
        LoadingWorkspaceView(title: "Loading workspaces")
      case .failed(let message):
        FailedWorkspaceView(message: message) {
          model.refresh(.workspaces)
        }
      case .loaded(let workspaces) where workspaces.isEmpty:
        EmptyWorkspaceView(
          title: "No registered workspaces",
          detail: "Add a folder to create a persistent local workspace grant.",
          systemImage: "folder.badge.plus"
        )
      case .loaded(let workspaces):
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(workspaces) { workspace in
              WorkspaceRow(workspace: workspace)
              Divider()
            }
          }
          .padding(.horizontal, 16)
        }
      }
    }
    .alert(item: $model.pendingWorkspaceRemoval) { workspace in
      Alert(
        title: Text("Remove \(workspace.displayName)?"),
        message: Text(
          "This removes the local workspace grant. It does not delete the folder or its contents."
        ),
        primaryButton: .destructive(Text("Remove")) {
          model.removeWorkspace(id: workspace.id)
        },
        secondaryButton: .cancel()
      )
    }
  }

  private func chooseWorkspaceFolder() {
    let panel = NSOpenPanel()
    panel.title = "Add Workspace"
    panel.prompt = "Add Workspace"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.resolvesAliases = true

    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        return
      }
      Task { @MainActor in
        model.addWorkspace(at: url)
      }
    }
  }
}

private struct WorkspaceRow: View {
  @EnvironmentObject private var model: ComputerMCPAppModel

  let workspace: WorkspaceSummary

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: workspace.isSelected ? "folder.fill.badge.checkmark" : "folder")
        .font(.title3)
        .foregroundStyle(workspace.isEnabled ? Color.accentColor : Color.secondary)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(workspace.displayName)
            .fontWeight(.medium)
          StateBadge(
            text: workspace.health.label,
            color: workspace.health.color
          )
        }

        Text(workspace.path)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(workspace.path)

        if let lastResolvedAt = workspace.lastResolvedAt {
          Text("Resolved \(lastResolvedAt.formatted(.relative(presentation: .named)))")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }

      Spacer()

      Toggle(
        "Enabled for \(workspace.activeProfileID)",
        isOn: Binding(
          get: { workspace.isSelected },
          set: { enabled in
            model.setWorkspaceEnabled(enabled, workspace: workspace)
          }
        )
      )
      .accessibilityIdentifier("workspace.\(workspace.id).enabled")
      .toggleStyle(.switch)
      .help("Grant this workspace to the active profile")

      Button {
        model.revealWorkspace(workspace)
      } label: {
        Image(systemName: "arrow.right.circle")
      }
      .buttonStyle(.borderless)
      .help("Show in Finder")
      .accessibilityLabel("Show \(workspace.displayName) in Finder")

      Button(role: .destructive) {
        model.requestWorkspaceRemoval(workspace)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Remove workspace grant")
      .accessibilityLabel("Remove \(workspace.displayName)")
    }
    .padding(.vertical, 6)
  }
}
