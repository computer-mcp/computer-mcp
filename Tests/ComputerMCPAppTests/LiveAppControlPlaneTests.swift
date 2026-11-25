import AppKit
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPTransport
import ComputerMCPTunnels
import Darwin
import Foundation
import GRDB
import SwiftUI
import Testing
import Vision

@testable import ComputerMCPApp
@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPPlugins

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@MainActor
@Suite(.serialized)
final class LiveAppControlPlaneTests {
  @Test
  func tunnelEditorPassesItsOpenedDigestThroughToTheControlPlane() async throws {
    try await withAppControlPlaneFixture { fixture in
      var initial = CloudflareEditorPresentation.new.draft
      initial.tunnelName = "named"
      initial.publicHostname = "gateway.example"
      initial.cloudflaredPath = "/tools/cloudflared"
      initial.tunnelToken = "synthetic-tunnel"
      initial.oauthEnabled = true
      initial.oauthClientAllowlist = ["client.example", "second.example"]
      #expect(initial.expectedTunnelDigest == nil)
      _ = try await fixture.app.saveCloudflareTunnelConfiguration(initial)

      let summary = try #require(try await fixture.app.fetchCloudflareTunnels().first)
      let profile = try #require(
        try await fixture.controlPlane.cloudflareTunnelConfigurations().first)
      #expect(try summary.configurationDigest == profile.configurationDigest)
      var draft = CloudflareEditorPresentation.edit(summary).draft
      #expect(draft.expectedTunnelDigest == summary.configurationDigest)
      #expect(draft.cloudflaredPath == initial.cloudflaredPath)
      draft.tunnelName = "first-edit"
      _ = try await fixture.app.saveCloudflareTunnelConfiguration(draft)

      let opened = try #require(try await fixture.app.fetchCloudflareTunnels().first)
      var stale = CloudflareEditorPresentation.edit(opened).draft
      var disabled = profile
      disabled.tunnelName = opened.tunnelName
      disabled.oauthEnabled = false
      _ = try await fixture.controlPlane.saveCloudflareTunnelConfiguration(
        disabled, tunnelToken: nil)
      stale.tunnelName = "unrelated-edit"
      await #expect(throws: CloudflareTunnelError.staleConfiguration(opened.id)) {
        try await fixture.app.saveCloudflareTunnelConfiguration(stale)
      }
      let current = try #require(try await fixture.app.fetchCloudflareTunnels().first)
      #expect(current.tunnelName == opened.tunnelName)
      #expect(!current.oauthEnabled)
      #expect(current.oauthClientAllowlist == opened.oauthClientAllowlist)
      #expect(current.configurationDigest != opened.configurationDigest)
    }
  }

  @Test
  func manifestEditorSavesOnlyAgainstTheManifestItOpened() async throws {
    try await withAppControlPlaneFixture { fixture in
      try await fixture.app.startApplication()
      let opened = try await fixture.app.fetchDiagnostics().manifest
      let first = opened.content + "\n# first edit\n"
      try await fixture.app.saveManifest(first, expectedDigest: opened.digest)
      await #expect(throws: (any Error).self) {
        try await fixture.app.saveManifest(
          opened.content + "\n# stale edit\n", expectedDigest: opened.digest)
      }
      let current = try await fixture.app.fetchDiagnostics().manifest
      #expect(current.content == first)
      #expect(current.digest != opened.digest)
    }
  }

  @Test
  func codexConfirmationAppliesOnlyTheReviewedPlan() async throws {
    let temporary = try ScopedTemporaryDirectory()
    let executable = temporary.url.appendingPathComponent("server")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = temporary.url.appendingPathComponent("codex")
    try FileManager.default.copyItem(at: executable, to: client)
    let runner = AppRegistrationTestRunner()
    let service = ClientRegistrationService(
      homeDirectory: temporary.url, stateDirectory: temporary.url.appendingPathComponent("state"),
      executableSearchDirectories: [temporary.url.path], environment: [:], processRunner: runner)
    let fixture = try AppControlPlaneFixture(
      registrationService: service, gatewayExecutablePath: executable.path)
    let model = ComputerMCPAppModel(controlPlane: fixture.app)
    await model.localClients.beginReview(.codex, operation: .register)
    let reviewed = try #require(model.localClients.review)
    #expect(reviewed.plan.display.state == .notRegistered)
    runner.changeEntry()
    await model.localClients.confirm(reviewed)
    #expect(
      model.localClients.outcome?.message
        == LocalClientsModel.message(for: .changedSincePreview, client: .codex))
    #expect(runner.writeCount == 0)
    await fixture.cleanup()
  }

  @Test
  func incompatibleCallerConsentCannotEnableTheShellFacility() async throws {
    try await withAppControlPlaneFixture { fixture in
      try await fixture.app.startApplication()
      try await fixture.app.startGateway()
      let client = try await GatewayClientSession.connectSocket(socketURL: fixture.socketURL)
      let snapshot = try #require(try await fixture.app.fetchClientAccess().sessions.first)
      #expect(snapshot.profile?.grant.allowedCallers.contains(snapshot.caller) == false)
      let before = try await fixture.controlPlane.activeConfiguration()
      #expect(!before.policy.shellEnabled)
      await #expect(throws: (any Error).self) {
        try await fixture.app.grantClientFullAccess(
          id: snapshot.id, lifetime: .thisSession, expectedRevision: snapshot.revision,
          expectedTrustRevision: 0)
      }
      #expect(try await fixture.controlPlane.activeConfiguration() == before)
      #expect(try await fixture.app.fetchClientAccess().sessions.first?.fullAccessConsent == nil)
      await client.disconnect()
    }
  }

  @Test
  func ownerPresentationControlsTheConnectedSessionAndSeparatePersistentTrust() async throws {
    try await withAppControlPlaneFixture { fixture in
      let configuration = GatewayConfiguration(
        policy: .init(shellEnabled: true),
        profiles: [
          .init(
            id: .chatGPTOperate, permissions: appPermissions([.project("*"): .granted(.read)]),
            fullAccess: true, allowedCallers: [.localMCP])
        ], projectDirectory: fixture.root)
      _ = try await fixture.controlPlane.activateManifest(
        configuration.exportedTOML(),
        expectedDigest: try? await fixture.controlPlane.configurationDigest())
      try await fixture.controlPlane.setActiveGatewayProfile(.chatGPTOperate)
      try await fixture.app.startApplication()
      try await fixture.app.registerProject(at: fixture.root)
      let projectID = try #require(try await fixture.controlPlane.database.projects().first?.id)
      try await fixture.app.startGateway()
      var client = try await GatewayClientSession.connectSocket(socketURL: fixture.socketURL)
      do {
        let initial = try #require(try await fixture.app.fetchClientAccess().sessions.first)
        #expect(initial.fullAccessConsent == nil)
        try await fixture.app.grantClientFullAccess(
          id: initial.id, lifetime: .thisSession, expectedRevision: initial.revision,
          expectedTrustRevision: 0)
        #expect(try await client.listToolNames().contains("shell.run"))
        let approved = try #require(try await fixture.app.fetchClientAccess().sessions.first)
        try await fixture.app.limitClientAccess(
          id: approved.id, limits: ManagedPolicy(allowsFullAccess: false),
          expectedRevision: approved.revision)
        try await expectRequestableShellRefusal(client, projectID: projectID)
        let limited = try #require(try await fixture.app.fetchClientAccess().sessions.first)
        #expect(limited.fullAccessConsent == nil)
        #expect(!limited.accessLimit.allowsFullAccess)
        await #expect(throws: (any Error).self) {
          try await fixture.app.grantClientFullAccess(
            id: limited.id, lifetime: .alwaysAllowClient, expectedRevision: limited.revision,
            expectedTrustRevision: 0)
        }
        await client.disconnect()
        client = try await GatewayClientSession.connectSocket(socketURL: fixture.socketURL)
        let fresh = try #require(try await fixture.app.fetchClientAccess().sessions.first)
        try await fixture.app.grantClientFullAccess(
          id: fresh.id, lifetime: .alwaysAllowClient, expectedRevision: fresh.revision,
          expectedTrustRevision: 0)
        let trusted = try await fixture.app.fetchClientAccess()
        let trust = try #require(trusted.trusts.first)
        #expect(trust.fullAccessAllowed)
        #expect(try await client.listToolNames().contains("shell.run"))
        try await fixture.app.revokeClientTrust(id: trust.id, expectedRevision: trust.revision)
        try await expectRequestableShellRefusal(client, projectID: projectID)
        let afterRevocation = try await fixture.app.fetchClientAccess()
        let revoked = try #require(afterRevocation.sessions.first)
        let revokedTrust = try #require(afterRevocation.trusts.first { $0.id == trust.id })
        #expect(revoked.fullAccessConsent == nil)
        #expect(!revokedTrust.fullAccessAllowed && revokedTrust.revision > trust.revision)
        try await fixture.app.endClientAccess(id: revoked.id, expectedRevision: revoked.revision)
        #expect(try await client.listToolNames().isEmpty)
        await client.disconnect()
      } catch {
        await client.disconnect()
        throw error
      }
    }
  }

  @Test(.nativeIntegration, arguments: [false, true])
  func applicationStopJoinsInFlightOwnerWorkWithEitherGatewayState(gatewayRunning: Bool)
    async throws
  {
    let observed = AppOwnerHelperObservation()
    let bootstrap = try nativeGatewayTestExecutable().deletingLastPathComponent()
      .appendingPathComponent("computer-mcp-execution-bootstrap")
    let launcher: (AppControlPlaneServiceDirectories) -> ExecutionLauncher = { directories in
      ExecutionLauncher(
        platform: AppOwnerHelperExecutionPlatform(
          directory: directories.database.deletingLastPathComponent().appendingPathComponent(
            directories.database.lastPathComponent + ".executions", isDirectory: true),
          bootstrap: bootstrap, observation: observed))
    }
    try await withAppControlPlaneFixture(executionLauncher: launcher) { fixture in
      let configuration = GatewayConfiguration(
        profiles: [
          .init(
            id: .localAdmin,
            permissions: appPermissions([.machineInformation: .granted(.access)]),
            allowedCallers: [.localCLI])
        ], builtin: .init(enabled: ["system.software"]), projectDirectory: fixture.root)
      _ = try await fixture.controlPlane.activateManifest(
        configuration.exportedTOML(),
        expectedDigest: try? await fixture.controlPlane.configurationDigest())
      try await fixture.controlPlane.setGatewayDesiredRunning(gatewayRunning)
      try await fixture.app.startApplication()
      #expect(
        await fixture.gatewayService.snapshot().state == (gatewayRunning ? .running : .stopped))
      let client = AppControlPlaneServiceClient(
        socketURL: fixture.controlSocket.socketConfiguration.socketURL)
      let events = observed.changed.stream()
      let calling = Task {
        defer { observed.completed() }
        return try await client.call(
          "tools.call",
          arguments: .object([
            "name": .string("system.software"),
            "arguments": .object(["timeout_ms": .number(60_000)]),
          ]))
      }
      do {
        var changes = events.makeAsyncIterator()
        _ = await changes.next()
        let earlyCompletion: String
        if observed.processID == nil {
          switch await calling.result {
          case .success(let result): earlyCompletion = "Returned \(result)"
          case .failure(let error): earlyCompletion = "Threw \(String(reflecting: error))"
          }
        } else {
          earlyCompletion = "The call is still in flight."
        }
        let pid = try #require(
          observed.processID,
          "The admitted read-only helper must start. \(earlyCompletion)")
        #expect(kill(pid, 0) == 0)
        #expect(!observed.callCompleted)
        let stoppingStartedAt = ContinuousClock.now
        await fixture.app.stopApplication()
        #expect(
          stoppingStartedAt.duration(to: .now) < .seconds(10),
          "App shutdown must terminate the helper before its 30-second natural exit")
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        _ = await calling.result
        #expect(observed.callCompleted)
        #expect(await fixture.controlSocket.snapshot().state == .stopped)
        #expect(await fixture.gatewayService.snapshot().state == .stopped)
      } catch {
        await fixture.app.stopApplication()
        calling.cancel()
        _ = await calling.result
        throw error
      }
    }
  }

  @Test
  func localMCPConnectionTargetsTheOwningAppInstance() async throws {
    try await withAppControlPlaneFixture { fixture in
      let connection = try await fixture.app.localMCPConnection()
      #expect(connection.command == fixture.controlPlane.gatewayExecutablePath)
      #expect(
        connection.arguments == [
          "bridge", "--client-identity", "local-mcp", "--socket", fixture.socketURL.path,
        ])
    }
  }

  @Test
  func projectHealthChecksBookmarkAccessAndMissingFolders() async throws {
    try await withAppControlPlaneFixture { fixture in
      let database = await fixture.controlPlane.database
      let availableRoot = fixture.root.appendingPathComponent("available")
      let badBookmarkRoot = fixture.root.appendingPathComponent("bad-bookmark")
      for directory in [availableRoot, badBookmarkRoot] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      try database.saveProject(
        ComputerMCPCore.RegisteredProject(
          id: "available", displayName: "Available", rootPath: availableRoot.path))
      try database.saveProject(
        ComputerMCPCore.RegisteredProject(
          id: "missing", displayName: "Missing",
          rootPath: fixture.root.appendingPathComponent("missing").path))
      try database.saveProject(
        ComputerMCPCore.RegisteredProject(
          id: "bad-bookmark", displayName: "Bad bookmark", rootPath: badBookmarkRoot.path,
          bookmarkData: Data("invalid-bookmark".utf8)))
      let reports = try await fixture.app.fetchProjects()
      let available = try #require(reports.first { $0.id == "available" })
      let missing = try #require(reports.first { $0.id == "missing" })
      let badBookmark = try #require(reports.first { $0.id == "bad-bookmark" })
      #expect(available.health == .available)
      #expect(available.lastResolvedAt != nil)
      #expect(available.healthDetail == nil)
      #expect(missing.health == .missing)
      #expect(missing.lastResolvedAt == nil)
      #expect(missing.healthDetail != nil)
      #expect(badBookmark.health == .unavailable)
      #expect(badBookmark.lastResolvedAt == nil)
      #expect(badBookmark.healthDetail != nil)
    }
  }

  @Test
  func testPermissionRequestUsesInjectedLocalRequester() async throws {
    let requester = AppTestPermissionRequester(
      outcome: PermissionRequestOutcome(
        permissionID: "screen-recording",
        state: .notGranted,
        systemPromptRequested: true
      )
    )
    try await withAppControlPlaneFixture(permissionRequester: requester) { fixture in
      let outcome = try await fixture.app.requestPermission(id: "screen-recording")

      #expect((outcome.permissionID) == ("screen-recording"))
      #expect((outcome.state) == (.notGranted))
      #expect(outcome.systemPromptRequested)
      #expect((requester.requestedIDs) == (["screen-recording"]))
    }
  }

  @Test
  func testPermissionLinksTargetCurrentPrivacySettingsExtension() async throws {
    try await withAppControlPlaneFixture { fixture in
      let permissions = try await fixture.app.fetchPermissions()
      let links = Dictionary(
        uniqueKeysWithValues: permissions.compactMap { permission in
          permission.settingsURL.map { (permission.id, $0.absoluteString) }
        }
      )

      #expect(
        links["accessibility"]
          == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
      )
      #expect(
        links["screen-recording"]
          == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
      )
    }
  }

  @Test
  func testPermissionRequesterRejectsUnknownPermission() {
    expectThrows(
      try MacOSSystemPermissionRequester().requestPermission(id: "camera")
    ) { error in
      #expect((error.localizedDescription) == ("Unknown macOS permission: camera"))
    }
  }

  @Test
  func h12PrivacyProjectsAndEditsDirectProviderAuthority() async throws {
    try await withAppControlPlaneFixture { fixture in
      let host = fixture.controlPlane
      var configuration = try await host.activeConfiguration()
      configuration.mcp.servers.append(
        .init(id: "local-fixture", transport: .stdio, command: "/usr/bin/true"))
      _ = try await host.activateManifest(
        configuration.exportedTOML(), expectedDigest: host.configurationDigest())

      let service = LivePrivacySecurityService(controlPlane: fixture.app)
      let principalID = "server/local-fixture"
      let initial = try await service.privacySnapshot()
      let review = try #require(initial.reviewedProviders[principalID])
      #expect(review.availability == .needsApproval)
      #expect(review.effectiveMode == nil)
      #expect(initial.principals.contains { $0.id == principalID && $0.kind == .localServer })
      #expect(initial.principals.contains { $0.id == GatewayProfileID.localAdmin.rawValue })

      var selection = Permissions()
      try selection.set(.granted(.access), for: .screen)
      try await service.approveProvider(
        review, permissions: selection, execution: .sandbox, sandboxSettings: .init())
      let approved = try await service.privacySnapshot()
      let provider = try #require(approved.reviewedProviders[principalID])
      #expect(provider.availability == .active)
      #expect(provider.effectiveMode == .sandbox)
      #expect(approved.reviewedProfiles == initial.reviewedProfiles)

      var screen = try #require(
        approved.grants.first {
          $0.principalID == principalID && $0.permission == .screen
        })
      #expect(screen.value == .granted(.allow))
      #expect(screen.effectiveValue == .granted(.allow))
      fixture.policyReader.set(
        .machineFile, .available(Data("[permissions]\nscreen = 'deny'".utf8)))
      let restricted = try await service.privacySnapshot()
      let restrictedScreen = try #require(
        restricted.grants.first {
          $0.principalID == principalID && $0.permission == .screen
        })
      #expect(restrictedScreen.value == .granted(.allow))
      #expect(restrictedScreen.effectiveValue == .denied)
      #expect(
        restrictedScreen.limitNotices == [.init(source: "Machine Policy", effect: .permission(nil))]
      )

      screen.value = .denied
      await #expect(throws: AppControlPlaneError.self) {
        try await service.setGrant(screen, reviewed: approved)
      }
      try await service.setGrant(screen, reviewed: restricted)
      await #expect(throws: AppControlPlaneError.self) {
        try await service.revokeAll(principalID: principalID, reviewed: approved)
      }
      let edited = try await service.privacySnapshot()
      #expect(
        edited.reviewedProviders[principalID]?.approval?.permissions.state(for: .screen) == .denied)
      #expect(edited.reviewedProfiles == initial.reviewedProfiles)

      try await service.revokeAll(principalID: principalID, reviewed: edited)
      let revoked = try await service.privacySnapshot()
      #expect(revoked.reviewedProviders[principalID]?.availability == .disabled)
      #expect(revoked.reviewedProviders[principalID]?.effectiveMode == nil)
      #expect(
        revoked.grants.first {
          $0.principalID == principalID && $0.permission == .screen
        }?.effectiveValue == nil)

      configuration.mcp.servers.removeAll { $0.id == "local-fixture" }
      _ = try await host.activateManifest(
        configuration.exportedTOML(), expectedDigest: host.configurationDigest())
      let unavailable = try await service.privacySnapshot()
      #expect(unavailable.reviewedProviders[principalID]?.availability == .unavailable)
      #expect(unavailable.reviewedProviders[principalID]?.approval != nil)
    }
  }

  @Test
  func h12RestoredProviderAuthorityRequiresAnExplicitReview() async throws {
    try await withAppControlPlaneFixture { fixture in
      let host = fixture.controlPlane
      var configuration = try await host.activeConfiguration()
      configuration.mcp.servers.append(
        .init(id: "restore-fixture", transport: .stdio, command: "/usr/bin/true"))
      _ = try await host.activateManifest(
        configuration.exportedTOML(), expectedDigest: host.configurationDigest())
      let service = LivePrivacySecurityService(controlPlane: fixture.app)
      let principalID = "server/restore-fixture"
      let initial = try await service.privacySnapshot()
      try await service.approveProvider(
        #require(initial.reviewedProviders[principalID]), permissions: .init(),
        execution: .fullAccessAllowed, sandboxSettings: .init())
      let before = try await service.privacySnapshot()
      #expect(before.reviewedProviders[principalID]?.effectiveMode == .fullAccess(.standing))

      fixture.policyReader.set(.machineFile, .available(Data("full_access = false".utf8)))
      let restricted = try await service.privacySnapshot()
      let principal = try #require(restricted.principals.first { $0.id == principalID })
      #expect(principal.execution == .fullAccessAllowed)
      #expect(principal.effectiveExecution == nil)
      #expect(principal.fullAccessLimitSources == ["Machine Policy"])

      fixture.counter.forget()
      let restored = try await service.privacySnapshot()
      #expect(restored.epoch != before.epoch)
      #expect(restored.reviewedProviders[principalID]?.availability == .needsRestoreReview)
      #expect(restored.reviewedProviders[principalID]?.approval?.epoch == before.epoch)
      #expect(restored.reviewedProviders[principalID]?.effectiveMode == nil)
      await #expect(throws: AppControlPlaneError.self) {
        try await service.revokeAll(principalID: principalID, reviewed: before)
      }
    }
  }

  @Test
  func h12VerifiedClientsKeepSharedProfileAndEffectiveAvailability() async throws {
    try await withAppControlPlaneFixture { fixture in
      let host = fixture.controlPlane
      let database = await host.database
      let permissionService = try database.permissionRuntime(platform: host.platform).service
      let service = LivePrivacySecurityService(controlPlane: fixture.app)
      fixture.policyReader.set(
        .machineFile, .available(Data("[permissions]\nscreen = 'deny'".utf8)))
      let profileID = GatewayProfileID.chatGPTOperate
      for identity in ["first-client", "second-client"] {
        let subject = try GatewayPermissionSubject(
          context: .init(caller: .secureTunnel, profileID: profileID, trustedPrincipalID: identity))
        let decision = try permissionService.admit(
          subject: subject, tool: "screen.capture", projectID: nil, argumentsDigest: identity,
          requirements: .init(actions: [.init(requirement: try .init(.screen, .access))]))
        #expect(decision == .denied(.managedLimit([.machine])))
      }

      let reviewed = try await service.privacySnapshot()
      let clients = reviewed.principals.filter { $0.sharedProfileID == profileID }
      #expect(Set(clients.map(\.id)).count == 2)
      #expect(clients.allSatisfy { $0.clientAvailability == .available })
      #expect(
        clients.allSatisfy {
          reviewed.clientSubjects[$0.id]?.limits.sources[.machine] != nil
        })
      let clientIDs = Set(clients.map(\.id))
      let screen = reviewed.grants.filter {
        clientIDs.contains($0.principalID) && $0.permission == .screen
      }
      #expect(screen.count == 2)
      #expect(screen.allSatisfy { $0.value == .ask && $0.effectiveValue == .denied })
      await #expect(throws: AppControlPlaneError.self) {
        try await service.setGrant(#require(screen.first), reviewed: reviewed)
      }

      fixture.counter.forget()
      let restored = try await service.privacySnapshot()
      let suspended = restored.principals.filter { $0.sharedProfileID == profileID }
      #expect(suspended.count == 2)
      #expect(suspended.allSatisfy { $0.clientAvailability == .restoreReview })
      #expect(
        restored.grants.filter { clientIDs.contains($0.principalID) }.allSatisfy {
          $0.effectiveValue == nil && $0.effectiveNetwork == nil
        })
    }
  }

  @Test
  func privacyConfirmationIncludesUnadoptedProfilesWithoutGlobalSuspension() async throws {
    try await withAppControlPlaneFixture { fixture in
      try await fixture.controlPlane.database.connection.writer.write { database in
        try database.execute(sql: "UPDATE permissionProfiles SET authorityEpoch = NULL")
      }
      let view = try await fixture.app.fetchPermissionRequests()
      #expect(!view.suspended)
      #expect(!view.unconfirmedProfileIDs.isEmpty)
      let model = PrivacySecurityModel(
        service: LivePrivacySecurityService(controlPlane: fixture.app))
      await model.refresh()
      #expect(model.snapshot.suspendedForReview)
      await model.confirmRestoredPermissions()
      #expect(model.failure == nil)
      #expect(!model.snapshot.suspendedForReview)
      #expect(try await fixture.app.fetchPermissionRequests().unconfirmedProfileIDs.isEmpty)
    }
  }

  @Test
  func privacyNetworkEditsPersistAndSystemSettingsUseTheReadSummary() async throws {
    try await withAppControlPlaneFixture { fixture in
      let service = LivePrivacySecurityService(controlPlane: fixture.app)
      let model = PrivacySecurityModel(service: service)
      await model.refresh()
      var requested: PermissionSummary?
      service.requestPermission = { requested = $0 }
      service.openSystemSettings(for: .accessibility)
      #expect(requested?.id == "accessibility")
      #expect(requested?.settingsURL != nil)
      let grant = PrivacyGrant(
        principalID: GatewayProfileID.chatGPTOperate.rawValue, permission: .projects,
        object: .init(id: "*", name: "All Projects", detail: nil), value: .granted(.read))
      let before = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
      #expect(
        await model.setNetwork(
          grant,
          to: .custom(
            hosts: ["API.Example.COM", "*.example.org"], includesTrusted: true)))
      let after = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
      #expect(
        after.grant.projectNetworks["*"]?.configuration
          == .custom(
            hosts: ["api.example.com", "*.example.org"], includesTrusted: true))
      #expect(after.permissionRevision > before.permissionRevision)
      #expect(after.grant.permissions == before.grant.permissions)
      #expect(after.grant.allowedCallers == before.grant.allowedCallers)
      #expect(after.grant.fullAccess == before.grant.fullAccess)
      #expect(
        !(await model.setNetwork(
          grant,
          to: .custom(
            hosts: ["https://invalid.example/path"], includesTrusted: false))))
      let unchanged = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
      #expect(unchanged.permissionRevision == after.permissionRevision)
    }
  }

  @Test
  func privacyEditsRefuseChangesSinceTheOwnerReadTheSnapshot() async throws {
    try await withAppControlPlaneFixture { fixture in
      let model = PrivacySecurityModel(
        service: LivePrivacySecurityService(controlPlane: fixture.app))
      await model.refresh()
      let grant = try #require(
        model.snapshot.grants.first {
          $0.principalID == GatewayProfileID.chatGPTOperate.rawValue && $0.permission == .screen
        })
      let original = model.snapshot.revision
      let options = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
      var changed = options.grant
      try changed.permissions.set(.denied, for: .screen)
      try await fixture.app.saveProfilePermissions(changed, reviewed: options)
      await model.set(grant, to: .granted(.allow))
      #expect(
        model.failure
          == AppLocalization.string(
            "The permissions changed while you were editing. Review them and try again."))
      #expect(model.snapshot.revision > original)
      let saved = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
      #expect(saved.grant.permissions.state(for: .screen) == .denied)
    }
  }

  @Test
  func privacyEditAlsoChecksTheReviewedProfileRevision() async throws {
    try await withAppControlPlaneFixture { fixture in
      let service = LivePrivacySecurityService(controlPlane: fixture.app)
      var reviewed = try await service.privacySnapshot()
      let grant = try #require(
        reviewed.grants.first {
          $0.principalID == GatewayProfileID.chatGPTOperate.rawValue && $0.permission == .screen
        })
      let index = try #require(
        reviewed.reviewedProfiles.firstIndex { $0.id.rawValue == grant.principalID })
      reviewed.reviewedProfiles[index].authorizationRevision = -1
      do {
        try await service.setGrant(grant, reviewed: reviewed)
        Issue.record("The profile revision must match the reviewed snapshot")
      } catch {
        #expect(
          error.localizedDescription
            == LivePrivacySecurityService.changedPermissions().localizedDescription)
      }
      #expect(try await service.privacySnapshot().revision == reviewed.revision)
    }
  }

  @Test
  func privacyNetworkSheetKeepsItsOpeningRevisionAcrossPolling() async throws {
    try await withAppControlPlaneFixture { fixture in
      let model = PrivacySecurityModel(
        service: LivePrivacySecurityService(controlPlane: fixture.app))
      await model.refresh()
      let grant = try #require(
        model.snapshot.grants.first {
          $0.principalID == GatewayProfileID.chatGPTOperate.rawValue && $0.permission == .projects
        })
      let edit = PrivacyNetworkEdit(grant: grant, snapshot: model.snapshot)
      let options = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
      var changed = options.grant
      changed.projectNetworks[grant.object!.id] = .trusted
      try await fixture.app.saveProfilePermissions(changed, reviewed: options)
      await model.refresh()
      #expect(!(await model.setNetwork(edit.grant, to: .full, reviewed: edit.snapshot)))
      #expect(model.failure != nil)
      let saved = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
      #expect(saved.grant.projectNetworks[grant.object!.id]?.configuration == .trusted)
    }
  }

  @Test
  func privacyRestorationCannotConfirmAViewReplacedByPolling() async throws {
    try await withAppControlPlaneFixture { fixture in
      let service = LivePrivacySecurityService(controlPlane: fixture.app)
      let reviewed = try await service.privacySnapshot()
      let options = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
      var changed = options.grant
      try changed.permissions.set(.denied, for: .screen)
      try await fixture.app.saveProfilePermissions(changed, reviewed: options)
      try await fixture.controlPlane.database.connection.writer.write { database in
        try database.execute(sql: "UPDATE permissionProfiles SET authorityEpoch = NULL")
      }
      let polled = try await service.privacySnapshot()
      #expect(polled.revision != reviewed.revision)
      do {
        try await service.confirmRestoredPermissions(reviewed: reviewed)
        Issue.record("A replaced permission view must not be confirmed")
      } catch {
        #expect(
          error.localizedDescription
            == LivePrivacySecurityService.changedPermissions().localizedDescription)
      }
      #expect(try await service.privacySnapshot().suspendedForReview)
    }
  }

  @Test
  func privacyRestorationRejectsANewEpochAtTheSameControlRevision() async throws {
    try await withAppControlPlaneFixture { fixture in
      let service = LivePrivacySecurityService(controlPlane: fixture.app)
      fixture.counter.forget()
      let reviewed = try await service.privacySnapshot()
      #expect(reviewed.suspendedForReview)
      fixture.counter.forget()
      let polled = try await service.privacySnapshot()
      #expect(polled.epoch != reviewed.epoch)
      #expect(polled.revision == reviewed.revision)
      #expect(polled.reviewedProfiles == reviewed.reviewedProfiles)
      do {
        try await service.confirmRestoredPermissions(reviewed: reviewed)
        Issue.record(
          "The owner must review the new epoch even if the control revision is unchanged")
      } catch {
        #expect(
          error.localizedDescription
            == LivePrivacySecurityService.changedPermissions().localizedDescription)
      }
      #expect(try await service.privacySnapshot().suspendedForReview)
    }
  }

  @Test
  func privacyUnboundProfilesUseGatewayPolicyLimitsAndKeepSavedGrants() async throws {
    try await withAppControlPlaneFixture { fixture in
      let options = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
      var saved = options.grant
      try saved.permissions.set(.granted(.access), for: .screen)
      try await fixture.app.saveProfilePermissions(saved, reviewed: options)
      fixture.policyReader.set(
        .machineFile,
        .available(Data("remote_full_access = false\n[permissions]\nscreen = 'deny'".utf8)))
      let view = try await fixture.app.fetchPermissionRequests()
      #expect(view.subjects.isEmpty)
      let snapshot = try await LivePrivacySecurityService(controlPlane: fixture.app)
        .privacySnapshot()
      let profile = try #require(view.profiles.first { $0.id == .chatGPTOperate })
      let row = try #require(
        snapshot.grants.first { $0.principalID == profile.id.rawValue && $0.permission == .screen })
      #expect(row.availableLevels.isEmpty)
      #expect(row.limitNotices == [.init(source: "Machine Policy", effect: .permission(nil))])
      #expect(row.value == .granted(.allow))
      #expect(profile.permissions.state(for: .screen) == .granted(.access))
      #expect(
        snapshot.principals.first { $0.id == profile.id.rawValue }?.fullAccessLimitSources == [
          "Machine Policy"
        ])
    }
  }

  @Test
  func privacyFullAccessFlagRepresentsEligibilityWithoutConnectionConsent() async throws {
    try await withAppControlPlaneFixture { fixture in
      let model = PrivacySecurityModel(
        service: LivePrivacySecurityService(controlPlane: fixture.app))
      await model.refresh()
      let principal = try #require(model.principal(GatewayProfileID.chatGPTOperate.rawValue))
      await model.setExecution(principal, .fullAccessAllowed)
      #expect(model.failure == nil)
      #expect(model.principal(principal.id)?.execution == .fullAccessAllowed)
      let current = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
      #expect(current.grant.fullAccess)
      let connections = try await fixture.app.fetchClientAccess()
      #expect(connections.sessions.allSatisfy { $0.fullAccessConsent == nil })
      #expect(connections.trusts.isEmpty)
    }
  }

  @Test
  func privacyRevokeKeepsTheCatalogAndWritesOnlyTheSelectedEntry() async throws {
    try await withAppControlPlaneFixture { fixture in
      let model = PrivacySecurityModel(
        service: LivePrivacySecurityService(controlPlane: fixture.app))
      await model.refresh()
      let principal = try #require(model.principal(GatewayProfileID.chatGPTOperate.rawValue))
      let rowIDs = Set(model.grants(for: principal).map(\.id))
      await model.revokeAll(principal)
      let rows = model.grants(for: principal)
      #expect(Set(rows.map(\.id)) == rowIDs)
      #expect(rows.allSatisfy { $0.value == .ask && !$0.isStored })
      #expect(model.grants(for: .screen).allSatisfy { $0.principalID != principal.id })
      let screen = try #require(rows.first { $0.permission == .screen })
      await model.set(screen, to: .granted(.allow))
      #expect(model.failure == nil)
      let saved = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
      #expect(saved.grant.permissions.entries.count == 1)
      #expect(saved.grant.permissions.state(for: .screen) == .granted(.access))
    }
  }

  @Test(arguments: [PrivacyPermissionKind.projects, .plugins, .mcpServers])
  func privacyChoosingInheritanceRemovesOnlyTheExplicitEntry(kind: PrivacyPermissionKind)
    async throws
  {
    try await withAppControlPlaneFixture { fixture in
      let options = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
      var profile = options.grant
      let fallback: Permission
      let concrete: Permission
      let value: PermissionValue
      switch kind {
      case .projects:
        (fallback, concrete, value) = (.project("*"), .project("inherit-target"), .read)
      case .plugins: (fallback, concrete, value) = (.plugin("*"), .plugin("inherit-target"), .use)
      default: (fallback, concrete, value) = (.mcpServer("*"), .mcpServer("inherit-target"), .all)
      }
      try profile.permissions.set(.granted(value), for: fallback)
      try profile.permissions.set(.denied, for: concrete)
      profile.projectNetworks["inherit-target"] = .full
      try await fixture.app.saveProfilePermissions(profile, reviewed: options)
      let model = PrivacySecurityModel(
        service: LivePrivacySecurityService(controlPlane: fixture.app))
      await model.refresh()
      let row = try #require(
        model.snapshot.grants.first {
          $0.principalID == profile.id.rawValue && $0.permission == kind
            && $0.object?.id == "inherit-target"
        })
      #expect(row.choice == .explicit(.denied))
      await model.set(row, choice: .inherited)
      #expect(model.failure == nil)
      let saved = try await fixture.app.fetchProfilePermissionOptions(id: profile.id)
      var expected = profile.permissions
      expected.removeEntry(for: concrete)
      #expect(saved.grant.permissions.entries == expected.entries)
      #expect(saved.grant.permissions.state(for: concrete) == .granted(value))
      #expect(saved.grant.projectNetworks == profile.projectNetworks)
      #expect(saved.grant.allowedCallers == profile.allowedCallers)
      #expect(saved.grant.fullAccess == profile.fullAccess)
      await model.set(row, to: .ask)
      #expect(model.failure == nil)
      let overridden = try await fixture.app.fetchProfilePermissionOptions(id: profile.id)
      try expected.set(.notGranted, for: concrete)
      #expect(overridden.grant.permissions.entries == expected.entries)
      #expect(overridden.grant.permissions.state(for: concrete) == .notGranted)
      #expect(overridden.grant.projectNetworks == profile.projectNetworks)
    }
  }

  @Test
  func profilePermissionsRoundTripWithoutRestartingTheGateway() async throws {
    try await withAppControlPlaneFixture { fixture in
      try await fixture.app.startApplication()
      let original = await fixture.gatewayService.snapshot()
      let profile = try #require(
        try await fixture.app.fetchProfiles().first { $0.id == "chatgpt-operate" })
      var grant = profile.permissions
      grant.fullAccess = false
      try grant.permissions.set(.denied, for: .screen)
      grant.allowedCallers = [.localMCP]
      let options = try await fixture.app.fetchProfilePermissionOptions(id: grant.id)
      try await fixture.app.saveProfilePermissions(grant, reviewed: options)
      let updated = try #require(
        try await fixture.app.fetchProfiles().first { $0.id == profile.id })
      #expect(!updated.permissions.fullAccess)
      #expect(updated.permissions.permissions.state(for: .screen) == .denied)
      #expect(updated.permissions.allowedCallers == [.localMCP])
      #expect(updated.permissions.authorizationRevision > grant.authorizationRevision)
      let current = await fixture.gatewayService.snapshot()
      #expect(current.state == .running)
      #expect(current.startedAt == original.startedAt)
    }
  }

  @Test
  func restrictedSelectionRequiresDeliberateCallerAdmissionAndUpdatesTheSameConnection()
    async throws
  {
    try await withAppControlPlaneFixture { fixture in
      let configuration = GatewayConfiguration(
        runtime: .init(caller: .localMCP, profileID: .chatGPTOperate),
        profiles: [
          .init(
            id: .chatGPTOperate,
            permissions: appPermissions([
              .machineInformation: .granted(.access), .project("project"): .granted(.read),
            ]),
            allowedCallers: [.secureTunnel])
        ], builtin: .init(enabled: ["system.time", "file.read", "file.write"]),
        projectDirectory: fixture.root)
      _ = try await fixture.controlPlane.activateManifest(
        configuration.exportedTOML(),
        expectedDigest: try? await fixture.controlPlane.configurationDigest())
      try await fixture.controlPlane.database.saveProject(
        .init(id: "project", displayName: "My Project", rootPath: fixture.root.path))
      try await fixture.controlPlane.setActiveGatewayProfile(.chatGPTOperate)
      try await fixture.app.startApplication()
      let started = await fixture.gatewayService.snapshot().startedAt
      let client = try await GatewayClientSession.connectSocket(socketURL: fixture.socketURL)
      do {
        #expect(try await client.listToolNames().isEmpty)
        let first = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
        var grant = first.grant
        try grant.permissions.set(.granted(.read), for: .project("project"))
        try await fixture.app.saveProfilePermissions(grant, reviewed: first)
        #expect(try await client.listToolNames().isEmpty)
        let reviewed = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTOperate)
        grant = reviewed.grant
        grant.allowedCallers.insert(.localMCP)
        try await fixture.app.saveProfilePermissions(grant, reviewed: reviewed)
        let tools = try await client.listToolNames()
        #expect(tools.contains("system.time") && tools.contains("file.read"))
        #expect(tools.contains("file.write") && !tools.contains("shell.run"))
        let write = try #require(try await client.listTools().first { $0.name == "file.write" })
        #expect(write.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"] != nil)
        let target = fixture.root.appendingPathComponent("blocked.txt")
        let refused = try await client.call(
          toolName: "file.write",
          arguments: .object([
            "project_id": .string("project"), "path": .string("blocked.txt"),
            "content": .string("requires-write-authority"),
          ]))
        #expect(refused.result.objectValue?["isError"] == .bool(true))
        #expect(
          refused.result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?[
            "code"] == .string("permission.denied"))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(
          try await client.call(toolName: "system.time").result.objectValue?["isError"]
            != .bool(true))
        #expect(await fixture.gatewayService.snapshot().startedAt == started)
        #expect(try await fixture.app.fetchClientAccess().sessions.first?.fullAccessConsent == nil)
        #expect(try await fixture.app.fetchClientAccess().trusts.isEmpty)
        await client.disconnect()
      } catch {
        await client.disconnect()
        throw error
      }
    }
  }

  @Test
  func projectWildcardShowsEffectiveAccessAndExplicitChoices() async throws {
    try await withAppControlPlaneFixture { fixture in
      let database = await fixture.controlPlane.database
      for (id, name) in [("one", "One"), ("two", "Two")] {
        let root = fixture.root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try database.saveProject(.init(id: id, displayName: name, rootPath: root.path))
      }
      let options = try await fixture.app.fetchProfilePermissionOptions(id: .chatGPTObserve)
      var grant = options.grant
      try grant.permissions.set(.granted(.read), for: .project("*"))
      try await fixture.app.saveProfilePermissions(grant, reviewed: options)
      let before = try await fixture.app.fetchProjects()
      #expect(before.allSatisfy { $0.access == .ask && $0.effectiveAccess == .read })
      let reviewed = try #require(before.first { $0.id == "one" })
      try await fixture.app.setProjectAccess(
        .deny, projectID: "one", profileID: GatewayProfileID.chatGPTObserve.rawValue,
        expectedProfileRevision: reviewed.profileRevision,
        expectedPermissionRevision: reviewed.permissionRevision)
      let after = try await fixture.app.fetchProjects()
      #expect(after.first { $0.id == "one" }?.access == .deny)
      #expect(after.first { $0.id == "one" }?.effectiveAccess == .deny)
      #expect(after.first { $0.id == "two" }?.effectiveAccess == .read)
      let names = try await fixture.app.fetchPermissionObjectNames()
      #expect(names.projects["one"] == "One")
    }
  }

  @Test
  func h16RecoverySettingsUseLiveWorktreeAndRecoveryOperations() async throws {
    let interruption = H16ReleaseInterruption()
    try await withAppControlPlaneFixture(recoveryWillSync: interruption.check) { fixture in
      let root = fixture.root.resolvingSymlinksInPath()
      let source = root.appendingPathComponent("Disposable Project")
      let foreign = root.appendingPathComponent("Foreign Checkout")
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
      try h16Git(["init", "-b", "main"], in: source, home: root)
      try Data("fixture\n".utf8).write(to: source.appendingPathComponent("file.txt"))
      try h16Git(["add", "file.txt"], in: source, home: root)
      try h16Git(["commit", "-m", "Base"], in: source, home: root)
      try h16Git(["worktree", "add", "--detach", foreign.path, "HEAD"], in: source, home: root)

      let configuration = GatewayConfiguration(
        policy: .init(shellEnabled: true),
        profiles: [
          .init(
            id: .chatGPTOperate, permissions: appPermissions([.project("*"): .granted(.write)]),
            allowedCallers: [.localMCP])
        ],
        builtin: .init(enabled: ["git.worktree_add", "git.branch_delete"]),
        projectDirectory: root)
      _ = try await fixture.controlPlane.activateManifest(
        configuration.exportedTOML(),
        expectedDigest: try await fixture.controlPlane.configurationDigest())
      try await fixture.controlPlane.setActiveGatewayProfile(.chatGPTOperate)
      try await fixture.controlPlane.database.saveProject(
        .init(id: "h16-fixture", displayName: "Disposable Project", rootPath: source.path))
      try await fixture.app.startApplication()
      let project = try #require(
        try await fixture.app.fetchProjects().first {
          $0.id == "h16-fixture"
        })
      try await fixture.app.startGateway()
      let client = try await GatewayClientSession.connectSocket(socketURL: fixture.socketURL)
      do {
        func call(_ name: String, _ arguments: [String: JSONValue]) async throws
          -> [String: JSONValue]
        {
          let result = try await client.call(toolName: name, arguments: .object(arguments))
          try #require(result.result.objectValue?["isError"] != .bool(true), "\(result.result)")
          return try #require(
            result.result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
        }

        let created = try await call(
          "git.worktree_add", ["project_id": .string(project.id), "name": .string("review")])
        let id = try #require(created["project_id"]?.stringValue)
        let path = try #require(created["path"]?.stringValue)
        let branch = try #require(created["branch"]?.stringValue)
        try #require(path.hasPrefix(root.path + "/"))
        let checkout = URL(fileURLWithPath: path)
        let baseBlob = try h16Git(["rev-parse", "HEAD:file.txt"], in: checkout, home: root)
        try h16Git(["tag", "base-blob", baseBlob], in: checkout, home: root)
        try h16Git(
          ["tag", "-a", "independent", "-m", "Retained fixture"], in: checkout, home: root)
        let tag = try h16Git(["rev-parse", "refs/tags/independent"], in: checkout, home: root)
        try h16Git(
          ["tag", "-a", "restore-review", "-m", "Separate retained fixture"],
          in: checkout, home: root)
        let restoreTag = try h16Git(
          ["rev-parse", "refs/tags/restore-review"], in: checkout, home: root)

        let appModel = ComputerMCPAppModel(
          controlPlane: fixture.app, onboardingPreferences: H16CompletedOnboarding())
        let model = appModel.worktreeRecovery
        await model.refresh()
        let inventory = try #require(
          model.projectInventory(
            id: project.id, registeredAt: project.registeredAt))
        let rows = model.worktrees(for: inventory)
        let foreignRow = try #require(rows.first { $0.path == foreign.path })
        #expect(foreignRow.state == .foreign && foreignRow.target == nil)
        let target = try #require(rows.first { $0.target?.projectID == id }?.target)
        let (clean, originalEpoch) = try #require(await model.reviewRemoval(target))
        #expect(!clean.hasUncommittedChanges)

        let staleFile = checkout.appendingPathComponent("changed-after-review")
        try Data("uncommitted".utf8).write(to: staleFile)
        await model.confirmRemoval(clean, discard: false, epoch: originalEpoch)
        #expect(model.removals.first?.outcome == .notStarted)
        #expect(model.removals.first?.issue?.key == "recovery.review_changed")
        #expect(FileManager.default.fileExists(atPath: staleFile.path))

        let marker = checkout.appendingPathComponent("writer.pid")
        _ = try await call(
          "shell.spawn",
          [
            "project_id": .string(id), "shell": .string("/bin/sh"),
            "command": .string("echo $$ > writer.pid; exec /bin/sleep 60"),
          ])
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: marker.path), .now < deadline {
          try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(
          Int32(
            String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .newlines)))
        try #require(pid > 1 && kill(pid, 0) == 0)
        let (dirty, epoch) = try #require(await model.reviewRemoval(target))
        #expect(dirty.hasUncommittedChanges)
        await model.confirmRemoval(dirty, discard: false, epoch: epoch)
        #expect(FileManager.default.fileExists(atPath: checkout.path))
        await model.confirmRemoval(dirty, discard: true, epoch: epoch)
        let removal = try #require(model.removals.first { $0.id == dirty.operationID })
        guard case .removed(let result) = removal.outcome else {
          Issue.record(
            "Removal outcome was \(String(describing: removal.outcome)); \(removal.issue?.details ?? "")"
          )
          return
        }
        #expect(result.terminationWarnings.isEmpty)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(!FileManager.default.fileExists(atPath: checkout.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        let postRemoval = try #require(
          model.projectInventory(
            id: project.id, registeredAt: project.registeredAt))
        #expect(
          model.worktrees(for: postRemoval).contains {
            $0.id == .managed(target.worktreeID) && $0.state == .removed
          })
        try await h16VerifyRecoveryRoute(appModel, project: project)

        let missing = root.appendingPathComponent("Moved Fixture Source")
        try FileManager.default.moveItem(at: source, to: missing)
        await model.refresh()
        #expect(
          model.projectInventory(id: project.id, registeredAt: project.registeredAt)?
            .isInventoryAvailable == false)
        #expect(model.stores?.first?.records.contains { $0.oid == tag } == true)
        try FileManager.default.moveItem(at: missing, to: source)
        await model.refresh()

        let store = try #require(model.stores?.first)
        let storeID = RecoveryStoreIdentity(store)
        let oldRecord = try #require(store.records.first { $0.oid == baseBlob })
        let oldChoice = RetainedRecoverySelection(store: storeID, record: oldRecord)
        let (staleRelease, staleEpoch) = try #require(await model.reviewRelease([oldChoice]))
        let deleted = try await call(
          "git.branch_delete",
          [
            "project_id": .string(project.id), "name": .string(branch),
            "dry_run": .bool(false), "confirm_delete": .bool(true),
          ])
        #expect(deleted["deleted"] == .bool(true))
        await model.confirm(.release(staleRelease), epoch: staleEpoch)
        #expect(
          model.operations.first { $0.id == staleRelease.handle.id }?.status?.outcome == .stale)
        #expect(await model.reviewRelease([oldChoice]) == nil)
        #expect(model.issue?.key == "recovery.review_changed")
        model.issue = nil

        try await fixture.app.removeProject(id: project.id)
        try FileManager.default.moveItem(at: source, to: missing)
        await model.refresh()
        let retainedStore = try #require(model.stores?.first)
        #expect(RecoveryStoreIdentity(retainedStore) == storeID)
        let tagRecord = try #require(retainedStore.records.first { $0.oid == tag })
        let choice = RetainedRecoverySelection(store: storeID, record: tagRecord)
        try await h16VerifyRecoveryRoute(appModel, project: nil)

        let (release, releaseEpoch) = try #require(await model.reviewRelease([choice]))
        let storage = try #require(await fixture.controlPlane.database.worktreeStorage)
        let anchor = storage.recovery.appendingPathComponent(
          "stores/\(storeID.key)/repository.git/refs/recovery/\(tagRecord.id.uuidString.lowercased())"
        )
        try #require(anchor.path.hasPrefix(root.path + "/"))
        try #require(FileManager.default.fileExists(atPath: anchor.path))
        interruption.arm(anchor)
        await model.confirm(.release(release), epoch: releaseEpoch)
        let retry = try #require(model.operations.first { $0.id == release.handle.id })
        #expect(interruption.fired && retry.canResume)
        #expect(retry.status?.outcome == .pending)
        await model.retry(retry)
        #expect(model.operations.first { $0.id == release.handle.id }?.status?.outcome == .released)
        #expect(model.stores?.first?.records.contains { $0.id == tagRecord.id } == false)
        #expect(!model.operations.contains { $0.review.handle.action == .maintenance })

        let (maintenance, maintenanceEpoch) = try #require(await model.prepareMaintenance(storeID))
        await model.confirm(.maintenance(maintenance), epoch: maintenanceEpoch)
        let readback = try #require(model.operations.first { $0.id == maintenance.handle.id })
        guard case .measured(let allocation) = readback.status?.outcome else {
          Issue.record(
            "Expected measured storage readback, got \(String(describing: readback.status?.outcome))."
          )
          return
        }
        #expect(allocation.reclaimedBytes == allocation.baselineBytes - allocation.finalBytes)
        #expect(readback.measuredAt != nil)

        let unaffected = try #require(model.stores?.first?.records.first { $0.oid == restoreTag })
        let restoreChoice = RetainedRecoverySelection(store: storeID, record: unaffected)
        let (beforeRestore, beforeRestoreEpoch) = try #require(
          await model.reviewRelease([restoreChoice]))
        fixture.counter.forget()
        await model.confirm(.release(beforeRestore), epoch: beforeRestoreEpoch)
        #expect(model.authorityIssue?.key == "recovery.restore_review")
        #expect(model.stores?.first?.records.contains { $0.id == unaffected.id } == true)
        await client.disconnect()
      } catch {
        await client.disconnect()
        throw error
      }
    }
  }

  @discardableResult
  private func h16Git(_ arguments: [String], in directory: URL, home: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: try testExecutable("git"))
    process.currentDirectoryURL = directory
    process.environment = [
      "HOME": home.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
    ]
    process.arguments =
      [
        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
      ] + arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    try #require(process.terminationStatus == 0, "\(text)")
    return text
  }

  private func h16VerifyRecoveryRoute(
    _ model: ComputerMCPAppModel, project: ProjectSummary?
  ) async throws {
    let route = project == nil ? "privacy" : "projects"
    if project != nil { model.refresh(.projects) }
    _ = NSApplication.shared

    for language in ["en", "zh-Hans"] {
      let locale = Locale(identifier: language)
      let chinese = language == "zh-Hans"
      let recoveryTitle = chinese ? "保留的提交与存储" : "Retained Commits & Storage"
      let recoverySection = chinese ? "工作树与恢复" : "Worktrees & Recovery"
      let reclaim = chinese ? "回收存储空间…" : "Reclaim Storage…"
      #expect(AppLocalization.string("commits.standalone.title", locale: locale) == recoveryTitle)
      #expect(AppLocalization.string("entry.privacy.row_title", locale: locale) == recoveryTitle)
      #expect(
        AppLocalization.string("entry.projects.section_title", locale: locale) == recoverySection)
      #expect(AppLocalization.string("storage.action.reclaim", locale: locale) == reclaim)

      model.selectedSection = project == nil ? .permissions : .projects
      model.projectRecoveryPath = []
      model.privacySecurity.path = []
      let host = NSHostingView(
        rootView: AppShellView()
          .environmentObject(model)
          .environment(\.locale, locale)
          .environment(\.colorScheme, chinese ? .dark : .light))
      host.sizingOptions = []
      let viewport = NSRect(x: 0, y: 0, width: 1120, height: 1440)
      host.frame = viewport
      let window = NSWindow(
        contentRect: viewport, styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: chinese ? .darkAqua : .aqua)
      window.contentView = host
      defer { window.close() }
      window.display()

      let entryLabels =
        project.map { [$0.displayName] }
        ?? [chinese ? "提交与存储" : recoveryTitle, recoverySection]
      let entry = try await h16FindLabels(entryLabels, in: host, language: language)
      try h16Capture(entry, name: "h16-\(route)-entry-\(language)")
      if let project {
        model.projectRecoveryPath.append(project)
      } else {
        model.privacySecurity.path.append(.recovery)
      }

      // These operation results exist only in the recovery model populated by this fixture.
      let resultKey = project == nil ? "recovery.review_changed" : "worktree.removal.verified"
      let sharedResult =
        chinese && project == nil
        ? "选择发生变化" : AppLocalization.string(resultKey, locale: locale)
      let destination = try await h16FindLabels(
        [sharedResult, reclaim], in: host, language: language,
        isReady: { !model.worktreeRecovery.isWorking })
      try h16Capture(destination, name: "h16-\(route)-destination-\(language)")
    }
  }

  private func h16FindLabels(
    _ labels: [String], in host: NSView, language: String, isReady: () -> Bool = { true }
  ) async throws -> NSBitmapImageRep {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let expected = labels.map(Self.h16Normalized)
    var recognized: [String] = []
    repeat {
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      let wasReady = isReady()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let image = try #require(bitmap.cgImage)
      let result = try await Task.detached {
        try Self.h16RecognizeText(image, language: language)
      }.value
      recognized = result
      let normalized = recognized.map(Self.h16Normalized)
      if wasReady, isReady(),
        expected.allSatisfy({ label in normalized.contains(where: { $0.contains(label) }) })
      {
        return bitmap
      }
      try await Task.sleep(for: .milliseconds(150))
    } while .now < deadline
    throw H16NavigationError.labelsMissing(labels, recognized)
  }

  nonisolated private static func h16RecognizeText(
    _ image: CGImage, language: String
  ) throws -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLanguages = language == "zh-Hans" ? ["zh-Hans", "en-US"] : ["en-US"]
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { observation in
      observation.topCandidates(1).first?.string
    }
  }

  nonisolated private static func h16Normalized(_ text: String) -> String {
    text.lowercased().filter { $0.isLetter || $0.isNumber }
  }

  private func h16Capture(_ bitmap: NSBitmapImageRep, name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["COMPUTER_MCP_UI_SNAPSHOT_DIR"] else {
      return
    }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
  }

  @Test
  func testProfileActivationUpdatesAdmissionAndRejectedProfileRollsBack() async throws {
    try await withAppControlPlaneFixture { fixture in
      try await fixture.app.startApplication()
      var status = try await fixture.app.fetchStatus()
      #expect((status.serviceState) == (.running))
      #expect((status.activeProfileName) == (GatewayProfileID.chatGPTObserve.rawValue))

      try await fixture.app.activateProfile(id: GatewayProfileID.chatGPTOperate.rawValue)
      status = try await fixture.app.fetchStatus()
      #expect((status.serviceState) == (.running))
      #expect((status.activeProfileName) == (GatewayProfileID.chatGPTOperate.rawValue))
      let activeAfterOperate = try await fixture.controlPlane.activeGatewayProfile()
      #expect((activeAfterOperate) == (.chatGPTOperate))

      do {
        try await fixture.app.activateProfile(id: GatewayProfileID.localAdmin.rawValue)
        Issue.record("Expected local-admin App socket activation to fail.")
      } catch let error as AppControlPlaneServiceError {
        #expect((error) == (.localAdminCannotBeSocketProfile))
      }
      status = try await fixture.app.fetchStatus()
      #expect((status.serviceState) == (.running))
      #expect((status.activeProfileName) == (GatewayProfileID.chatGPTOperate.rawValue))
      let activeAfterRejection = try await fixture.controlPlane.activeGatewayProfile()
      #expect((activeAfterRejection) == (.chatGPTOperate))
    }
  }

  @Test
  func testTunnelListsDoNotQueryKeychain() async throws {
    let keychainAdapter = AppTestKeychainAdapter()
    try await withAppControlPlaneFixture(keychainAdapter: keychainAdapter) { fixture in
      let reference = try SecretReference(account: "tunnel.current.openai-api-key")
      try await fixture.controlPlane.saveOpenAITunnelConfiguration(
        OpenAITunnelConfiguration(
          id: "current",
          tunnelClientProfile: "computer-mcp",
          tunnelID: "tunnel_current",
          manifestPath: fixture.controlPlane.directories.manifest.path,
          gatewayExecutablePath: "computer-mcp",
          gatewaySocketPath: fixture.controlPlane.directories.gatewaySocket.path,
          apiKeyReference: reference
        )
      )

      _ = try await fixture.app.fetchOpenAITunnels()
      _ = try await fixture.app.fetchCloudflareTunnels()

      #expect(keychainAdapter.secretReadCount == 0)
    }
  }

  @Test
  func pluginScreenUsesSharedHostTransactionsAndRetainsFilesOnRemoval() async throws {
    try await withAppControlPlaneFixture { fixture in
      for project in ["first", "second"] {
        let root = fixture.root.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try await fixture.controlPlane.database.saveProject(
          .init(id: project, displayName: project.capitalized, rootPath: root.path))
      }
      let package = fixture.root.appendingPathComponent("Local Package", isDirectory: true)
      let skill = package.appendingPathComponent("skills/guide", isDirectory: true)
      try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
      try "---\nname: guide\ndescription: Test guide\n---\nRead only.".write(
        to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
      try """
      id = 'screen-package'
      name = 'Screen package'
      version = '1.0.0'
      plugin_api = 1
      [[permissions]]
      id = 'screen'
      access = 'allow'
      purpose = 'Inspect the screen'
      [[permissions]]
      id = 'desktop-control'
      access = 'allow'
      purpose = 'Interact with selected applications'
      [[permissions]]
      id = 'project'
      access = 'read'
      purpose = 'Read selected projects'
      [sandbox]
      network = 'trusted'
      purpose = 'Look up metadata on trusted hosts'
      read_exceptions = [{ path = '~/.screen-helper/metadata', purpose = 'Read saved metadata' }]
      [[skills]]
      id = 'guide'
      path = 'skills'
      """.write(
        to: package.appendingPathComponent(PluginManifest.filename), atomically: true,
        encoding: .utf8)
      let model = PluginManagementModel(controlPlane: fixture.app)
      await model.reload()
      #expect(model.snapshot?.state.revision == 0)
      #expect(await model.apply(.registerDevelopment(package), expectedRevision: 0))
      let registered = try #require(model.snapshot)
      let installation = try #require(registered.state.installations.first)
      #expect(registered.state.settings["screen-package"]?.enabled == false)
      #expect(model.selectedID == "screen-package")
      let draft = PluginSettingsDraft(id: "screen-package", snapshot: registered)
      let enable = PluginHostChange.enabled(pluginID: "screen-package", true)
      await #expect(throws: ProviderEnablementError.reviewRequired) {
        try await fixture.app.changePlugins(enable, expectedRevision: 1)
      }
      #expect(!(await model.apply(enable, expectedRevision: 1)))
      let declined = try #require(model.enablementReview)
      #expect(declined.provider.declarations?.permissions.count == 3)
      #expect(declined.names.projects["first"] == "First")
      #expect(declined.requestedMode == .sandbox)
      #expect(declined.provider.declarations?.sandbox?.network == .trusted)
      #expect(try declined.readExceptions().map(\.purpose) == ["Read saved metadata"])
      if ProcessInfo.processInfo.environment["COMPUTER_MCP_UI_SNAPSHOT_DIR"] != nil {
        try renderEnablement(
          PluginEnablementReviewForm(model: model, review: declined) { _ in },
          name: "plugin-enablement")
        try renderEnablement(
          PluginEnablementReviewForm(model: model, review: declined) { _ in },
          name: "plugin-enablement-details", scrollToBottom: true)
      }
      model.cancelEnablement(reviewID: declined.id)
      #expect(!(await model.confirmEnablement(reviewID: declined.id, selection: .init())))
      #expect(try await fixture.app.fetchPlugins().state == registered.state)

      var activating = draft
      activating.enabled = true
      if ProcessInfo.processInfo.environment["COMPUTER_MCP_UI_SNAPSHOT_DIR"] != nil {
        let window = enablementWindow(PluginSettingsEditor(model: model, initial: activating))
        defer { window.close() }
        // Save, decline, and save again from the same retained editor draft.
        for _ in 0..<2 {
          try pressEnablementShortcut(.approve, in: window)
          try await waitForEnablementPresentation {
            model.enablementReview != nil && !model.isSaving
          }
          try pressEnablementShortcut(.decline, in: window)
          try await waitForEnablementPresentation { model.enablementReview == nil }
        }
        #expect(try await fixture.app.fetchPlugins().state == registered.state)
      }
      let save = PluginHostChange.settings(pluginID: activating.id, try activating.settings())
      await #expect(throws: ProviderEnablementError.reviewRequired) {
        try await fixture.app.changePlugins(save, expectedRevision: 1)
      }
      #expect(!(await model.apply(save, expectedRevision: 1)))
      let review = try #require(model.enablementReview)
      var selection = ProviderEnablementSelection()
      try selection.permissions.set(.granted(.access), for: .screen)
      try selection.permissions.set(.granted(.read), for: .project("first"))
      #expect(await model.confirmEnablement(reviewID: review.id, selection: selection))
      #expect(!(await model.confirmEnablement(reviewID: review.id, selection: selection)))
      let inventory = try await fixture.app.fetchPrivacyPermissionInventory()
      let active = try #require(
        inventory.providers.first { $0.identity == review.provider.identity })
      #expect(active.availability == .active)
      #expect(active.approval?.permissions.state(for: .screen) == .granted(.access))
      #expect(active.approval?.permissions.state(for: .project("first")) == .granted(.read))
      #expect(active.approval?.permissions.state(for: .project("second")) != .granted(.read))
      #expect(active.approval?.permissions.state(for: .desktopControl) != .granted(.access))
      #expect(model.snapshot?.contributions.map(\.componentID) == ["guide"])
      #expect(try await fixture.controlPlane.pluginSnapshot().state == model.snapshot?.state)

      #expect(
        !(await model.apply(
          .settings(pluginID: draft.id, try draft.settings()), expectedRevision: draft.revision)))
      #expect(model.snapshot?.state.revision == 2)
      #expect(await model.apply(.enabled(pluginID: draft.id, false), expectedRevision: 2))
      let disabled = try #require(
        try await fixture.app.fetchPrivacyPermissionInventory().providers.first {
          $0.identity == review.provider.identity
        })
      #expect(disabled.availability == .disabled)
      try await fixture.app.saveProviderPermissions(
        reviewed: disabled, permissions: selection.permissions, fullAccess: false,
        sandboxSettings: .init(), editingApproval: false)
      await model.reload()
      #expect(model.snapshot?.contributions.map(\.componentID) == ["guide"])
      #expect(
        await model.apply(.removeDevelopment(installationID: installation.id), expectedRevision: 4))
      let removed = try #require(model.snapshot)
      #expect(removed.state.installations.isEmpty)
      #expect(removed.state.settings["screen-package"]?.enabled == true)
      #expect(removed.contributions.isEmpty)
      #expect(!removed.issues.isEmpty)
      #expect(FileManager.default.fileExists(atPath: skill.appendingPathComponent("SKILL.md").path))
      #expect(try await fixture.app.fetchPlugins().state == removed.state)
    }
  }

  @Test
  func h13LocalRegistrationApprovalRollsBackFailedApplyAndKeepsRemoteTransportFlow() async throws {
    try await withAppControlPlaneFixture { fixture in
      let model = MCPRegistrationModel(controlPlane: fixture.app)
      await model.reload()
      let initial = try #require(model.snapshot)
      let server = MCPServerConfig(id: "manual", transport: .stdio, command: "/usr/bin/true")
      let add = MCPRegistrationChange.add(server)
      #expect(await model.review(add))
      let preview = try #require(model.preview)
      let declined = try #require(model.enablementReview)
      #expect(declined.localServer == preview.after)
      #expect(declined.names.mcpServers[server.id] == server.id)
      #expect(declined.allowsModeSelection)
      #expect(declined.sandboxContainer == .localServer("manual"))
      if ProcessInfo.processInfo.environment["COMPUTER_MCP_UI_SNAPSHOT_DIR"] != nil {
        try renderEnablement(
          MCPRegistrationsView(model: model) { _ in }, name: "mcp-enablement-preview",
          size: NSSize(width: 780, height: 620))
        try renderEnablement(
          ProviderEnablementReviewView(review: declined, isBusy: false) { _ in
          } onDecline: {
          },
          name: "mcp-enablement")
      }
      await model.apply()
      await #expect(throws: ProviderEnablementError.reviewRequired) {
        try await fixture.app.changeMCPRegistration(
          add, apply: true, expectedCurrentDigest: initial.currentDigest)
      }
      model.cancelReview()
      await model.confirmEnablement(reviewID: declined.id, selection: .init())
      #expect(try await fixture.app.fetchMCPRegistrations() == initial)

      if ProcessInfo.processInfo.environment["COMPUTER_MCP_UI_SNAPSHOT_DIR"] != nil {
        #expect(await model.review(add))
        let window = enablementWindow(MCPRegistrationsView(model: model) { _ in })
        defer { window.close() }
        try await waitForEnablementPresentation { !model.isBusy }
        try pressEnablementShortcut(.approve, in: window)
        try await waitForEnablementPresentation { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        try pressEnablementShortcut(.decline, in: sheet)
        try await waitForEnablementPresentation {
          model.enablementReview == nil && model.preview == nil && window.attachedSheet == nil
        }
        #expect(try await fixture.app.fetchMCPRegistrations() == initial)
      }

      #expect(await model.review(add))
      let rejected = try #require(model.enablementReview)
      var invalid = ProviderEnablementSelection()
      try invalid.permissions.set(.granted(.read), for: .project("missing"))
      await model.confirmEnablement(reviewID: rejected.id, selection: invalid)
      #expect(model.errorMessage != nil)
      #expect(try await fixture.app.fetchMCPRegistrations() == initial)
      #expect(
        try await fixture.app.fetchPrivacyPermissionInventory().providers.allSatisfy {
          $0.identity != .localServer("manual")
        })

      #expect(await model.review(add))
      let stale = try #require(model.enablementReview)
      fixture.policyReader.set(.machineFile, .available(Data("full_access = false".utf8)))
      await model.confirmEnablement(reviewID: stale.id, selection: .init())
      #expect(model.errorMessage != nil)
      #expect(try await fixture.app.fetchMCPRegistrations() == initial)
      fixture.policyReader.set(.machineFile, .absent)

      #expect(await model.review(add))
      let accepted = try #require(model.enablementReview)
      var selection = ProviderEnablementSelection()
      try selection.permissions.set(.granted(.read), for: .mcpServer(server.id))
      await model.confirmEnablement(reviewID: accepted.id, selection: selection)
      #expect(model.errorMessage == nil)
      #expect(
        model.snapshot?.registrations.contains { $0.id == "manual" && $0.server.enabled } == true)
      let approved = try await fixture.app.fetchPrivacyPermissionInventory().providers.first {
        $0.identity == .localServer("manual")
      }
      #expect(approved?.availability == .active)
      #expect(approved?.sourceDigest == accepted.provider.sourceDigest)
      #expect(approved?.approval?.permissions.state(for: .mcpServer(server.id)) == .granted(.read))
      await model.confirmEnablement(reviewID: accepted.id, selection: .init())
      #expect(
        try await fixture.app.fetchPrivacyPermissionInventory().providers.first {
          $0.identity == .localServer("manual")
        }?.approval?.revision == approved?.approval?.revision)

      let remote = MCPServerConfig(
        id: "remote-review", transport: .streamableHTTP, url: "https://example.invalid/mcp")
      #expect(await model.review(.add(remote)))
      #expect(model.enablementReview == nil)
      await model.apply()
      #expect(model.errorMessage == nil)
      #expect(model.snapshot?.registrations.contains { $0.id == remote.id } == true)

      let extra = MCPServerConfig(id: "restored", transport: .stdio, command: "/usr/bin/true")
      #expect(await model.review(.add(extra)))
      let retired = try #require(model.enablementReview)
      fixture.counter.forget()
      await model.confirmEnablement(reviewID: retired.id, selection: .init())
      #expect(model.errorMessage != nil)
      #expect(
        try await fixture.app.fetchMCPRegistrations().registrations.allSatisfy { $0.id != extra.id }
      )
    }
  }

  @Test
  func applicationRecoversPluginFilesWhileGatewayRemainsDisabled() async throws {
    try await withAppControlPlaneFixture { fixture in
      try await fixture.controlPlane.setGatewayDesiredRunning(false)
      let directories = fixture.controlPlane.directories
      let database = try GatewayDatabase(path: directories.database.path)
      let identity: PluginDirectoryIdentity
      do {
        let storage = try PluginInstallationStorage(
          at: directories.plugins,
          directoryFactory: MacOSPlatform.services(launcher: testExecutionLauncher())
            .pluginDirectories)
        defer { storage.finishTransaction() }
        identity = try storage.createInstallation()
        try database.recordPluginDirectory(
          .init(
            installationID: identity.url.lastPathComponent, pluginID: "interrupted-install",
            identity: identity))
      }
      try await fixture.app.startApplication()
      #expect(try await fixture.app.fetchStatus().serviceState == .stopped)
      #expect(try database.pluginOwnedDirectories().isEmpty)
      #expect(!FileManager.default.fileExists(atPath: identity.url.path))
      #expect(try await fixture.app.fetchPlugins().recoveryError == nil)
      #expect(try database.pluginStoreSnapshot().revision == 0)
    }
  }

  private func expectRequestableShellRefusal(
    _ client: GatewayClientSession, projectID: String
  ) async throws {
    let tool = try #require(try await client.listTools().first { $0.name == "shell.run" })
    #expect(tool.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"] != nil)
    let refused = try await client.call(
      toolName: "shell.run",
      arguments: .object([
        "project_id": .string(projectID), "mode": .string("argv"),
        "executable": .string("/bin/echo"), "argv": .array([.string("refused")]),
      ]))
    #expect(refused.result.objectValue?["isError"] == .bool(true))
    let error = try #require(
      refused.result.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue)
    #expect(error["code"] == .string("permission.denied"))
    #expect(error["request_ids"] == nil)
  }

  private func withAppControlPlaneFixture<T>(
    permissionRequester: any SystemPermissionRequesting = MacOSSystemPermissionRequester(),
    keychainAdapter: any KeychainAdapter = AppTestKeychainAdapter(),
    executionLauncher: ((AppControlPlaneServiceDirectories) -> ExecutionLauncher)? = nil,
    recoveryWillSync: @escaping @Sendable () throws -> Void = {},
    operation: (AppControlPlaneFixture) async throws -> T
  ) async throws -> T {
    let fixture = try AppControlPlaneFixture(
      permissionRequester: permissionRequester,
      keychainAdapter: keychainAdapter,
      executionLauncher: executionLauncher, recoveryWillSync: recoveryWillSync
    )
    do {
      let result = try await operation(fixture)
      await fixture.cleanup()
      return result
    } catch {
      await fixture.cleanup()
      throw error
    }
  }
}

