import ComputerMCP
import SwiftUI

struct PluginCatalogView: View {
  @ObservedObject var management: PluginManagementModel
  @ObservedObject var model: PluginCatalogModel
  @State private var release: PluginReleaseSelection?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  init(management: PluginManagementModel) {
    self.management = management
    model = management.catalog
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Official plugin search", bundle: AppLocalization.resourceBundle).font(.title2.bold())
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Done", bundle: AppLocalization.resourceBundle)
        }
        .keyboardShortcut(.cancelAction)
      }
      Text(
        "Search published official plugins. Results are filtered for this Mac.",
        bundle: AppLocalization.resourceBundle
      )
      .foregroundStyle(.secondary)
      HStack {
        TextField(text: $model.query) {
          Text(
            "Search names, descriptions, or repositories", bundle: AppLocalization.resourceBundle)
        }
        .textFieldStyle(.roundedBorder).onSubmit { Task { await model.search() } }
        Picker(selection: $model.kind) {
          Text("All contributions", bundle: AppLocalization.resourceBundle).tag(
            IntegrationKind?.none)
          Text(verbatim: "MCP").tag(IntegrationKind?.some(.mcp))
          Text(verbatim: "CLI").tag(IntegrationKind?.some(.cli))
          Text("Skills", bundle: AppLocalization.resourceBundle).tag(IntegrationKind?.some(.skills))
        } label: {
          Text("Contribution", bundle: AppLocalization.resourceBundle)
        }
        .labelsHidden().fixedSize()
        Button {
          Task { await model.search() }
        } label: {
          Text("Search", bundle: AppLocalization.resourceBundle)
        }.disabled(model.isLoading)
      }
      if let error = model.errorMessage {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: error).foregroundStyle(.red)
          if model.result != nil {
            Text(
              "Previous results are shown below; the latest request failed.",
              bundle: AppLocalization.resourceBundle
            )
            .foregroundStyle(.secondary)
          }
        }.textSelection(.enabled)
      }
      if model.isLoading {
        HStack {
          ProgressView().controlSize(.small)
          Text("Searching official catalog", bundle: AppLocalization.resourceBundle)
          Spacer()
          Button {
            model.cancel()
          } label: {
            Text("Cancel search", bundle: AppLocalization.resourceBundle)
          }
        }
      }
      if let result = model.result {
        results(result)
      } else {
        Spacer()
        Text(
          "Discovery does not install packages or grant access.",
          bundle: AppLocalization.resourceBundle
        )
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
    let pageLabel = AppLocalization.formatted(
      "Catalog page %@", locale: locale, String(result.page))
    let fetchedTime = result.fetchedAt.formatted(
      Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(verbatim: pageLabel)
        Spacer()
        Group {
          if result.cached {
            Text("Cached", bundle: AppLocalization.resourceBundle)
          } else {
            Text("Loaded from official catalog", bundle: AppLocalization.resourceBundle)
          }
        }.foregroundStyle(.secondary)
        Text(verbatim: fetchedTime)
          .foregroundStyle(.secondary)
      }
      if let status = result.catalog {
        let generationLabel = AppLocalization.formatted(
          "Catalog generation %@", locale: locale, String(status.generation))
        let publicationLabel = AppLocalization.formatted(
          "Published %@", locale: locale,
          status.generatedAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
        if status.stale {
          Label {
            Text(
              "Catalog could not be refreshed. Showing saved results.",
              bundle: AppLocalization.resourceBundle)
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .foregroundStyle(.orange)
        }
        Text(verbatim: generationLabel)
          .font(.caption).foregroundStyle(.secondary)
        Text(verbatim: publicationLabel)
          .font(.caption).foregroundStyle(.secondary)
      }
      if !result.query.isEmpty {
        LabeledContent {
          Text(verbatim: result.query)
        } label: {
          Text("Results for", bundle: AppLocalization.resourceBundle)
        }
      }
      if let kind = result.kind {
        LabeledContent {
          Text(verbatim: kind.rawValue)
        } label: {
          Text("Contribution", bundle: AppLocalization.resourceBundle)
        }
      }
      if !result.issues.isEmpty {
        Label {
          Text(
            "Some catalog data is unavailable. Review the details below.",
            bundle: AppLocalization.resourceBundle)
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.secondary)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if result.entries.isEmpty {
            Text("No matching plugins.", bundle: AppLocalization.resourceBundle)
              .font(.headline).padding(.vertical, 24)
          }
          ForEach(result.entries) { entry in
            entryView(entry)
            Divider()
          }
          if !result.issues.isEmpty {
            DisclosureGroup {
              ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 4) {
                  Text(verbatim: issue.repository).font(.headline)
                  Text(verbatim: issueMessage(issue))
                  Text(verbatim: issue.code).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
              }
            } label: {
              Text("Catalog issues", bundle: AppLocalization.resourceBundle)
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Button {
          Task { await model.page(result.page - 1) }
        } label: {
          Text("Previous page", bundle: AppLocalization.resourceBundle)
        }
        .disabled(result.page <= 1 || model.isLoading)
        Button {
          if let next = result.nextPage { Task { await model.page(next) } }
        } label: {
          Text("Next page", bundle: AppLocalization.resourceBundle)
        }
        .disabled(result.nextPage == nil || model.isLoading)
        Spacer()
        Button {
          Task { await model.refresh() }
        } label: {
          Text("Refresh catalog", bundle: AppLocalization.resourceBundle)
        }.disabled(model.isLoading)
      }
      Text(
        "Search, filters and pages use the cached catalog.", bundle: AppLocalization.resourceBundle
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(
        "Official source identifies the publisher, not a verified artifact or signature. Discovery does not install packages or grant access.",
        bundle: AppLocalization.resourceBundle
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
        Text("Choose release archive", bundle: AppLocalization.resourceBundle)
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
        if !entry.skills.isEmpty {
          Label {
            Text("Skills", bundle: AppLocalization.resourceBundle)
          } icon: {
            Image(systemName: "book")
          }
        }
      }.font(.caption)
      DisclosureGroup {
        LabeledContent {
          Text(verbatim: entry.pluginID)
        } label: {
          Text("Plugin", bundle: AppLocalization.resourceBundle)
        }
        LabeledContent {
          Text(verbatim: String(entry.repositoryID))
        } label: {
          Text("Repository ID", bundle: AppLocalization.resourceBundle)
        }
        LabeledContent {
          Text(verbatim: String(entry.publisherID))
        } label: {
          Text("Publisher ID", bundle: AppLocalization.resourceBundle)
        }
        LabeledContent {
          Text(verbatim: entry.revision)
        } label: {
          Text("Commit", bundle: AppLocalization.resourceBundle)
        }
        LabeledContent {
          Text(verbatim: entry.manifestSHA256)
        } label: {
          Text("Manifest SHA-256", bundle: AppLocalization.resourceBundle)
        }
        Link(destination: entry.manifestURL) {
          Text("Open pinned declaration", bundle: AppLocalization.resourceBundle)
        }
      } label: {
        Text("Source details", bundle: AppLocalization.resourceBundle)
      }
      .font(.caption).textSelection(.enabled)
    }
  }

  private func issueMessage(_ issue: PluginCatalogIssue) -> String {
    if let status = issue.httpStatus {
      return AppLocalization.formatted(
        "Plugin request failed with HTTP %@.", locale: locale, String(status))
    }
    return AppLocalization.errorDescription(
      issue.message, preferredLocalizations: [locale.identifier])
  }
}
