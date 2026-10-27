import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ComputerMCPApp
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPermissions

@MainActor
@Suite struct PrivacySecurityViewTests {
  @Test func answeringARequestRefreshesTheSnapshot() async throws {
    let service = PrivacySecurityFake()
    let model = PrivacySecurityModel(service: service)
    await model.refresh()
    let request = try #require(model.snapshot.requests.first)
    await model.answer(request, .onlyThisTime)
    #expect(service.answers == [request.id: .onlyThisTime])
    #expect(model.snapshot.requests.isEmpty)
  }

  @Test func registrationRequestsExplainWhatAllowingGrants() throws {
    let l = PrivacyText(locale: Locale(identifier: "en"))
    var request = try #require(PrivacySecurityFake.sample.requests.first)
    request.registration = .newProject
    #expect(request.object?.detail == "/Users/owner/Developer/site")
    #expect(
      PrivacyRequestPrompt.requesterCaption(for: request, using: l)
        == "git.worktree_add · Secure Tunnel")
    #expect(
      PrivacyRequestPrompt.detail(for: request, using: l)
        == "Allowing registers this folder as a project and gives “ChatGPT” access to it and its worktrees until you revoke it."
    )
    request.registration = .existingProject
    #expect(
      PrivacyRequestPrompt.detail(for: request, using: l)
        == "Allowing gives “ChatGPT” access to this project and all its worktrees until you revoke it."
    )
  }

  @Test func holdersCountGrantedPrincipalsOnly() async {
    let model = PrivacySecurityModel(service: PrivacySecurityFake())
    await model.refresh()
    #expect(model.holders(of: .projects) == 2)
    #expect(model.holders(of: .screen) == 1)
    #expect(model.holders(of: .unifiedLogs) == 0)
    #expect(model.holders(of: .fullAccess) == 1)
  }

  @Test func networkEditsRefreshTheProjectGrant() async throws {
    let service = PrivacySecurityFake()
    let model = PrivacySecurityModel(service: service)
    await model.refresh()
    let grant = try #require(model.snapshot.grants.first { $0.permission == .projects })
    for network: PrivacyNetworkAccess in [
      .trusted, .full, .none,
      .custom(hosts: ["api.example.com", "*.example.org"], includesTrusted: true),
    ] {
      #expect(await model.setNetwork(grant, to: network))
      #expect(
        model.snapshot.grants.first { $0.id == grant.id }?.network == (try network.validated()))
    }
    #expect(service.networkWrites == 4)
  }

  @Test func customHostsAcceptSeparatorsAndNormalizeWildcardsAndAddresses() throws {
    var draft = PrivacyNetworkDraft(.trusted)
    draft.hosts = " API.Example.COM, *.Example.ORG\n127.0.0.1, [2001:db8::1]\napi.example.com, "
    #expect(
      try draft.network()
        == .custom(
          hosts: ["*.example.org", "127.0.0.1", "2001:db8::1", "api.example.com"],
          includesTrusted: true))
    draft.includesTrusted = false
    let network = try draft.network()
    let reopened = PrivacyNetworkDraft(network)
    #expect(try reopened.network() == network)
    #expect(!reopened.includesTrusted)
  }

  @Test(arguments: [
    "https://example.com/path", "bad host", "*.", "a..com", "host:443", "999.1.1.1",
  ])
  func invalidHostsDoNotWriteOrChangeTheSnapshot(_ host: String) async throws {
    let service = PrivacySecurityFake()
    let model = PrivacySecurityModel(service: service)
    await model.refresh()
    let original = model.snapshot
    let grant = try #require(original.grants.first)
    var draft = PrivacyNetworkDraft(.none)
    draft.hosts = host
    #expect(throws: (any Error).self) { try draft.network() }
    #expect(!(await model.setNetwork(grant, to: .custom(hosts: [host], includesTrusted: false))))
    #expect(service.networkWrites == 0)
    #expect(model.snapshot == original)
    #expect(model.failure != nil)
  }

  @Test func failedNetworkSaveKeepsTheSnapshotAndReportsFailure() async throws {
    let service = PrivacySecurityFake()
    let model = PrivacySecurityModel(service: service)
    await model.refresh()
    let original = model.snapshot
    let grant = try #require(original.grants.first)
    service.failNetworkSave = true
    #expect(!(await model.setNetwork(grant, to: .full)))
    #expect(service.networkWrites == 1)
    #expect(model.snapshot == original)
    #expect(model.failure != nil)
  }

  @Test func managedLimitsRemoveValuesAndKeepTheirSources() throws {
    var profile = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    try profile.permissions.set(.granted(.write), for: .project("p1"))
    let grants = LivePrivacySecurityService.grants(
      profile, names: .init(projects: ["p1": "Project"]),
      paths: ["p1": "/Users/owner/Project"], limits: try Self.limits())
    let project = try #require(grants.first { $0.object?.id == "p1" })
    #expect(project.availableLevels == [.read])
    #expect(project.value == .granted(.read))
    #expect(project.allowsNetwork(.trusted))
    #expect(!project.allowsNetwork(.full))
    #expect(!project.allowsNetwork(.custom(hosts: ["other.example"], includesTrusted: false)))
    let screen = try #require(grants.first { $0.permission == .screen })
    #expect(screen.availableLevels.isEmpty)
    #expect(screen.source == .managedLimit("Machine Policy"))
    #expect(LivePrivacySecurityService.fullAccessSources(try Self.limits()) == ["Machine Policy"])
    let denied = LivePrivacySecurityService.grants(
      profile, names: .init(projects: ["p1": "Project"]),
      paths: ["p1": "/Users/owner/Project"],
      limits: [
        ManagedLimits(
          machine: .available(
            ManagedPolicy(deniedReadLocations: [try CanonicalPath("/Users/owner")])))
      ])
    #expect(denied.first { $0.object?.id == "p1" }?.availableLevels.isEmpty == true)
  }

  @Test func principalCatalogIncludesEveryPermissionAndKnownObject() {
    let rows = LivePrivacySecurityService.grants(
      .init(id: .chatGPTOperate, allowedCallers: [.secureTunnel]),
      names: .init(
        projects: ["p1": "Project"],
        plugins: ["plugin": "Plugin"], mcpServers: ["server": "Server"]))
    #expect(rows.allSatisfy { $0.value == .ask && !$0.isStored })
    #expect(
      Set(rows.map(\.permission))
        == Set(PrivacyPermissionKind.allCases.filter { $0 != .fullAccess }))
    #expect(
      rows.filter { $0.permission == .filesAndFolders }.count == FolderCategory.allCases.count)
    #expect(rows.contains { $0.permission == .projects && $0.object?.id == "*" })
    #expect(rows.contains { $0.permission == .plugins && $0.object?.id == "plugin" })
    #expect(rows.contains { $0.permission == .mcpServers && $0.object?.id == "server" })
  }

  @Test func pluginRequestsWithoutProfilesRemainAnswerable() async throws {
    let principal = Principal.plugin(.package("plugin"))
    let content = PermissionRequestContent(
      principal: principal,
      requirement: try PermissionRequirement(.screen, .access), scope: .principal)
    let request = PermissionRequest(
      identity: BasisIdentity(),
      invocation: InvocationIdentity(
        principal: principal, tool: "screen.capture", projectID: nil, argumentsDigest: "digest"),
      content: .permission(content), now: Date(), requirements: .init(actions: []), basis: [])
    let mapped = try #require(
      LivePrivacySecurityService.request(
        .init(request: request, profileID: nil, alwaysIsShared: false), principals: [],
        names: .init(plugins: ["plugin": "Screen Helper"])))
    #expect(mapped.principal.name == "Screen Helper")
    #expect(mapped.principal.kind == .plugin(version: ""))
    let service = PrivacySecurityFake()
    service.current.requests = [mapped]
    let model = PrivacySecurityModel(service: service)
    await model.refresh()
    await model.answer(mapped, .always)
    #expect(service.answers[mapped.id] == .always)
    #expect(model.snapshot.requests.isEmpty)
    #expect(
      LivePrivacySecurityService.invocationPrincipal(
        .plugin(.localServer("server")),
        names: .init(mcpServers: ["server": "Local Server"])
      ).kind == .localServer)
  }

  @Test func failedWritesRefreshTheOwnersView() async throws {
    let service = PrivacySecurityFake()
    let model = PrivacySecurityModel(service: service)
    await model.refresh()
    let grant = try #require(model.snapshot.grants.first)
    service.current.revision += 1
    service.failNetworkSave = true
    #expect(!(await model.setNetwork(grant, to: .full)))
    #expect(model.snapshot.revision == service.current.revision)
    #expect(model.failure != nil)
  }

  @Test func fullAccessEligibilityAndConsentHaveDistinctStates() async throws {
    let service = PrivacyConnectionsFake()
    let model = ClientAccessModel(controlPlane: service)
    await model.reload()
    let principal = service.principal
    #expect(model.privacyExecutionTitle(for: principal) == "Full Access Allowed")
    #expect(service.session(nil).privacyExecutionTitle == "Sandbox")
    service.sessions = [service.session(.thisSession)]
    await model.reload()
    #expect(model.privacyExecutionTitle(for: principal) == "Full Access for This Session")
    service.sessions = [service.session(.alwaysAllowClient)]
    await model.reload()
    #expect(model.privacyExecutionTitle(for: principal) == "Full Access")
    model.requestFullAccess(service.sessions[0])
    #expect(model.pendingConsent?.lifetime == .thisSession)
    #expect(model.pendingConsent?.trustRevision == 2)
    service.sessions = [service.session(nil, restricted: true)]
    await model.reload()
    #expect(!model.consentIsCurrent)
    model.pendingConsent = nil
    model.requestFullAccess(service.sessions[0])
    #expect(model.pendingConsent == nil)
  }

  private static func limits() throws -> [ManagedLimits] {
    var ceilings = Permissions()
    try ceilings.set(.granted(.read), for: .project("*"))
    try ceilings.set(.denied, for: .screen)
    return [
      ManagedLimits(
        machine: .available(
          ManagedPolicy(
            permissionCeilings: ceilings,
            allowsFullAccess: false, network: .trusted)))
    ]
  }

  @Test func rendersInBothLanguagesAndAppearances() async throws {
    let model = PrivacySecurityModel(service: PrivacySecurityFake())
    await model.refresh()
    let resources = try Self.compiledCatalog()
    defer { try? FileManager.default.removeItem(at: resources.bundleURL) }
    let request = try #require(model.snapshot.requests.first)
    for (locale, dark) in [("en", false), ("zh-Hans", true)] {
      let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
      let suffix = "\(locale)-\(dark ? "dark" : "light")"
      try render(
        PrivacySecurityView(model: model).styled(locale, dark, resources),
        size: NSSize(width: 720, height: 1100), appearance: appearance,
        name: "privacy-home-" + suffix)
      try render(
        NavigationStack { PrivacyPermissionDetailView(model: model, permission: .projects) }
          .styled(locale, dark, resources),
        size: NSSize(width: 720, height: 640), appearance: appearance,
        name: "privacy-projects-" + suffix)
      try render(
        NavigationStack { PrivacyPrincipalDetailView(model: model, principalID: "chatgpt") }
          .styled(locale, dark, resources),
        size: NSSize(width: 720, height: 900), appearance: appearance,
        name: "privacy-chatgpt-" + suffix)
      let grant = try #require(model.snapshot.grants.first { $0.permission == .projects })
      try render(
        Form { PrivacyNetworkPicker(model: model, grant: grant) }
          .formStyle(.grouped).styled(locale, dark, resources),
        size: NSSize(width: 440, height: 120), appearance: appearance,
        name: "privacy-network-picker-" + suffix)
      try render(
        PrivacyNetworkSheet(
          network: .custom(
            hosts: ["api.example.com", "*.example.org"], includesTrusted: true)
        ) { _ in true }
        .styled(locale, dark, resources),
        size: NSSize(width: 488, height: 380), appearance: appearance,
        name: "privacy-network-custom-" + suffix)
      try render(
        PrivacyRequestPrompt(request: request) { _ in }.styled(locale, dark, resources),
        size: NSSize(width: 388, height: 600), appearance: appearance,
        name: "privacy-prompt-" + suffix)
      var registration = request
      registration.registration = .newProject
      try render(
        PrivacyRequestPrompt(request: registration) { _ in }.styled(locale, dark, resources),
        size: NSSize(width: 388, height: 600), appearance: appearance,
        name: "privacy-registration-" + suffix)
      let managedService = PrivacySecurityFake()
      var profile = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
      try profile.permissions.set(.granted(.write), for: .project("p1"))
      let managedPrincipal = PrivacyPrincipal(
        id: profile.id.rawValue, name: "ChatGPT",
        kind: .client(connection: "Secure Tunnel"), execution: .sandbox,
        fullAccessLimitSources: ["Machine Policy"])
      managedService.current.principals = [managedPrincipal]
      managedService.current.grants = LivePrivacySecurityService.grants(
        profile,
        names: .init(projects: ["p1": "Project"]), limits: try Self.limits())
      let managedModel = PrivacySecurityModel(service: managedService)
      await managedModel.refresh()
      try render(
        NavigationStack {
          PrivacyPrincipalDetailView(model: managedModel, principalID: managedPrincipal.id)
        }
        .styled(locale, dark, resources),
        size: NSSize(width: 720, height: 1600), appearance: appearance,
        name: "privacy-managed-" + suffix)
      var revokedPrincipal = managedPrincipal
      revokedPrincipal.fullAccessLimitSources = []
      managedService.current.principals = [revokedPrincipal]
      managedService.current.grants = LivePrivacySecurityService.grants(
        .init(id: .chatGPTOperate, allowedCallers: [.secureTunnel]),
        names: .init(
          projects: ["p1": "Project"],
          plugins: ["helper": "Helper"], mcpServers: ["server": "Local Server"]))
      await managedModel.refresh()
      try render(
        NavigationStack {
          PrivacyPrincipalDetailView(model: managedModel, principalID: managedPrincipal.id)
        }
        .styled(locale, dark, resources),
        size: NSSize(width: 720, height: 1800), appearance: appearance,
        name: "privacy-revoked-" + suffix)
      let connectionsService = PrivacyConnectionsFake()
      connectionsService.sessions = [connectionsService.session(.thisSession)]
      let connections = ClientAccessModel(controlPlane: connectionsService)
      await connections.reload()
      try render(
        Form {
          PrivacyConnectionsSection(model: connections, principal: connectionsService.principal)
        }
        .formStyle(.grouped).styled(locale, dark, resources),
        size: NSSize(width: 720, height: 420), appearance: appearance,
        name: "privacy-connections-" + suffix)
      connections.requestFullAccess(connectionsService.sessions[0])
      let draft = try #require(connections.pendingConsent)
      try render(
        ClientConsentView(model: connections, draftID: draft.id).styled(locale, dark, resources),
        size: NSSize(width: 548, height: 580), appearance: appearance,
        name: "privacy-consent-" + suffix)
      try render(
        Form {
          PrivacyClientExecutionLabel(model: connections, principal: connectionsService.principal)
        }
        .formStyle(.grouped).styled(locale, dark, resources),
        size: NSSize(width: 440, height: 120), appearance: appearance,
        name: "privacy-full-access-" + suffix)
      connectionsService.sessions = []
      await connections.reload()
      try render(
        Form {
          PrivacyClientExecutionLabel(model: connections, principal: connectionsService.principal)
        }
        .formStyle(.grouped).styled(locale, dark, resources),
        size: NSSize(width: 440, height: 120), appearance: appearance,
        name: "privacy-full-access-allowed-" + suffix)
      let pluginRequest = PrivacyRequest(
        id: "plugin-request",
        principal: .init(
          id: "plugin/helper",
          name: "Screen Helper", kind: .plugin(version: ""), execution: .sandbox),
        permission: .screen, object: nil, level: .allow, purpose: nil,
        tool: "screen.capture", expires: .distantFuture)
      try render(
        PrivacyRequestPrompt(request: pluginRequest) { _ in }.styled(locale, dark, resources),
        size: NSSize(width: 388, height: 600), appearance: appearance,
        name: "privacy-plugin-request-" + suffix)

    }
  }
}