@MainActor
private final class AppControlPlaneFixture {
  let root: URL
  let socketURL: URL
  let controlPlane: AppControlPlaneService
  let gatewayService: AppGatewayService
  let controlSocket: ControlSocketService
  let app: LiveAppControlPlane
  let counter = TestAuthorizationEpochCounter()
  let policyReader = TestManagedPolicyReader()

  init(
    permissionRequester: any SystemPermissionRequesting = MacOSSystemPermissionRequester(),
    keychainAdapter: any KeychainAdapter = AppTestKeychainAdapter(),
    registrationService: ClientRegistrationService? = nil,
    gatewayExecutablePath: String = "computer-mcp",
    executionLauncher: ((AppControlPlaneServiceDirectories) -> ExecutionLauncher)? = nil,
    recoveryWillSync: @escaping @Sendable () throws -> Void = {}
  ) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let socketDirectory = URL(
      fileURLWithPath: "/private/tmp/cm-app-\(UUID().uuidString.prefix(8))",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: socketDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    socketURL = socketDirectory.appendingPathComponent("gateway.sock")
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("Application Support/Computer MCP"),
      logs: root.appendingPathComponent("Logs/Computer MCP")
    )
    try directories.prepare()
    let database = try GatewayDatabase(path: directories.database.path)
    _ = database.permissionStore(counter: counter)
    try database.bootstrapPermissionProfiles(
      GatewayProfileID.builtIns.map { GatewayConfiguration().profileGrant(for: $0) },
      declarations: [])
    let launcher = executionLauncher?(directories) ?? testExecutionLauncher()
    var platform = MacOSPlatform.services(launcher: launcher)
    platform.permissionPolicyReader = policyReader
    let permissionGateway = try database.permissionRuntime(platform: platform).service
    let owner = try GatewayPermissionOwner(
      context: .init(
        caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "app-fixture-owner"),
      validate: {})
    let permissionControl = PermissionControlService(service: permissionGateway, owner: { owner })
    let manifestStore = try AtomicManifestStore(
      manifestURL: directories.manifest,
      database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications))
    _ = try manifestStore.activate(manifest: DefaultGatewayConfiguration.manifest)
    let secretStore = try KeychainSecretStore(
      service: "com.showxu.computer-mcp.tests.\(UUID().uuidString)",
      accessGroup: "TESTTEAMID.com.showxu.computer-mcp.tests",
      adapter: keychainAdapter
    )
    controlPlane = AppControlPlaneService(
      directories: directories,
      database: database,
      permissionControl: permissionControl,
      recoveryOwner: try GatewayRecoveryOwnerService(
        database: database, platform: platform,
        owner: .init(
          caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "app-fixture-owner"),
        journalIO: .init(beforeDirectorySync: recoveryWillSync)),
      manifestStore: manifestStore,
      defaultManifest: DefaultGatewayConfiguration.manifest,
      secretStore: secretStore,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: testExecutionLauncher(),
        secretStore: secretStore,
        executableSearchDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
          .executableSearchDirectories,
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()
      ),
      gatewayExecutablePath: gatewayExecutablePath,
      launchAtLoginController: AppTestLaunchAtLoginController(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(),
      platform: platform
    )
    gatewayService = AppGatewayService(
      controlPlane: controlPlane,
      socketConfiguration: GatewaySocketConfiguration(socketURL: socketURL)
    )
    controlSocket = ControlSocketService(
      controlPlane: controlPlane, gatewayService: gatewayService,
      socketURL: socketDirectory.appendingPathComponent("control.sock"))
    app = LiveAppControlPlane(
      controlPlane: controlPlane,
      gatewayService: gatewayService,
      fileLogger: try AppFileLogger(directory: directories.logs),
      controlSocketService: controlSocket,
      permissionRequester: permissionRequester,
      registrationService: registrationService
    )
  }

  func cleanup() async {
    await app.stopApplication()
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
  }
}

