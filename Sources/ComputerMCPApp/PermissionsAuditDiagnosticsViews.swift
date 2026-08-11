import AppKit
import ComputerMCP
import SwiftUI

struct PermissionsView: View {
  @EnvironmentObject private var model: ComputerMCPAppModel

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceHeader(
        "Permissions",
        subtitle: "macOS privacy access used by enabled endpoints"
      ) {
        RefreshButton {
          model.refresh(.permissions)
        }
      }

      Divider()

      switch model.permissions {
      case .idle, .loading:
        LoadingWorkspaceView(title: "Checking permissions")
      case .failed(let message):
        FailedWorkspaceView(message: message) {
          model.refresh(.permissions)
        }
      case .loaded(let permissions) where permissions.isEmpty:
        EmptyWorkspaceView(
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
      WorkspaceHeader(
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
        LoadingWorkspaceView(title: "Loading audit log")
      case .failed(let message):
        FailedWorkspaceView(message: message) {
          model.refresh(.audit)
        }
      case .loaded(let entries) where entries.isEmpty:
        EmptyWorkspaceView(
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
        || (entry.workspaceName?.localizedCaseInsensitiveContains(model.auditQuery) ?? false)
    }

    return Group {
      if filtered.isEmpty {
        EmptyWorkspaceView(
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
          if let workspaceName = entry.workspaceName {
            Label(workspaceName, systemImage: "folder")
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
      WorkspaceHeader(
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
        LoadingWorkspaceView(title: "Running diagnostics")
      case .failed(let message):
        FailedWorkspaceView(message: message) {
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
            "Revision %@ will be validated and activated atomically. The running gateway will restart.",
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
          "Generated",
          value: DateFormatter.computerMCPDateTime.string(from: snapshot.generatedAt)
        )
        LabeledContent("Application support") {
          pathText(snapshot.applicationSupportDirectory)
        }
        LabeledContent("Logs") {
          pathText(snapshot.logDirectory)
        }

        if let exportedURL = model.exportedDiagnosticsURL {
          LabeledContent("Last export") {
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

      Section("Configuration") {
        LabeledContent("Manifest") {
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
            manifestEditor = ManifestEditorPresentation(content: snapshot.manifest.content)
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

      Section("Checks") {
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
}

private struct ManifestEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: ComputerMCPAppModel
  @State private var content: String

  init(presentation: ManifestEditorPresentation) {
    _content = State(initialValue: presentation.content)
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
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("Validate and Activate") {
          model.saveManifest(content)
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
