import ComputerMCPAuthorization
import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPTunnels
import Foundation
import GRDB
import MCP
import Testing

@testable import ComputerMCPControlPlane
@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

@Suite(.timeLimit(.minutes(1)))
struct OAuthControlPlaneTests {
  @Test func tunnelConfigurationDigestCoversEverySavedField() throws {
    let profile = CloudflareTunnelConfiguration(
      id: "tunnel", tunnelName: "named", publicHostname: "gateway.example",
      cloudflaredPath: "/tools/cloudflared", oauthEnabled: true,
      oauthClientAllowlist: ["client.example", "second.example"],
      tunnelTokenReference: try SecretReference(account: "cloudflare.tunnel.tunnel-token"),
      accessTokenReference: try SecretReference(account: "cloudflare.tunnel.access-token"))
    let digest = try profile.configurationDigest
    #expect(digest == "d162d170b8f351efb885cf2ccf786eec0885a9d53cee53138b5c8fd81bee540e")
    let edits: [(String, (inout CloudflareTunnelConfiguration) -> Void)] = [
      ("id", { $0.id = "other" }),
      ("tunnel_name", { $0.tunnelName = "other" }),
      ("public_hostname", { $0.publicHostname = "other.example" }),
      ("gateway_profile", { $0.gatewayProfile = .cloudflareOperate }),
      ("local_port", { $0.localPort += 1 }),
      ("metrics_port", { $0.metricsPort += 1 }),
      ("cloudflared_path", { $0.cloudflaredPath = nil }),
      ("oauth_enabled", { $0.oauthEnabled = false }),
      ("oauth_client_allowlist", { $0.oauthClientAllowlist.removeLast() }),
    ]
    for (field, edit) in edits {
      var changed = profile
      edit(&changed)
      #expect(try changed.configurationDigest != digest, "Digest must cover \(field)")
    }
  }