private enum H16NavigationError: Error {
  case labelsMissing([String], [String])
}

private struct H16CompletedOnboarding: OnboardingPreferenceStoring {
  let completedVersion = UserDefaultsOnboardingPreferences.currentVersion
  func markCompleted(version: Int) {}
}

private final class H16ReleaseInterruption: @unchecked Sendable {
  private let lock = NSLock()
  private var state: (anchor: URL?, fired: Bool) = (nil, false)

  var fired: Bool { lock.withLock { state.fired } }

  func arm(_ anchor: URL) {
    lock.withLock { state = (anchor, false) }
  }

  func check() throws {
    try lock.withLock {
      guard let anchor = state.anchor, !FileManager.default.fileExists(atPath: anchor.path)
      else { return }
      state = (nil, true)
      throw CancellationError()
    }
  }
}

private final class AppOwnerHelperObservation: @unchecked Sendable {
  let changed = GatewayToolChangeBroadcaster()
  private let lock = NSLock()
  private var pid: Int32?
  private var finished = false
  var processID: Int32? { lock.withLock { pid } }
  var callCompleted: Bool { lock.withLock { finished } }

  func started(_ processID: Int32) {
    lock.withLock { pid = processID }
    changed.send()
  }

  func completed() {
    lock.withLock { finished = true }
    changed.send()
  }
}