extension PrivacySecurityViewTests {
  /// SwiftPM copies the String Catalog uncompiled; compile it as the App build does.
  fileprivate static func compiledCatalog() throws -> Bundle {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("PrivacySecurityViewTests-\(UUID().uuidString)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
      "xcstringstool", "compile",
      root.appendingPathComponent("Sources/ComputerMCPApp/Resources/Localizable.xcstrings").path,
      "--output-directory", output.path, "--serialization-format", "binary",
    ]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return try #require(Bundle(url: output))
  }
}

extension View {
  fileprivate func styled(_ locale: String, _ dark: Bool, _ resources: Bundle) -> some View {
    environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.locale, Locale(identifier: locale))
      .environment(\.localizationResources, resources)
  }
}

@MainActor
private final class PrivacySecurityFake: PrivacySecurityService {
  var current = PrivacySecurityFake.sample
  var answers: [String: PrivacyRequestAnswer] = [:]
  var networkWrites = 0
  var failNetworkSave = false

  func privacySnapshot() async throws -> PrivacySnapshot { current }

  func answer(request id: String, with answer: PrivacyRequestAnswer, reviewed: PrivacySnapshot)
    async throws
  {
    answers[id] = answer
    current.requests.removeAll { $0.id == id }
  }

  func setGrant(_ grant: PrivacyGrant, reviewed: PrivacySnapshot) async throws {
    current.grants.removeAll { $0.id == grant.id }
    current.grants.append(grant)
  }