  @Test func ownerContractsListApproveDenyAndRevoke() async throws {
    let fixture = try ControlFixture()
    defer { fixture.remove() }
    let server = fixture.server()
    let pairing = try await server.authorize(fixture.fields, address: "fixture")
    let owner = GatewayClientControl.app(fixture.operations)
    let listed = try await owner.call(name: "clients.authorizations", arguments: [:])
    let request = try #require(
      listed.objectValue?["authorizations"]?.arrayValue?.first?.objectValue)
    #expect(request["pairing_code"] == .string(pairing.request.pairingCode))
    #expect(request["client_host"] == .string("client.example"))
    #expect(request["redirect_host"] == .string("consumer.example"))
    #expect(request["status_digest"] == nil)
    await #expect(throws: OAuthError.invalidRequest) {
      try await owner.call(
        name: "clients.authorize", arguments: ["pairing_code": .string("000000")])
    }
    let approved = try await owner.call(
      name: "clients.authorize",
      arguments: [
        "pairing_code": .string(pairing.request.pairingCode),
        "profile_id": .string("cloudflare-operate"),
      ])
    #expect(approved.objectValue?["profile_id"] == .string("cloudflare-operate"))
    let id = try #require(approved.objectValue?["id"]?.stringValue)
    let grants = try await owner.call(name: "clients.grants", arguments: [:])
    #expect(grants.objectValue?["grants"]?.arrayValue?.count == 1)
    _ = try await owner.call(name: "clients.revoke_grant", arguments: ["id": .string(id)])
    #expect(try await server.grants(approver: .localApp).first?.revokedAt != nil)
    let denied = try await server.authorize(fixture.fields, address: "fixture")
    _ = try await owner.call(
      name: "clients.deny", arguments: ["pairing_code": .string(denied.request.pairingCode)])
    #expect(try await server.pendingRequests(approver: .localApp).isEmpty)
  }

  @Test(arguments: [GatewayCallerKind.cloudflareTunnel, .secureTunnel, .localMCP])
  func serviceRejectsNonOwnerCallers(caller: GatewayCallerKind) async throws {
    let fixture = try ControlFixture()
    defer { fixture.remove() }
    await #expect(throws: OAuthError.accessDenied) {
      try await fixture.service.oauthAuthorizations(approver: caller)
    }
    await #expect(throws: OAuthError.accessDenied) {
      try await fixture.service.authorizeOAuthClient(pairingCode: "ABCDEF", approver: caller)
    }
    await #expect(throws: OAuthError.accessDenied) {
      try await fixture.service.denyOAuthAuthorization(pairingCode: "ABCDEF", approver: caller)
    }
    await #expect(throws: OAuthError.accessDenied) {
      try await fixture.service.oauthGrants(approver: caller)
    }
    await #expect(throws: OAuthError.accessDenied) {
      try await fixture.service.revokeOAuthGrant(id: "grant", approver: caller)
    }
  }

  @Test(arguments: [false, true])
  func defaultApprovalRequiresAnEffectivelyReadOnlyObserveProfile(throughControl: Bool)
    async throws
  {
    let fixture = try ControlFixture()
    defer { fixture.remove() }
    let server = fixture.server()
    let owner = GatewayClientControl.app(fixture.operations)
    func approve(_ code: String, profile: GatewayProfileID? = nil) async throws -> GatewayProfileID
    {
      if throughControl {
        var arguments: [String: JSONValue] = ["pairing_code": .string(code)]
        if let profile { arguments["profile_id"] = .string(profile.rawValue) }
        let response = try await owner.call(name: "clients.authorize", arguments: arguments)
        return try #require(
          GatewayProfileID(rawValue: response.objectValue?["profile_id"]?.stringValue ?? ""))
      }
      return try await fixture.service.authorizeOAuthClient(
        pairingCode: code, profileID: profile
      ).profileID
    }
    let first = try await server.authorize(fixture.fields, address: "fixture")
    #expect(try await approve(first.request.pairingCode) == .cloudflareObserve)

    var observe = try #require(
      try await fixture.service.profileGrants().first { $0.id == .cloudflareObserve })
    observe.mode = .projectOperations
    try fixture.database.saveProfile(observe, expectedRevision: observe.authorizationRevision)
    #expect(
      try await fixture.service.profileGrants().first { $0.id == .cloudflareObserve }?.mode
        == .projectOperations)
    let next = try await server.authorize(fixture.fields, address: "fixture")
    do {
      _ = try await approve(next.request.pairingCode)
      Issue.record("Approval needs an explicit profile when Observe permits operations.")
    } catch GatewayToolError.invalidArguments(let message) {
      #expect(message.contains("explicit profile"))
      #expect(message.contains("--profile"))
      #expect(message.contains("profile_id"))
    }
    #expect(try await server.pendingRequests(approver: .localApp).count == 1)
    #expect(try await server.grants(approver: .localApp).count == 1)
    #expect(
      try await approve(next.request.pairingCode, profile: .cloudflareObserve) == .cloudflareObserve
    )
  }

  @Test(arguments: [false, true], [false, true])
  func approvalRejectsChangedProfileAuthorizationUntilItIsReviewedAgain(
    throughControl: Bool, changeMode: Bool
  ) async throws {
    let fixture = try ControlFixture()
    defer { fixture.remove() }
    let server = fixture.server()
    let pairing = try await server.authorize(fixture.fields, address: "fixture")
    let reviewed = try #require(
      try await fixture.service.profileGrants().first { $0.id == .cloudflareObserve })
    #expect(reviewed.mode == .readOnly)
    let changed = try await fixture.service.updateProfilePermissions(
      profileID: reviewed.id, mode: changeMode ? .projectOperations : nil,
      capabilityIDs: changeMode ? ["file.read", "file.write"] : ["file.read"],
      expectedRevision: reviewed.authorizationRevision)
    #expect(changed.mode == (changeMode ? .projectOperations : .readOnly))
    #expect(changed.capabilityIDs != reviewed.capabilityIDs)
    let owner = GatewayClientControl.app(fixture.operations)
    func approve(digest: String) async throws -> GatewayProfileID {
      if throughControl {
        let response = try await owner.call(
          name: "clients.authorize",
          arguments: [
            "pairing_code": .string(pairing.request.pairingCode),
            "profile_id": .string(reviewed.id.rawValue),
            "authorization_digest": .string(digest),
          ])
        return try #require(
          GatewayProfileID(rawValue: response.objectValue?["profile_id"]?.stringValue ?? ""))
      }
      return try await fixture.service.authorizeOAuthClient(
        pairingCode: pairing.request.pairingCode, profileID: reviewed.id,
        expectedAuthorizationDigest: digest
      ).profileID
    }
    do {
      _ = try await approve(digest: OAuthApprovalProfile(grant: reviewed).authorizationDigest)
      Issue.record("An approval must use the authorization digest the owner reviewed.")
    } catch GatewayToolError.invalidArguments(let message) {
      #expect(message.contains("authorization changed"))
      #expect(message.contains("review"))
    }
    #expect(try await server.pendingRequests(approver: .localApp).count == 1)
    #expect(try await server.grants(approver: .localApp).isEmpty)
    #expect(
      try await approve(digest: OAuthApprovalProfile(grant: changed).authorizationDigest)
        == reviewed.id)
  }

  @Test func permissionPublicationWaitsForApprovalToCommit() async throws {
    let gate = CommitGate()
    defer { gate.resume() }
    let fixture = try ControlFixture(approvalWillCommit: { gate.pause() })
    defer { fixture.remove() }
    let flow = fixture.server()
    let pairing = try await flow.authorize(fixture.fields, address: "fixture")
    let reviewed = try #require(
      try await fixture.service.oauthApprovalProfiles().first {
        $0.grant.id == .cloudflareObserve
      })
    let lock = await fixture.service.manifestStore.publicationLock
    let approving = Task {
      try await fixture.service.authorizeOAuthClient(
        pairingCode: pairing.request.pairingCode, profileID: reviewed.grant.id,
        expectedAuthorizationDigest: reviewed.authorizationDigest)
    }
    await gate.waitUntilPaused()
    let changing = Task {
      try await fixture.service.updateProfilePermissions(
        profileID: reviewed.grant.id, mode: .projectOperations,
        capabilityIDs: ["file.read", "file.write"])
    }
    gate.resume()
    let grant = try await approving.value
    let changed = try await changing.value
    #expect(grant.profileID == reviewed.grant.id)
    #expect(changed.mode == .projectOperations)
    #expect(
      try OAuthApprovalProfile(grant: changed).authorizationDigest != reviewed.authorizationDigest)
    #expect(try await flow.pendingRequests(approver: .localApp).isEmpty)
    #expect(lock.waitingCount == 0)
  }

  private func waitForPublicationWaiters(_ lock: ConfigurationPublicationLock, count: Int) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while lock.waitingCount != count, ContinuousClock.now < deadline { await Task.yield() }
    #expect(lock.waitingCount == count)
  }

  @Test func startupWithoutAManifestEndsStoredTunnelAuthority() async throws {
    let fixture = try ControlFixture()
    defer { fixture.remove() }
    let flow = fixture.server()
    let pairing = try await flow.authorize(fixture.fields, address: "fixture")
    let grant = try await fixture.service.authorizeOAuthClient(
      pairingCode: pairing.request.pairingCode)
    let pending = try await flow.authorize(fixture.fields, address: "pending")
    try FileManager.default.removeItem(at: fixture.service.directories.manifest)
    let restarted = try fixture.restartedService()
    try await restarted.start()
    #expect(try fixture.database.oauthTransaction { try $0.grant(id: grant.id) }?.revokedAt != nil)
    #expect(try fixture.database.oauthTransaction { try $0.requests(tunnelID: "tunnel") }.isEmpty)
    await #expect(throws: OAuthError.invalidRequest) {
      try await flow.status(statusToken: pending.statusToken, address: "pending")
    }
    try await restarted.stop()
  }

  @Test(arguments: [false, true], [false, true])
  func derivedProjectAuthorizationSerializesWithApproval(removing: Bool, changeFirst: Bool)
    async throws
  {
    let gate = CommitGate()
    defer { gate.resume() }
    let fixture = try ControlFixture(approvalWillCommit: { gate.pause() })
    defer { fixture.remove() }
    let source = fixture.root.appendingPathComponent("source").resolvingSymlinksInPath()
    let child = fixture.root.appendingPathComponent("child").resolvingSymlinksInPath()
    for directory in [source, child] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try fixture.database.saveProject(
      .init(id: "source", displayName: "Source", rootPath: source.path))
    try fixture.database.saveProfile(
      .init(
        id: .cloudflareOperate, capabilityIDs: ["project.list"], projectIDs: ["source"],
        allowedCallers: [.cloudflareTunnel], mode: .projectOperations))
    let registration = MCPDerivedProjectRegistration(
      origin: "fixture", receiptID: "derived-receipt", sourceProjectID: "source",
      sourceRoot: source.path, receiptDigest: "fixture-digest", profileID: .cloudflareOperate,
      principalID: "existing-client", caller: .cloudflareTunnel,
      project: .init(id: "child", displayName: "Child", rootPath: child.path))
    if removing {
      try fixture.database.registerDerivedProject(
        registration, verifiedPrincipalID: "existing-client", caller: .cloudflareTunnel)
    }
    let connection = try GatewayDatabaseConnection(
      path: try #require(fixture.database.fileURL).path)
    try await connection.writer.writeWithoutTransaction {
      try $0.execute(sql: "PRAGMA busy_timeout = 0")
    }
    let writer = GatewayDatabase(connection: connection)
    func changeProject() throws {
      if removing {
        try writer.unregisterDerivedProject(
          registration, verifiedPrincipalID: "existing-client", caller: .cloudflareTunnel)
      } else {
        try writer.registerDerivedProject(
          registration, verifiedPrincipalID: "existing-client", caller: .cloudflareTunnel)
      }
    }
    let flow = fixture.server()
    let pairing = try await flow.authorize(fixture.fields, address: "fixture")
    let reviewed = try #require(
      try await fixture.service.oauthApprovalProfiles().first { $0.grant.id == .cloudflareOperate })
    if changeFirst {
      try changeProject()
      await #expect(throws: (any Error).self) {
        try await fixture.service.authorizeOAuthClient(
          pairingCode: pairing.request.pairingCode, profileID: reviewed.grant.id,
          expectedAuthorizationDigest: reviewed.authorizationDigest)
      }
      #expect(try await flow.grants(approver: .localApp).isEmpty)
      #expect(try await flow.pendingRequests(approver: .localApp).count == 1)
    } else {
      let approving = Task {
        try await fixture.service.authorizeOAuthClient(
          pairingCode: pairing.request.pairingCode, profileID: reviewed.grant.id,
          expectedAuthorizationDigest: reviewed.authorizationDigest)
      }
      await gate.waitUntilPaused()
      // This connection cannot commit between the digest comparison and grant insertion.
      #expect(throws: DatabaseError.self) { try changeProject() }
      gate.resume()
      #expect(try await approving.value.profileID == reviewed.grant.id)
      try changeProject()
      #expect(try await flow.pendingRequests(approver: .localApp).isEmpty)
    }
    let current = try #require(
      try await fixture.service.oauthApprovalProfiles().first { $0.grant.id == reviewed.grant.id })
    #expect(current.authorizationDigest != reviewed.authorizationDigest)
    #expect(current.grant.projectIDs.contains("child") == !removing)
  }

  // These integration cases publish manifests through the macOS exclusive-rename
  // adapter. Linux manifest recovery-record publication reports ENOSYS.
  #if os(macOS)
    @Test func manifestDerivedAuthorizationRejectsTheDigestDisplayedBeforeAPermissionChange()
      async throws
    {
      let fixture = try ControlFixture()
      defer { fixture.remove() }
      var configuration = try await fixture.service.activeConfiguration()
      configuration.profiles = [
        .init(
          id: .cloudflareObserve, capabilities: ["file.read"],
          allowedCallers: [.cloudflareTunnel], mode: .readOnly)
      ]
      _ = try await fixture.service.activateManifest(
        configuration.exportedTOML(),
        expectedDigest: try? await fixture.service.configurationDigest())
      let reviewed = try #require(
        try await fixture.service.oauthApprovalProfiles().first {
          $0.grant.id == .cloudflareObserve
        })
      #expect(try fixture.database.profiles().isEmpty)
      let flow = fixture.server()
      let pairing = try await flow.authorize(fixture.fields, address: "fixture")
      configuration.profiles[0].mode = .projectOperations
      configuration.profiles[0].capabilities = ["file.read", "file.write"]
      _ = try await fixture.gatewayService.changeManifest(
        configuration.exportedTOML(),
        expectedDigest: try await fixture.service.configurationDigest())
      await #expect(throws: (any Error).self) {
        try await fixture.service.authorizeOAuthClient(
          pairingCode: pairing.request.pairingCode, profileID: reviewed.grant.id,
          expectedAuthorizationDigest: reviewed.authorizationDigest)
      }
      #expect(try fixture.database.profiles().isEmpty)
      #expect(try await flow.grants(approver: .localApp).isEmpty)
      #expect(try await flow.pendingRequests(approver: .localApp).count == 1)
      let current = try #require(
        try await fixture.service.oauthApprovalProfiles().first {
          $0.grant.id == reviewed.grant.id
        })
      #expect(current.authorizationDigest != reviewed.authorizationDigest)
      _ = try await fixture.service.authorizeOAuthClient(
        pairingCode: pairing.request.pairingCode, profileID: current.grant.id,
        expectedAuthorizationDigest: current.authorizationDigest)
    }

    @Test(arguments: ["delete", "activate", "import", "rollback", "reload", "startup"])
    func everyTunnelRemovalEndsAuthorityBeforeRestoration(path: String) async throws {
      let fixture = try ControlFixture()
      defer { fixture.remove() }
      let profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      let original = try await fixture.service.activeConfiguration().exportedTOML()
      var removed = try await fixture.service.activeConfiguration()
      removed.transports.cloudflare = []
      let absent = try removed.exportedTOML()
      let flow = fixture.server()
      let (_, tokenCode) = try await fixture.approvedCode(flow)
      let tokens = try await flow.token(fixture.codeFields(tokenCode), address: "tokens")
      let (_, code) = try await fixture.approvedCode(flow)
      let pending = try await flow.authorize(fixture.fields, address: "pending")
      let undelivered = try await flow.authorize(fixture.fields, address: "undelivered")
      _ = try await fixture.service.authorizeOAuthClient(
        pairingCode: undelivered.request.pairingCode)
      var owner = fixture.service
      var listener: GatewayHTTPRuntime?
      if path != "startup" {
        let source = try await fixture.gatewayService.makeHTTPSessions(
          profileID: .cloudflareObserve,
          trace: .init(transport: "cloudflare_tunnel", tunnelInstanceID: profile.id))
        let origin = GatewayHTTPRuntime(
          configuration: .init(), source: .managed(source), host: "127.0.0.1",
          port: profile.localPort,
          publicBaseURL: fixture.configuration.issuer, accessToken: "fixture-static",
          oauth: GatewayOAuthHTTP(server: flow))
        listener = origin
        try await origin.startListening()
        await fixture.installOrigin(origin, profile: profile)
        #expect(
          try await fixture.postResponse(
            port: profile.localPort, token: "fixture-static", initialize: true
          ).statusCode == 200)
      }
      let socket = ControlSocketService(
        controlPlane: fixture.service, gatewayService: fixture.gatewayService,
        socketURL: fixture.root.appendingPathComponent("control.sock"))
      do {
        switch path {
        case "delete":
          try await fixture.operations.deleteCloudflareTunnelConfiguration(id: profile.id)
        case "activate":
          _ = try await fixture.operations.activateManifest(
            absent, expectedDigest: try await owner.configurationDigest())
        case "import":
          try await socket.start()
          let client = AppControlPlaneServiceClient(
            socketURL: fixture.root.appendingPathComponent("control.sock"))
          let preview = try await client.call(
            "config.import", arguments: .object(["toml": .string(absent)]))
          let digest = try #require(preview.objectValue?["current_digest"]?.stringValue)
          _ = try await client.call(
            "config.import",
            arguments: .object([
              "toml": .string(absent), "apply": .bool(true),
              "expected_current_digest": .string(digest),
            ]))
        case "rollback":
          let revision = ConfigurationRevision(
            digest: try AtomicManifestStore.digest(of: Data(absent.utf8)), manifest: absent)
          try fixture.database.saveConfigurationRevision(revision)
          _ = try await fixture.operations.rollbackManifest(to: revision.id)
        case "reload":
          try Data(absent.utf8).write(to: owner.directories.manifest, options: .atomic)
          fixture.monitor.signal()
          let deadline = ContinuousClock.now.advanced(by: .seconds(5))
          while try await !owner.cloudflareTunnelConfigurations().isEmpty,
            ContinuousClock.now < deadline
          {
            await Task.yield()
          }
        case "startup":
          try Data(absent.utf8).write(to: owner.directories.manifest, options: .atomic)
          owner = try fixture.restartedService()
          try await owner.start()
        default: Issue.record("Unknown publication path")
        }
        #expect(try await owner.cloudflareTunnelConfigurations().isEmpty)
        #expect(try await flow.pendingRequests(approver: .localApp).isEmpty)
        #expect(try await flow.grants(approver: .localApp).allSatisfy { $0.revokedAt != nil })
        await #expect(throws: OAuthError.invalidGrant) {
          try await flow.token(fixture.refreshFields(tokens.refreshToken), address: "tokens")
        }
        _ = try await owner.activateManifest(
          original, expectedDigest: try? await owner.configurationDigest())
        #expect(try await owner.cloudflareTunnelConfigurations().first?.id == profile.id)
        #expect(
          try await owner.cloudflareTunnelConfigurations().first?.publicHostname
            == profile.publicHostname)
        #expect(
          try await flow.authenticate(accessToken: tokens.accessToken, address: "tokens") == nil)
        await #expect(throws: OAuthError.invalidGrant) {
          try await flow.token(fixture.refreshFields(tokens.refreshToken), address: "tokens")
        }
        await #expect(throws: OAuthError.invalidGrant) {
          try await flow.token(fixture.codeFields(code), address: "tokens")
        }
        for pairing in [pending, undelivered] {
          await #expect(throws: OAuthError.invalidRequest) {
            try await flow.status(statusToken: pairing.statusToken, address: "pending")
          }
          await #expect(throws: OAuthError.invalidRequest) {
            try await owner.authorizeOAuthClient(pairingCode: pairing.request.pairingCode)
          }
        }
        await socket.stop()
        await listener?.stop()
        await fixture.gatewayService.stop()
        try await owner.stop()
      } catch {
        await socket.stop()
        await listener?.stop()
        await fixture.gatewayService.stop()
        try? await owner.stop()
        throw error
      }
    }

    @Test func deletionJoinsAuthorizationSuspendedBeforeInsertion() async throws {
      let fixture = try ControlFixture()
      defer { fixture.remove() }
      let gate = SuspensionGate()
      let canceled = AsyncStream<Void>.makeStream()
      let flow = fixture.server(authorizationWillInsert: {
        await withTaskCancellationHandler {
          await gate.pause()
        } onCancel: {
          canceled.continuation.yield(())
          canceled.continuation.finish()
        }
      })
      let profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      let listener = GatewayHTTPRuntime(
        configuration: .init(), registry: RotationRegistry(), host: "127.0.0.1",
        port: profile.localPort,
        publicBaseURL: fixture.configuration.issuer, accessToken: "fixture-static",
        oauth: GatewayOAuthHTTP(server: flow))
      try await listener.startListening()
      await fixture.installOrigin(listener, profile: profile)
      let session = URLSession(configuration: .ephemeral)
      defer { session.invalidateAndCancel() }
      var url = URLComponents(string: "http://127.0.0.1:\(profile.localPort)/oauth/authorize")!
      url.queryItems = fixture.fields.map { URLQueryItem(name: $0.key, value: $0.value) }
      var request = URLRequest(url: url.url!)
      request.setValue("gateway.example", forHTTPHeaderField: "Host")
      let authorization = Task { try? await session.data(for: request) }
      await gate.waitUntilPaused()
      let deleting = Task {
        try await fixture.service.deleteCloudflareTunnelConfiguration(id: profile.id)
      }
      for await _ in canceled.stream { break }
      #expect(await listener.activeOAuthRequestCount() == 1)
      #expect(try await fixture.service.cloudflareTunnelConfigurations().count == 1)
      #expect(
        try fixture.database.oauthTransaction { try $0.requests(tunnelID: profile.id).isEmpty })
      await gate.resume()
      try await deleting.value
      _ = await authorization.value
      #expect(await listener.activeOAuthRequestCount() == 0)
      #expect(try await fixture.service.cloudflareTunnelConfigurations().isEmpty)
      #expect(
        try fixture.database.oauthTransaction { try $0.requests(tunnelID: profile.id).isEmpty })
      #expect(
        try fixture.database.auditEvents(limit: 100).contains {
          $0.capabilityID == "oauth.authorization_requested"
        })
    }

    @Test(arguments: [false, true])
    func openedTunnelSaveCannotRestoreNewerOAuthRestrictions(disableOAuth: Bool) async throws {
      let fixture = try ControlFixture()
      defer { fixture.remove() }
      var profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      profile.oauthClientAllowlist = ["client.example", "second.example"]
      _ = try await fixture.service.saveCloudflareTunnelConfiguration(
        profile, tunnelToken: "synthetic-tunnel")
      let opened = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      let openedDigest = try opened.configurationDigest

      var restriction = fixture.saveInput(for: opened)
      if disableOAuth {
        restriction.oauthEnabled = false
      } else {
        restriction.oauthClientAllowlist = ["client.example"]
      }
      _ = try await fixture.operations.saveCloudflareTunnelConfiguration(restriction)
      let restricted = try #require(
        try await fixture.service.cloudflareTunnelConfigurations().first)
      let manifestDigest = try await fixture.service.configurationDigest()
      #expect(try restricted.configurationDigest != openedDigest)

      var draft = fixture.saveInput(for: opened)
      draft.tunnelName = "unrelated-edit"
      draft.oauthEnabled = opened.oauthEnabled
      draft.oauthClientAllowlist = opened.oauthClientAllowlist
      draft.expectedTunnelDigest = openedDigest
      let stale = draft
      await #expect(throws: CloudflareTunnelError.staleConfiguration(opened.id)) {
        try await fixture.operations.saveCloudflareTunnelConfiguration(stale)
      }
      #expect(try await fixture.service.cloudflareTunnelConfigurations() == [restricted])
      #expect(try await fixture.service.configurationDigest() == manifestDigest)
      #expect(restricted.oauthEnabled == !disableOAuth)
      #expect(
        restricted.oauthClientAllowlist
          == (disableOAuth ? opened.oauthClientAllowlist : ["client.example"]))

      var refreshed = fixture.saveInput(for: restricted)
      refreshed.tunnelName = draft.tunnelName
      refreshed.expectedTunnelDigest = try restricted.configurationDigest
      let saved = try await fixture.operations.saveCloudflareTunnelConfiguration(refreshed)
      #expect(saved.profile.tunnelName == draft.tunnelName)
      #expect(saved.profile.oauthEnabled == restricted.oauthEnabled)
      #expect(saved.profile.oauthClientAllowlist == restricted.oauthClientAllowlist)
    }

    @Test(arguments: [false, true], [false, true])
    func staleTunnelSaveIsRefusedAfterGatewayPublication(
      disableOAuth: Bool, bindTunnelDigest: Bool
    ) async throws {
      let gate = SuspensionGate()
      let fixture = try ControlFixture(manifestWillPublish: { await gate.pause() })
      defer { fixture.remove() }
      let profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      _ = try await fixture.service.saveCloudflareTunnelConfiguration(
        profile, tunnelToken: "synthetic-tunnel")
      let digest = try await fixture.service.configurationDigest()
      var configuration = try await fixture.service.activeConfiguration()
      configuration.transports.cloudflare[0].oauthEnabled = !disableOAuth
      configuration.transports.cloudflare[0].oauthClientAllowlist = ["updated.example"]
      configuration.builtin.enabled = ["file.read"]
      let manifest = try configuration.exportedTOML()
      let publishing = Task {
        try await fixture.gatewayService.changeManifest(manifest, expectedDigest: digest)
      }
      await gate.waitUntilPaused()
      var input = fixture.saveInput(for: profile)
      input.tunnelName = "updated-name"
      input.expectedTunnelDigest = bindTunnelDigest ? try profile.configurationDigest : nil
      let savingInput = input
      let saving = Task {
        try await fixture.operations.saveCloudflareTunnelConfiguration(savingInput)
      }
      let lock = await fixture.service.manifestStore.publicationLock
      await waitForPublicationWaiters(lock, count: 1)
      await gate.resume()
      _ = try await publishing.value
      if bindTunnelDigest {
        await #expect(throws: CloudflareTunnelError.staleConfiguration(profile.id)) {
          try await saving.value
        }
      } else {
        await #expect(throws: AtomicManifestStoreError.staleDigest) { try await saving.value }
      }
      let current = try await fixture.service.activeConfiguration()
      #expect(current.transports.cloudflare[0].tunnelName == profile.tunnelName)
      #expect(current.transports.cloudflare[0].oauthEnabled == !disableOAuth)
      #expect(current.transports.cloudflare[0].oauthClientAllowlist == ["updated.example"])
      #expect(current.builtin.enabled == ["file.read"])
    }

    @Test func staleGatewayPublicationIsRefusedAfterTunnelSave() async throws {
      let fixture = try ControlFixture()
      defer { fixture.remove() }
      let profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      _ = try await fixture.service.saveCloudflareTunnelConfiguration(
        profile, tunnelToken: "synthetic-tunnel")
      let digest = try await fixture.service.configurationDigest()
      var configuration = try await fixture.service.activeConfiguration()
      configuration.builtin.enabled = ["file.read"]
      var input = fixture.saveInput(for: profile)
      input.oauthEnabled = false
      input.tunnelName = "updated-name"
      let savingInput = input
      let manifest = try configuration.exportedTOML()
      let lock = await fixture.service.manifestStore.publicationLock
      await lock.acquire()
      let saving = Task {
        try await fixture.operations.saveCloudflareTunnelConfiguration(savingInput)
      }
      await waitForPublicationWaiters(lock, count: 1)
      let publishing = Task {
        try await fixture.gatewayService.changeManifest(manifest, expectedDigest: digest)
      }
      await waitForPublicationWaiters(lock, count: 2)
      lock.release()
      _ = try await saving.value
      await #expect(throws: AtomicManifestStoreError.staleDigest) { try await publishing.value }
      let current = try await fixture.service.activeConfiguration()
      #expect(current.transports.cloudflare[0].tunnelName == "updated-name")
      #expect(!current.transports.cloudflare[0].oauthEnabled)
      #expect(current.builtin.enabled != ["file.read"])
    }

    @Test func tunnelStartCannotRegisterAfterRemovalHasDrainedTheListener() async throws {
      let gate = SuspensionGate()
      let fixture = try ControlFixture(manifestWillPublish: { await gate.pause() })
      defer { fixture.remove() }
      let digest = try await fixture.service.configurationDigest()
      var configuration = try await fixture.service.activeConfiguration()
      configuration.transports.cloudflare = []
      let manifest = try configuration.exportedTOML()
      let publishing = Task {
        try await fixture.gatewayService.changeManifest(manifest, expectedDigest: digest)
      }
      await gate.waitUntilPaused()
      let starting = Task {
        try await fixture.service.startCloudflareTunnel(
          profileID: "tunnel", gatewayService: fixture.gatewayService)
      }
      let lock = await fixture.service.manifestStore.publicationLock
      await waitForPublicationWaiters(lock, count: 1)
      #expect(await fixture.service.cloudflareStartTasks.isEmpty)
      await gate.resume()
      _ = try await publishing.value
      await #expect(throws: CloudflareTunnelError.profileNotFound("tunnel")) {
        try await starting.value
      }
    }

    @Test func deletionWaitsForAnAdmittedApprovalThenRevokesIt() async throws {
      let gate = CommitGate()
      defer { gate.resume() }
      let fixture = try ControlFixture(approvalWillCommit: { gate.pause() })
      defer { fixture.remove() }
      let flow = fixture.server()
      let pairing = try await flow.authorize(fixture.fields, address: "fixture")
      let approving = Task {
        try await fixture.service.authorizeOAuthClient(pairingCode: pairing.request.pairingCode)
      }
      await gate.waitUntilPaused()
      let deleting = Task {
        try await fixture.service.deleteCloudflareTunnelConfiguration(
          id: fixture.configuration.tunnelID)
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while await fixture.service.cloudflareCredentialMutationWaiters[
        fixture.configuration.tunnelID]?.count != 1,
        ContinuousClock.now < deadline
      { await Task.yield() }
      #expect(
        await fixture.service.cloudflareCredentialMutationWaiters[fixture.configuration.tunnelID]?
          .count == 1)
      gate.resume()
      let approved = try await approving.value
      try await deleting.value
      #expect(try await fixture.service.cloudflareTunnelConfigurations().isEmpty)
      #expect(try await flow.pendingRequests(approver: .localApp).isEmpty)
      #expect(
        try await flow.grants(approver: .localApp).allSatisfy {
          $0.id == approved.id && $0.revokedAt != nil
        })
      let events = try fixture.database.auditEvents(limit: 100).sorted {
        $0.occurredAt < $1.occurredAt
      }
      let approval = try #require(
        events.firstIndex { $0.capabilityID == "oauth.authorization_approved" })
      let revocation = try #require(events.firstIndex { $0.capabilityID == "oauth.grant_revoked" })
      #expect(approval < revocation)
    }

    @Test func queuedRotationPreservesTheCompletedSavesOAuthPolicy() async throws {
      let fixture = try ControlFixture()
      defer { fixture.remove() }
      let profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      _ = try await fixture.service.saveCloudflareTunnelConfiguration(
        profile, tunnelToken: "synthetic-tunnel")
      let saving = SuspensionGate()
      await fixture.secrets.pauseWrite(
        "updated-tunnel", for: profile.tunnelTokenReference, gate: saving)
      var disabling = fixture.saveInput(for: profile)
      disabling.oauthEnabled = false
      disabling.oauthClientAllowlist = ["updated.example"]
      disabling.tunnelToken = "updated-tunnel"
      let firstInput = disabling
      let first = Task {
        try await fixture.operations.saveCloudflareTunnelConfiguration(firstInput)
      }
      await saving.waitUntilPaused()
      var rotating = fixture.saveInput(for: profile)
      rotating.regenerateAccessToken = true
      let secondInput = rotating
      let second = Task {
        try await fixture.operations.saveCloudflareTunnelConfiguration(secondInput)
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while await fixture.service.cloudflareCredentialMutationWaiters[profile.id]?.count != 1,
        ContinuousClock.now < deadline
      { await Task.yield() }
      #expect(await fixture.service.cloudflareCredentialMutationWaiters[profile.id]?.count == 1)
      await saving.resume()
      _ = try await first.value
      let rotated = try await second.value
      #expect(!rotated.profile.oauthEnabled)
      #expect(rotated.profile.oauthClientAllowlist == ["updated.example"])
      #expect(rotated.generatedAccessToken != nil)
      let current = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      #expect(!current.oauthEnabled)
      #expect(current.oauthClientAllowlist == ["updated.example"])
      #expect(
        await fixture.secrets.valueAsynchronously(
          for: profile.accessTokenReference, authenticationUI: .fail)
          == rotated.generatedAccessToken)
    }

    @Test func staleSaveOfAnotherTunnelCannotOverwriteCompletedDisablement() async throws {
      let fixture = try ControlFixture()
      defer { fixture.remove() }
      let profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      _ = try await fixture.service.saveCloudflareTunnelConfiguration(
        profile, tunnelToken: "synthetic-tunnel")
      let other = CloudflareTunnelConfiguration(
        id: "other", tunnelName: "other-named", publicHostname: "other.example",
        oauthEnabled: true, oauthClientAllowlist: ["client.example"],
        tunnelTokenReference: try SecretReference(account: "cloudflare.other.tunnel-token"),
        accessTokenReference: try SecretReference(account: "cloudflare.other.access-token"))
      _ = try await fixture.service.saveCloudflareTunnelConfiguration(
        other, tunnelToken: "synthetic-other-tunnel")
      let saving = SuspensionGate()
      await fixture.secrets.pauseWrite(
        "updated-tunnel", for: profile.tunnelTokenReference, gate: saving)
      var input = fixture.saveInput(for: profile)
      input.tunnelName = "updated-named"
      input.tunnelToken = "updated-tunnel"
      let savingInput = input
      let first = Task {
        try await fixture.operations.saveCloudflareTunnelConfiguration(savingInput)
      }
      await saving.waitUntilPaused()
      do {
        var disabling = fixture.saveInput(for: other)
        disabling.oauthEnabled = false
        _ = try await fixture.operations.saveCloudflareTunnelConfiguration(disabling)
        #expect(
          try await fixture.service.cloudflareTunnelConfigurations().first { $0.id == other.id }?
            .oauthEnabled == false)
        await saving.resume()
        await #expect(throws: AtomicManifestStoreError.staleDigest) { try await first.value }
        let current = try await fixture.service.cloudflareTunnelConfigurations()
        #expect(current.first { $0.id == profile.id }?.tunnelName == profile.tunnelName)
        #expect(current.first { $0.id == other.id }?.oauthEnabled == false)
        #expect(current.first { $0.id == other.id }?.oauthClientAllowlist == ["client.example"])
      } catch {
        await saving.resume()
        _ = await first.result
        throw error
      }
    }

    @Test func startWaitsForDeletionToRevokeGrantsAndInvalidateTheListenerCredential() async throws
    {
      let fixture = try ControlFixture()
      defer { fixture.remove() }
      let profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      let token = try #require(
        try await fixture.service.saveCloudflareTunnelConfiguration(
          profile, tunnelToken: "synthetic-tunnel", regenerateAccessToken: true
        ).generatedAccessToken)
      let pairing = try await fixture.server().authorize(fixture.fields, address: "fixture")
      let grant = try await fixture.service.authorizeOAuthClient(
        pairingCode: pairing.request.pairingCode)
      _ = try await fixture.service.startCloudflareTunnel(
        profileID: profile.id, gatewayService: fixture.gatewayService)
      let pending = try await fixture.server().authorize(fixture.fields, address: "pending")
      let delivered = try await fixture.server().authorize(fixture.fields, address: "delivered")
      _ = try await fixture.service.authorizeOAuthClient(pairingCode: delivered.request.pairingCode)
      guard
        case .redirect(let callback) = try await fixture.server().status(
          statusToken: delivered.statusToken, address: "delivered"),
        let code = URLComponents(string: callback)?.queryItems?.first(where: { $0.name == "code" })?
          .value
      else { throw OAuthError.invalidGrant }
      let credential = try #require(await fixture.service.cloudflareAccessCredentials[profile.id])
      let revoking = SuspensionGate()
      try await fixture.service.pauseOriginStop(profileID: profile.id, gate: revoking)
      let deleting = Task {
        try await fixture.service.deleteCloudflareTunnelConfiguration(id: profile.id)
      }
      await revoking.waitUntilPaused()
      #expect(await fixture.service.cloudflareRuntimes[profile.id]?.state == .stopping)
      #expect(
        try fixture.database.oauthTransaction { try $0.requests(tunnelID: profile.id) }.contains {
          $0.id == pending.request.id
        })
      #expect(
        try fixture.database.oauthTransaction { try $0.grant(id: grant.id) }?.revokedAt == nil)
      #expect(
        try fixture.database.oauthTransaction { try $0.code(digest: OAuthSecret.digest(code)) }
          != nil)
      let starting = Task {
        try await fixture.service.startCloudflareTunnel(
          profileID: profile.id, gatewayService: fixture.gatewayService)
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while await fixture.service.cloudflareCredentialMutationWaiters[profile.id]?.count != 1,
        ContinuousClock.now < deadline
      { await Task.yield() }
      #expect(await fixture.service.cloudflareCredentialMutationWaiters[profile.id]?.count == 1)
      #expect(await fixture.service.cloudflareStartTasks[profile.id] == nil)
      await revoking.resume()
      do {
        try await deleting.value
        await #expect(throws: CloudflareTunnelError.profileNotFound(profile.id)) {
          try await starting.value
        }
        #expect(try await fixture.service.cloudflareTunnelConfigurations().isEmpty)
        #expect(await fixture.service.cloudflareRuntimes.isEmpty)
        #expect(await fixture.service.cloudflareStartTasks.isEmpty)
        #expect(await fixture.service.cloudflareCredentialMutationWaiters.isEmpty)
        #expect(await fixture.service.cloudflareAccessCredentials[profile.id] == nil)
        #expect(
          await fixture.secrets.valueAsynchronously(
            for: profile.accessTokenReference, authenticationUI: .fail) == nil)
        #expect(
          try await fixture.server().grants(approver: .localApp).contains {
            $0.id == grant.id && $0.revokedAt != nil
          })
        _ = try await fixture.service.saveCloudflareTunnelConfiguration(
          profile, tunnelToken: "synthetic-recreated")
        #expect(try await fixture.server().pendingRequests(approver: .localApp).isEmpty)
        await #expect(throws: OAuthError.invalidRequest) {
          try await fixture.service.authorizeOAuthClient(pairingCode: pending.request.pairingCode)
        }
        await #expect(throws: OAuthError.invalidRequest) {
          try await fixture.server().status(statusToken: pairing.statusToken, address: "fixture")
        }
        await #expect(throws: OAuthError.invalidGrant) {
          try await fixture.server().token(
            [
              "grant_type": "authorization_code", "client_id": fixture.fields["client_id"]!,
              "redirect_uri": fixture.fields["redirect_uri"]!, "code": code,
              "code_verifier": String(repeating: "a", count: 43),
              "resource": fixture.configuration.resource,
            ], address: "delivered")
        }
        // A listener retaining the deleted profile's credential must refuse its token.
        let retained = GatewayHTTPRuntime(
          configuration: .init(), registry: RotationRegistry(), host: "127.0.0.1",
          port: profile.localPort, publicBaseURL: nil, accessCredential: credential)
        try await retained.startListening()
        do {
          #expect(try await fixture.post(port: profile.localPort, token: token) == 401)
          await retained.stop()
        } catch {
          await retained.stop()
          throw error
        }
        await fixture.gatewayService.stop()
      } catch {
        await revoking.resume()
        _ = await deleting.result
        _ = await starting.result
        try? await fixture.service.stop()
        await fixture.gatewayService.stop()
        throw error
      }
    }

    @Test(arguments: [false, true])
    func accessTokenRotationDuringStartupUsesTheCurrentCredential(rotateBeforeRead: Bool)
      async throws
    {
      let gate = SuspensionGate()
      let fixture = try ControlFixture(tokenDidRead: { await gate.pause() })
      defer { fixture.remove() }
      let profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      await fixture.secrets.setAsynchronously("synthetic-tunnel", for: profile.tunnelTokenReference)
      await fixture.secrets.setAsynchronously(
        "old-fixture-access", for: profile.accessTokenReference)
      var newToken: String?
      if rotateBeforeRead {
        newToken = try await fixture.service.saveCloudflareTunnelConfiguration(
          profile, tunnelToken: nil, regenerateAccessToken: true
        ).generatedAccessToken
      }
      let starting = Task {
        try await fixture.service.startCloudflareTunnel(
          profileID: profile.id, gatewayService: fixture.gatewayService)
      }
      await gate.waitUntilPaused()
      if !rotateBeforeRead {
        newToken = try await fixture.service.saveCloudflareTunnelConfiguration(
          profile, tunnelToken: nil, regenerateAccessToken: true
        ).generatedAccessToken
      }
      await gate.resume()
      do {
        _ = try await starting.value
        let current = try #require(newToken)
        #expect(try await fixture.post(port: profile.localPort, token: "old-fixture-access") == 401)
        #expect(try await fixture.post(port: profile.localPort, token: current) == 400)
        _ = try await fixture.service.stopCloudflareTunnel(profileID: profile.id)
        try await fixture.service.deleteCloudflareTunnelConfiguration(id: profile.id)
        #expect(await fixture.service.cloudflareAccessCredentials[profile.id] == nil)
        await fixture.gatewayService.stop()
      } catch {
        await gate.resume()
        _ = await starting.result
        try? await fixture.service.stop()
        await fixture.gatewayService.stop()
        throw error
      }
    }

    @Test func failedRotationRestoresTheCredentialAndSecretTogether() async throws {
      let fixture = try ControlFixture()
      defer { fixture.remove() }
      let profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      await fixture.secrets.setAsynchronously("synthetic-tunnel", for: profile.tunnelTokenReference)
      let original = try #require(
        try await fixture.service.saveCloudflareTunnelConfiguration(
          profile, tunnelToken: nil, regenerateAccessToken: true
        ).generatedAccessToken)
      let credential = try #require(await fixture.service.cloudflareAccessCredentials[profile.id])
      fixture.loader.rejectStagedManifest = true
      await #expect(throws: (any Error).self) {
        try await fixture.service.saveCloudflareTunnelConfiguration(
          profile, tunnelToken: nil, regenerateAccessToken: true)
      }
      fixture.loader.rejectStagedManifest = false
      #expect(
        await fixture.secrets.valueAsynchronously(
          for: profile.accessTokenReference, authenticationUI: .fail) == original)
      // A fresh listener shares the restored digest rather than reading a captured value.
      let runtime = GatewayHTTPRuntime(
        configuration: .init(), registry: RotationRegistry(), host: "127.0.0.1",
        port: profile.localPort, publicBaseURL: nil, accessCredential: credential)
      try await runtime.startListening()
      do {
        #expect(try await fixture.post(port: profile.localPort, token: original) == 400)
        await runtime.stop()
      } catch {
        await runtime.stop()
        throw error
      }
    }

    @Test func overlappingRotationWaitsForFailedSavesRollback() async throws {
      let fixture = try ControlFixture()
      defer { fixture.remove() }
      let profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
      await fixture.secrets.setAsynchronously("synthetic-tunnel", for: profile.tunnelTokenReference)
      let original = try #require(
        try await fixture.service.saveCloudflareTunnelConfiguration(
          profile, tunnelToken: nil, regenerateAccessToken: true
        ).generatedAccessToken)
      let credential = try #require(await fixture.service.cloudflareAccessCredentials[profile.id])
      let rollback = SuspensionGate()
      await fixture.secrets.pauseWrite(original, for: profile.accessTokenReference, gate: rollback)
      fixture.loader.rejectStagedManifest = true
      let failedSave = Task {
        try await fixture.service.saveCloudflareTunnelConfiguration(
          profile, tunnelToken: nil, regenerateAccessToken: true)
      }
      await rollback.waitUntilPaused()
      let failedToken = try #require(
        await fixture.secrets.valueAsynchronously(
          for: profile.accessTokenReference, authenticationUI: .fail))
      let readsDuringRollback = await fixture.secrets.readCount
      fixture.loader.rejectStagedManifest = false
      let successfulSave = Task {
        try await fixture.service.saveCloudflareTunnelConfiguration(
          profile, tunnelToken: nil, regenerateAccessToken: true)
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while await fixture.service.cloudflareCredentialMutationWaiters[profile.id]?.count != 1,
        ContinuousClock.now < deadline
      { await Task.yield() }
      #expect(await fixture.service.cloudflareCredentialMutationWaiters[profile.id]?.count == 1)
      #expect(await fixture.secrets.readCount == readsDuringRollback)
      await rollback.resume()
      await #expect(throws: (any Error).self) { try await failedSave.value }
      let current = try #require(try await successfulSave.value.generatedAccessToken)
      #expect(
        await fixture.secrets.valueAsynchronously(
          for: profile.accessTokenReference, authenticationUI: .fail) == current)
      #expect(await fixture.service.cloudflareAccessCredentials[profile.id] === credential)
      #expect(await fixture.service.cloudflareCredentialMutationWaiters[profile.id] == nil)
      let runtime = GatewayHTTPRuntime(
        configuration: .init(), registry: RotationRegistry(), host: "127.0.0.1",
        port: profile.localPort, publicBaseURL: nil, accessCredential: credential)
      try await runtime.startListening()
      do {
        #expect(try await fixture.post(port: profile.localPort, token: current) == 400)
        #expect(try await fixture.post(port: profile.localPort, token: original) == 401)
        #expect(try await fixture.post(port: profile.localPort, token: failedToken) == 401)
        await runtime.stop()
      } catch {
        await runtime.stop()
        throw error
      }
    }

  #endif

  @Test(arguments: [GatewayCallerKind.localApp, .localCLI])
  func ownerRevocationClosesTheLiveListenersStreams(caller: GatewayCallerKind) async throws {
    let fixture = try ControlFixture()
    defer { fixture.remove() }
    let profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
    let flow = fixture.server()
    let pairing = try await flow.authorize(fixture.fields, address: "fixture")
    let grant = try await fixture.service.authorizeOAuthClient(
      pairingCode: pairing.request.pairingCode)
    guard
      case .redirect(let callback) = try await flow.status(
        statusToken: pairing.statusToken, address: "fixture"),
      let code = URLComponents(string: callback)?.queryItems?.first(where: { $0.name == "code" })?
        .value
    else { throw OAuthError.invalidGrant }
    let tokens = try await flow.token(
      [
        "grant_type": "authorization_code", "client_id": fixture.fields["client_id"]!,
        "redirect_uri": fixture.fields["redirect_uri"]!, "code": code,
        "code_verifier": String(repeating: "a", count: 43),
        "resource": fixture.configuration.resource,
      ], address: "fixture")
    let listenerServer = await fixture.service.oauthServer(for: profile)
    let sessions = try #require(await fixture.service.cloudflareOAuthSessions[profile.id])
    let managed = GatewayHTTPManagedSessions(
      makeSession: { principal in
        GatewayControlSessionServing(
          base: RotationRegistry(),
          session: GatewayControlSession(
            principalID: principal, profileID: .cloudflareObserve, caller: .cloudflareTunnel))
      }, closeSession: { _ in }, shutdown: {},
      makeOAuthSession: { principal, selected in
        GatewayControlSessionServing(
          base: RotationRegistry(),
          session: GatewayControlSession(
            principalID: principal, profileID: selected, caller: .cloudflareTunnel))
      })
    let runtime = GatewayHTTPRuntime(
      configuration: .init(), source: .managed(managed), host: "127.0.0.1", port: profile.localPort,
      publicBaseURL: fixture.configuration.issuer, accessToken: "static-fixture",
      oauth: GatewayOAuthHTTP(server: listenerServer, sessions: sessions))
    try await runtime.startListening()
    let observer = OAuthStreamObserver()
    let session = URLSession(configuration: .ephemeral, delegate: observer, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      let initialized = try await fixture.postResponse(
        port: profile.localPort, token: tokens.accessToken, initialize: true)
      #expect(initialized.statusCode == 200)
      let id = try #require(initialized.value(forHTTPHeaderField: "MCP-Session-Id"))
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(profile.localPort)/mcp")!)
      request.setValue("gateway.example", forHTTPHeaderField: "Host")
      request.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization")
      request.setValue(id, forHTTPHeaderField: "MCP-Session-Id")
      request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
      session.dataTask(with: request).resume()
      var events = observer.events.makeAsyncIterator()
      #expect(await events.next() == .opened(200))
      // The service constructs another authorization server for this operation.
      try await fixture.service.revokeOAuthGrant(id: grant.id, approver: caller)
      #expect(await events.next() == .ended)
      #expect(await runtime.controlSessions().isEmpty)
      #expect(try await fixture.post(port: profile.localPort, token: tokens.accessToken) == 401)
      #expect(
        try fixture.database.auditEvents(limit: 100).contains {
          $0.capabilityID == "oauth.sessions_ended" && $0.caller == caller
        })
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  @Test func oauthContractsAreLocalAndValidateTheirArguments() throws {
    for id in [
      "clients.authorizations", "clients.authorize", "clients.deny", "clients.grants",
      "clients.revoke_grant",
    ] {
      let contract = try #require(GatewayClientControl.contracts.first { $0.name == id })
      let capability = try #require(AppControlCapabilityCatalog.byID[id])
      #expect(capability.localOnly)
      #expect(capability.surface == .appAndCLI)
      _ = try contract.tool()
      #expect(throws: (any Error).self) {
        try contract.validate(.object(["full_access": .bool(true)]))
      }
    }
    let approve = try #require(
      GatewayClientControl.contracts.first { $0.name == "clients.authorize" })
    _ = try approve.validate(
      .object([
        "pairing_code": .string("ABCDEF"),
        "authorization_digest": .string(String(repeating: "a", count: 64)),
      ]))
    #expect(throws: (any Error).self) {
      try approve.validate(
        .object(["pairing_code": .string("ABCDEF"), "authorization_digest": .integer(7)]))
    }
  }
}

