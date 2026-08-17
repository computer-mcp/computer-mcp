import AppKit
import ComputerMCP
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceHeader(
        "Home",
        subtitle: "Gateway runtime and local data plane"
      ) {
        HStack {
          gatewayAction
          RefreshButton {
            model.refresh(.home)
          }
        }
      }

      Divider()

      switch model.status {
      case .idle, .loading:
        LoadingWorkspaceView(title: "Loading gateway status")
      case .failed(let message):
        FailedWorkspaceView(message: message) {
          model.refresh(.home)
        }
      case .loaded(let snapshot):
        statusContent(snapshot)
      }
    }
    .sheet(item: $model.codexRegistrationPresentation) { presentation in
      CodexRegistrationConfirmation(presentation: presentation)
        .environmentObject(model)
    }
    .alert(
      "Codex registration complete",
      isPresented: Binding(
        get: { model.codexRegistrationMessage != nil },
        set: { if !$0 { model.dismissCodexRegistrationMessage() } }
      )
    ) {
      Button("OK") { model.dismissCodexRegistrationMessage() }
    } message: {
      Text(verbatim: AppLocalization.string(model.codexRegistrationMessage ?? ""))
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
      Section("Next step") {
        if let recommendation = nextRecommendation {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
              Text(verbatim: AppLocalization.string(recommendation.title)).font(.headline)
              Text(verbatim: AppLocalization.string(recommendation.detail))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(
              AppLocalization.string(recommendation.buttonLabel),
              action: recommendation.action
            )
          }
        } else {
          Label("All configured connections are healthy.", systemImage: "checkmark.seal.fill")
            .foregroundStyle(.green)
        }
      }

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
          LabeledContent("Active profile") {
            Text(verbatim: AppLocalization.string(profile))
          }
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
              Text(verbatim: AppLocalization.string(snapshot.launchAtLogin.label))
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
          value: AppLocalization.formatted(
            "%@ of %@ running",
            String(snapshot.runningProviderCount),
            String(snapshot.providerCount)
          )
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
          LabeledContent("~/.local/bin/computer-mcp", value: cli.state.localizedLabel)
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

      Section("Connect a local MCP client") {
        LabeledContent("App") {
          StateBadge(text: "Running", color: .green, systemImage: "checkmark.circle.fill")
        }
        LabeledContent("Gateway") {
          StateBadge(
            text: snapshot.serviceState.label,
            color: snapshot.serviceState.color,
            systemImage: snapshot.serviceState.systemImage
          )
        }

        switch model.localMCPConnection {
        case .idle, .loading:
          ProgressView().accessibilityLabel("Preparing local MCP command")
        case .failed(let message):
          Label(AppLocalization.string(message), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
          Button("Retry") { model.refresh(.home) }
        case .loaded(let connection):
          LabeledContent("CLI") {
            Text(verbatim: connection.cliInstallation.state.localizedLabel)
          }
          LabeledContent("Command") {
            Text(connection.command)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .lineLimit(2)
              .truncationMode(.middle)
          }
          LabeledContent("Arguments") {
            Text(connection.arguments.joined(separator: " "))
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
          }
          HStack {
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(connection.displayCommand, forType: .string)
            } label: {
              Label("Copy stdio Command", systemImage: "doc.on.doc")
            }
            Button {
              model.previewCodexRegistration()
            } label: {
              Label("Register with Codex", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .disabled(
              model.isActionRunning("codex.preview")
                || model.isActionRunning("codex.install")
            )
          }
        }

        Text(
          "The Codex consumer registration uses the App-owned bridge. Internal Codex providers are configured separately under Providers."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Remote connections") {
        readinessLink(.chatgpt, workspace: .chatgpt)
        readinessLink(.cloudflare, workspace: .cloudflare)
      }

      if let lastError = snapshot.lastError {
        Section("Last error") {
          Label {
            Text(verbatim: AppLocalization.errorDescription(lastError))
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
          }
          .foregroundStyle(.red)
          .textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private func readinessLink(_ journey: ProductJourney, workspace: AppWorkspace) -> some View {
    HStack {
      Label(
        journey == .chatgpt ? "ChatGPT" : "Cloudflare",
        systemImage: workspace.systemImage
      )
      Spacer()
      if case .loaded(let snapshots) = model.readiness,
        let snapshot = snapshots.first(where: { $0.journey == journey })
      {
        StateBadge(
          text: snapshot.status.label,
          color: snapshot.status.color,
          systemImage: snapshot.status.systemImage
        )
      } else {
        ProgressView().controlSize(.small)
      }
      Button("Open") { model.selectedWorkspace = workspace }
    }
  }

  private var nextRecommendation: HomeRecommendation? {
    guard case .loaded(let snapshots) = model.readiness else {
      return HomeRecommendation(
        title: "Check connection health",
        detail: "Refresh the App, gateway, and configured transports.",
        buttonLabel: "Refresh",
        action: { model.refresh(.home) }
      )
    }

    if let local = snapshots.first(where: { $0.journey == .local }),
      local.status != .ready,
      local.status != .verified
    {
      if local.checks.contains(where: { $0.id == "gateway.running" && $0.status == .fail }) {
        return HomeRecommendation(
          title: "Start the gateway",
          detail: "The local MCP bridge and remote transports depend on the App-owned gateway.",
          buttonLabel: "Start",
          action: { model.startGateway() }
        )
      }
      if local.checks.contains(where: { $0.id == "local.cli" && $0.status == .fail }) {
        return HomeRecommendation(
          title: "Install the App-owned CLI",
          detail: "Install the signed embedded bridge before registering a local MCP client.",
          buttonLabel: "Install",
          action: { model.installCommandLineTool() }
        )
      }
      return HomeRecommendation(
        title: local.nextAction?.label ?? "Finish local MCP setup",
        detail: "Prepare the App-owned CLI bridge for local MCP clients.",
        buttonLabel: "Review",
        action: { model.refresh(.home) }
      )
    }

    if let remote = snapshots.first(where: {
      $0.journey != .local && $0.status != .verified && $0.status != .notConfigured
    }) {
      let target: AppWorkspace = remote.journey == .chatgpt ? .chatgpt : .cloudflare
      return HomeRecommendation(
        title: remote.nextAction?.label ?? "Verify the remote connection",
        detail: AppLocalization.formatted(
          "Continue the %@ connection from its dedicated setup page.",
          target.title
        ),
        buttonLabel: "Continue",
        action: { model.selectedWorkspace = target }
      )
    }

    if snapshots.contains(where: { $0.journey != .local && $0.status == .notConfigured }) {
      return HomeRecommendation(
        title: "Choose a remote connection when you need one",
        detail: "ChatGPT and Cloudflare each have a complete guided setup page.",
        buttonLabel: "Connect ChatGPT",
        action: { model.selectedWorkspace = .chatgpt }
      )
    }
    return nil
  }
}

private struct HomeRecommendation {
  let title: String
  let detail: String
  let buttonLabel: String
  let action: () -> Void
}

private struct CodexRegistrationConfirmation: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: ComputerMCPAppModel

  let presentation: CodexRegistrationPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Register Computer MCP with Codex?")
        .font(.title2.weight(.semibold))
      Text("Review the exact command before Computer MCP changes your Codex MCP registration.")
        .foregroundStyle(.secondary)
      Text(displayCommand)
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      Text("No API keys, tunnel tokens, or TOML paths are included.")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Register") {
          model.installCodexRegistration()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 640)
  }

  private var displayCommand: String {
    ([presentation.invocation.codexCLI] + presentation.invocation.arguments)
      .map(shellToken)
      .joined(separator: " ")
  }

  private func shellToken(_ value: String) -> String {
    guard !value.isEmpty,
      value.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:")).contains($0)
      })
    else {
      return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return value
  }
}

