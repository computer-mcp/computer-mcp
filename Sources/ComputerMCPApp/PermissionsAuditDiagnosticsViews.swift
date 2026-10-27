import AppKit
import ComputerMCPConfiguration
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPMacOS
import ComputerMCPPermissions
import SwiftUI

struct PermissionsView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel
  @State private var showsRequests = true

  var body: some View {
    VStack(spacing: 0) {
      ProjectHeader(
        "Permissions",
        subtitle: "Client permissions and macOS privacy access"
      ) {
        RefreshButton {
          model.refresh(.permissions)
        }
      }

      Divider()

      Picker("Permissions", selection: $showsRequests) {
        Text("Permission requests", bundle: AppLocalization.resourceBundle).tag(true)
        Text("macOS privacy", bundle: AppLocalization.resourceBundle).tag(false)
      }
      .pickerStyle(.segmented).padding(16)

      if showsRequests {
        PermissionRequestsView()
      } else {
        switch model.permissions {
        case .idle, .loading:
          LoadingProjectView(title: "Checking permissions")
        case .failed(let message):
          FailedProjectView(message: message) {
            model.refresh(.permissions)
          }
        case .loaded(let permissions) where permissions.isEmpty:
          EmptyProjectView(
            title: "No permission checks available",
            detail: "Enabled providers have not reported any macOS permission requirements.",
            systemImage: "hand.raised"
          )
        case .loaded(let permissions):
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(permissions) { permission in
                PermissionRow(permission: permission)
                Divider()
              }
            }
            .padding(.horizontal, 16)
          }
        }
      }
    }
  }
}

private struct PermissionRequestsView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel
  @State private var authorityReview: PermissionAuthorityReviewSnapshot?

  var body: some View {
    switch model.permissionRequests {
    case .idle, .loading:
      LoadingProjectView(title: "Loading permission requests")
    case .failed(let message):
      FailedProjectView(message: message) { model.refresh(.permissions) }
    case .loaded(let view):
      let pending = view.requests.filter {
        $0.request.status == .pending && $0.request.expiresAt > Date()
      }
      VStack(spacing: 0) {
        if view.suspended || !view.unconfirmedProfileIDs.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("Saved authority needs review", bundle: AppLocalization.resourceBundle).font(
              .headline)
            Text(
              "Saved permissions remain inactive until you review and confirm them for the current epoch.",
              bundle: AppLocalization.resourceBundle
            )
            .foregroundStyle(.secondary)
            Button(AppLocalization.string("Review saved authority…")) {
              authorityReview = .init(view: view, names: model.permissionObjectNames)
            }.disabled(view.epoch == nil)
              .accessibilityIdentifier("permission.authority.review")
          }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
          Divider()
        }
        if !view.sources.isEmpty {
          PermissionManagedSourcesView(sources: view.sources)
          Divider()
        }
        if pending.isEmpty {
          EmptyProjectView(
            title: "No permission requests", detail: "Requests from connected clients appear here.",
            systemImage: "checkmark.shield")
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
              ForEach(pending, id: \.request.id) { item in
                requestRow(
                  item, revision: view.revision,
                  suspended: view.suspended
                    || item.profileID.map(view.unconfirmedProfileIDs.contains) == true)
                Divider()
              }
            }.padding(16)
          }
        }
      }.sheet(item: $authorityReview) { reviewed in
        PermissionAuthorityReview(snapshot: reviewed) {
          try await model.confirmPermissionAuthority(reviewed.view)
        }
      }

    }
  }

  private func requestRow(_ item: GatewayPermissionRequestView, revision: UInt64, suspended: Bool)
    -> some View
  {
    let request = item.request
    return VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: request.permissionTitle(names: model.permissionObjectNames)).font(.headline)
      if case .permission(let value) = request.content {
        LabeledContent(
          AppLocalization.string("Access"),
          value: AppLocalization.string(value.requirement.value.permissionTitle))
      }
      if let profile = item.profileID {
        LabeledContent(
          AppLocalization.string("Profile"), value: PermissionObjectNames.profile(profile))
      }
      LabeledContent(
        AppLocalization.string("Client"),
        value: request.principalTitle(names: model.permissionObjectNames))
      LabeledContent(AppLocalization.string("Requested by"), value: request.invocation.tool)
      Text(verbatim: request.scopeTitle(names: model.permissionObjectNames)).textSelection(.enabled)
      if let purpose = request.pluginPurpose {
        LabeledContent(AppLocalization.string("Plugin purpose"), value: purpose)
      }
      Text(
        "After allowing access, ask the client to retry its request. The App does not repeat the operation.",
        bundle: AppLocalization.resourceBundle
      ).font(.caption).foregroundStyle(.secondary)
      if item.alwaysIsShared {
        Text(
          "Always applies to every client using this profile.",
          bundle: AppLocalization.resourceBundle
        ).font(.caption).foregroundStyle(.secondary)
      }
      LabeledContent(
        AppLocalization.string("Expires"),
        value: request.expiresAt.formatted(date: .abbreviated, time: .shortened)
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(AppLocalization.string("Deny"), role: .cancel) {
          model.answerPermissionRequest(id: request.id, answer: nil, expectedRevision: revision)
        }.accessibilityIdentifier("permission.request.\(request.id).deny")
        if case .projectRegistration = request.content {
          Text("Project registration is unavailable.", bundle: AppLocalization.resourceBundle)
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Button(AppLocalization.string("Only this time")) {
            model.answerPermissionRequest(
              id: request.id, answer: .onlyThisTime, expectedRevision: revision)
          }.accessibilityIdentifier("permission.request.\(request.id).once")
          Button(AppLocalization.string("Always")) {
            model.answerPermissionRequest(
              id: request.id, answer: .always, expectedRevision: revision)
          }.accessibilityIdentifier("permission.request.\(request.id).always")
        }
      }.disabled(suspended || model.isActionRunning("permission.answer.\(request.id)"))
    }.accessibilityElement(children: .contain)
      .accessibilityIdentifier("permission.request.\(request.id)")
  }
}