/// Keeps the admitted helper in flight under its real sandbox and Darwin ownership.
private struct AppOwnerHelperExecutionPlatform: ExecutionPlatform {
  let directory: URL
  let observation: AppOwnerHelperObservation
  private let base: DarwinExecutionPlatform

  init(directory: URL, bootstrap: URL, observation: AppOwnerHelperObservation) {
    self.directory = directory.resolvingSymlinksInPath()
    self.observation = observation
    base = DarwinExecutionPlatform(bootstrapExecutable: bootstrap)
  }

  var supportsRecovery: Bool { base.supportsRecovery }
  var bootSessionID: String? { base.bootSessionID }
  var hostSystemReadPaths: [SandboxPath] { base.hostSystemReadPaths }
  func supportsDurableOwnership(sandboxed: Bool) -> Bool {
    base.supportsDurableOwnership(sandboxed: sandboxed)
  }

  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    let workingDirectory = URL(fileURLWithPath: command.directory.value).resolvingSymlinksInPath()
    guard command.executable.value == "/usr/bin/sw_vers", command.arguments.isEmpty,
      let prepared = try PreparedExecutionContext.current(),
      case .sandbox(let admitted) = prepared.mode, let sandbox, sandbox.readOnly,
      admitted.readOnly, command.directory == sandbox.worktree,
      admitted.worktree == sandbox.worktree,
      workingDirectory.deletingLastPathComponent().path == directory.path,
      UUID(uuidString: workingDirectory.lastPathComponent) != nil,
      command.inheritedDescriptors.isEmpty
    else {
      throw ExecutionEnvironmentError.unavailable(
        "Only the admitted system.software helper is supported")
    }
    let waiting = ExecutionCommand(
      executable: try SandboxPath("/bin/sleep"), arguments: ["30"],
      directory: command.directory, environment: command.environment,
      directoryDescriptor: command.directoryDescriptor,
      inheritedDescriptors: command.inheritedDescriptors)
    let ownership = try await base.start(
      waiting, sandbox: sandbox, method: method, input: input, output: output, error: error,
      bindOwnership: bindOwnership)
    observation.started(try ownership.recoveryState().root.processID)
    return ownership
  }

  func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
    try await base.recover(state)
  }

  func interrupt(_ members: [ExecutionMember]) async throws { try await base.interrupt(members) }

  func releaseRecovery(_ state: ExecutionRecoveryState) throws { try base.releaseRecovery(state) }
}