private final class ControlFixture: Sendable {
  let root: URL
  let database: GatewayDatabase
  let loader: FixtureManifestLoader
  let service: AppControlPlaneService
  let operations: AppControlPlaneOperations
  let gatewayService: AppGatewayService
  let secrets = FixtureSecrets()
  let monitor = FixtureManifestMonitor()
  let configuration = OAuthServerConfiguration(
    tunnelID: "tunnel", tunnelName: "named", hostname: "gateway.example",
    clientAllowlist: ["client.example"])

  init(
    tokenDidRead: @escaping @Sendable () async throws -> Void = {},
    approvalWillCommit: @escaping @Sendable () throws -> Void = {},
    manifestWillPublish: @escaping @Sendable () async throws -> Void = {}
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "oauth-control-" + String(UUID().uuidString.prefix(12)))
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("Support"),
      logs: root.appendingPathComponent("Logs"))
    try directories.prepare()
    database = try GatewayDatabase(path: directories.database.path)
    let cloudflared = root.appendingPathComponent("cloudflared-fixture")
    try Data(
      """
      #!/bin/sh
      if [ "$1" = "version" ]; then echo 'cloudflared version 2026.1.0'; exit 0; fi
      trap 'exit 0' TERM INT
      while :; do sleep 1; done
      """.utf8
    ).write(to: cloudflared)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: cloudflared.path)
    var manifest = GatewayConfiguration()
    manifest.transports.cloudflare = [
      .init(
        id: "tunnel", tunnelName: "named", publicHostname: "gateway.example",
        localPort: try Self.availablePort(), metricsPort: try Self.availablePort(),
        cloudflaredPath: cloudflared.path, oauthEnabled: true,
        oauthClientAllowlist: ["client.example"])
    ]
    try Data(manifest.exportedTOML().utf8).write(to: directories.manifest)
    loader = FixtureManifestLoader(
      base: GatewayManifestConfigurationLoader(
        database: database, applications: TestApplicationBundleLocator()))
    let store = try AtomicManifestStore(
      manifestURL: directories.manifest, database: database, loader: loader)
    let monitor = monitor
    let platform = PlatformServices(
      launcher: testExecutionLauncher(),
      projectGrants: UnusedPlatform(), pluginDirectories: UnusedPlatform(),
      applications: TestApplicationBundleLocator(), toolProviders: UnusedPlatform(),
      managementToolNames: [],
      executableSearchDirectories: [], gitExecutable: "git",
      fileChanges: { _ in monitor })
    service = AppControlPlaneService(
      directories: directories, database: database, manifestStore: store,
      defaultManifest: try manifest.exportedTOML(), secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: testExecutionLauncher(),
        secretStore: secrets, executableSearchDirectories: [],
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()),
      launchAtLoginController: UnusedPlatform(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(), platform: platform,
      oauthApprovalWillCommit: approvalWillCommit, cloudflareAccessTokenDidRead: tokenDidRead)
    gatewayService = AppGatewayService(
      controlPlane: service,
      socketConfiguration: .init(socketURL: root.appendingPathComponent("gateway.sock")),
      manifestWillPublish: manifestWillPublish)
    operations = AppControlPlaneOperations(controlPlane: service, gatewayService: gatewayService)
  }

  var fields: [String: String] {
    [
      "response_type": "code", "client_id": "https://client.example/cimd",
      "redirect_uri": "https://consumer.example/callback", "state": "fixture",
      "code_challenge": OAuthSecret.challenge(String(repeating: "a", count: 43)),
      "code_challenge_method": "S256", "resource": configuration.resource,
    ]
  }
  func server(authorizationWillInsert: @escaping @Sendable () async throws -> Void = {})
    -> OAuthAuthorizationServer
  {
    OAuthAuthorizationServer(
      configuration: configuration, store: database,
      identifier: CIMDClientIdentifier(fetcher: ControlDocument()),
      authorizationWillInsert: authorizationWillInsert)
  }
  func approvedCode(_ flow: OAuthAuthorizationServer) async throws -> (OAuthGrant, String) {
    let pairing = try await flow.authorize(fields, address: UUID().uuidString)
    let grant = try await service.authorizeOAuthClient(pairingCode: pairing.request.pairingCode)
    guard
      case .redirect(let target) = try await flow.status(
        statusToken: pairing.statusToken, address: "fixture"),
      let code = URLComponents(string: target)?.queryItems?.first(where: { $0.name == "code" })?
        .value
    else { throw OAuthError.invalidGrant }
    return (grant, code)
  }
  func codeFields(_ code: String) -> [String: String] {
    [
      "grant_type": "authorization_code", "client_id": fields["client_id"]!,
      "redirect_uri": fields["redirect_uri"]!,
      "code": code, "code_verifier": String(repeating: "a", count: 43),
      "resource": configuration.resource,
    ]
  }
  func refreshFields(_ refresh: String) -> [String: String] {
    [
      "grant_type": "refresh_token", "client_id": fields["client_id"]!, "refresh_token": refresh,
      "resource": configuration.resource,
    ]
  }
  func restartedService() throws -> AppControlPlaneService {
    let directories = service.directories
    let database = try GatewayDatabase(path: directories.database.path)
    let store = try AtomicManifestStore(
      manifestURL: directories.manifest, database: database, loader: loader)
    return AppControlPlaneService(
      directories: directories, database: database, manifestStore: store,
      defaultManifest: service.defaultManifest, secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: testExecutionLauncher(),
        secretStore: secrets, executableSearchDirectories: [],
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()),
      launchAtLoginController: UnusedPlatform(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(), platform: service.platform)
  }
  func installOrigin(_ origin: GatewayHTTPRuntime, profile: CloudflareTunnelConfiguration) async {
    await service.installOrigin(origin, profile: profile)
  }
  func post(port: Int, token: String) async throws -> Int {
    try await postResponse(port: port, token: token).statusCode
  }
  func saveInput(for profile: CloudflareTunnelConfiguration) -> CloudflareTunnelConfigurationInput {
    .init(
      id: profile.id, tunnelName: profile.tunnelName, publicHostname: profile.publicHostname,
      gatewayProfile: profile.gatewayProfile, localPort: profile.localPort,
      metricsPort: profile.metricsPort, cloudflaredPath: profile.cloudflaredPath)
  }
  func postResponse(port: Int, token: String, initialize: Bool = false) async throws
    -> HTTPURLResponse
  {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    request.httpMethod = "POST"
    request.setValue("gateway.example", forHTTPHeaderField: "Host")
    request.timeoutInterval = 5
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = Data(
      (initialize
        ? #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"fixture","version":"1"}}}"#
        : "{}").utf8)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (_, response) = try await session.data(for: request)
    return try #require(response as? HTTPURLResponse)
  }
  private static func availablePort() throws -> Int {
    #if canImport(Darwin)
      let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    #else
      let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { throw FixtureFailure.unused }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        guard bind(descriptor, $0, length) == 0 else { return Int32(-1) }
        return getsockname(descriptor, $0, &length)
      }
    }
    guard result == 0 else { throw FixtureFailure.unused }
    return Int(in_port_t(bigEndian: address.sin_port))
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

