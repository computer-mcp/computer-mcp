import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ComputerMCPApp
@testable import ComputerMCPAuthorization
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

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

  @Test
  func signInApprovalDefaultsToReadOnlyAndKeepsTheOwnersChoice() async throws {
    let service = ClientAccessFake()
    service.oauth = true
    var observeProfile = ProfileGrant.cloudflareObserve
    observeProfile.authorizationRevision = 17
    var operateProfile = ProfileGrant.cloudflareOperate
    operateProfile.authorizationRevision = 23
    service.remoteProfiles = [operateProfile, observeProfile]
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    #expect(model.pendingOAuthRequests.map(\.pairingCode) == ["K7M2QP", "R4TX9H"])
    #expect(model.oauthProfileOptions.map(\.id) == [.cloudflareObserve, .cloudflareOperate])
    #expect(model.statusText == AppLocalization.formatted("Sign-in requests waiting: %@", "2"))
    let first = model.pendingOAuthRequests[0]
    let second = model.pendingOAuthRequests[1]
    let observe = try #require(model.oauthProfile(for: first))
    #expect(observe.id == .cloudflareObserve && observe.mode == .readOnly)
    #expect(await model.approve(first, reviewed: observe))
    model.chooseOAuthProfile(.cloudflareOperate, for: second)
    model.chooseOAuthProfile(.chatGPTOperate, for: second)
    let operate = try #require(model.oauthProfile(for: second))
    #expect(operate.id == .cloudflareOperate)
    #expect(await model.approve(second, reviewed: operate))
    #expect(
      service.actions == [
        "oauth-approve:K7M2QP:cloudflare:cloudflare-observe",
        "oauth-approve:R4TX9H:cloudflare:cloudflare-operate",
      ])
    #expect(model.oauthProfileChoices.isEmpty)
    #expect(service.oauthApprovalRevisions == [17, 23])
    #expect(service.approvals.isEmpty)
  }

  @Test
  func reviewedPermissionsMustMatchEvenWhenTheAccessModeIsUnchanged() async throws {
    let service = ClientAccessFake()
    service.oauth = true
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    let request = try #require(model.pendingOAuthRequests.first)
    let reviewed = try #require(model.oauthProfile(for: request))
    var current = reviewed
    current.capabilityIDs.insert("file.read")
    current.authorizationRevision += 1
    service.remoteProfiles = [current]
    await model.reload()
    #expect(!(await model.approve(request, reviewed: reviewed)))
    #expect(model.errorMessage != nil)
    #expect(service.actions.isEmpty)
  }

  @Test
  func aProfileNamedObserveThatAllowsChangesIsNeverTheDefault() async throws {
    let service = ClientAccessFake()
    service.oauth = true
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    let request = try #require(model.pendingOAuthRequests.first)
    let reviewed = try #require(model.oauthProfile(for: request))
    var observe = ProfileGrant.cloudflareObserve
    observe.mode = .workspaceOperations
    service.remoteProfiles = [observe, .cloudflareOperate]
    await model.reload()
    #expect(model.oauthProfile(for: request) == nil)
    #expect(!(await model.approve(request, reviewed: reviewed)))
    #expect(model.errorMessage != nil)
    #expect(service.actions.isEmpty)
  }

  @Test
  func aChosenProfileWhoseAccessChangesMustBeChosenAgain() async throws {
    let service = ClientAccessFake()
    service.oauth = true
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    let request = try #require(model.pendingOAuthRequests.first)
    model.chooseOAuthProfile(.cloudflareOperate, for: request)
    let reviewed = try #require(model.oauthProfile(for: request))
    var operate = ProfileGrant.cloudflareOperate
    operate.mode = .localFullAccess
    service.remoteProfiles = [operate, .cloudflareObserve]
    await model.reload()
    #expect(model.oauthProfile(for: request) == nil)
    #expect(!(await model.approve(request, reviewed: reviewed)))
    #expect(service.actions.isEmpty)
    model.chooseOAuthProfile(.cloudflareObserve, for: request)
    let observe = try #require(model.oauthProfile(for: request))
    #expect(await model.approve(request, reviewed: observe))
    #expect(service.actions == ["oauth-approve:K7M2QP:cloudflare:cloudflare-observe"])
  }

  @Test
  func expiredSignInRequestsLeaveTheListAndCannotBeApproved() async throws {
    let service = ClientAccessFake()
    service.oauth = true
    let expired = OAuthPendingAuthorization(
      id: "c-request", tunnelID: "cloudflare", pairingCode: "W3NC8J", clientHost: "claude.ai",
      redirectHost: "claude.ai", createdAt: Date(timeIntervalSinceNow: -700),
      expiresAt: Date(timeIntervalSinceNow: -100))
    service.oauthRequests.append(expired)
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    #expect(model.pendingOAuthRequests.map(\.pairingCode) == ["K7M2QP", "R4TX9H"])
    #expect(model.statusText == AppLocalization.formatted("Sign-in requests waiting: %@", "2"))
    #expect(!(await model.approve(expired, reviewed: .cloudflareObserve)))
    #expect(model.errorMessage != nil)
    #expect(service.actions.isEmpty)
  }

  @Test
  func signInCannotBeApprovedWithoutATunnelProfile() async throws {
    let service = ClientAccessFake()
    service.oauth = true
    service.remoteProfiles = []
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    let request = try #require(model.pendingOAuthRequests.first)
    #expect(model.oauthProfile(for: request) == nil)
    #expect(!(await model.approve(request, reviewed: .cloudflareObserve)))
    #expect(service.actions.isEmpty)
  }

  @Test
  func denyAndRevokeUseTheSelectedRecordsAndHideRevokedGrants() async throws {
    let service = ClientAccessFake()
    service.oauth = true
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    #expect(model.activeOAuthGrants.map(\.id) == ["recent", "older"])
    let request = try #require(model.pendingOAuthRequests.last)
    model.chooseOAuthProfile(.cloudflareOperate, for: request)
    await model.deny(request)
    #expect(model.oauthProfileChoices.isEmpty)
    await model.revoke(model.activeOAuthGrants[1])
    #expect(service.actions == ["oauth-deny:R4TX9H:cloudflare", "oauth-revoke:older"])
    service.failWrite = true
    await model.revoke(model.activeOAuthGrants[0])
    #expect(model.errorMessage != nil)
    #expect(service.actions.count == 3)
  }

  @Test
  func cloudflareEditorRendersSignInSettings() throws {
    let model = ComputerMCPAppModel(
      controlPlane: UnavailableControlPlane(), onboardingPreferences: CompletedOnboarding())
    var presentation = CloudflareEditorPresentation.new
    presentation.draft.tunnelName = "computer-mcp-release"
    presentation.draft.publicHostname = "mcp.example.com"
    presentation.draft.oauthEnabled = true
    for dark in [false, true] {
      let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
      try render(
        CloudflareTunnelEditorView(presentation: presentation).environmentObject(model)
          .environment(\.locale, Locale(identifier: "en")),
        size: .init(width: 600, height: 700), appearance: appearance,
        name: dark ? "cloudflare-editor-oauth-dark" : "cloudflare-editor-oauth-light")
    }
  }

  @Test
  func signInRequestsAndRemoteClientsRenderWithoutIssuingWrites() async throws {
    let service = ClientAccessFake()
    service.oauth = true
    let model = ClientAccessModel(controlPlane: service)
    for dark in [false, true] {
      let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
      await model.reload()
      try render(
        ClientAccessView(model: model).padding(24).environment(\.locale, Locale(identifier: "en")),
        size: .init(width: 900, height: 900),
        appearance: appearance,
        name: dark ? "client-access-oauth-dark" : "client-access-oauth-light")
      service.remoteProfiles = []
      await model.reload()
      try render(
        ClientAccessView(model: model).padding(24).environment(\.locale, Locale(identifier: "en")),
        size: .init(width: 900, height: 900),
        appearance: appearance,
        name: dark ? "client-access-oauth-no-profile-dark" : "client-access-oauth-no-profile-light")
      service.remoteProfiles = [.cloudflareOperate]
      await model.reload()
      try render(
        ClientAccessView(model: model).padding(24).environment(\.locale, Locale(identifier: "en")),
        size: .init(width: 900, height: 900), appearance: appearance,
        name: dark ? "client-access-oauth-choose-dark" : "client-access-oauth-choose-light")
      service.remoteProfiles = [.cloudflareOperate, .cloudflareObserve]
    }
    #expect(service.actions.isEmpty)
  }
}

