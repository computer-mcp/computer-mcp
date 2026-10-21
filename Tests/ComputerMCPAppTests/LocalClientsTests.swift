import AppKit
import ComputerMCPCore
import ComputerMCPTestSupport
import Foundation
import SwiftUI
import Testing

@testable import ComputerMCPApp
@testable import ComputerMCPControlPlane

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalClientsTests {
  @Test
  func connectingAppliesExactlyTheReviewedPlan() async throws {
    let fixture = try LocalClientsFixture()
    let model = LocalClientsModel(controlPlane: fixture.fake)
    await model.reload()
    #expect(model.status(for: .claudeDesktop)?.state == .notRegistered)
    #expect(model.status(for: .codex)?.state == .unavailable)
    await model.beginReview(.claudeDesktop, operation: .register)
    let review = try #require(model.review)
    #expect(review.plan.display.warnings.count == 2)
    await model.confirm(review)
    #expect(fixture.fake.applied == [review.plan.fingerprint])
    #expect(model.review == nil)
    #expect(
      model.outcome?.title == AppLocalization.formatted("Connected to %@", "Claude Desktop"))
    #expect(model.status(for: .claudeDesktop)?.state == .registered)
    let written = try fixture.desktopConfiguration()
    #expect(
      written["mcpServers"]?.objectValue?["computer-mcp"]?.objectValue?["command"]
        == .string(fixture.server.executable))
  }

  @Test
  func aChangeAfterReviewIsRefusedAndExplained() async throws {
    let fixture = try LocalClientsFixture()
    try fixture.writeDesktopConfiguration(#"{"theme":"dark"}"#)
    let model = LocalClientsModel(controlPlane: fixture.fake)
    await model.beginReview(.claudeDesktop, operation: .register)
    let review = try #require(model.review)
    try fixture.writeDesktopConfiguration(#"{"theme":"light"}"#)
    await model.confirm(review)
    #expect(
      model.outcome?.message
        == LocalClientsModel.message(for: .changedSincePreview, client: .claudeDesktop))
    #expect(try fixture.desktopConfiguration() == ["theme": .string("light")])
  }

  @Test
  func removingKeepsTheClientsOtherSettings() async throws {
    let fixture = try LocalClientsFixture()
    try fixture.writeDesktopConfiguration(#"{"theme":"dark"}"#)
    let model = LocalClientsModel(controlPlane: fixture.fake)
    await model.beginReview(.claudeDesktop, operation: .register)
    await model.confirm(try #require(model.review))
    await model.beginReview(.claudeDesktop, operation: .remove)
    let removal = try #require(model.review)
    #expect(removal.plan.display.operation == .remove)
    await model.confirm(removal)
    #expect(model.outcome?.title == AppLocalization.formatted("Removed from %@", "Claude Desktop"))
    #expect(model.status(for: .claudeDesktop)?.state == .notRegistered)
    #expect(try fixture.desktopConfiguration()["theme"] == .string("dark"))
  }

  @Test
  func onlyTheOpenReviewCanBeConfirmed() async throws {
    let fixture = try LocalClientsFixture()
    let model = LocalClientsModel(controlPlane: fixture.fake)
    await model.beginReview(.claudeDesktop, operation: .register)
    let review = try #require(model.review)
    model.cancelReview()
    await model.confirm(review)
    #expect(fixture.fake.applied.isEmpty)
    #expect(model.outcome == nil)
  }

  @Test
  func resultsAndErrorsReadAsSentences() async throws {
    let fixture = try LocalClientsFixture()
    let plan = try await fixture.fake.previewClientRegistration(
      client: .claudeDesktop, operation: .register
    ).display
    let uncertain = LocalClientsModel.outcome(
      ClientRegistrationResult(
        outcome: .uncertain, errorCode: .uncertain, steps: [], finalState: .notRegistered,
        finalEntry: nil, appliesAfter: plan.appliesAfter), plan: plan)
    #expect(uncertain.title == AppLocalization.string("Result unknown"))
    let running = LocalClientsModel.outcome(
      ClientRegistrationResult(
        outcome: .failed, errorCode: .clientRunning, steps: [], finalState: .notRegistered,
        finalEntry: nil, appliesAfter: plan.appliesAfter), plan: plan)
    #expect(
      running.message.hasPrefix(
        AppLocalization.formatted("Quit %@, then try again.", "Claude Desktop")))
    let thrown = LocalClientsModel.failure(
      ClientRegistrationError(.writerBusy), client: .claudeDesktop)
    #expect(
      thrown.message
        == AppLocalization.string("Another client change is in progress. Try again shortly."))
  }

  @Test
  func anUncertainChangeWaitsForAnExplicitRefresh() async throws {
    let fixture = try LocalClientsFixture()
    fixture.fake.applyOverride = { plan in
      ClientRegistrationResult(
        outcome: .uncertain, errorCode: .uncertain,
        steps: [.init(step: "add", outcome: .uncertain, exitCode: nil)],
        finalState: .notRegistered, finalEntry: nil, appliesAfter: plan.display.appliesAfter)
    }
    let model = LocalClientsModel(controlPlane: fixture.fake)
    await model.reload()
    await model.beginReview(.claudeDesktop, operation: .register)
    await model.confirm(try #require(model.review))
    #expect(model.uncertainClients == [.claudeDesktop])
    #expect(model.outcome?.title == AppLocalization.string("Result unknown"))
    #expect(model.outcome?.message.contains(AppLocalization.string("adding the new entry")) == true)
    let reads = fixture.fake.fetchCount
    await model.reload()
    await model.beginReview(.claudeDesktop, operation: .register)
    #expect(fixture.fake.fetchCount == reads)
    #expect(model.review == nil)
    await model.reload(explicit: true)
    #expect(fixture.fake.fetchCount == reads + 1)
    #expect(model.uncertainClients.isEmpty)
  }

  @Test(arguments: [false, true])
  func aFailedReplacementSaysWhetherTheEntryWasRestored(restored: Bool) async throws {
    let fixture = try LocalClientsFixture()
    let plan = try await fixture.fake.previewClientRegistration(
      client: .claudeDesktop, operation: .register
    ).display
    let outcome = LocalClientsModel.outcome(
      ClientRegistrationResult(
        outcome: .failed, errorCode: .processFailed,
        steps: [
          .init(step: "remove", outcome: .succeeded, exitCode: 0),
          .init(step: "add", outcome: .failed, exitCode: 1),
          .init(step: "restore", outcome: restored ? .succeeded : .failed, exitCode: 1),
        ],
        finalState: restored ? .different : .notRegistered, finalEntry: nil,
        appliesAfter: plan.appliesAfter), plan: plan)
    let restoration =
      restored
      ? AppLocalization.string("The previous entry was restored.")
      : AppLocalization.formatted(
        "The previous entry couldn't be restored. Check %@'s settings.", "Claude Desktop")
    #expect(outcome.message.contains(restoration))
    #expect(
      outcome.message.contains(
        AppLocalization.formatted(
          "It now shows: %@.",
          AppLocalization.string(restored ? "Different entry" : "Not connected"))))
  }

  @Test
  func everyErrorCodeReadsAsASentence() {
    let codes: [ClientRegistrationErrorCode] = [
      .changedSincePreview, .confirmationRequired, .unsupportedEntry, .clientRunning,
      .unavailable, .unreadable, .writerBusy, .writeFailed, .invalidInput,
      .invalidServerExecutable, .supportDirectoryMissing, .processFailed, .uncertain,
    ]
    for code in codes {
      for client in RegistrationClient.allCases {
        let message = LocalClientsModel.message(for: code, client: client)
        #expect(!message.isEmpty && !message.contains(code.rawValue))
      }
    }
  }

  @Test
  func overlappingReviewsStartOnePreview() async throws {
    let fixture = try LocalClientsFixture()
    let (started, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var release: CheckedContinuation<Void, Never>?
    fixture.fake.previewGate = {
      await withCheckedContinuation {
        release = $0
        signal.yield(())
      }
    }
    let model = LocalClientsModel(controlPlane: fixture.fake)
    let first = Task { await model.beginReview(.claudeDesktop, operation: .register) }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    #expect(model.busyClient == .claudeDesktop)
    await model.beginReview(.codex, operation: .register)
    fixture.fake.previewGate = nil
    release?.resume()
    await first.value
    #expect(fixture.fake.previewCount == 1)
    #expect(model.review?.plan.display.client == .claudeDesktop)
  }

  @Test
  func rowsAndReviewSheetsRender() async throws {
    let fixture = try LocalClientsFixture()
    let location = ClientRegistrationLocation(
      configurationFile: fixture.desktopFile.path, configurationVariable: nil,
      configurationValue: nil)
    let model = LocalClientsModel(controlPlane: fixture.fake)
    fixture.fake.statusOverride = [
      .init(client: .codex, state: .registered, location: location, observedEntry: nil),
      .init(client: .claudeCode, state: .different, location: location, observedEntry: nil),
      .init(client: .claudeDesktop, state: .unreadable, location: location, observedEntry: nil),
    ]
    await model.reload()
    try fixture.writeDesktopConfiguration(
      #"{"mcpServers":{"computer-mcp":{"command":"/Applications/Old.app/computer-mcp","args":["--token","SENTINEL-ARGUMENT"],"env":{"API_KEY":"SENTINEL-VALUE"}}}}"#
    )
    await model.beginReview(.claudeDesktop, operation: .register)
    let replacement = try #require(model.review)
    #expect(replacement.plan.display.state == .different)
    #expect(!String(describing: replacement.plan.display).contains("SENTINEL"))
    try fixture.writeDesktopConfiguration(#"{"mcpServers":[]}"#)
    let refused = LocalClientReview(
      plan: try await fixture.fake.previewClientRegistration(
        client: .claudeDesktop, operation: .register))
    #expect(refused.plan.display.refusalCode == .unreadable)
    for dark in [false, true] {
      let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
      let suffix = dark ? "dark" : "light"
      try render(
        Form { Section("Connect a local MCP client") { LocalClientRows(model: model) } }
          .formStyle(.grouped).environment(\.locale, Locale(identifier: "en")),
        size: .init(width: 640, height: 260), appearance: appearance,
        name: "local-clients-\(suffix)")
      try render(
        LocalClientReviewSheet(model: model, review: replacement)
          .environment(\.locale, Locale(identifier: "en")),
        size: .init(width: 600, height: 520), appearance: appearance,
        name: "local-client-review-\(suffix)")
      try render(
        LocalClientReviewSheet(model: model, review: refused)
          .environment(\.locale, Locale(identifier: "en")),
        size: .init(width: 600, height: 320), appearance: appearance,
        name: "local-client-refusal-\(suffix)")
    }
    #expect(fixture.fake.applied.isEmpty)
  }
}

@MainActor
private final class LocalClientsFixture {
  let temporary: ScopedTemporaryDirectory
  let server: ClientRegistrationCommand
  let desktopFile: URL
  let fake: LocalClientsFake

  init() throws {
    temporary = try ScopedTemporaryDirectory()
    let executable = temporary.url.appendingPathComponent("computer-mcp")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    server = ClientRegistrationCommand(
      executable: executable.path,
      arguments: ["bridge", "--client-identity", "local-mcp", "--socket", "/tmp/gateway.sock"])
    let support = temporary.url.appendingPathComponent("Claude", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    desktopFile = support.appendingPathComponent("claude_desktop_config.json")
    let service = ClientRegistrationService(
      homeDirectory: temporary.url.appendingPathComponent("home"),
      stateDirectory: temporary.url.appendingPathComponent("state"),
      executableSearchDirectories: [], environment: [:],
      desktop: ClaudeDesktopRegistration(
        configurationFile: desktopFile, isInstalled: { true }, isRunning: { false }))
    fake = LocalClientsFake(service: service, server: server)
  }

  func writeDesktopConfiguration(_ text: String) throws {
    try Data(text.utf8).write(to: desktopFile)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: desktopFile.path)
  }

  func desktopConfiguration() throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: desktopFile))
  }
}

@MainActor
private final class LocalClientsFake: LocalClientRegistering {
  let service: ClientRegistrationService
  let server: ClientRegistrationCommand
  var statusOverride: [ClientRegistrationStatus]?
  var applyOverride: ((ClientRegistrationPlan) -> ClientRegistrationResult)?
  var previewGate: (() async -> Void)?
  var applied: [String] = []
  var fetchCount = 0
  var previewCount = 0

  init(service: ClientRegistrationService, server: ClientRegistrationCommand) {
    self.service = service
    self.server = server
  }

  func fetchClientRegistrations() async throws -> [ClientRegistrationStatus] {
    fetchCount += 1
    return try statusOverride ?? service.statuses(server: server)
  }
  func previewClientRegistration(client: RegistrationClient, operation: ClientRegistrationOperation)
    async throws -> ClientRegistrationPlan
  {
    previewCount += 1
    if let previewGate { await previewGate() }
    return try service.preview(client: client, operation: operation, server: server)
  }
  func applyClientRegistration(_ plan: ClientRegistrationPlan) async throws
    -> ClientRegistrationResult
  {
    applied.append(plan.fingerprint)
    if let applyOverride { return applyOverride(plan) }
    return try service.apply(plan)
  }
}