private struct PermissionManagedSourcesView: View {
  let sources: [GatewayManagedPolicyView]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(sources.filter { $0.failure != nil }.enumerated()), id: \.offset) { _, source in
        Text(verbatim: source.location + " · " + (source.failure ?? ""))
          .font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      DisclosureGroup(AppLocalization.string("Managed sources")) {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
              VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: source.source.rawValue + " · " + source.location)
                if let profile = source.profileID { Text(verbatim: profile.rawValue) }
                LabeledContent(
                  AppLocalization.string("State"),
                  value: AppLocalization.string(
                    source.failure != nil
                      ? "Unavailable" : source.revision == "absent" ? "Not configured" : "Available"
                  ))
                LabeledContent(AppLocalization.string("Revision"), value: source.revision)
              }.font(.caption).textSelection(.enabled)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 180)
      }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension PermissionRequest {
  fileprivate func principalTitle(names: PermissionObjectNames) -> String {
    switch invocation.principal {
    case .client(let id): id
    case .plugin(.package(let id)): names.plugin(id)
    case .plugin(.localServer(let id)): names.server(id)
    }
  }
  fileprivate func permissionTitle(names: PermissionObjectNames) -> String {
    switch content {
    case .permission(let value): names.title(for: value.requirement.permission)
    case .network: AppLocalization.string("Network access")
    case .projectRegistration: AppLocalization.string("Project access")
    }
  }
  fileprivate func scopeTitle(names: PermissionObjectNames) -> String {
    switch content {
    case .permission(let value):
      switch value.scope {
      case .principal: AppLocalization.string(value.requirement.value.permissionTitle)
      case .project(let id): names.project(id)
      case .path(let path): path.string
      case .host(let host, let project): "\(host) · \(names.project(project))"
      }
    case .network(let value): "\(value.host) · \(names.project(value.projectID))"
    case .projectRegistration(let value): value.path.string
    }
  }
  fileprivate var pluginPurpose: String? {
    switch content {
    case .permission(let value): value.pluginPurpose
    case .network(let value): value.pluginPurpose
    case .projectRegistration: nil
    }
  }
}