@MainActor
private struct CompletedOnboarding: OnboardingPreferenceStoring {
  var completedVersion: Int { UserDefaultsOnboardingPreferences.currentVersion }
  func markCompleted(version: Int) {}
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
  var oauth = false
  var remoteProfiles: [ProfileGrant] = [.cloudflareOperate, .cloudflareObserve]
  var oauthRequests = [
    OAuthPendingAuthorization(
      id: "a-request", tunnelID: "cloudflare", pairingCode: "R4TX9H", clientHost: "claude.ai",
      redirectHost: "claude.ai", createdAt: Date(timeIntervalSinceNow: -60),
      expiresAt: Date(timeIntervalSinceNow: 540)),
    OAuthPendingAuthorization(
      id: "b-request", tunnelID: "cloudflare", pairingCode: "K7M2QP", clientHost: "claude.com",
      redirectHost: "claude.ai", createdAt: Date(timeIntervalSinceNow: -120),
      expiresAt: Date(timeIntervalSinceNow: 480)),
  ]
  let oauthGrants = [
    OAuthGrant(
      id: "older", tunnelID: "cloudflare", clientID: "https://claude.ai/oauth/mcp-client.json",
      redirectHost: "claude.ai", profileID: .cloudflareObserve,
      resource: "https://mcp.example.com/mcp", scope: "mcp",
      createdAt: Date(timeIntervalSinceNow: -86_400)),
    OAuthGrant(
      id: "recent", tunnelID: "cloudflare", clientID: "https://claude.com/oauth/client.json",
      redirectHost: "claude.ai", profileID: .cloudflareOperate,
      resource: "https://mcp.example.com/mcp", scope: "mcp",
      createdAt: Date(timeIntervalSinceNow: -172_800), lastUsedAt: Date(timeIntervalSinceNow: -30)),
    OAuthGrant(
      id: "revoked", tunnelID: "cloudflare", clientID: "https://claude.ai/oauth/mcp-client.json",
      redirectHost: "claude.ai", profileID: .cloudflareObserve,
      resource: "https://mcp.example.com/mcp", scope: "mcp",
      createdAt: Date(timeIntervalSinceNow: -3_600), revokedAt: Date(timeIntervalSinceNow: -60)),
  ]

