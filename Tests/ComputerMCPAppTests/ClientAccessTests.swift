import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ComputerMCP
@testable import ComputerMCPApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ClientAccessTests {
  @Test
  func aReadStartedBeforeApprovalCannotReplaceItsCommittedState() async throws {
    let service = ClientAccessFake()
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    let old = try #require(model.snapshot)
    model.requestFullAccess(service.session)
    let (events, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var release: CheckedContinuation<ClientAccessSnapshot, Never>?
    service.onFetch = {
      await withCheckedContinuation {
        release = $0
        signal.yield(())
      }
    }
    let reading = Task { await model.reload() }
    var iterator = events.makeAsyncIterator()
    _ = await iterator.next()
    service.onFetch = nil
    service.committedRevision = 5
    #expect(await model.approve())
    #expect(model.snapshot?.sessions.first?.revision == 5)
    release?.resume(returning: old)
    await reading.value
    #expect(model.snapshot?.sessions.first?.revision == 5)
    #expect(service.approvals.count == 1)
  }

  @Test
  func eachConfirmationDefaultsToThisSessionAndKeepsTheReviewedTrustRevision() async throws {
    let service = ClientAccessFake()
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    model.requestFullAccess(service.session)
    #expect(model.pendingConsent?.lifetime == .thisSession)
    #expect(model.pendingConsent?.trustRevision == 7)
    model.pendingConsent?.lifetime = .alwaysAllowClient
    #expect(await model.approve())
    #expect(service.approvals.count == 1)
    #expect(service.approvals[0].lifetime == .alwaysAllowClient)
    #expect(service.approvals[0].session.revision == 4)
    #expect(service.approvals[0].trustRevision == 7)
    #expect(model.pendingConsent == nil)
    model.requestFullAccess(service.session)
    #expect(model.pendingConsent?.lifetime == .thisSession)
  }

  @Test(arguments: [false, true])
  func refreshDoesNotRebaseAnOpenConsent(trustChanged: Bool) async {
    let service = ClientAccessFake()
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    model.requestFullAccess(service.session)
    let reviewed = model.pendingConsent?.id
    if trustChanged { service.trust.revision += 1 } else { service.revision += 1 }
    await model.reload()
    #expect(model.pendingConsent?.id == reviewed)
    #expect(model.pendingConsent?.session.revision == 4)
    #expect(model.pendingConsent?.trustRevision == 7)
    #expect(!model.consentIsCurrent)
    #expect(!(await model.approve()))
    #expect(service.approvals.isEmpty)
  }

  @Test
  func failedWriteRefreshesWithoutRetryingAndFailedReadDoesNotClaimNoControl() async {
    let service = ClientAccessFake()
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    #expect(model.controllingSessions.count == 1)
    model.requestFullAccess(service.session)
    service.failWrite = true
    #expect(!(await model.approve()))
    #expect(service.approvals.count == 1)
    #expect(model.pendingConsent != nil && model.errorMessage != nil)
    service.failRead = true
    await model.reload()
    #expect(!model.isAvailable)
    #expect(model.controllingSessions.count == 1)
    #expect(model.statusText == AppLocalization.string("Client access status unavailable"))
    #expect(!(await model.approve()))
    #expect(service.approvals.count == 1)
  }

  @Test
  func endLimitAndRevokeUseTheSelectedRecordsWithoutGrantingAuthority() async {
    let service = ClientAccessFake()
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    await model.limit(service.session, to: .localFullAccess)
    #expect(service.actions.isEmpty)
    await model.limit(service.session, to: .readOnly)
    await model.end(service.session)
    await model.revoke(service.trust)
    #expect(
      service.actions == ["limit:6F83917A:4:read-only", "end:6F83917A:4", "revoke:trust:7"])
    #expect(service.approvals.isEmpty)
  }

  @Test
  func profileCeilingAndEndedStateHaveTruthfulPresentation() {
    let service = ClientAccessFake()
    var session = service.session
    #expect(session.currentAccess == .workspaceOperations)
    var grant = service.profile.grant
    grant.mode = .readOnly
    session.profile = .init(grant: grant, persisted: false)
    #expect(session.currentAccess == .readOnly)
    session.profile = nil
    #expect(session.currentAccess == nil)
    service.ended = true
    #expect(service.session.currentAccess == nil)
  }

  @Test
  func accessAndConsentViewsRenderWithoutIssuingWrites() async throws {
    let service = ClientAccessFake()
    let model = ClientAccessModel(controlPlane: service)
    for dark in [false, true] {
      let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
      await model.reload()
      try render(
        ClientAccessView(model: model).padding(24), size: .init(width: 900, height: 640),
        appearance: appearance, name: dark ? "client-access-dark" : "client-access-light")
      model.requestFullAccess(service.session)
      try render(
        ClientConsentView(model: model, draftID: try #require(model.pendingConsent?.id)),
        size: .init(width: 550, height: 440), appearance: appearance,
        name: dark ? "client-consent-dark" : "client-consent-light")
    }
    #expect(service.approvals.isEmpty && service.actions.isEmpty)
  }
}

@MainActor
private final class ClientAccessFake: ClientAccessManaging {
  let profile = GatewayControlProfile(
    grant: .init(
      id: .chatGPTOperate, capabilityIDs: ["file.read"], workspaceIDs: ["fixture"],
      allowedCallers: [.localMCP], mode: .workspaceOperations), persisted: false)
  var revision: Int64 = 4
  var ended = false
  var session: GatewayControlSessionSnapshot {
    .init(
      id: "6F83917A", principalID: "verified-client", profileID: .chatGPTOperate,
      caller: .localMCP, revision: revision, accessLimit: .workspaceOperations, ended: ended,
      fullAccessConsent: nil, profile: profile)
  }
  lazy var trust = GatewayClientTrust(
    id: "trust", principalID: "verified-client", profileID: .chatGPTOperate,
    caller: .localMCP, revision: 7, profile: profile, fullAccessAllowed: true,
    updatedAt: Date(timeIntervalSince1970: 0))
  var failRead = false
  var failWrite = false
  var committedRevision: Int64?
  var onFetch: (() async -> ClientAccessSnapshot)?
  var approvals: [ClientConsentDraft] = []
  var actions: [String] = []

  func fetchClientAccess() async throws -> ClientAccessSnapshot {
    if let onFetch { return await onFetch() }
    if failRead { throw AppControlPlaneError.unavailable("Read unavailable") }
    return .init(sessions: [session], trusts: [trust])
  }
  func grantClientFullAccess(
    id: String, lifetime: GatewayFullAccessLifetime,
    expectedRevision: Int64, expectedTrustRevision: Int64
  ) async throws {
    #expect(id == session.id)
    #expect(expectedRevision == session.revision)
    approvals.append(
      .init(session: session, trustRevision: expectedTrustRevision, lifetime: lifetime))
    if failWrite { throw AppControlPlaneError.unavailable("Write unavailable") }
    if let committedRevision { revision = committedRevision }
  }
  func limitClientAccess(id: String, mode: GatewayPermissionMode, expectedRevision: Int64)
    async throws
  {
    actions.append("limit:\(id):\(expectedRevision):\(mode.rawValue)")
  }
  func endClientAccess(id: String, expectedRevision: Int64) async throws {
    actions.append("end:\(id):\(expectedRevision)")
  }
  func revokeClientTrust(id: String, expectedRevision: Int64) async throws {
    actions.append("revoke:\(id):\(expectedRevision)")
  }
}
