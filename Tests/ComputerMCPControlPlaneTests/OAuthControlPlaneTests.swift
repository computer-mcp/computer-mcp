import ComputerMCPAuthorization
import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPGateway
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPTunnels
import Foundation
import MCP
import Testing

@testable import ComputerMCPControlPlane

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
  func accessTokenRotationDuringStartupUsesTheCurrentCredential(rotateBeforeRead: Bool) async throws
  {
    let gate = StartupTokenGate()
    let fixture = try ControlFixture(tokenDidRead: { await gate.pause() })
    defer { fixture.remove() }
    let profile = try #require(try await fixture.service.cloudflareTunnelConfigurations().first)
    await fixture.secrets.setAsynchronously("synthetic-tunnel", for: profile.tunnelTokenReference)
    await fixture.secrets.setAsynchronously("old-fixture-access", for: profile.accessTokenReference)
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
    await gate.waitUntilRead()
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
  let configuration = OAuthServerConfiguration(
    tunnelID: "tunnel", tunnelName: "named", hostname: "gateway.example",
    clientAllowlist: ["client.example"])

  init(tokenDidRead: @escaping @Sendable () async throws -> Void = {}) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "oauth-control-" + UUID().uuidString)
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
    let platform = PlatformServices(
      workspaceGrants: UnusedPlatform(), pluginDirectories: UnusedPlatform(),
      applications: TestApplicationBundleLocator(), toolProviders: UnusedPlatform(),
      managementToolNames: [],
      executableSearchDirectories: [], gitExecutable: "git",
      fileChanges: { _ in QuietManifestMonitor() })
    service = AppControlPlaneService(
      directories: directories, database: database, manifestStore: store,
      defaultManifest: try manifest.exportedTOML(), secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        secretStore: secrets, executableSearchDirectories: [],
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()),
      launchAtLoginController: UnusedPlatform(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(), platform: platform,
      cloudflareAccessTokenDidRead: tokenDidRead)
    gatewayService = AppGatewayService(
      controlPlane: service,
      socketConfiguration: .init(socketURL: root.appendingPathComponent("gateway.sock")))
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
  func server() -> OAuthAuthorizationServer {
    OAuthAuthorizationServer(
      configuration: configuration, store: database,
      identifier: CIMDClientIdentifier(fetcher: ControlDocument()))
  }
  func post(port: Int, token: String) async throws -> Int {
    try await postResponse(port: port, token: token).statusCode
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
  func setAsynchronously(_ secret: String, for reference: SecretReference) {
    values[reference.account] = secret
  }
  func valueAsynchronously(
    for reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) -> String? { values[reference.account] }
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

private struct UnusedPlatform: WorkspaceBookmarkServicing, PluginArchiveDirectoryFactory,
  GatewayToolProviderFactory, LaunchAtLoginControlling
{
  func registerFolder(at url: URL, displayName: String?) throws -> RegisteredWorkspace {
    throw FixtureFailure.unused
  }
  func resolve(_ workspace: RegisteredWorkspace) throws -> ResolvedWorkspaceAccess {
    throw FixtureFailure.unused
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

private actor StartupTokenGate {
  private var read = false
  private var resumed = false
  private var readWaiters: [CheckedContinuation<Void, Never>] = []
  private var startup: CheckedContinuation<Void, Never>?
  func pause() async {
    read = true
    let waiters = readWaiters
    readWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    if !resumed { await withCheckedContinuation { startup = $0 } }
  }
  func waitUntilRead() async {
    if !read { await withCheckedContinuation { readWaiters.append($0) } }
  }
  func resume() {
    resumed = true
    startup?.resume()
    startup = nil
  }
}

private struct RotationRegistry: GatewayToolServing {
  func listTools(context: InvocationContext) throws -> [MCPTool] { [] }
  func callTool(name: String, arguments: JSONValue?, context: InvocationContext) throws -> JSONValue
  { .null }
}

private struct QuietManifestMonitor: FileChangeMonitor {
  var changes: AsyncStream<Void> { AsyncStream { _ in } }
  func close() async {}
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
