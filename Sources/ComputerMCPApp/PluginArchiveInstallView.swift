import ComputerMCP
import SwiftUI
import UniformTypeIdentifiers

struct PluginArchiveInstallView: View {
  @ObservedObject var model: PluginManagementModel
  let revision: Int64
  @Environment(\.dismiss) private var dismiss
  @State private var archive: URL?
  @State private var importing = false
  @State private var pluginID = ""
  @State private var version = ""
  @State private var sha256 = ""

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          Text(
            "Choose a ZIP, TAR or gzip package and enter its expected identity and SHA-256 from a trusted source.",
            bundle: AppLocalization.resourceBundle
          )
          .foregroundStyle(.secondary)
          Button {
            importing = true
          } label: {
            Text("Choose archive", bundle: AppLocalization.resourceBundle)
          }
          if let archive { Text(verbatim: archive.path).textSelection(.enabled) }
          TextField(text: $pluginID) { Text("Plugin ID", bundle: AppLocalization.resourceBundle) }
          TextField(text: $version) { Text("Version", bundle: AppLocalization.resourceBundle) }
          TextField(text: $sha256) { Text("SHA-256", bundle: AppLocalization.resourceBundle) }
            .font(.system(.body, design: .monospaced))
        } header: {
          Text("Install archive", bundle: AppLocalization.resourceBundle)
        }
        Section {
          Text(
            "A matching digest verifies the archive bytes, not an official publisher. New plugins start disabled. Updates keep host settings and earlier versions.",
            bundle: AppLocalization.resourceBundle
          )
          Text(
            "External dependencies are not installed. Use an earlier source in the plugin details to roll back.",
            bundle: AppLocalization.resourceBundle
          )
        }.foregroundStyle(.secondary)
      }
      .formStyle(.grouped)
      .disabled(model.isSaving)
      if let error = model.errorMessage {
        Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled).padding(16)
      }
      Divider()
      HStack {
        if model.isSaving { ProgressView().controlSize(.small) }
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Cancel", bundle: AppLocalization.resourceBundle)
        }
        .keyboardShortcut(.cancelAction)
        Button {
          install()
        } label: {
          Text("Install", bundle: AppLocalization.resourceBundle)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(archive == nil || pluginID.isEmpty || version.isEmpty || sha256.isEmpty)
      }
      .padding(16).disabled(model.isSaving)
    }
    .frame(width: 620, height: 480)
    .interactiveDismissDisabled(model.isSaving)
    .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
      switch result {
      case .success(let url): archive = url
      case .failure(let error): model.report(error)
      }
    }
  }

  private func install() {
    guard let archive else { return }
    do {
      let change = PluginHostChange.installArchive(
        archive: archive, sha256: sha256, pluginID: pluginID, version: try PluginVersion(version))
      Task {
        let accessing = archive.startAccessingSecurityScopedResource()
        defer { if accessing { archive.stopAccessingSecurityScopedResource() } }
        if await model.apply(change, expectedRevision: revision) { dismiss() }
      }
    } catch { model.report(error) }
  }
}
