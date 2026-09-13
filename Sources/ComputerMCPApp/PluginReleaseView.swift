import ComputerMCP
import SwiftUI

struct PluginReleaseView: View {
  @ObservedObject var management: PluginManagementModel
  let selection: PluginReleaseSelection
  @StateObject private var model: PluginReleaseModel
  @State private var selectedID: String?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  init(
    management: PluginManagementModel, selection: PluginReleaseSelection, model: PluginReleaseModel
  ) {
    self.management = management
    self.selection = selection
    _model = StateObject(wrappedValue: model)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Choose release archive", bundle: .module).font(.title2.bold())
      Text(verbatim: selection.entry.repository).foregroundStyle(.secondary)
      HStack {
        TextField(text: $model.tag) {
          Text("Release tag (blank for latest stable)", bundle: .module)
        }
        .textFieldStyle(.roundedBorder)
        .onSubmit { load() }
        Button {
          load()
        } label: {
          Text("Load release", bundle: .module)
        }
      }.disabled(model.isLoading || management.isSaving)
      if model.isLoading {
        HStack {
          ProgressView().controlSize(.small)
          Text("Loading release archives", bundle: .module)
          Spacer()
          Button {
            model.cancel()
          } label: {
            Text("Cancel", bundle: .module)
          }
        }
      }
      if let error = model.errorMessage {
        Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
      }
      if let result = model.result {
        let pageLabel = AppLocalization.formatted(
          "Asset page %@", locale: locale, String(result.page))
        HStack {
          Text(
            verbatim:
              "\(result.declaration.pluginID) · \(result.declaration.version) · \(result.tag)")
          if result.prerelease { Text("Prerelease", bundle: .module).foregroundStyle(.orange) }
        }
        if !result.issues.isEmpty {
          Text(
            "Some release archives lack a valid size or SHA-256 and cannot be installed.",
            bundle: .module
          )
          .foregroundStyle(.orange)
        }
        List(result.artifacts, selection: $selectedID) { artifact in
          let sizeLabel = ByteCountFormatter.string(fromByteCount: artifact.size, countStyle: .file)
          VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: artifact.name).font(.headline)
            Text(verbatim: sizeLabel)
            Text(verbatim: "SHA-256: \(artifact.sha256)").font(.caption.monospaced())
              .textSelection(.enabled)
          }.padding(.vertical, 4).tag(artifact.id)
        }.disabled(management.isSaving || !model.canInstall)
        if result.artifacts.isEmpty {
          Text("No installable archives on this release page.", bundle: .module)
        }
        HStack {
          Button {
            page(result.page - 1)
          } label: {
            Text("Previous page", bundle: .module)
          }
          .disabled(result.page <= 1)
          Button {
            if let next = result.nextPage { page(next) }
          } label: {
            Text("Next page", bundle: .module)
          }.disabled(result.nextPage == nil)
          Spacer()
          Text(verbatim: pageLabel)
        }.disabled(model.isLoading || management.isSaving)
        DisclosureGroup {
          LabeledContent {
            Text(verbatim: String(result.declaration.repositoryID))
          } label: {
            Text("Repository ID", bundle: .module)
          }
          LabeledContent {
            Text(verbatim: String(result.releaseID))
          } label: {
            Text("Release ID", bundle: .module)
          }
          LabeledContent {
            Text(verbatim: result.declaration.revision)
          } label: {
            Text("Commit", bundle: .module)
          }
          LabeledContent {
            Text(verbatim: result.declaration.manifestSHA256)
          } label: {
            Text("Manifest SHA-256", bundle: .module)
          }
        } label: {
          Text("Source details", bundle: .module)
        }
        .font(.caption).textSelection(.enabled)
      } else {
        Spacer()
      }
      Text(
        "Choose an archive for your Mac. The App checks compatibility and source again before installation. Publisher provenance is not a signature.",
        bundle: .module
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(
        "New plugins start disabled. Updates keep host settings and earlier versions. External dependencies are not installed.",
        bundle: .module
      )
      .font(.caption).foregroundStyle(.secondary)
      if let error = management.errorMessage {
        Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled)
      }
      if stale {
        Text(
          "Plugin settings changed. Close and reopen this window before installing.",
          bundle: .module
        )
        .foregroundStyle(.orange)
      }
      Divider()
      HStack {
        if management.isSaving {
          ProgressView().controlSize(.small)
          if management.isCancelling {
            Text("Cancelling and checking the result…", bundle: .module)
          } else {
            Text("Downloading, checking and installing…", bundle: .module)
          }
          Button {
            management.cancelChange()
          } label: {
            Text("Cancel installation", bundle: .module)
          }
          .disabled(management.isCancelling)
        }
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Close", bundle: .module)
        }
        .keyboardShortcut(.cancelAction)
        .disabled(management.isSaving)
        Button {
          install()
        } label: {
          Text("Download and install", bundle: .module)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(selectedArtifact == nil || !model.canInstall || stale || management.isSaving)
      }
    }
    .padding(24).frame(width: 720, height: 720)
    .interactiveDismissDisabled(management.isSaving)
    .task { if model.result == nil { await model.search() } }
    .onDisappear { model.cancel() }
  }

  private var stale: Bool { management.snapshot?.state.revision != selection.revision }
  private var selectedArtifact: GitHubPluginArtifact? {
    model.result?.artifacts.first { $0.id == selectedID }
  }
  private func load() {
    selectedID = nil
    Task { await model.search() }
  }
  private func page(_ page: Int) {
    selectedID = nil
    Task { await model.page(page) }
  }
  private func install() {
    guard let artifact = selectedArtifact, model.canInstall, !stale else { return }
    Task {
      if await management.apply(.installRelease(artifact), expectedRevision: selection.revision) {
        dismiss()
      }
    }
  }
}