@MainActor
private final class AppTestPermissionRequester: SystemPermissionRequesting,
  @unchecked Sendable
{
  let outcome: PermissionRequestOutcome
  private(set) var requestedIDs: [String] = []

  init(outcome: PermissionRequestOutcome) {
    self.outcome = outcome
  }

  func requestPermission(id: String) throws -> PermissionRequestOutcome {
    requestedIDs.append(id)
    return outcome
  }
}

private final class AppTestKeychainAdapter: KeychainAdapter, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  private var readCount = 0

  var secretReadCount: Int {
    lock.withLock { readCount }
  }

  func set(service: String, account: String, data: Data) {
    lock.withLock {
      values["\(service)\u{1f}\(account)"] = data
    }
  }

  func get(service: String, account: String) -> Data? {
    lock.withLock {
      readCount += 1
      return values["\(service)\u{1f}\(account)"]
    }
  }

  func delete(service: String, account: String) {
    _ = lock.withLock {
      values.removeValue(forKey: "\(service)\u{1f}\(account)")
    }
  }
}

private struct AppTestLaunchAtLoginController: LaunchAtLoginControlling {
  func state() -> LaunchAtLoginState {
    .disabled
  }

  func setEnabled(_ enabled: Bool) throws {}
}

/// Lock-protected state is shared with the control plane's blocking executor.
private final class AppRegistrationTestRunner: RegistrationProcessRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var changed = false
  private var writes = 0
  var writeCount: Int { lock.withLock { writes } }
  func changeEntry() { lock.withLock { changed = true } }
  func run(
    executable: String, arguments: [String], environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    lock.withLock {
      let get = arguments.contains("get")
      if arguments.contains("add") { writes += 1 }
      return .init(
        executable: executable, arguments: arguments, exitCode: get && !changed ? 1 : 0,
        timedOut: false,
        stdout: get && changed
          ? "{\"transport\":{\"type\":\"stdio\",\"command\":\"changed\",\"args\":[]}}" : "",
        stderr: get && !changed ? "No MCP server named computer-mcp" : "",
        stdoutTruncated: false, stderrTruncated: false)
    }
  }
}