struct WorkspacesView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel
  @State private var isWorkspaceImporterPresented = false
  @State private var isWorkspacePickerPresented = false

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceHeader(
        "Workspaces",
        subtitle: "Folder grants and persistent bookmark health"
      ) {
        HStack {
          Button {
            presentWorkspacePicker()
          } label: {
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
        title: AppLocalization.verbatimText(
          AppLocalization.formatted("Remove %@?", workspace.displayName)
        ),
        message: Text(
          "This removes the local workspace grant. It does not delete the folder or its contents."
        ),
        primaryButton: .destructive(Text("Remove")) {
          model.removeWorkspace(id: workspace.id)
        },
        secondaryButton: .cancel()
      )
    }
    .fileImporter(
      isPresented: $isWorkspaceImporterPresented,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      handleWorkspaceImport(result)
    }
    .sheet(isPresented: $isWorkspacePickerPresented) {
      WorkspaceDirectoryPicker { url in
        model.addWorkspace(at: url)
      }
    }
  }

  private func presentWorkspacePicker() {
    if #available(macOS 27.0, *) {
      isWorkspacePickerPresented = true
    } else {
      isWorkspaceImporterPresented = true
    }
  }

  private func handleWorkspaceImport(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      guard let url = urls.first else {
        return
      }
      model.addWorkspace(at: url)
    case .failure(let error):
      let cocoaError = error as NSError
      guard cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError
      else {
        return
      }
      model.presentedError = PresentedAppError(
        title: "Unable to select workspace",
        message: AppLocalization.errorDescription(error)
      )
    }
  }
}