private enum FixtureFailure: Error { case unused }

private actor FixtureSecrets: SecretStore {
  private var values: [String: String] = [:]
  private var pausedWrite: (String, SecretReference, SuspensionGate)?
  private(set) var readCount = 0
  func pauseWrite(_ secret: String, for reference: SecretReference, gate: SuspensionGate) {
    pausedWrite = (secret, reference, gate)
  }
  func setAsynchronously(_ secret: String, for reference: SecretReference) async {
    if let (value, target, gate) = pausedWrite, value == secret, target == reference {
      pausedWrite = nil
      await gate.pause()
    }
    values[reference.account] = secret
  }
  func valueAsynchronously(
    for reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) -> String? {
    readCount += 1
    return values[reference.account]
  }
  func containsAsynchronously(
    _ reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) -> Bool { values[reference.account] != nil }
  func deleteAsynchronously(_ reference: SecretReference) {
    values.removeValue(forKey: reference.account)
  }
}

private struct ControlDocument: CIMDFetching {
  func fetch(_ url: URL, maxBytes: Int, timeout: TimeInterval) async throws -> Data {
    Data(
      #"{"client_id":"https://client.example/cimd","redirect_uris":["https://consumer.example/callback"]}"#
        .utf8)
  }
}

private struct UnusedPlatform: ProjectBookmarkServicing, PluginArchiveDirectoryFactory,
  GatewayToolProviderFactory, LaunchAtLoginControlling
{
  func registerFolder(at url: URL, displayName: String?) throws -> RegisteredProject {
    throw FixtureFailure.unused
  }
  func resolve(_ project: RegisteredProject) throws -> ResolvedProjectAccess {
    throw ProjectBookmarkError.bookmarkResolutionFailed(projectID: project.id)
  }
  func create(at url: URL) throws -> any PluginArchiveStagingDirectory {
    throw FixtureFailure.unused
  }
  func recover(_ identity: PluginDirectoryIdentity) throws -> any PluginArchiveStagingDirectory {
    throw FixtureFailure.unused
  }
  func identity(url: URL, status: stat, descriptor: Int32) throws -> PluginDirectoryIdentity {
    throw FixtureFailure.unused
  }
  func matches(_ identity: PluginDirectoryIdentity, status: stat, descriptor: Int32) throws -> Bool
  { throw FixtureFailure.unused }
  func renameExclusively(
    from source: String, in sourceDirectory: Int32, to destination: String,
    in destinationDirectory: Int32
  ) throws { throw FixtureFailure.unused }
  func makeProviders(
    configuration: GatewayConfiguration, commandRunner: any CommandRunning,
    processManager: any ProcessManaging, shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient, hostContext: MCPHostContext
  ) -> GatewayToolRegistry {
    .init(providers: { [] }, downstreamPolicy: { _, _ in throw FixtureFailure.unused })
  }
  func state() -> LaunchAtLoginState { .unavailable }
  func setEnabled(_ enabled: Bool) throws { throw FixtureFailure.unused }
}

