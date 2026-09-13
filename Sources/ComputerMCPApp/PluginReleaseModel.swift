import Combine
import ComputerMCP
import Foundation

struct PluginReleaseSelection: Identifiable {
  let entry: PluginCatalogEntry
  let revision: Int64
  var id: String { entry.id }
}

@MainActor
final class PluginReleaseModel: ObservableObject {
  let entry: PluginCatalogEntry
  @Published var tag = ""
  @Published private(set) var result: GitHubPluginReleaseArtifacts?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  private let controlPlane: any PluginManaging
  private var generation = 0
  private var request: Task<GitHubPluginReleaseArtifacts, any Error>?

  init(entry: PluginCatalogEntry, controlPlane: any PluginManaging) {
    self.entry = entry
    self.controlPlane = controlPlane
  }

  var canInstall: Bool { result != nil && !isLoading && errorMessage == nil }

  func search() async {
    await load(tag: tag.isEmpty ? nil : tag, page: 1)
  }

  func page(_ page: Int) async {
    guard let result else { return }
    // Keep pagination on the displayed tag, even when latest or the draft changes.
    await load(tag: result.tag, page: page)
  }

  func cancel() {
    generation += 1
    request?.cancel()
    request = nil
    isLoading = false
  }

  private func load(tag: String?, page: Int) async {
    guard !isLoading else { return }
    generation += 1
    let current = generation
    isLoading = true
    errorMessage = nil
    let controlPlane = controlPlane
    let entry = entry
    let task = Task {
      try await controlPlane.pluginReleaseArtifacts(
        repository: entry.repository, repositoryID: entry.repositoryID, tag: tag, page: page)
    }
    request = task
    defer {
      if current == generation {
        request = nil
        isLoading = false
      }
    }
    do {
      let next = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      guard current == generation, !Task.isCancelled, !task.isCancelled else { return }
      guard next.declaration.pluginID == entry.pluginID,
        next.declaration.repositoryID == entry.repositoryID
      else { throw PluginCatalogError.invalidProvenance }
      result = next
    } catch {
      guard current == generation, !Task.isCancelled, !task.isCancelled,
        !(error is CancellationError)
      else { return }
      if case PluginCatalogError.httpStatus(let status) = error {
        errorMessage = AppLocalization.formatted(
          "GitHub request failed with HTTP %@.", String(status))
      } else {
        errorMessage = AppLocalization.errorDescription(error)
      }
    }
  }
}