extension Permission {
  var permissionTitle: String {
    switch self {
    case .project(let id): "Project · \(id)"
    case .filesAndFolders(let category): category.permissionTitle
    case .plugin(let id): "Plugin · \(id)"
    case .mcpServer(let id): "MCP server · \(id)"
    case .screen: "Screen"
    case .desktopControl: "Desktop control"
    case .localNetwork: "Local network"
    case .machineInformation: "Machine information"
    case .unifiedLogs: "Unified logs"
    case .skills: "Skills"
    }
  }
}

private struct PermissionRow: View {
  @EnvironmentObject private var model: ComputerMCPAppModel
  let permission: PermissionSummary

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: permissionIcon)
        .font(.title3)
        .foregroundStyle(permission.state.color)
        .frame(width: 26)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(verbatim: AppLocalization.string(permission.displayName))
            .fontWeight(.medium)
          StateBadge(
            text: permission.state.label,
            color: permission.state.color
          )
        }
        Text(verbatim: AppLocalization.string(permission.detail))
          .foregroundStyle(.secondary)
        AppLocalization.verbatimText(
          AppLocalization.formatted(
            "Checked %@",
            permission.checkedAt.formatted(.relative(presentation: .named))
          )
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
      }

      Spacer()

      if permission.state != .granted {
        Button {
          model.requestPermission(permission)
        } label: {
          Label("Request Access", systemImage: "cursorarrow.click.2")
        }
        .disabled(model.isActionRunning("permission.request.\(permission.id)"))
        .accessibilityIdentifier("permission.\(permission.id).request")
      }

      if permission.settingsURL != nil {
        Button {
          model.openPermissionSettings(permission)
        } label: {
          Image(systemName: "gear")
        }
        .help("Open System Settings")
        .accessibilityLabel(
          AppLocalization.formatted(
            "Open %@ settings", AppLocalization.string(permission.displayName))
        )
        .accessibilityIdentifier("permission.\(permission.id).settings")
      }
    }
    .padding(.vertical, 7)
  }

  private var permissionIcon: String {
    switch permission.state {
    case .granted: "checkmark.shield.fill"
    case .denied: "xmark.shield.fill"
    case .notGranted: "exclamationmark.shield.fill"
    case .notDetermined: "questionmark.diamond"
    case .unavailable: "shield.slash"
    }
  }
}

struct AuditView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel

  var body: some View {
    VStack(spacing: 0) {
      ProjectHeader(
        "Audit",
        subtitle: "Redacted capability decisions and execution outcomes"
      ) {
        RefreshButton {
          model.refresh(.audit)
        }
      }

      Divider()

      switch model.audit {
      case .idle, .loading:
        LoadingProjectView(title: "Loading audit log")
      case .failed(let message):
        FailedProjectView(message: message) {
          model.refresh(.audit)
        }
      case .loaded(let entries) where entries.isEmpty:
        EmptyProjectView(
          title: "No audit entries",
          detail: "Capability decisions will appear here after the gateway processes calls.",
          systemImage: "list.bullet.rectangle"
        )
      case .loaded(let entries):
        auditList(entries)
      }
    }
    .searchable(text: $model.auditQuery, placement: .toolbar, prompt: "Filter audit")
  }

  private func auditList(_ entries: [AuditEntrySummary]) -> some View {
    let filtered = entries.filter { entry in
      guard !model.auditQuery.isEmpty else {
        return true
      }
      return entry.caller.localizedCaseInsensitiveContains(model.auditQuery)
        || entry.capability.localizedCaseInsensitiveContains(model.auditQuery)
        || entry.requestID.localizedCaseInsensitiveContains(model.auditQuery)
        || entry.summary.localizedCaseInsensitiveContains(model.auditQuery)
        || (entry.projectName?.localizedCaseInsensitiveContains(model.auditQuery) ?? false)
    }

    return Group {
      if filtered.isEmpty {
        EmptyProjectView(
          title: "No matching audit entries",
          detail: "Change the filter to see other decisions.",
          systemImage: "line.3.horizontal.decrease.circle"
        )
      } else {
        List(filtered) { entry in
          AuditRow(entry: entry)
        }
        .listStyle(.inset)
      }
    }
  }
}