private actor SuspensionGate {
  private var paused = false
  private var resumed = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var operation: CheckedContinuation<Void, Never>?
  func pause() async {
    paused = true
    let waiters = pauseWaiters
    pauseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    if !resumed { await withCheckedContinuation { operation = $0 } }
  }
  func waitUntilPaused() async {
    if !paused { await withCheckedContinuation { pauseWaiters.append($0) } }
  }
  func resume() {
    resumed = true
    operation?.resume()
    operation = nil
  }
}

private struct RotationRegistry: GatewayToolServing {
  func listTools(context: InvocationContext) throws -> [MCPTool] { [] }
  func callTool(name: String, arguments: JSONValue?, context: InvocationContext) throws -> JSONValue
  { .null }
}

private final class FixtureManifestMonitor: FileChangeMonitor, Sendable {
  let changes: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  init() { (changes, continuation) = AsyncStream.makeStream() }
  func signal() { continuation.yield(()) }
  func close() async { continuation.finish() }
}

private struct GatedOriginStop: HTTPOriginLifecycle {
  let origin: any HTTPOriginLifecycle
  let gate: SuspensionGate
  func stop() async {
    await origin.stop()
    await gate.pause()
  }
}

extension AppControlPlaneService {
  fileprivate func pauseOriginStop(profileID: String, gate: SuspensionGate) throws {
    guard let origin = cloudflareRuntimes[profileID]?.origin else { throw FixtureFailure.unused }
    cloudflareRuntimes[profileID]?.origin = GatedOriginStop(origin: origin, gate: gate)
  }
  fileprivate func installOrigin(
    _ origin: GatewayHTTPRuntime, profile: CloudflareTunnelConfiguration
  ) {
    cloudflareRuntimes[profile.id] = .init(
      profile: profile, state: .running, process: nil, origin: origin, tokenFile: nil,
      stdoutHandle: nil, stderrHandle: nil, startedAt: Date(), lastError: nil)
  }
}