  func setNetwork(
    _ grant: PrivacyGrant, to network: PrivacyNetworkAccess, reviewed: PrivacySnapshot
  ) async throws {
    networkWrites += 1
    if failNetworkSave { throw CancellationError() }
    for index in current.grants.indices where current.grants[index].id == grant.id {
      current.grants[index].network = network
    }
  }

  func revokeAll(principalID: String, reviewed: PrivacySnapshot) async throws {
    for index in current.grants.indices where current.grants[index].principalID == principalID {
      current.grants[index].value = .ask
    }
  }

  func setExecution(
    principalID: String, to execution: PrivacyPrincipal.Execution, reviewed: PrivacySnapshot
  ) async throws {
    for index in current.principals.indices where current.principals[index].id == principalID {
      current.principals[index].execution = execution
    }
  }

  func confirmRestoredPermissions(reviewed: PrivacySnapshot) async throws {
    current.suspendedForReview = false
  }

  func openSystemSettings(for permission: PrivacySystemPermission.Kind) {}

  static var sample: PrivacySnapshot {
    let chatgpt = PrivacyPrincipal(
      id: "chatgpt", name: "ChatGPT", kind: .client(connection: "Secure Tunnel"),
      execution: .sandbox)
    let claude = PrivacyPrincipal(
      id: "claude-code", name: "Claude Code", kind: .client(connection: "This Mac"),
      execution: .fullAccessAllowed)
    let codex = PrivacyPrincipal(
      id: "codex", name: "Codex", kind: .plugin(version: "1.4.0"), execution: .sandbox)
    let host = PrivacyObject(
      id: "p1", name: "computer-mcp", detail: "/Users/owner/Developer/workspace/tools/computer-mcp")
    let site = PrivacyObject(
      id: "p2", name: "computer-mcp.github.io", detail: "/Users/owner/Developer/site")
    return PrivacySnapshot(
      requests: [
        PrivacyRequest(
          id: "r1", principal: chatgpt, permission: .projects, object: site, level: .readWrite,
          purpose: nil, tool: "git.worktree_add", expires: .distantFuture)
      ],
      principals: [chatgpt, claude, codex],
      grants: [
        PrivacyGrant(
          principalID: "chatgpt", permission: .projects, object: host,
          value: .granted(.readWrite), network: PrivacyNetworkAccess.none),
        PrivacyGrant(
          principalID: "codex", permission: .projects, object: host, value: .granted(.readWrite),
          network: .custom(hosts: ["api.openai.com", "chatgpt.com"], includesTrusted: false),
          source: .pluginDeclaration),
        PrivacyGrant(
          principalID: "claude-code", permission: .projects, object: site, value: .ask),
        PrivacyGrant(
          principalID: "chatgpt", permission: .screen, object: nil, value: .granted(.allow)),
        PrivacyGrant(principalID: "chatgpt", permission: .desktopControl, object: nil, value: .ask),
        PrivacyGrant(principalID: "chatgpt", permission: .unifiedLogs, object: nil, value: .denied),
        PrivacyGrant(
          principalID: "chatgpt", permission: .localNetwork, object: nil, value: .denied,
          source: .managedLimit("Machine Policy")),
      ],
      managedSources: [
        PrivacyManagedSource(
          id: "machine", name: "Machine Policy",
          location: "/Library/Application Support/Computer MCP/policy.toml", state: .active)
      ],
      systemPermissions: [
        PrivacySystemPermission(kind: .screenRecording, state: .allowed),
        PrivacySystemPermission(kind: .accessibility, state: .notDetermined),
      ])
  }
}