private struct AuditRow: View {
  let entry: AuditEntrySummary

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      StateBadge(text: entry.decision.label, color: entry.decision.color)
        .frame(width: 82, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(entry.capability)
            .font(.system(.body, design: .monospaced))
            .fontWeight(.medium)
          Text(entry.caller)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Text(verbatim: AppLocalization.string(entry.summary))
          .lineLimit(2)

        HStack(spacing: 12) {
          Text(DateFormatter.computerMCPDateTime.string(from: entry.timestamp))
          AppLocalization.verbatimText(
            AppLocalization.formatted(
              "Request %@",
              String(entry.requestID.prefix(12))
            )
          )
          .textSelection(.enabled)
          if let projectName = entry.projectName {
            Label(projectName, systemImage: "folder")
          }
          if let outputByteCount = entry.outputByteCount {
            AppLocalization.verbatimText(AppLocalization.formatted("%@ B", String(outputByteCount)))
          }
          if let inputDigest = entry.inputDigest {
            AppLocalization.verbatimText(
              AppLocalization.formatted(
                "Input %@",
                String(inputDigest.prefix(12))
              )
            )
            .textSelection(.enabled)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding(.vertical, 6)
  }
}

struct DiagnosticsView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel
  @State private var manifestEditor: ManifestEditorPresentation?
  @State private var pendingRollback: ManifestRevisionSummary?

  var body: some View {
    VStack(spacing: 0) {
      ProjectHeader(
        "Diagnostics",
        subtitle: "Runtime checks and redacted support bundle"
      ) {
        HStack {
          Button(action: chooseExportDestination) {
            Label("Export", systemImage: "square.and.arrow.up")
          }
          .disabled(model.isActionRunning("diagnostics.export"))

          RefreshButton {
            model.refresh(.diagnostics)
          }
        }
      }

      Divider()

      switch model.diagnostics {
      case .idle, .loading:
        LoadingProjectView(title: "Running diagnostics")
      case .failed(let message):
        FailedProjectView(message: message) {
          model.refresh(.diagnostics)
        }
      case .loaded(let snapshot):
        diagnosticsContent(snapshot)
      }
    }
    .sheet(item: $manifestEditor) { presentation in
      ManifestEditorView(presentation: presentation)
        .environmentObject(model)
    }
    .alert(item: $pendingRollback) { revision in
      Alert(
        title: Text("Roll back configuration?"),
        message: AppLocalization.verbatimText(
          AppLocalization.formatted(
            "Revision %@ will be validated and activated. Existing connections and running tasks will be preserved.",
            String(revision.digest.prefix(12))
          )
        ),
        primaryButton: .destructive(Text("Roll Back")) {
          model.rollbackManifest(to: revision.id)
        },
        secondaryButton: .cancel()
      )
    }
  }

  private func diagnosticsContent(_ snapshot: DiagnosticsSnapshot) -> some View {
    Form {
      Section {
        LabeledContent(
          AppLocalization.string("Generated"),
          value: DateFormatter.computerMCPDateTime.string(from: snapshot.generatedAt)
        )
        LabeledContent(AppLocalization.string("Application support")) {
          pathText(snapshot.applicationSupportDirectory)
        }
        LabeledContent(AppLocalization.string("Logs")) {
          pathText(snapshot.logDirectory)
        }

        if let exportedURL = model.exportedDiagnosticsURL {
          LabeledContent(AppLocalization.string("Last export")) {
            Button {
              NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
            } label: {
              Label(exportedURL.lastPathComponent, systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.link)
          }
        }
      } header: {
        Text("Support")
      }

      Section(AppLocalization.string("Configuration")) {
        LabeledContent(AppLocalization.string("Manifest")) {
          Text(snapshot.manifest.path)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }

        HStack {
          AppLocalization.verbatimText(
            AppLocalization.formatted(
              "%@ retained revision(s)",
              String(snapshot.manifest.revisions.count)
            )
          )
          .foregroundStyle(.secondary)
          Spacer()
          Button {
            manifestEditor = ManifestEditorPresentation(
              content: snapshot.manifest.content, baseDigest: snapshot.manifest.digest)
          } label: {
            Label("Edit", systemImage: "pencil")
          }
          .accessibilityIdentifier("manifest.edit")
          .disabled(model.isActionRunning("manifest.save"))
        }

        ForEach(snapshot.manifest.revisions.prefix(10)) { revision in
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 7) {
                Text(String(revision.digest.prefix(12)))
                  .font(.system(.body, design: .monospaced))
                if revision.isCurrent {
                  StateBadge(
                    text: "Current",
                    color: .green,
                    systemImage: "checkmark.circle.fill"
                  )
                }
              }
              Text(DateFormatter.computerMCPDateTime.string(from: revision.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)
              if let activationError = revision.activationError {
                Text(activationError)
                  .font(.caption)
                  .foregroundStyle(.red)
                  .lineLimit(2)
              }
            }
            Spacer()
            if !revision.isCurrent && revision.activationError == nil {
              Button {
                pendingRollback = revision
              } label: {
                Image(systemName: "arrow.uturn.backward")
              }
              .help("Roll back to this revision")
              .disabled(model.isActionRunning("manifest.rollback.\(revision.id)"))
            }
          }
          .padding(.vertical, 3)
        }
      }

      Section(AppLocalization.string("Checks")) {
        if snapshot.items.isEmpty {
          Text("No diagnostic checks were returned.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(snapshot.items) { item in
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: item.level.systemImage)
                .foregroundStyle(item.level.color)
                .frame(width: 20)

              VStack(alignment: .leading, spacing: 3) {
                HStack {
                  Text(verbatim: AppLocalization.string(item.title))
                    .fontWeight(.medium)
                  Spacer()
                  Text(verbatim: AppLocalization.string(item.value))
                    .foregroundStyle(item.level.color)
                    .textSelection(.enabled)
                }
                if let detail = item.detail {
                  Text(verbatim: AppLocalization.string(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
              }
            }
            .padding(.vertical, 4)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private func pathText(_ path: String) -> some View {
    Text(path)
      .font(.system(.body, design: .monospaced))
      .lineLimit(1)
      .truncationMode(.middle)
      .textSelection(.enabled)
      .help(path)
  }

  private func chooseExportDestination() {
    let panel = NSSavePanel()
    panel.title = AppLocalization.string("Export Diagnostics")
    panel.prompt = AppLocalization.string("Export")
    panel.nameFieldStringValue = "Computer-MCP-Diagnostics.zip"
    panel.canCreateDirectories = true

    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        return
      }
      Task { @MainActor in
        model.exportDiagnostics(to: url)
      }
    }
  }
}

private struct ManifestEditorPresentation: Identifiable {
  let id = UUID()
  var content: String
  /// The manifest the editor opened, kept for the whole edit.
  let baseDigest: String
}

private struct ManifestEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: ComputerMCPAppModel
  @State private var content: String
  private let baseDigest: String

  init(presentation: ManifestEditorPresentation) {
    _content = State(initialValue: presentation.content)
    baseDigest = presentation.baseDigest
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Gateway Manifest")
            .font(.title2.weight(.semibold))
          Text("Changes are validated, versioned, and activated atomically.")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(16)

      Divider()

      TextEditor(text: $content)
        .font(.system(.body, design: .monospaced))
        .padding(8)

      Divider()

      HStack {
        Button {
          content = DefaultGatewayConfiguration.manifest
        } label: {
          Label("Load Built-in Defaults", systemImage: "arrow.counterclockwise")
        }
        .accessibilityIdentifier("manifest.load-built-in-defaults")
        .help("Replace the editor content with the built-in manifest")
        Spacer()
        Button(AppLocalization.string("Cancel")) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button(AppLocalization.string("Validate and Activate")) {
          model.saveManifest(content, expectedDigest: baseDigest)
          dismiss()
        }
        .accessibilityIdentifier("manifest.validate-and-activate")
        .keyboardShortcut(.defaultAction)
        .disabled(
          content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.isActionRunning("manifest.save")
        )
      }
      .padding(16)
    }
    .frame(width: 820, height: 640)
  }
}
