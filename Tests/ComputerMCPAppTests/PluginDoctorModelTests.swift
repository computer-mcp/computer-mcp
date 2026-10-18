import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ComputerMCP
@testable import ComputerMCPApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PluginDoctorModelTests {
  @Test
  func failedRefreshKeepsThePreviousObservationAndAnExplicitError() async throws {
    let service = PluginDoctorFake()
    let model = PluginDoctorModel(controlPlane: service, pluginID: "sample")
    await model.check()
    service.onCheck = { throw GatewayToolError.invalidArguments("Package is unavailable.") }
    await model.check()
    #expect(model.report?.revision == 7)
    #expect(model.errorMessage != nil && !model.isChecking)
    #expect(service.requestedIDs == ["sample", "sample"])
  }

  @Test
  func cancelledResponseCannotReplaceANewCheckAndDuplicateClicksDoNotQueue() async throws {
    let service = PluginDoctorFake()
    let model = PluginDoctorModel(controlPlane: service, pluginID: "sample")
    let started = AsyncStream<Void>.makeStream()
    var pending: CheckedContinuation<PluginDoctorReport, any Error>?
    service.onCheck = {
      try await withCheckedThrowingContinuation {
        pending = $0
        started.continuation.yield(())
      }
    }
    let first = Task { await model.check() }
    var iterator = started.stream.makeAsyncIterator()
    await iterator.next()
    #expect(model.isChecking)
    await model.check()
    #expect(service.requestedIDs == ["sample"])
    model.cancel()
    service.onCheck = { try doctorReport(revision: 8) }
    await model.check()
    pending?.resume(returning: try doctorReport(revision: 7))
    await first.value
    #expect(model.report?.revision == 8)
    #expect(model.errorMessage == nil && !model.isChecking)
    #expect(service.requestedIDs == ["sample", "sample"])
  }

  @Test
  func parentTaskCancellationReachesTheReadAndDoesNotReportFailure() async {
    let service = PluginDoctorFake()
    let model = PluginDoctorModel(controlPlane: service, pluginID: "sample")
    let started = AsyncStream<Void>.makeStream()
    var readWasCancelled = false
    service.onCheck = {
      defer { readWasCancelled = Task.isCancelled }
      started.continuation.yield(())
      try await Task.sleep(for: .seconds(30))
      return try doctorReport()
    }
    let task = Task { await model.check() }
    var iterator = started.stream.makeAsyncIterator()
    await iterator.next()
    task.cancel()
    await task.value
    #expect(readWasCancelled)
    #expect(model.report == nil && model.errorMessage == nil && !model.isChecking)
  }

  @Test
  func nativeDoctorRendersDisabledDependenciesAndFailedRefreshInLightAndDark() async throws {
    for dark in [false, true] {
      let service = PluginDoctorFake()
      let model = PluginDoctorModel(controlPlane: service, pluginID: "sample")
      await model.check()
      if dark {
        service.onCheck = { throw GatewayToolError.invalidArguments("Package is unavailable.") }
        await model.check()
      }
      try render(
        PluginDoctorView(model: model).environment(\.colorScheme, dark ? .dark : .light),
        size: NSSize(width: 640, height: 620),
        appearance: try #require(NSAppearance(named: dark ? .darkAqua : .aqua)),
        name: dark ? "doctor-failed-refresh-dark" : "doctor-disabled-light")
    }
  }

  @Test
  func nativeDoctorRendersApplicationBindingInLightAndDark() async throws {
    let service = PluginDoctorFake()
    service.onCheck = { try doctorReport(resolutionSource: "application_bundle") }
    let model = PluginDoctorModel(controlPlane: service, pluginID: "sample")
    await model.check()
    #expect(model.report?.dependencies.first?.resolutionSource == "application_bundle")
    for dark in [false, true] {
      try render(
        PluginDoctorView(model: model).environment(\.colorScheme, dark ? .dark : .light),
        size: NSSize(width: 640, height: 620),
        appearance: try #require(NSAppearance(named: dark ? .darkAqua : .aqua)),
        name: dark ? "doctor-application-dark" : "doctor-application-light")
    }
  }
}

@MainActor
private final class PluginDoctorFake: PluginManaging {
  var onCheck: (() async throws -> PluginDoctorReport)?
  private(set) var requestedIDs: [String] = []

  func doctorPlugin(id: String) async throws -> PluginDoctorReport {
    requestedIDs.append(id)
    if let onCheck { return try await onCheck() }
    return try doctorReport()
  }
  func fetchPlugins() async throws -> PluginHostSnapshot {
    Issue.record("Doctor unexpectedly read the management list.")
    throw CancellationError()
  }
  func changePlugins(_ change: PluginHostChange, expectedRevision: Int64) async throws
    -> PluginHostSnapshot
  {
    Issue.record("Doctor unexpectedly changed plugin state.")
    throw CancellationError()
  }
  func searchPlugins(query: String, kind: IntegrationKind?, page: Int, refresh: Bool) async throws
    -> PluginCatalogSearchResult
  {
    Issue.record("Doctor unexpectedly searched GitHub.")
    throw CancellationError()
  }
  func pluginReleaseArtifacts(repository: String, repositoryID: Int64, tag: String?, page: Int)
    async throws -> GitHubPluginReleaseArtifacts
  {
    Issue.record("Doctor unexpectedly searched releases.")
    throw CancellationError()
  }
}

private func doctorReport(revision: Int64 = 7, resolutionSource: String = "unresolved") throws
  -> PluginDoctorReport
{
  let manifest = try PluginManifest.parse(
    """
    id = 'sample'
    name = 'Sample'
    version = '1.0.0'
    [[dependencies]]
    id = 'vendor'
    commands = ['fixture-runtime']
    instructions = 'Configure the vendor runtime separately. 此包尚未启用。'
    [[skills]]
    id = 'guidance'
    path = 'skills'
    """)
  return PluginDoctorReport(
    pluginID: "sample", revision: revision, checkedAt: Date(timeIntervalSince1970: 1_788_846_000),
    enabled: false, source: nil, version: manifest.version,
    checks: [
      .init(
        id: "dependency:vendor", kind: .executable, status: .failed,
        message: "The executable was not found in the configured location or launch search path.",
        dependencyID: "vendor", enabled: false)
    ],
    dependencies: [
      .init(
        declaration: manifest.dependencies[0],
        executable: resolutionSource == "application_bundle"
          ? "/Applications/Fixture.app/Contents/MacOS/vendor" : nil,
        resolutionSource: resolutionSource)
    ],
    status: .failed, scope: "configuration_and_files",
    notChecked: ["runtime_version", "binary_compatibility", "connection", "system_permissions"])
}