@MainActor
private final class PrivacyConnectionsFake: ClientAccessManaging {
  let profile = GatewayControlProfile(
    grant: .init(
      id: .chatGPTOperate,
      fullAccess: true, allowedCallers: [.secureTunnel]), persisted: false)
  var principal: PrivacyPrincipal {
    .init(
      id: profile.grant.id.rawValue, name: "ChatGPT", kind: .client(connection: "Secure Tunnel"),
      execution: .fullAccessAllowed)
  }
  var sessions: [GatewayControlSessionSnapshot] = []
  func session(_ lifetime: GatewayFullAccessLifetime?, restricted: Bool = false)
    -> GatewayControlSessionSnapshot
  {
    .init(
      id: "session", principalID: "client", profileID: .chatGPTOperate, caller: .secureTunnel,
      revision: 1, accessLimit: .init(allowsFullAccess: !restricted), ended: false,
      fullAccessConsent: lifetime.map {
        .init(
          lifetime: $0, grantedAt: .now, profile: profile,
          trustID: nil, trustRevision: nil)
      }, profile: profile)
  }
  func fetchClientAccess() async throws -> ClientAccessSnapshot {
    .init(
      sessions: sessions,
      trusts: [
        .init(
          id: "trust", principalID: "client", profileID: .chatGPTOperate,
          caller: .secureTunnel, revision: 2, profile: profile, fullAccessAllowed: true,
          updatedAt: .now)
      ])
  }
}
