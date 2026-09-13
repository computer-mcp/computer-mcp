import Combine
import ComputerMCP
import Foundation

@MainActor
protocol PluginCatalogManaging: AnyObject {
  func searchPlugins(query: String, kind: IntegrationKind?, page: Int, refresh: Bool) async throws
    -> PluginCatalogSearchResult
}

@MainActor
final class PluginCatalogModel: ObservableObject {
  @Published var query = ""
  @Published var kind: IntegrationKind?
  @Published private(set) var result: PluginCatalogSearchResult?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?

  private let controlPlane: any PluginCatalogManaging
  private var generation = 0
  private var request: Task<PluginCatalogSearchResult, any Error>?

  init(controlPlane: any PluginCatalogManaging) { self.controlPlane = controlPlane }

  func search() async {
    await load(query: query, kind: kind, page: 1, refresh: false)
  }

  func refresh() async {
    guard let result else {
      await search()
      return
    }
    await load(query: result.query, kind: result.kind, page: result.page, refresh: true)
  }

  func page(_ page: Int) async {
    guard let result else { return }
    // Paging belongs to the submitted search, not text being edited for a future search.
    await load(query: result.query, kind: result.kind, page: page, refresh: false)
  }

  func cancel() {
    generation += 1
    request?.cancel()
    request = nil
    isLoading = false
  }

  private func load(query: String, kind: IntegrationKind?, page: Int, refresh: Bool) async {
    guard !isLoading else { return }
    generation += 1
    let current = generation
    isLoading = true
    errorMessage = nil
    let controlPlane = controlPlane
    let task = Task {
      try await controlPlane.searchPlugins(query: query, kind: kind, page: page, refresh: refresh)
    }
    request = task
    defer {
      if generation == current {
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
      guard generation == current, !Task.isCancelled, !task.isCancelled else { return }
      result = next
    } catch {
      guard generation == current, !Task.isCancelled, !task.isCancelled,
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
