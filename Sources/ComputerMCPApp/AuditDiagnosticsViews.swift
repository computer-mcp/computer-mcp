import AppKit
import ComputerMCPConfiguration
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPMacOS
import SwiftUI

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
