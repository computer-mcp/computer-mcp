import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ComputerMCP
@testable import ComputerMCPApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PluginCatalogModelTests {
  @Test
  func nativeCatalogRendersResultsAndFailuresInLightAndDark() async throws {
    let service = PluginCatalogFake()
    service.onSearch = { request in
      PluginCatalogSearchResult(
        publisher: "computer-mcp", publisherID: 315_005_910, query: request.query,
        kind: request.kind,
        page: 1, nextPage: 2, checkedRepositories: 10,
        fetchedAt: Date(timeIntervalSince1970: 1_788_846_000), cached: false,
        entries: [
          PluginCatalogEntry(
            repositoryID: 1234, repository: "computer-mcp/render-fixture", publisherID: 315_005_910,
            revision: String(repeating: "a", count: 40),
            manifestBlobSHA: String(repeating: "b", count: 40),
            manifestSHA256: String(repeating: "c", count: 64), pluginID: "render-fixture",
            name: "Workspace tools · 工作区工具", version: try PluginVersion("1.2.3"),
            summary: "Isolated render fixture with MCP, CLI and skills; not a published package.",
            mcp: ["native"], cli: ["command"], skills: ["guidance"])
        ], issues: [])
    }
    let management = PluginManagementModel(controlPlane: service)
    await management.reload()
    let model = management.catalog
    await model.search()
    for dark in [false, true] {
      let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
      try render(
        PluginCatalogView(management: management).environment(\.colorScheme, dark ? .dark : .light),
        size: NSSize(width: 760, height: 680), appearance: appearance,
        name: dark ? "catalog-dark" : "catalog-light")
    }
    let failureManagement = PluginManagementModel(controlPlane: service)
    await failureManagement.reload()
    let failureModel = failureManagement.catalog
    await failureModel.search()
    service.onSearch = { _ in throw PluginCatalogError.rateLimited(retryAfterSeconds: 60) }
    await failureModel.refresh()
    #expect(failureModel.errorMessage != nil)
    try render(
      PluginCatalogView(management: failureManagement).environment(\.colorScheme, .light),
      size: NSSize(width: 760, height: 680), appearance: try #require(NSAppearance(named: .aqua)),
      name: "catalog-failed-refresh")
  }

  @Test
  func pagingAndRefreshKeepSubmittedCriteriaWhileDraftChanges() async throws {
    let service = PluginCatalogFake()
    let model = PluginCatalogModel(controlPlane: service)
    model.query = "工作"
    model.kind = .mcp
    await model.search()
    model.query = "another query"
    model.kind = .cli
    await model.page(2)
    await model.refresh()
    #expect(
      service.requests == [
        .init(query: "工作", kind: .mcp, page: 1, refresh: false),
        .init(query: "工作", kind: .mcp, page: 2, refresh: false),
        .init(query: "工作", kind: .mcp, page: 2, refresh: true),
      ])
    #expect(model.result?.page == 2)
    #expect(model.result?.query == "工作")
    await model.search()
    #expect(model.result?.page == 1)
    #expect(model.result?.query == "another query")
    #expect(model.result?.kind == .cli)
  }

  @Test
  func failedRefreshKeepsLastGoodResultAndVisibleFailure() async {
    let service = PluginCatalogFake()
    let model = PluginCatalogModel(controlPlane: service)
    await model.search()
    service.onSearch = { _ in throw PluginCatalogError.rateLimited(retryAfterSeconds: 60) }
    await model.refresh()
    #expect(model.result?.page == 1)
    #expect(model.errorMessage != nil)
    #expect(!model.isLoading)
    #expect(service.requests.count == 2)
  }

  @Test
  func cancelledResponseCannotReplaceLaterResultsAndDuplicateClicksDoNotQueue() async {
    let service = PluginCatalogFake()
    let model = PluginCatalogModel(controlPlane: service)
    let started = AsyncStream<Void>.makeStream()
    var continuation: CheckedContinuation<PluginCatalogSearchResult, any Error>?
    service.onSearch = { _ in
      try await withCheckedThrowingContinuation {
        continuation = $0
        started.continuation.yield(())
      }
    }
    model.query = "first"
    let first = Task { await model.search() }
    var iterator = started.stream.makeAsyncIterator()
    await iterator.next()
    #expect(model.isLoading)
    await model.search()
    #expect(service.requests.count == 1)
    model.cancel()
    service.onSearch = nil
    model.query = "second"
    await model.search()
    continuation?.resume(returning: catalogResult(query: "first"))
    await first.value
    #expect(model.result?.query == "second")
    #expect(model.errorMessage == nil)
    #expect(!model.isLoading)
    started.continuation.finish()
  }

  @Test
  func unavailableHostIsNotAnEmptyCatalog() async {
    let model = PluginCatalogModel(controlPlane: UnavailableControlPlane())
    await model.search()
    #expect(model.result == nil)
    #expect(model.errorMessage != nil)
  }
}

@MainActor
private final class PluginCatalogFake: PluginManaging {
  func doctorPlugin(id: String) async throws -> PluginDoctorReport { throw CancellationError() }
  func fetchPlugins() async throws -> PluginHostSnapshot {
    try PluginHostSnapshot(state: PluginStoreSnapshot())
  }
  func changePlugins(_ change: PluginHostChange, expectedRevision: Int64) async throws
    -> PluginHostSnapshot
  {
    throw PluginHostError.connectedClients
  }
  func pluginReleaseArtifacts(repository: String, repositoryID: Int64, tag: String?, page: Int)
    async throws -> GitHubPluginReleaseArtifacts
  { throw PluginCatalogError.networkUnavailable }
  struct Request: Equatable {
    let query: String
    let kind: IntegrationKind?
    let page: Int
    let refresh: Bool
  }
  private(set) var requests: [Request] = []
  var onSearch: ((Request) async throws -> PluginCatalogSearchResult)?

  func searchPlugins(query: String, kind: IntegrationKind?, page: Int, refresh: Bool) async throws
    -> PluginCatalogSearchResult
  {
    let request = Request(query: query, kind: kind, page: page, refresh: refresh)
    requests.append(request)
    if let onSearch { return try await onSearch(request) }
    return catalogResult(query: query, kind: kind, page: page)
  }
}

private func catalogResult(query: String = "", kind: IntegrationKind? = nil, page: Int = 1)
  -> PluginCatalogSearchResult
{
  PluginCatalogSearchResult(
    publisher: "computer-mcp", publisherID: 315_005_910, query: query, kind: kind,
    page: page, nextPage: page + 1, checkedRepositories: 10,
    fetchedAt: Date(timeIntervalSince1970: 1_788_846_000), cached: false, entries: [], issues: [])
}
