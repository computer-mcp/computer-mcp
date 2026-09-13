import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ComputerMCP
@testable import ComputerMCPApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PluginReleaseTests {
  @Test
  func pageLabelUsesTheViewLocale() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComputerMCPReleaseLocalization-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: output) }
    let result = try ProcessCommandRunner().run(
      executable: "/usr/bin/xcrun",
      arguments: [
        "xcstringstool", "compile",
        root.appendingPathComponent("Sources/ComputerMCPApp/Resources/Localizable.xcstrings").path,
        "--output-directory", output.path, "--serialization-format", "binary",
      ], workingDirectory: root, environment: [:], timeoutMilliseconds: 30_000,
      maxOutputBytes: 16_384)
    try #require(result.exitCode == 0, "\(result.stderr)")
    let bundle = try #require(Bundle(url: output))
    #expect(
      AppLocalization.formatted(
        "Asset page %@", locale: Locale(identifier: "zh-Hans"), bundle: bundle, "2")
        == "归档页 2")
    #expect(
      AppLocalization.formatted(
        "Asset page %@", locale: Locale(identifier: "en"), bundle: bundle, "2")
        == "Asset page 2")
  }

  @Test(arguments: [false, true])
  func cancellationWaitsForCompletionAndKeepsCommittedResult(committed: Bool) async throws {
    let service = try ReleaseAppFake()
    service.commitAfterCancellation = committed
    let management = PluginManagementModel(controlPlane: service)
    await management.reload()
    let started = AsyncStream<Void>.makeStream()
    var continuation: CheckedContinuation<Void, Never>?
    service.beforeInstall = {
      await withCheckedContinuation {
        continuation = $0
        started.continuation.yield(())
      }
    }
    let operation = Task {
      await management.apply(.installRelease(service.artifact), expectedRevision: 0)
    }
    var events = started.stream.makeAsyncIterator()
    await events.next()
    management.cancelChange()
    #expect(management.isSaving && management.isCancelling)
    #expect(await management.apply(.installRelease(service.artifact), expectedRevision: 0) == false)
    continuation?.resume()
    #expect(await operation.value == committed)
    #expect(!management.isSaving && !management.isCancelling)
    #expect(management.snapshot?.state.revision == (committed ? 1 : 0))
    #expect((management.errorMessage == nil) == committed)
    #expect(service.revisions == [0])
    started.continuation.finish()
  }

  @Test
  func pagesStayOnDisplayedReleaseAndFailurePreventsInstallation() async throws {
    let service = try ReleaseAppFake()
    let model = PluginReleaseModel(entry: service.artifact.declaration, controlPlane: service)
    await model.search()
    #expect(model.canInstall)
    model.tag = "edited-but-not-submitted"
    await model.page(2)
    #expect(service.requests.map(\.tag) == [nil, "release/1.2.3"])
    #expect(service.requests.map(\.page) == [1, 2])
    #expect(model.result?.page == 2)
    service.failure = .httpStatus(503)
    await model.search()
    #expect(model.result?.page == 2)
    #expect(model.errorMessage?.contains("503") == true)
    #expect(!model.canInstall && !model.isLoading)
  }

  @Test
  func changedPluginIdentityCannotReplaceSearchSelection() async throws {
    let service = try ReleaseAppFake()
    let model = PluginReleaseModel(entry: service.artifact.declaration, controlPlane: service)
    await model.search()
    service.artifact = try releaseAppArtifact(pluginID: "different")
    await model.search()
    #expect(model.result?.declaration.pluginID == "combined")
    #expect(model.errorMessage != nil && !model.canInstall)
  }

  @Test
  func lateCancelledReadCannotReplaceNewResult() async throws {
    let service = try ReleaseAppFake()
    let model = PluginReleaseModel(entry: service.artifact.declaration, controlPlane: service)
    let started = AsyncStream<Void>.makeStream()
    var continuation: CheckedContinuation<GitHubPluginReleaseArtifacts, any Error>?
    service.beforeRead = {
      try await withCheckedThrowingContinuation {
        continuation = $0
        started.continuation.yield(())
      }
    }
    let first = Task { await model.search() }
    var events = started.stream.makeAsyncIterator()
    await events.next()
    await model.search()
    #expect(service.requests.count == 1)
    model.cancel()
    service.beforeRead = nil
    await model.search()
    await model.page(2)
    continuation?.resume(returning: service.result(page: 1))
    await first.value
    #expect(model.result?.page == 2 && model.canInstall)
    started.continuation.finish()
  }

  @Test
  func installationForwardsExactSelectionAndRevisionOnce() async throws {
    let service = try ReleaseAppFake()
    let management = PluginManagementModel(controlPlane: service)
    await management.reload()
    let selection = service.artifact
    #expect(await management.apply(.installRelease(selection), expectedRevision: 0))
    #expect(service.installed == [selection])
    #expect(service.revisions == [0])
    #expect(management.snapshot?.state.revision == 1)
  }

  @Test
  func releaseScreenRendersBothLocalesAndAppearances() async throws {
    let service = try ReleaseAppFake()
    let management = PluginManagementModel(controlPlane: service)
    await management.reload()
    let model = PluginReleaseModel(entry: service.artifact.declaration, controlPlane: service)
    await model.search()
    let selection = PluginReleaseSelection(entry: service.artifact.declaration, revision: 0)
    for language in ["en", "zh-Hans"] {
      for dark in [false, true] {
        try render(
          PluginReleaseView(management: management, selection: selection, model: model)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.colorScheme, dark ? .dark : .light),
          size: NSSize(width: 720, height: 720),
          appearance: try #require(NSAppearance(named: dark ? .darkAqua : .aqua)),
          name: "release-\(language)-\(dark ? "dark" : "light")")
      }
    }
  }

  @Test
  func savingAndFailedReleaseScreensRender() async throws {
    let service = try ReleaseAppFake()
    let management = PluginManagementModel(controlPlane: service)
    await management.reload()
    let model = PluginReleaseModel(entry: service.artifact.declaration, controlPlane: service)
    await model.search()
    let selection = PluginReleaseSelection(entry: service.artifact.declaration, revision: 0)
    let started = AsyncStream<Void>.makeStream()
    var continuation: CheckedContinuation<Void, Never>?
    service.beforeInstall = {
      await withCheckedContinuation {
        continuation = $0
        started.continuation.yield(())
      }
    }
    let operation = Task {
      await management.apply(.installRelease(service.artifact), expectedRevision: 0)
    }
    var events = started.stream.makeAsyncIterator()
    await events.next()
    do {
      try render(
        PluginReleaseView(management: management, selection: selection, model: model)
          .environment(\.locale, Locale(identifier: "en"))
          .environment(\.colorScheme, .dark),
        size: NSSize(width: 720, height: 720),
        appearance: try #require(NSAppearance(named: .darkAqua)),
        name: "release-saving")
      management.cancelChange()
      try render(
        PluginReleaseView(management: management, selection: selection, model: model)
          .environment(\.locale, Locale(identifier: "zh-Hans")),
        size: NSSize(width: 720, height: 720), appearance: try #require(NSAppearance(named: .aqua)),
        name: "release-cancelling-zh")
    } catch {
      management.cancelChange()
      continuation?.resume()
      _ = await operation.value
      started.continuation.finish()
      throw error
    }
    continuation?.resume()
    #expect(await operation.value == false)
    started.continuation.finish()
    service.failure = .httpStatus(503)
    await model.search()
    try render(
      PluginReleaseView(management: management, selection: selection, model: model),
      size: NSSize(width: 720, height: 720), appearance: try #require(NSAppearance(named: .aqua)),
      name: "release-failed")
  }
}

