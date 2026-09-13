import ComputerMCP
import SwiftUI
import UniformTypeIdentifiers

struct PluginsView: View {
  @ObservedObject var model: PluginManagementModel
  @State private var importing = false
  @State private var importRevision: Int64 = 0
  @State private var sheet: PluginSheet?
  @State private var removal: PluginRemoval?

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceHeader("Plugins", subtitle: "Packages that contribute MCP, CLI, and skills") {
        Button {
          importRevision = model.snapshot?.state.revision ?? 0
          importing = true
        } label: {
          Label("Add local package", systemImage: "plus")
        }
        .disabled(model.snapshot == nil || model.isSaving)
        RefreshButton { Task { await model.reload() } }
      }
      Divider()
      HStack {
        Button {
          sheet = .search
        } label: {
          Label("Search official plugins", systemImage: "magnifyingglass")
        }
        Button("Install archive") {
          sheet = .install(revision: model.snapshot?.state.revision ?? 0)
        }
        .disabled(model.snapshot == nil || model.isSaving)
        Spacer()
        if model.isSaving { ProgressView().controlSize(.small) }
        Button("Retry file recovery") {
          let revision = model.snapshot?.state.revision ?? 0
          Task { await model.apply(.recover, expectedRevision: revision) }
        }
        .disabled(model.snapshot == nil || model.isSaving)
      }.padding(.horizontal, 20).padding(.vertical, 12)
      if let error = model.errorMessage {
        Text(verbatim: error)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .padding(16)
      }
      if let snapshot = model.snapshot {
        if let error = snapshot.recoveryError {
          Text(verbatim: AppLocalization.string(error))
            .foregroundStyle(.orange).textSelection(.enabled).padding(16)
        }
        if model.pluginIDs.isEmpty {
          EmptyWorkspaceView(
            title: "No plugins registered",
            detail: "Add a local package to review its contributions before enabling it.",
            systemImage: "puzzlepiece.extension")
        } else {
          HSplitView {
            List(model.pluginIDs, id: \.self, selection: $model.selectedID) { id in
              VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: id)
                Text(snapshot.state.settings[id]?.enabled == true ? "Enabled" : "Disabled")
                  .font(.caption).foregroundStyle(.secondary)
              }
              .tag(id)
            }
            .frame(minWidth: 160, idealWidth: 200, maxWidth: 280)
            if let id = model.selectedID {
              details(id: id, snapshot: snapshot)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
      } else if model.isRefreshing {
        LoadingWorkspaceView(title: "Loading plugins")
      } else {
        FailedWorkspaceView(message: model.errorMessage ?? AppLocalization.string("Unavailable")) {
          Task { await model.reload() }
        }
      }
    }
    .task { await model.reload() }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
      switch result {
      case .success(let url):
        let revision = importRevision
        Task {
          let accessing = url.startAccessingSecurityScopedResource()
          defer { if accessing { url.stopAccessingSecurityScopedResource() } }
          await model.apply(.registerDevelopment(url), expectedRevision: revision)
        }
      case .failure(let error): model.report(error)
      }
    }
    .sheet(item: $sheet) { sheet in
      switch sheet {
      case .settings(let draft): PluginSettingsEditor(model: model, initial: draft)
      case .search: PluginCatalogView(management: model)
      case .install(let revision): PluginArchiveInstallView(model: model, revision: revision)
      case .doctor(let doctor): PluginDoctorView(model: doctor)
      }
    }
    .alert(item: $removal) { pending in
      Alert(
        title: Text(pending.artifact ? "Uninstall this archive?" : "Remove local registration?"),
        message: Text(
          pending.artifact
            ? "Only this installation's owned files will be removed. Host settings, other versions and external dependencies will be kept."
            : "Package files and saved host settings will be kept."),
        primaryButton: .destructive(Text(pending.artifact ? "Uninstall" : "Remove registration")) {
          Task {
            await model.apply(
              pending.artifact
                ? .uninstallArtifact(installationID: pending.id)
                : .removeDevelopment(installationID: pending.id), expectedRevision: pending.revision
            )
          }
        }, secondaryButton: .cancel())
    }
  }

  private func details(id: String, snapshot: PluginHostSnapshot) -> some View {
    Form {
      Section {
        LabeledContent("Plugin", value: id)
        LabeledContent("Status") {
          Text(snapshot.state.settings[id]?.enabled == true ? "Enabled" : "Disabled")
        }
        HStack {
          Button("Edit settings") {
            sheet = .settings(PluginSettingsDraft(id: id, snapshot: snapshot))
          }
          Button(snapshot.state.settings[id]?.enabled == true ? "Disable" : "Enable") {
            Task {
              await model.apply(
                .enabled(pluginID: id, snapshot.state.settings[id]?.enabled != true),
                expectedRevision: snapshot.state.revision)
            }
          }
        }
        .disabled(
          snapshot.state.settings[id] == nil && !snapshot.bundled.contains { $0.manifest.id == id })
      }
      Section("Sources") {
        ForEach(snapshot.bundled.filter { $0.manifest.id == id }, id: \.manifest.id) { package in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(verbatim: package.manifest.version.description)
              Text("Bundled").foregroundStyle(.secondary)
              if snapshot.state.selectedInstallations[id] == nil {
                Label("Selected", systemImage: "checkmark")
              }
            }
            Text(verbatim: package.root.path).textSelection(.enabled)
          }
        }
        ForEach(snapshot.state.installations.filter { $0.pluginID == id }) { record in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(verbatim: record.version.description)
              Text(verbatim: record.source.kind.displayName).foregroundStyle(.secondary)
              if snapshot.state.selectedInstallations[id] == record.id {
                Label("Selected", systemImage: "checkmark")
              }
            }
            Text(verbatim: record.source.root.path).textSelection(.enabled)
            if let repository = record.source.repository {
              LabeledContent("Source repository", value: repository)
            }
            if let digest = record.source.artifactSHA256 {
              LabeledContent("SHA-256", value: digest).textSelection(.enabled)
            }
            if let release = record.source.githubRelease {
              LabeledContent {
                Text(verbatim: release.tag)
              } label: {
                Text("Release tag", bundle: .module)
              }
              LabeledContent {
                Text(verbatim: String(release.releaseID))
              } label: {
                Text("Release ID", bundle: .module)
              }
              LabeledContent {
                Text(verbatim: String(release.assetID))
              } label: {
                Text("Asset ID", bundle: .module)
              }
              Text(verbatim: release.declaration.revision).font(.caption.monospaced())
                .textSelection(.enabled)
            }
            HStack {
              Button("Use this source") {
                Task {
                  await model.apply(
                    .select(pluginID: id, installationID: record.id),
                    expectedRevision: snapshot.state.revision)
                }
              }
              .disabled(snapshot.state.selectedInstallations[id] == record.id)
              if record.source.kind == .development {
                Button("Refresh registration") {
                  Task {
                    await model.apply(
                      .registerDevelopment(record.source.root),
                      expectedRevision: snapshot.state.revision)
                  }
                }
                Button("Remove registration", role: .destructive) {
                  removal = PluginRemoval(
                    id: record.id, revision: snapshot.state.revision, artifact: false)
                }
              } else if record.source.kind == .artifact {
                Button("Uninstall", role: .destructive) {
                  removal = PluginRemoval(
                    id: record.id, revision: snapshot.state.revision, artifact: true)
                }
              }
            }
          }
        }
        Button("Use bundled fallback") {
          Task {
            await model.apply(
              .select(pluginID: id, installationID: nil), expectedRevision: snapshot.state.revision)
          }
        }
        Text("Without a matching bundled package, contributions remain unavailable.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Registration diagnostics") {
        Button {
          sheet = .doctor(PluginDoctorModel(controlPlane: model.controlPlane, pluginID: id))
        } label: {
          Text("Check package", bundle: .module)
        }
        Text(
          "Resolved registrations do not confirm a working connection. Caller permissions still apply."
        )
        .foregroundStyle(.secondary)
        ForEach(snapshot.issues.filter { $0.pluginID == id }, id: \.message) { issue in
          Text(verbatim: issue.message).textSelection(.enabled)
        }
        ForEach(Array(snapshot.diagnostics.filter { $0.pluginID == id }.enumerated()), id: \.offset)
        { _, diagnostic in
          VStack(alignment: .leading, spacing: 4) {
            switch diagnostic.code {
            case .dependencyUnavailable: Text("Dependency unavailable")
            case .executableUnavailable: Text("Executable unavailable")
            case .executableUnverified: Text("Executable needs verification")
            case .hostIncompatible: Text("Host incompatible")
            }
            if let dependency = diagnostic.dependencyID { Text(verbatim: dependency) }
            if let inspection = diagnostic.executable {
              Text(inspection.message).textSelection(.enabled)
              Text(inspection.interpreters.last?.executable ?? inspection.executable)
                .font(.caption).textSelection(.enabled)
            }
            if let instructions = diagnostic.instructions {
              Text(verbatim: instructions).textSelection(.enabled)
            }
          }
        }
        ForEach(snapshot.contributions.filter { $0.pluginID == id }, id: \.componentID) {
          contribution in
          LabeledContent("Resolved component", value: contribution.componentID)
        }
      }
    }
    .formStyle(.grouped)
    .disabled(model.isSaving)
  }
}

private struct PluginRemoval: Identifiable {
  let id: String
  let revision: Int64
  let artifact: Bool
}

private enum PluginSheet: Identifiable {
  case settings(PluginSettingsDraft)
  case search
  case install(revision: Int64)
  case doctor(PluginDoctorModel)

  var id: String {
    switch self {
    case .settings(let draft): "settings-\(draft.id)"
    case .search: "search"
    case .install: "install"
    case .doctor(let doctor): "doctor-\(doctor.pluginID)"
    }
  }
}

extension PluginSourceKind {
  fileprivate var displayName: String {
    switch self {
    case .development: AppLocalization.string("Local development")
    case .bundled: AppLocalization.string("Bundled")
    case .artifact: AppLocalization.string("Installed archive")
    }
  }
}