  func fetchClientAccess() async throws -> ClientAccessSnapshot {
    if let onFetch { return await onFetch() }
    if failRead { throw AppControlPlaneError.unavailable("Read unavailable") }
    guard oauth else { return .init(sessions: [session], trusts: [trust]) }
    return .init(
      sessions: [session], trusts: [trust], oauthRequests: oauthRequests,
      oauthGrants: oauthGrants, remoteProfiles: remoteProfiles,
      tunnelHosts: ["cloudflare": "mcp.example.com"])
  }
  var oauthApprovalRevisions: [Int64] = []
  func approveOAuthRequest(
    _ request: OAuthPendingAuthorization, profile: GatewayProfileID,
    expectedAuthorizationRevision: Int64
  )
    async throws
  {
    actions.append("oauth-approve:\(request.pairingCode):\(request.tunnelID):\(profile.rawValue)")
    oauthApprovalRevisions.append(expectedAuthorizationRevision)
    if failWrite { throw AppControlPlaneError.unavailable("Write unavailable") }
  }
  func denyOAuthRequest(_ request: OAuthPendingAuthorization) async throws {
    actions.append("oauth-deny:\(request.pairingCode):\(request.tunnelID)")
    if failWrite { throw AppControlPlaneError.unavailable("Write unavailable") }
  }
  func revokeOAuthGrant(id: String) async throws {
    actions.append("oauth-revoke:\(id)")
    if failWrite { throw AppControlPlaneError.unavailable("Write unavailable") }
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
