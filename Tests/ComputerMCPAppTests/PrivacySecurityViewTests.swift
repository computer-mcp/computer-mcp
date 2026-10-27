import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ComputerMCPApp

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
        size: NSSize(width: 340, height: 420), appearance: appearance,
        name: "privacy-prompt-" + suffix)
      var registration = request
      registration.registration = .newProject
      try render(
        PrivacyRequestPrompt(request: registration) { _ in }.styled(locale, dark, resources),
        size: NSSize(width: 340, height: 420), appearance: appearance,
        name: "privacy-registration-" + suffix)
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

  func answer(request id: String, with answer: PrivacyRequestAnswer) async throws {
    answers[id] = answer
    current.requests.removeAll { $0.id == id }
  }

  func setGrant(_ grant: PrivacyGrant) async throws {
    current.grants.removeAll { $0.id == grant.id }
    current.grants.append(grant)
  }

  func setNetwork(_ grant: PrivacyGrant, to network: PrivacyNetworkAccess) async throws {
    networkWrites += 1
    if failNetworkSave { throw CancellationError() }
    for index in current.grants.indices where current.grants[index].id == grant.id {
      current.grants[index].network = network
    }
  }

  func revokeAll(principalID: String) async throws {
    for index in current.grants.indices where current.grants[index].principalID == principalID {
      current.grants[index].value = .ask
    }
  }

  func setExecution(principalID: String, to execution: PrivacyPrincipal.Execution) async throws {
    for index in current.principals.indices where current.principals[index].id == principalID {
      current.principals[index].execution = execution
    }
  }

  func confirmRestoredPermissions() async throws { current.suspendedForReview = false }

  func openSystemSettings(for permission: PrivacySystemPermission.Kind) {}

  static var sample: PrivacySnapshot {
    let chatgpt = PrivacyPrincipal(
      id: "chatgpt", name: "ChatGPT", kind: .client(connection: "Secure Tunnel"),
      execution: .sandbox)
    let claude = PrivacyPrincipal(
      id: "claude-code", name: "Claude Code", kind: .client(connection: "This Mac"),
      execution: .fullAccessConnection)
    let codex = PrivacyPrincipal(
      id: "codex", name: "Codex", kind: .plugin(version: "1.4.0"), execution: .sandbox)
    let host = PrivacyObject(
      id: "p1", name: "computer-mcp", detail: "~/Developer/workspace/tools/computer-mcp")
    let site = PrivacyObject(id: "p2", name: "computer-mcp.github.io", detail: "~/Developer/site")
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
