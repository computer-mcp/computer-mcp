import AppKit
import CoreML
import CryptoKit
import Foundation
import SwiftUI
import Testing
import Vision

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
    #expect(request.object?.detail == "/Users/example/Developer/site")
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

  @Test func requestShortcutsUseTheActionsForThatRequestType() async throws {
    let application = NSApplication.shared
    var request = try #require(PrivacySecurityFake.sample.requests.first)
    for registration in [PrivacyRequest.Registration?.none, .newProject, .existingProject] {
      request.registration = registration
      let approvals: [PrivacyRequestAnswer] =
        registration == nil ? [.onlyThisTime, .always] : [.always]
      #expect(request.approvalAnswers == approvals)
      for (key, code, answer) in [("\r", UInt16(36), approvals[0]), ("\u{1b}", 53, .dontAllow)] {
        var selected: PrivacyRequestAnswer?
        let window = NSWindow(
          contentViewController: NSHostingController(
            rootView: PrivacyRequestPrompt(request: request) { selected = $0 }))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderBack(nil)
        window.makeKey()
        application.updateWindows()
        window.contentView?.layoutSubtreeIfNeeded()
        let event = try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
        #expect(window.performKeyEquivalent(with: event))
        for _ in 0..<10 where selected == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(selected == answer)
      }
    }
  }

  @Test func sharedWorktreeGrantResolvesTheOriginalProfileAndProject() async throws {
    let profile = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    let owner = PrivacyPrincipal(
      id: profile.id.rawValue, name: "Profile",
      kind: .client(connection: "Secure Tunnel"), execution: .sandbox)
    let client = PrivacyPrincipal(
      id: "client/individual", name: "Individual",
      kind: .client(connection: "Secure Tunnel"), execution: .sandbox,
      sharedProfileID: profile.id)
    let names = PermissionObjectNames(projects: ["parent": "Parent", "child": "Worktree"])
    let sources = ["child": "parent"]
    let ownerRows = LivePrivacySecurityService.grants(
      profile, names: names, sourceProjects: sources)
    let clientRows = LivePrivacySecurityService.grants(
      profile, names: names, sourceProjects: sources, principalID: client.id)
    let service = PrivacySecurityFake()
    service.current = PrivacySnapshot(principals: [owner, client], grants: ownerRows + clientRows)
    let model = PrivacySecurityModel(service: service)
    await model.refresh()
    let child = try #require(
      model.grants(for: .projects, includingUnset: true).first {
        $0.principalID == client.id && $0.object?.id == "child"
      })
    #expect(!model.canEdit(child))
    let original = try #require(model.sourceGrant(for: child))
    #expect(original.principalID == owner.id && original.object?.id == "parent")
    #expect(model.canEdit(original))
    #expect(model.sourceGrant(for: original) == nil)
  }

  @Test func holdersCountGrantedPrincipalsOnly() async {
    let model = PrivacySecurityModel(service: PrivacySecurityFake())
    await model.refresh()
    #expect(model.holders(of: .projects) == 2)
    #expect(model.holders(of: .screen) == 1)
    #expect(model.holders(of: .unifiedLogs) == 0)
    #expect(model.holders(of: .fullAccess) == 1)
  }

  @Test func h12WorktreeGrantInheritsSourceAndWildcardNetworkWithEffectiveCeilings() throws {
    var profile = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    try profile.permissions.set(.granted(.write), for: .project("*"))
    try profile.permissions.set(.granted(.write), for: .project("source"))
    try profile.permissions.set(.denied, for: .project("worktree"))
    profile.projectNetworks["*"] = .full
    profile.projectNetworks["worktree"] = NetworkAccess.none

    var ceilings = Permissions()
    try ceilings.set(.denied, for: .screen)
    try ceilings.set(.granted(.read), for: .project("source"))
    let limits = ManagedLimits(
      machine: .available(.init(permissionCeilings: ceilings, network: .trusted)))
    let rows = LivePrivacySecurityService.grants(
      profile, names: .init(projects: ["source": "Source", "worktree": "Worktree"]),
      limits: [limits], trustedHosts: ["trusted.example"], sourceProjects: ["worktree": "source"])
    let child = try #require(rows.first { $0.object?.id == "worktree" })
    #expect(child.sourceProjectID == "source" && child.inheritsProjectAuthority)
    #expect(child.choice == .inherited)
    #expect(child.value == .granted(.readWrite))
    #expect(child.effectiveValue == .granted(.read))
    #expect(child.network == .full)
    #expect(child.effectiveNetwork == .custom(hosts: ["trusted.example"], includesTrusted: false))
    let wildcard = try #require(rows.first { $0.permission == .projects && $0.object?.id == "*" })
    #expect(wildcard.effectiveValue == .granted(.readWrite))
    #expect(!wildcard.availableLevels.contains(.readWrite))
    let screen = try #require(rows.first { $0.permission == .screen })
    #expect(screen.value == .ask && screen.effectiveValue == .denied)
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
      paths: ["p1": "/Users/example/Project"], limits: try Self.limits())
    let project = try #require(grants.first { $0.object?.id == "p1" })
    #expect(project.availableLevels == [.read])
    let wildcard = try #require(grants.first { $0.permission == .projects && $0.object?.id == "*" })
    #expect(wildcard.availableLevels == [.read])
    #expect(wildcard.limitNotices == [.init(source: "Machine Policy", effect: .permission(.read))])
    #expect(project.value == .granted(.readWrite))
    #expect(project.limitNotices == [.init(source: "Machine Policy", effect: .permission(.read))])
    #expect(project.allowsNetwork(.trusted))
    #expect(!project.allowsNetwork(.full))
    #expect(!project.allowsNetwork(.custom(hosts: ["other.example"], includesTrusted: false)))
    let screen = try #require(grants.first { $0.permission == .screen })
    #expect(screen.availableLevels.isEmpty)
    #expect(screen.value == .ask)
    #expect(screen.limitNotices == [.init(source: "Machine Policy", effect: .permission(nil))])
    #expect(LivePrivacySecurityService.fullAccessSources(try Self.limits()) == ["Machine Policy"])
    let denied = LivePrivacySecurityService.grants(
      profile, names: .init(projects: ["p1": "Project"]),
      paths: ["p1": "/Users/example/Project"],
      limits: [
        ManagedLimits(
          machine: .available(
            ManagedPolicy(deniedReadLocations: [try CanonicalPath("/Users/example")])))
      ])
    #expect(denied.first { $0.object?.id == "p1" }?.availableLevels.isEmpty == true)
  }

  @Test func unreadablePolicyKeepsSavedPermissionsAndNetworkForRestoration() throws {
    var profile = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    try profile.permissions.set(.granted(.write), for: .project("p1"))
    try profile.permissions.set(.granted(.access), for: .screen)
    profile.projectNetworks["p1"] = .full
    let rows = LivePrivacySecurityService.grants(
      profile, names: .init(projects: ["p1": "Project"]),
      limits: [ManagedLimits(owner: .unreadable)])
    let project = try #require(rows.first { $0.object?.id == "p1" })
    #expect(project.value == .granted(.readWrite))
    #expect(project.network == .full)
    #expect(project.availableLevels.isEmpty)
    #expect(!project.allowsNetwork(.full))
    #expect(project.limitNotices == [.init(source: "Owner Policy", effect: .unreadable)])
    #expect(project.networkLimitNotices == project.limitNotices)
    #expect(rows.first { $0.permission == .screen }?.value == .granted(.allow))
    let l = PrivacyText(locale: Locale(identifier: "en"))
    #expect(
      project.limitNotices.first?.text(using: l) == "Not allowed while Owner Policy can't be read")
  }

  @Test func customNetworkUsesTheGatewaysTrustedHosts() throws {
    let rows = LivePrivacySecurityService.grants(
      .init(id: .chatGPTOperate, allowedCallers: [.secureTunnel]),
      names: .init(projects: ["p1": "Project"]), limits: try Self.limits(),
      trustedHosts: ["github.com", "*.example.org"])
    let project = try #require(rows.first { $0.object?.id == "p1" })
    for includesTrusted in [false, true] {
      #expect(
        project.allowsNetwork(
          .custom(hosts: ["github.com", "api.example.org"], includesTrusted: includesTrusted)))
      #expect(
        !project.allowsNetwork(
          .custom(hosts: ["untrusted.example"], includesTrusted: includesTrusted)))
    }
    #expect(!project.allowsNetwork(.custom(hosts: ["*.github.com"], includesTrusted: false)))
  }

  @Test func principalCatalogIncludesEveryPermissionAndKnownObject() {
    let rows = LivePrivacySecurityService.grants(
      .init(id: .chatGPTOperate, allowedCallers: [.secureTunnel]),
      names: .init(
        projects: ["p1": "Project"],
        plugins: ["plugin": "Plugin"], mcpServers: ["server": "Server"]))
    #expect(rows.allSatisfy { $0.value == .ask && !$0.isStored })
    #expect(
      rows.allSatisfy {
        $0.availableLevels == $0.permission.grantedValues && $0.limitNotices.isEmpty
      })
    #expect(
      Set(rows.map(\.permission))
        == Set(PrivacyPermissionKind.allCases.filter { $0 != .fullAccess }))
    #expect(
      rows.filter { $0.permission == .filesAndFolders }.count == FolderCategory.allCases.count)
    #expect(rows.contains { $0.permission == .projects && $0.object?.id == "*" })
    #expect(rows.contains { $0.permission == .plugins && $0.object?.id == "plugin" })
    #expect(rows.contains { $0.permission == .mcpServers && $0.object?.id == "server" })
  }

  @Test func inheritedProjectAccessKeepsItsSavedNetworkVisible() async throws {
    let service = PrivacySecurityFake()
    service.current = try Self.inheritedNetworkSnapshot()
    let model = PrivacySecurityModel(service: service)
    await model.refresh()
    let row = try #require(model.snapshot.grants.first { $0.object?.id == "p1" })
    #expect(row.value == .granted(.read))
    #expect(row.choice == .inherited)
    #expect(!row.isStored && row.isNetworkStored)
    #expect(row.network == .full && row.showsNetwork)
    #expect(row.object?.isRegistered == true)
    #expect(model.grants(for: .projects).contains(row))
    #expect(
      PrivacyGrantRow.inheritedTitle(row, using: PrivacyText(locale: Locale(identifier: "en")))
        == "Same as All Projects (Read)")
    let profile = try #require(model.snapshot.reviewedProfiles.first)
    #expect(profile.permissions.entries[.project("p1")] == nil)
    #expect(profile.projectNetworks["p1"]?.configuration == .full)
    #expect(
      Set(profile.projectNetworks.keys).isSubset(
        of: Set(model.snapshot.grants.filter(\.isNetworkStored).compactMap { $0.object?.id })))
  }

  @Test func unregisteredNetworkOnlyProjectRemainsVisibleWithoutAGrant() async throws {
    var profile = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    profile.projectNetworks["retired-project"] = .full
    let service = PrivacySecurityFake()
    service.current.grants = LivePrivacySecurityService.grants(profile, names: .init())
    let model = PrivacySecurityModel(service: service)
    await model.refresh()
    let row = try #require(
      model.grants(for: .projects).first { $0.object?.id == "retired-project" })
    #expect(row.object?.id == "retired-project" && row.object?.name == "retired-project")
    #expect(row.object?.isRegistered == false)
    #expect(row.value == .ask && row.choice == .inherited)
    #expect(row.network == .full && row.showsNetwork)
    #expect(
      PrivacyGrantRow.inheritedTitle(row, using: PrivacyText(locale: Locale(identifier: "en")))
        == "Ask")
    #expect(model.grants(for: .projects).count == 1)
    #expect(
      model.grants(for: .projects, includingUnset: true).contains {
        $0.object?.id == "*" && !$0.isStored
      })
  }

  @Test func inheritedChoicesUseLibraryResolutionForEveryObjectKind() throws {
    var profile = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    try profile.permissions.set(.granted(.read), for: .project("*"))
    try profile.permissions.set(.granted(.use), for: .plugin("*"))
    try profile.permissions.set(.granted(.all), for: .mcpServer("*"))
    try profile.permissions.set(.notGranted, for: .project("p1"))
    try profile.permissions.set(.denied, for: .plugin("plugin"))
    let rows = LivePrivacySecurityService.grants(
      profile,
      names: .init(
        projects: ["p1": "Project"], plugins: ["plugin": "Plugin"], mcpServers: ["server": "Server"]
      ))
    let project = try #require(rows.first { $0.object?.id == "p1" })
    #expect(project.value == .ask && project.choice == .explicit(.ask))
    #expect(project.inheritedValue == .granted(.read))
    #expect(!project.showsNetwork)
    let plugin = try #require(rows.first { $0.object?.id == "plugin" })
    #expect(plugin.value == .denied && plugin.choice == .explicit(.denied))
    #expect(plugin.inheritedValue == .granted(.use))
    let server = try #require(rows.first { $0.object?.id == "server" })
    #expect(server.value == .granted(.all) && server.choice == .inherited)
    let l = PrivacyText(locale: Locale(identifier: "en"))
    #expect(PrivacyGrantRow.inheritedTitle(plugin, using: l) == "Same as All Plugins (Use)")
    #expect(PrivacyGrantRow.inheritedTitle(server, using: l) == "Same as All MCP Servers (All)")
  }

  private static func inheritedNetworkSnapshot() throws -> PrivacySnapshot {
    var profile = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    try profile.permissions.set(.granted(.read), for: .project("*"))
    profile.projectNetworks["p1"] = .full
    profile.projectNetworks["retired-project"] = .trusted
    return PrivacySnapshot(
      reviewedProfiles: [profile],
      principals: [
        .init(
          id: profile.id.rawValue, name: "ChatGPT", kind: .client(connection: "Secure Tunnel"),
          execution: .sandbox, fullAccessLimitSources: ["Owner Policy"])
      ],
      grants: LivePrivacySecurityService.grants(
        profile, names: .init(projects: ["p1": "Project"]),
        limits: [ManagedLimits(owner: .unreadable)]), suspendedForReview: true)
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

  @Test func clientPluginUseDescribesExactAndWildcardExecution() async throws {
    let client = PrivacyPrincipal(
      id: "client", name: "Client", kind: .client(connection: "Secure Tunnel"), execution: .sandbox)
    let sandbox = PrivacyPrincipal(
      id: "plugin/sandbox", name: "Sandbox Fixture", kind: .plugin(version: "1"),
      execution: .fullAccessAllowed, providerAvailability: .active, effectiveExecution: .sandbox)
    let fullAccess = PrivacyPrincipal(
      id: "plugin/full", name: "Full Access Fixture", kind: .plugin(version: "1"),
      execution: .sandbox, providerAvailability: .active, effectiveExecution: .fullAccessAllowed)
    let blocked = PrivacyPrincipal(
      id: "plugin/blocked", name: "Blocked Fixture", kind: .plugin(version: "1"),
      execution: .fullAccessAllowed, providerAvailability: .active)
    let inactive = PrivacyPrincipal(
      id: "plugin/inactive", name: "Inactive Fixture", kind: .plugin(version: "1"),
      execution: .fullAccessAllowed, providerAvailability: .needsSourceReview)
    let snapshot = PrivacySnapshot(principals: [client, sandbox, fullAccess, blocked, inactive])
    func request(for objectID: String, from principal: PrivacyPrincipal = client) -> PrivacyRequest
    {
      PrivacyRequest(
        id: "plugin-use", principal: principal, permission: .plugins,
        object: PrivacyObject(id: objectID, name: "Plugin contribution", detail: nil),
        level: .use, purpose: nil, tool: "example.tool", expires: .distantFuture)
    }

    let english = PrivacyText(locale: Locale(identifier: "en"))
    let exact = PrivacySecurityView.pluginExecutionTargets(
      for: request(for: "sandbox"), in: snapshot)
    #expect(exact == [sandbox])
    #expect(
      PrivacyGrantRow.pluginExecutionSummary(for: exact, using: english) == "Execution: Sandbox")
    let wildcard = request(for: "*")
    let matches = PrivacySecurityView.pluginExecutionTargets(for: wildcard, in: snapshot)
    #expect(matches == [sandbox, fullAccess, blocked, inactive])
    #expect(
      PrivacyGrantRow.pluginExecutionSummary(for: matches, using: english)
        == "Sandbox and Full Access (Full Access Fixture) · Execution blocked for Blocked Fixture · Execution unavailable for Inactive Fixture"
    )
    #expect(
      PrivacyGrantRow.pluginExecutionSummary(for: [inactive], using: english)
        == "Execution unavailable")
    #expect(
      PrivacyGrantRow.pluginExecutionSummary(for: [blocked, sandbox], using: english)
        == "Execution: Sandbox · Execution blocked for Blocked Fixture")
    #expect(
      PrivacyGrantRow.pluginExecutionSummary(for: matches, using: english)?.contains(
        fullAccess.name) == true)
    #expect(
      PrivacySecurityView.pluginExecutionTargets(for: request(for: "missing"), in: snapshot).isEmpty
    )
    #expect(
      PrivacySecurityView.pluginExecutionTargets(
        for: request(for: "*", from: sandbox), in: snapshot
      ).isEmpty)

    if ProcessInfo.processInfo.environment["COMPUTER_MCP_UI_SNAPSHOT_DIR"] != nil {
      try await renderLocalizedEnablement(
        PrivacyRequestPrompt(request: wildcard, pluginExecutionTargets: [sandbox, fullAccess]) {
          _ in
        },
        name: "privacy-plugin-use", size: NSSize(width: 340, height: 460),
        headings: ("Sandbox and Full Access", "沙盒与完全访问"),
        controls: ("Only This Time", "仅这一次"))
    }
  }

  @Test func rendersInBothLanguagesAndAppearances() async throws {
    let model = PrivacySecurityModel(service: PrivacySecurityFake())
    await model.refresh()
    let resources = try Self.compiledCatalog()
    defer { try? FileManager.default.removeItem(at: resources.bundleURL) }
    let request = try #require(model.snapshot.requests.first)
    for (locale, dark) in [("en", false), ("en", true), ("zh-Hans", false), ("zh-Hans", true)] {
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
      profile.projectNetworks["p1"] = .full
      var restoredPrincipal = managedPrincipal
      restoredPrincipal.fullAccessLimitSources = ["Owner Policy"]
      managedService.current.principals = [restoredPrincipal]
      managedService.current.grants = LivePrivacySecurityService.grants(
        profile, names: .init(projects: ["p1": "Project"]),
        limits: [ManagedLimits(owner: .unreadable)])
      managedService.current.suspendedForReview = true
      await managedModel.refresh()
      try render(
        NavigationStack {
          PrivacyPrincipalDetailView(model: managedModel, principalID: managedPrincipal.id)
        }.styled(locale, dark, resources),
        size: NSSize(width: 720, height: 1800), appearance: appearance,
        name: "privacy-restored-policy-" + suffix)
      managedService.current.suspendedForReview = false
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
      let inheritedService = PrivacySecurityFake()
      inheritedService.current = try Self.inheritedNetworkSnapshot()
      let inheritedModel = PrivacySecurityModel(service: inheritedService)
      await inheritedModel.refresh()
      try render(
        NavigationStack {
          PrivacyPrincipalDetailView(
            model: inheritedModel, principalID: GatewayProfileID.chatGPTOperate.rawValue)
        }
        .styled(locale, dark, resources),
        size: NSSize(width: 720, height: 1900), appearance: appearance,
        name: "privacy-inherited-network-" + suffix)
      try render(
        NavigationStack {
          PrivacyPermissionDetailView(model: inheritedModel, permission: .projects)
        }
        .styled(locale, dark, resources),
        size: NSSize(width: 720, height: 800), appearance: appearance,
        name: "privacy-inherited-network-permission-" + suffix)
      var networkOnly = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
      networkOnly.projectNetworks["retired-project"] = .full
      inheritedService.current.grants = LivePrivacySecurityService.grants(
        networkOnly, names: .init())
      await inheritedModel.refresh()
      try render(
        NavigationStack {
          PrivacyPermissionDetailView(model: inheritedModel, permission: .projects)
        }
        .styled(locale, dark, resources),
        size: NSSize(width: 720, height: 420), appearance: appearance,
        name: "privacy-unregistered-network-" + suffix)
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
  static func compiledCatalog() throws -> Bundle {
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
  func styled(_ locale: String, _ dark: Bool, _ resources: Bundle) -> some View {
    environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.locale, Locale(identifier: locale))
      .environment(\.localizationResources, resources)
  }
}

@MainActor
func renderLocalizedEnablement(
  _ view: some View, name: String, size: NSSize = NSSize(width: 680, height: 720),
  headings: (en: String, zhHans: String), controls: (en: String, zhHans: String)? = nil,
  scrollToBottom: Bool = false
) async throws {
  let resources = try PrivacySecurityViewTests.compiledCatalog()
  defer { try? FileManager.default.removeItem(at: resources.bundleURL) }
  func comparable(_ text: String) -> String {
    // OCR can read the visually similar 查 as 査.
    let normalized = text.lowercased().replacingOccurrences(of: "査", with: "查")
    return String(
      String.UnicodeScalarView(
        normalized.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
  }
  try #require(comparable(headings.en) != comparable(headings.zhHans))
  for dark in [false, true] {
    let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
    let appearanceName = dark ? "dark" : "light"
    var digests: [SHA256.Digest] = []
    for (language, heading, other, control, otherControl) in [
      ("en", headings.en, headings.zhHans, controls?.en, controls?.zhHans),
      ("zh-Hans", headings.zhHans, headings.en, controls?.zhHans, controls?.en),
    ] {
      let filename = "\(name)-\(language)-\(appearanceName)"
      let png = try render(
        view.styled(language, dark, resources), size: size, appearance: appearance,
        name: filename, scrollToBottom: scrollToBottom)
      let lines = try await Task.detached(priority: .utility) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = language == "en" ? ["en-US"] : ["zh-Hans", "en-US"]
        for (stage, devices) in try request.supportedComputeStageDevices {
          if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
            request.setComputeDevice(cpu, for: stage)
          }
        }
        try VNImageRequestHandler(data: png).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      }.value
      let text = comparable(lines.joined(separator: " "))
      try #require(text.contains(comparable(heading)), "\(filename) rendered \(lines)")
      try #require(!text.contains(comparable(other)), "\(filename) rendered \(lines)")
      if let control, let otherControl {
        try #require(text.contains(comparable(control)), "\(filename) rendered \(lines)")
        try #require(!text.contains(comparable(otherControl)), "\(filename) rendered \(lines)")
      }
      let digest = SHA256.hash(data: png)
      digests.append(digest)
      print("\(filename).png \(digest.map { String(format: "%02x", $0) }.joined()) \(heading)")
    }
    try #require(digests[0] != digests[1], "\(name) \(appearanceName) captures must differ")
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
      execution: .fullAccessAllowed, effectiveExecution: .fullAccessAllowed)
    let codex = PrivacyPrincipal(
      id: "codex", name: "Codex", kind: .plugin(version: "1.4.0"), execution: .sandbox)
    let host = PrivacyObject(
      id: "p1", name: "computer-mcp",
      detail: "/Users/example/Developer/workspace/tools/computer-mcp")
    let site = PrivacyObject(
      id: "p2", name: "computer-mcp.github.io", detail: "/Users/example/Developer/site")
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
          value: .granted(.readWrite), network: PrivacyNetworkAccess.none,
          effectiveValue: .granted(.readWrite)),
        PrivacyGrant(
          principalID: "codex", permission: .projects, object: host, value: .granted(.readWrite),
          network: .custom(hosts: ["api.openai.com", "chatgpt.com"], includesTrusted: false),
          effectiveValue: .granted(.readWrite), source: .pluginDeclaration),
        PrivacyGrant(
          principalID: "claude-code", permission: .projects, object: site, value: .ask),
        PrivacyGrant(
          principalID: "chatgpt", permission: .screen, object: nil, value: .granted(.allow),
          effectiveValue: .granted(.allow)),
        PrivacyGrant(principalID: "chatgpt", permission: .desktopControl, object: nil, value: .ask),
        PrivacyGrant(principalID: "chatgpt", permission: .unifiedLogs, object: nil, value: .denied),
        PrivacyGrant(
          principalID: "chatgpt", permission: .localNetwork, object: nil, value: .denied,
          allowedLevels: [],
          limitNotices: [.init(source: "Machine Policy", effect: .permission(nil))]),
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
