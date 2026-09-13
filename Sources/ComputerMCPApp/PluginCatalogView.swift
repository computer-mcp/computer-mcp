import ComputerMCP
import SwiftUI

struct PluginCatalogView: View {
  @ObservedObject var management: PluginManagementModel
  @ObservedObject var model: PluginCatalogModel
  @State private var release: PluginReleaseSelection?
  @Environment(\.dismiss) private var dismiss

  init(management: PluginManagementModel) {
    self.management = management
    model = management.catalog
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Official plugin search").font(.title2.bold())
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text("Search public repositories published by computer-mcp on GitHub.")
        .foregroundStyle(.secondary)
      HStack {
        TextField("Search names, descriptions, or repositories", text: $model.query)
          .textFieldStyle(.roundedBorder).onSubmit { Task { await model.search() } }
        Picker("Contribution", selection: $model.kind) {
          Text("All contributions").tag(IntegrationKind?.none)
          Text(verbatim: "MCP").tag(IntegrationKind?.some(.mcp))
          Text(verbatim: "CLI").tag(IntegrationKind?.some(.cli))
          Text("Skills").tag(IntegrationKind?.some(.skills))
        }.labelsHidden().fixedSize()
        Button("Search") { Task { await model.search() } }.disabled(model.isLoading)
      }
      if let error = model.errorMessage {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: error).foregroundStyle(.red)
          if model.result != nil {
            Text("Previous results are shown below; the latest request failed.")
              .foregroundStyle(.secondary)
          }
        }.textSelection(.enabled)
      }
      if model.isLoading {
        HStack {
          ProgressView().controlSize(.small)
          Text("Searching GitHub")
          Spacer()
          Button("Cancel search") { model.cancel() }
        }
      }
      if let result = model.result {
        results(result)
      } else {
        Spacer()
        Text("Discovery does not install packages or grant access.")
          .foregroundStyle(.secondary)
        Spacer()
      }
    }
    .padding(24)
    .frame(minWidth: 700, idealWidth: 760, minHeight: 600, idealHeight: 680)
    .task { if model.result == nil { await model.search() } }
    .onDisappear { model.cancel() }
    .sheet(item: $release) { selection in
      PluginReleaseView(
        management: management, selection: selection,
        model: PluginReleaseModel(entry: selection.entry, controlPlane: management.controlPlane))
    }
  }

  private func results(_ result: PluginCatalogSearchResult) -> some View {
    let pageLabel = AppLocalization.formatted("Repository page %@", String(result.page))
    let fetchedTime = result.fetchedAt.formatted(date: .omitted, time: .shortened)
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(verbatim: pageLabel)
        Spacer()
        Text(result.cached ? "Cached" : "Fetched from GitHub").foregroundStyle(.secondary)
        Text(verbatim: fetchedTime)
          .foregroundStyle(.secondary)
      }
      if !result.query.isEmpty { LabeledContent("Results for", value: result.query) }
      if let kind = result.kind { LabeledContent("Contribution", value: kind.rawValue) }
      if !result.issues.isEmpty {
        Label(
          "Some repositories could not be checked. Results may be incomplete.",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.secondary)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if result.entries.isEmpty {
            Text("No matching plugins on this repository page.")
              .font(.headline).padding(.vertical, 24)
          }
          ForEach(result.entries) { entry in
            entryView(entry)
            Divider()
          }
          if !result.issues.isEmpty {
            DisclosureGroup("Repositories with discovery issues") {
              ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 4) {
                  Text(verbatim: issue.repository).font(.headline)
                  Text(verbatim: issueMessage(issue))
                  Text(verbatim: issue.code).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
              }
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Button("Previous page") { Task { await model.page(result.page - 1) } }
          .disabled(result.page <= 1 || model.isLoading)
        Button("Next page") {
          if let next = result.nextPage { Task { await model.page(next) } }
        }.disabled(result.nextPage == nil || model.isLoading)
        Spacer()
        Button("Refresh page") { Task { await model.refresh() } }.disabled(model.isLoading)
      }
      Text(
        "Each page checks up to 10 repositories. Continue to the next page even if this page has no matches."
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(
        "Official source identifies the publisher, not a verified artifact or signature. Discovery does not install packages or grant access."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func entryView(_ entry: PluginCatalogEntry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(verbatim: entry.name).font(.headline)
        Spacer()
        Text(verbatim: entry.version.description).foregroundStyle(.secondary)
      }
      if let summary = entry.summary { Text(verbatim: summary) }
      Link(destination: entry.repositoryURL) { Text(verbatim: entry.repository) }
      Button {
        if let revision = management.snapshot?.state.revision {
          release = PluginReleaseSelection(entry: entry, revision: revision)
        }
      } label: {
        Text("Choose release archive", bundle: .module)
      }
      .disabled(management.snapshot == nil || management.isSaving)
      HStack(spacing: 16) {
        if !entry.mcp.isEmpty {
          Label {
            Text(verbatim: "MCP")
          } icon: {
            Image(systemName: "network")
          }
        }
        if !entry.cli.isEmpty {
          Label {
            Text(verbatim: "CLI")
          } icon: {
            Image(systemName: "terminal")
          }
        }
        if !entry.skills.isEmpty { Label("Skills", systemImage: "book") }
      }.font(.caption)
      DisclosureGroup("Source details") {
        LabeledContent("Plugin", value: entry.pluginID)
        LabeledContent("Repository ID", value: String(entry.repositoryID))
        LabeledContent("Publisher ID", value: String(entry.publisherID))
        LabeledContent("Commit", value: entry.revision)
        LabeledContent("Manifest SHA-256", value: entry.manifestSHA256)
        Link("Open pinned declaration", destination: entry.manifestURL)
      }.font(.caption).textSelection(.enabled)
    }
  }

  private func issueMessage(_ issue: PluginCatalogIssue) -> String {
    if let status = issue.httpStatus {
      return AppLocalization.formatted("GitHub request failed with HTTP %@.", String(status))
    }
    return AppLocalization.errorDescription(issue.message)
  }
}