private struct WorkspaceDirectoryPicker: View {
  @Environment(\.dismiss) private var dismiss

  let onSelect: (URL) -> Void

  @State private var currentDirectory = FileManager.default.homeDirectoryForCurrentUser
  @State private var directories: [URL] = []
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Add Workspace")
            .font(.title2.weight(.semibold))
          Text("Add a folder to create a persistent local workspace grant.")
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        } label: {
          Label("Home", systemImage: "house")
        }

        Button {
          navigate(to: parentDirectory)
        } label: {
          Label("Up One Level", systemImage: "arrow.up")
        }
        .disabled(currentDirectory.path == "/")
      }
      .padding(20)

      Divider()

      HStack(spacing: 9) {
        Image(systemName: "folder.fill")
          .foregroundStyle(Color.accentColor)
        Text(verbatim: currentDirectory.path)
          .font(.system(.callout, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        Spacer()
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)

      Divider()

      Group {
        if let errorMessage {
          ContentUnavailableView(
            "Unable to read this folder",
            systemImage: "exclamationmark.triangle",
            description: Text(verbatim: errorMessage)
          )
        } else if directories.isEmpty {
          ContentUnavailableView("No subfolders", systemImage: "folder")
        } else {
          List(directories, id: \.path) { directory in
            Button {
              navigate(to: directory)
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "folder")
                  .foregroundStyle(Color.accentColor)
                  .frame(width: 20)
                Text(verbatim: FileManager.default.displayName(atPath: directory.path))
                  .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.forward")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.tertiary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
          .listStyle(.inset)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Current folder")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(verbatim: displayName(for: currentDirectory))
            .fontWeight(.medium)
        }

        Spacer()

        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Add") {
          let selectedDirectory = currentDirectory
          dismiss()
          onSelect(selectedDirectory)
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(20)
    }
    .frame(minWidth: 680, idealWidth: 760, minHeight: 480, idealHeight: 560)
    .task(id: currentDirectory) {
      loadCurrentDirectory()
    }
  }

  private var parentDirectory: URL {
    currentDirectory.deletingLastPathComponent().standardizedFileURL
  }

  private func navigate(to url: URL) {
    currentDirectory = url.standardizedFileURL
    directories = []
    errorMessage = nil
  }

  private func loadCurrentDirectory() {
    do {
      let urls = try FileManager.default.contentsOfDirectory(
        at: currentDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
      directories = urls.filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      }
      .sorted {
        FileManager.default.displayName(atPath: $0.path).localizedStandardCompare(
          FileManager.default.displayName(atPath: $1.path)
        ) == .orderedAscending
      }
      errorMessage = nil
    } catch {
      directories = []
      errorMessage = AppLocalization.errorDescription(error)
    }
  }

  private func displayName(for url: URL) -> String {
    let displayName = FileManager.default.displayName(atPath: url.path)
    return displayName.isEmpty ? url.path : displayName
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
          AppLocalization.verbatimText(
            AppLocalization.formatted(
              "Resolved %@",
              lastResolvedAt.formatted(.relative(presentation: .named))
            )
          )
          .font(.caption)
          .foregroundStyle(.tertiary)
        }
      }

      Spacer()

      Toggle(
        isOn: Binding(
          get: { workspace.isSelected },
          set: { enabled in
            model.setWorkspaceEnabled(enabled, workspace: workspace)
          }
        )
      ) {
        AppLocalization.verbatimText(
          AppLocalization.formatted(
            "Enabled for %@",
            workspace.activeProfileID
          )
        )
      }
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