@MainActor
private final class ReleaseAppFake: PluginManaging {
  func doctorPlugin(id: String) async throws -> PluginDoctorReport { throw CancellationError() }
  struct Request {
    let tag: String?
    let page: Int
  }
  var artifact: GitHubPluginArtifact
  var requests: [Request] = []
  var installed: [GitHubPluginArtifact] = []
  var revisions: [Int64] = []
  var failure: PluginCatalogError?
  var beforeRead: (() async throws -> GitHubPluginReleaseArtifacts)?
  var beforeInstall: (() async -> Void)?
  var commitAfterCancellation = false
  var state = PluginStoreSnapshot()

  init() throws { artifact = try releaseAppArtifact() }
  func result(page: Int) -> GitHubPluginReleaseArtifacts {
    GitHubPluginReleaseArtifacts(
      declaration: artifact.declaration, releaseID: artifact.releaseID, tag: artifact.tag,
      prerelease: true, page: page, nextPage: page + 1, artifacts: [artifact], issues: [])
  }
  func pluginReleaseArtifacts(repository: String, repositoryID: Int64, tag: String?, page: Int)
    async throws -> GitHubPluginReleaseArtifacts
  {
    #expect(
      repository == artifact.declaration.repository
        && repositoryID == artifact.declaration.repositoryID)
    requests.append(Request(tag: tag, page: page))
    if let beforeRead { return try await beforeRead() }
    if let failure { throw failure }
    return result(page: page)
  }
  func fetchPlugins() async throws -> PluginHostSnapshot { try PluginHostSnapshot(state: state) }
  func changePlugins(_ change: PluginHostChange, expectedRevision: Int64) async throws
    -> PluginHostSnapshot
  {
    guard case .installRelease(let artifact) = change else {
      throw PluginHostError.changeInProgress
    }
    installed.append(artifact)
    revisions.append(expectedRevision)
    await beforeInstall?()
    if !commitAfterCancellation { try Task.checkCancellation() }
    guard expectedRevision == state.revision else {
      throw PluginStoreError.staleRevision(expected: expectedRevision, actual: state.revision)
    }
    state.revision += 1
    return try PluginHostSnapshot(state: state)
  }
  func searchPlugins(query: String, kind: IntegrationKind?, page: Int, refresh: Bool) async throws
    -> PluginCatalogSearchResult
  {
    throw PluginCatalogError.networkUnavailable
  }
}

private func releaseAppArtifact(pluginID: String = "combined") throws -> GitHubPluginArtifact {
  GitHubPluginArtifact(
    declaration: PluginCatalogEntry(
      repositoryID: 7, repository: "computer-mcp/combined", publisherID: 315_005_910,
      revision: String(repeating: "a", count: 40),
      manifestBlobSHA: String(repeating: "b", count: 40),
      manifestSHA256: String(repeating: "c", count: 64), pluginID: pluginID,
      name: "Combined tools · 组合工具", version: try PluginVersion("1.2.3"), summary: nil,
      mcp: ["native"], cli: ["command"], skills: ["guide"]),
    releaseID: 9, tag: "release/1.2.3", prerelease: true, assetID: 11,
    name: "combined-macos-universal.zip", size: 20_971_520,
    sha256: String(repeating: "d", count: 64))
}
