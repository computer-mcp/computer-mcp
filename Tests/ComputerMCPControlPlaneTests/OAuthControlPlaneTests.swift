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
import Testing

@testable import ComputerMCPControlPlane

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

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

private final class ControlFixture {
  let root: URL
  let database: GatewayDatabase
  let service: AppControlPlaneService
  let operations: AppControlPlaneOperations
  let secrets = FixtureSecrets()
  let configuration = OAuthServerConfiguration(
    tunnelID: "tunnel", tunnelName: "named", hostname: "gateway.example",
    clientAllowlist: ["client.example"])

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "oauth-control-" + UUID().uuidString)
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("Support"),
      logs: root.appendingPathComponent("Logs"))
    try directories.prepare()
    database = try GatewayDatabase(path: directories.database.path)
    var manifest = GatewayConfiguration()
    manifest.transports.cloudflare = [
      .init(
        id: "tunnel", tunnelName: "named", publicHostname: "gateway.example", oauthEnabled: true,
        oauthClientAllowlist: ["client.example"])
    ]
    try Data(manifest.exportedTOML().utf8).write(to: directories.manifest)
    let store = try AtomicManifestStore(
      manifestURL: directories.manifest, database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database, applications: TestApplicationBundleLocator()))
    let platform = PlatformServices(
      workspaceGrants: UnusedPlatform(), pluginDirectories: UnusedPlatform(),
      applications: TestApplicationBundleLocator(), toolProviders: UnusedPlatform(),
      managementToolNames: [],
      executableSearchDirectories: [], gitExecutable: "git",
      fileChanges: { _ in throw FixtureFailure.unused })
    service = AppControlPlaneService(
      directories: directories, database: database, manifestStore: store,
      defaultManifest: try manifest.exportedTOML(), secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        secretStore: secrets, executableSearchDirectories: [],
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()),
      launchAtLoginController: UnusedPlatform(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(), platform: platform)
    operations = AppControlPlaneOperations(
      controlPlane: service,
      gatewayService: AppGatewayService(
        controlPlane: service,
        socketConfiguration: .init(socketURL: root.appendingPathComponent("gateway.sock"))))
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