private final class FixtureManifestLoader: ManifestConfigurationLoading, @unchecked Sendable {
  private let base: any ManifestConfigurationLoading
  private let lock = NSLock()
  private var reject = false
  var rejectStagedManifest: Bool {
    get { lock.withLock { reject } }
    set { lock.withLock { reject = newValue } }
  }
  init(base: any ManifestConfigurationLoading) { self.base = base }
  func load(path: String) throws -> GatewayConfiguration {
    if rejectStagedManifest && URL(fileURLWithPath: path).lastPathComponent.contains(".staged.") {
      throw FixtureFailure.unused
    }
    return try base.load(path: path)
  }
}

private final class OAuthStreamObserver: NSObject, URLSessionDataDelegate, Sendable {
  enum Event: Equatable, Sendable {
    case opened(Int)
    case ended
  }
  let events: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation
  override init() {
    (events, continuation) = AsyncStream<Event>.makeStream()
    super.init()
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    continuation.yield(.opened((response as? HTTPURLResponse)?.statusCode ?? 0))
    completionHandler(.allow)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    continuation.yield(.ended)
    continuation.finish()
  }
}

// The gate pauses a synchronous SQLite write on its database queue.
private final class CommitGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var resumed = false
  private let entered: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  init() { (entered, continuation) = AsyncStream.makeStream() }
  func pause() {
    condition.lock()
    continuation.yield(())
    continuation.finish()
    while !resumed { condition.wait() }
    condition.unlock()
  }
  func waitUntilPaused() async { for await _ in entered { return } }
  func resume() {
    condition.lock()
    resumed = true
    condition.broadcast()
    condition.unlock()
  }
}