private func appPermissions(_ entries: [Permission: ComputerMCPPermissions.PermissionState])
  -> Permissions
{
  var result = Permissions()
  for (permission, state) in entries { try! result.set(state, for: permission) }
  return result
}

@MainActor
private func renderEnablement(
  _ view: some View, name: String, size: NSSize = NSSize(width: 680, height: 720),
  scrollToBottom: Bool = false
) throws {
  for language in ["en", "zh-Hans"] {
    for dark in [false, true] {
      try render(
        view.environment(\.locale, Locale(identifier: language))
          .environment(\.colorScheme, dark ? .dark : .light),
        size: size, appearance: try #require(NSAppearance(named: dark ? .darkAqua : .aqua)),
        name: "\(name)-\(language)-\(dark ? "dark" : "light")",
        scrollToBottom: scrollToBottom)
    }
  }
}

private enum EnablementShortcut {
  case approve, decline
}

@MainActor
private func enablementWindow(_ view: some View) -> NSWindow {
  let application = NSApplication.shared
  let window = NSWindow(contentViewController: NSHostingController(rootView: view))
  window.isReleasedWhenClosed = false
  window.orderBack(nil)
  window.makeKey()
  application.updateWindows()
  return window
}

@MainActor
private func pressEnablementShortcut(_ shortcut: EnablementShortcut, in window: NSWindow) throws {
  window.contentView?.layoutSubtreeIfNeeded()
  let character = shortcut == .approve ? "\r" : "\u{1b}"
  let event = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: character,
      charactersIgnoringModifiers: character, isARepeat: false,
      keyCode: shortcut == .approve ? 36 : 53))
  try #require(window.performKeyEquivalent(with: event))
}

@MainActor
private func waitForEnablementPresentation(_ ready: () -> Bool) async throws {
  for _ in 0..<100 {
    if ready() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(ready())
}
